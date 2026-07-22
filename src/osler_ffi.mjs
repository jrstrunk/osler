// Hand-written mirror of `osler/internal`'s primitives and each of
// `osler`'s public parsers (date/time/offset/naive_datetime/datetime), used
// only on the JavaScript target via `@external`. The Erlang target keeps
// using the plain Gleam/BitArray implementation as its fallback body.
//
// Unlike the Gleam version, this never touches `BitArray` at all -- it reads
// character codes directly off the JS string with `charCodeAt`, which is a
// single monomorphic V8 intrinsic with no allocation, instead of going
// through Gleam's general (bit-offset-aware) `BitArray` class, which
// allocates a wrapper object + a `Uint8Array` view and does a method-call
// indirection for every single byte read.
//
// All the internal parse functions read/write through one mutable `state`
// object (cursor `i` plus whichever fields they produce) instead of
// returning `[value, nextIndex]` tuples -- that avoids allocating a small
// array on every single digit group parsed. Only the final successful
// Result payload gets allocated.
import { Ok, Error, toList, NonEmpty } from "./gleam.mjs";
import { Some, None } from "../gleam_stdlib/gleam/option.mjs";
import {
  Date as CalendarDate,
  TimeOfDay,
  January, February, March, April, May, June,
  July, August, September, October, November, December,
} from "../gleam_time/gleam/time/calendar.mjs";
import {
  Ixdtf, Zone, Tag, Parts, Am, Pm,
  Year4,
  Month,
  Month2,
  MonthShortName,
  MonthLongName,
  Day,
  Day2,
  WeekdayNumber,
  WeekdayShortName2,
  WeekdayShortName,
  WeekdayLongName,
  Hour24,
  Hour24Padded,
  Hour12,
  Hour12Padded,
  MeridiemLower,
  MeridiemUpper,
  Minute,
  Minute2,
  Second,
  Second2,
  Milli,
  Micro,
  Nano,
  Offset,
  OffsetZulu,
  OffsetColon,
  OffsetNoColon,
  IsoOffset,
  Gmt,
  ZoneName,
  ExtensionTags,
  Literal,
  Separator,
  TimeSeparator,
  DateTimeSeparator,
  EndOfInput,
  IsoDate,
  IsoTime,
  IsoNaiveDateTime,
} from "./osler/parser.mjs";
import { from_unix_seconds_and_nanoseconds } from "../gleam_time/gleam/time/timestamp.mjs";
import { minutes as duration_minutes } from "../gleam_time/gleam/time/duration.mjs";

const CHAR_0 = 0x30;
const CHAR_9 = 0x39;
const CHAR_COLON = 0x3a;
const CHAR_DOT = 0x2e;
const CHAR_PLUS = 0x2b;
const CHAR_MINUS = 0x2d;
const CHAR_SLASH = 0x2f;
const CHAR_UNDERSCORE = 0x5f;
const CHAR_SPACE = 0x20;
const CHAR_T_UPPER = 0x54;
const CHAR_T_LOWER = 0x74;
const CHAR_Z_UPPER = 0x5a;
const CHAR_Z_LOWER = 0x7a;
const CHAR_LBRACKET = 0x5b;
const CHAR_RBRACKET = 0x5d;
const CHAR_BANG = 0x21;
const CHAR_EQUALS = 0x3d;
const CHAR_A_UPPER = 0x41;
const CHAR_A_LOWER = 0x61;

const POW10 = [
  1000000000, 100000000, 10000000, 1000000, 100000, 10000, 1000, 100, 10, 1,
];

// Shared immutable singletons for the (very common) suffix-free case, so the
// hot path allocates neither a fresh `None` nor an empty list per call.
const SHARED_NONE = new None();
const EMPTY_TAGS = toList([]);

// A shared "fall back to the general parser" sentinel for `fast_timestamp`.
// Safe to reuse: the Gleam caller only checks `instanceof Ok`, never reads the
// error payload, so no per-call `Error` allocation is needed on the miss path.
const FALLBACK = new Error(undefined);

// Days of the (shifted) year before month `am`, i.e. `(153 * am + 2) / 5` for
// `am` in 0..11 -- a lookup that replaces that division in the epoch-seconds
// formula below. `am` is the March-based month index (see `scanCanonicalInstant`).
const DAYS_BEFORE_MONTH = [
  0, 31, 61, 92, 122, 153, 184, 214, 245, 275, 306, 337,
];

function isDigit(c) {
  return c >= CHAR_0 && c <= CHAR_9;
}

function isDateDelim(c) {
  return (
    c === CHAR_MINUS ||
    c === CHAR_SLASH ||
    c === CHAR_DOT ||
    c === CHAR_UNDERSCORE ||
    c === CHAR_SPACE
  );
}

// Returns the parsed value, or undefined on failure. Advances state.i on
// success.
function parse1or2(str, state) {
  const i = state.i;
  const c1 = str.charCodeAt(i);
  if (!isDigit(c1)) return undefined;
  const c2 = str.charCodeAt(i + 1);
  if (isDigit(c2)) {
    state.i = i + 2;
    return (c1 - CHAR_0) * 10 + (c2 - CHAR_0);
  }
  state.i = i + 1;
  return c1 - CHAR_0;
}

function parse2(str, state) {
  const i = state.i;
  const c1 = str.charCodeAt(i);
  const c2 = str.charCodeAt(i + 1);
  if (!isDigit(c1) || !isDigit(c2)) return undefined;
  state.i = i + 2;
  return (c1 - CHAR_0) * 10 + (c2 - CHAR_0);
}

// Sets state.year/month/day and advances state.i on success.
function parseDate(str, state) {
  const i0 = state.i;
  const y1 = str.charCodeAt(i0);
  const y2 = str.charCodeAt(i0 + 1);
  const y3 = str.charCodeAt(i0 + 2);
  const y4 = str.charCodeAt(i0 + 3);
  if (!isDigit(y1) || !isDigit(y2) || !isDigit(y3) || !isDigit(y4)) {
    return false;
  }
  const year =
    (y1 - CHAR_0) * 1000 +
    (y2 - CHAR_0) * 100 +
    (y3 - CHAR_0) * 10 +
    (y4 - CHAR_0);

  const i = i0 + 4;
  const next = str.charCodeAt(i);

  if (isDigit(next)) {
    // Compact form: YYYYMMDD
    const m1 = str.charCodeAt(i);
    const m2 = str.charCodeAt(i + 1);
    const d1 = str.charCodeAt(i + 2);
    const d2 = str.charCodeAt(i + 3);
    if (!isDigit(m1) || !isDigit(m2) || !isDigit(d1) || !isDigit(d2)) {
      return false;
    }
    state.year = year;
    state.month = (m1 - CHAR_0) * 10 + (m2 - CHAR_0);
    state.day = (d1 - CHAR_0) * 10 + (d2 - CHAR_0);
    state.i = i + 4;
    return true;
  }

  if (isDateDelim(next)) {
    const delim = next;
    state.i = i + 1;

    const month = parse1or2(str, state);
    if (month === undefined) return false;

    if (str.charCodeAt(state.i) !== delim) return false;
    state.i += 1;

    const day = parse1or2(str, state);
    if (day === undefined) return false;

    state.year = year;
    state.month = month;
    state.day = day;
    return true;
  }

  return false;
}

// Returns the nanosecond value (0 if there is no fraction), or undefined
// on failure. Advances state.i on success. Digits past the 9th (nanosecond
// precision) are truncated, matching `gleam_time`'s own `parse_rfc3339`
// behavior.
function parseFraction(str, state) {
  if (str.charCodeAt(state.i) !== CHAR_DOT) {
    return 0;
  }

  let j = state.i + 1;
  let acc = 0;
  let count = 0;
  let c;
  while (count < 9 && isDigit((c = str.charCodeAt(j)))) {
    acc = acc * 10 + (c - CHAR_0);
    j += 1;
    count += 1;
  }

  if (count === 0) return undefined; // "." with no digits after it

  while (isDigit(str.charCodeAt(j))) j += 1; // truncate remaining digits

  state.i = j;
  return acc * POW10[count];
}

// Sets state.hour/minute/second/nanosecond and advances state.i on
// success.
function parseTime(str, state) {
  const hour = parse1or2(str, state);
  if (hour === undefined) return false;

  if (str.charCodeAt(state.i) === CHAR_COLON) {
    state.i += 1;
    const minute = parse1or2(str, state);
    if (minute === undefined) return false;

    if (str.charCodeAt(state.i) === CHAR_COLON) {
      state.i += 1;
      const second = parse1or2(str, state);
      if (second === undefined) return false;

      const nanosecond = parseFraction(str, state);
      if (nanosecond === undefined) return false;

      state.hour = hour;
      state.minute = minute;
      state.second = second;
      state.nanosecond = nanosecond;
      return true;
    }

    state.hour = hour;
    state.minute = minute;
    state.second = 0;
    state.nanosecond = 0;
    return true;
  }

  if (isDigit(str.charCodeAt(state.i))) {
    // Compact form: HHMM or HHMMSS(.frac)
    const minute = parse2(str, state);
    if (minute === undefined) return false;

    if (isDigit(str.charCodeAt(state.i))) {
      const second = parse2(str, state);
      if (second === undefined) return false;

      const nanosecond = parseFraction(str, state);
      if (nanosecond === undefined) return false;

      state.hour = hour;
      state.minute = minute;
      state.second = second;
      state.nanosecond = nanosecond;
      return true;
    }

    if (str.charCodeAt(state.i) === CHAR_DOT) return false;

    state.hour = hour;
    state.minute = minute;
    state.second = 0;
    state.nanosecond = 0;
    return true;
  }

  return false;
}

// Sets state.offsetMinutes and advances state.i on success.
function parseOffset(str, state) {
  const c = str.charCodeAt(state.i);

  if (c === CHAR_Z_UPPER || c === CHAR_Z_LOWER) {
    state.i += 1;
    state.offsetMinutes = 0;
    return true;
  }

  if (c === CHAR_PLUS || c === CHAR_MINUS) {
    const sign = c === CHAR_MINUS ? -1 : 1;
    state.i += 1;

    const b1 = str.charCodeAt(state.i);
    if (!isDigit(b1)) return false;
    state.i += 1;

    let hour;
    let minute;
    const b2 = str.charCodeAt(state.i);
    if (isDigit(b2)) {
      hour = (b1 - CHAR_0) * 10 + (b2 - CHAR_0);
      state.i += 1;

      if (str.charCodeAt(state.i) === CHAR_COLON) {
        state.i += 1;
        const m = parse2(str, state);
        if (m === undefined) return false;
        minute = m;
      } else if (isDigit(str.charCodeAt(state.i))) {
        const m = parse2(str, state);
        if (m === undefined) return false;
        minute = m;
      } else {
        minute = 0;
      }
    } else {
      hour = b1 - CHAR_0;
      minute = 0;
    }

    if (hour > 24 || minute > 60) return false;

    state.offsetMinutes = sign * (hour * 60 + minute);
    return true;
  }

  return false;
}

function isDatetimeSep(c) {
  return (
    c === CHAR_T_UPPER ||
    c === CHAR_T_LOWER ||
    c === CHAR_UNDERSCORE ||
    c === CHAR_SPACE
  );
}

// --- RFC 9557 (IXDTF) suffix parsing ---------------------------------------
//
// Hand mirror of `osler/internal`'s suffix parser. After the RFC 3339
// date-time (with its required offset), an IXDTF string may carry a suffix:
//
//   suffix     = [time-zone] *suffix-tag
//   time-zone  = "[" critical-flag (time-zone-name / time-numoffset) "]"
//   suffix-tag = "[" critical-flag suffix-key "=" suffix-values "]"
//
// The zone name and each tag's key/value are captured verbatim so the suffix
// can be reproduced losslessly.

function isAlpha(c) {
  return (
    (c >= CHAR_A_UPPER && c <= CHAR_Z_UPPER) ||
    (c >= CHAR_A_LOWER && c <= CHAR_Z_LOWER)
  );
}

function isLcalpha(c) {
  return c >= CHAR_A_LOWER && c <= CHAR_Z_LOWER;
}

function isAlphaNum(c) {
  return isAlpha(c) || isDigit(c);
}

// time-zone-initial = ALPHA / "." / "_"
function isZoneInitial(c) {
  return isAlpha(c) || c === CHAR_DOT || c === CHAR_UNDERSCORE;
}

// time-zone-char = time-zone-initial / DIGIT / "-" / "+"
function isZoneChar(c) {
  return isZoneInitial(c) || isDigit(c) || c === CHAR_MINUS || c === CHAR_PLUS;
}

// key-initial = lcalpha / "_"
function isKeyInitial(c) {
  return isLcalpha(c) || c === CHAR_UNDERSCORE;
}

// key-char = key-initial / DIGIT / "-"
function isKeyChar(c) {
  return isKeyInitial(c) || isDigit(c) || c === CHAR_MINUS;
}

// time-numoffset = ("+" / "-") time-hour ":" time-minute -- exactly `±HH:MM`.
function validNumoffset(s) {
  if (s.length !== 6) return false;
  const c0 = s.charCodeAt(0);
  return (
    (c0 === CHAR_PLUS || c0 === CHAR_MINUS) &&
    isDigit(s.charCodeAt(1)) &&
    isDigit(s.charCodeAt(2)) &&
    s.charCodeAt(3) === CHAR_COLON &&
    isDigit(s.charCodeAt(4)) &&
    isDigit(s.charCodeAt(5))
  );
}

// suffix-key = key-initial *key-char
function validKey(s) {
  const n = s.length;
  if (n === 0 || !isKeyInitial(s.charCodeAt(0))) return false;
  for (let i = 1; i < n; i += 1) {
    if (!isKeyChar(s.charCodeAt(i))) return false;
  }
  return true;
}

// suffix-values = suffix-value *("-" suffix-value); suffix-value = 1*alphanum.
function validValues(s) {
  const n = s.length;
  if (n === 0) return false;
  let needAlnum = true;
  for (let i = 0; i < n; i += 1) {
    const c = s.charCodeAt(i);
    if (isAlphaNum(c)) {
      needAlnum = false;
    } else if (c === CHAR_MINUS && !needAlnum) {
      needAlnum = true;
    } else {
      return false;
    }
  }
  return !needAlnum;
}

// time-zone-name = time-zone-part *("/" time-zone-part); a part must not be
// "." or ".." (but "..." and longer are allowed by the ABNF).
function validZoneName(s) {
  const n = s.length;
  let i = 0;
  for (;;) {
    if (i >= n || !isZoneInitial(s.charCodeAt(i))) return false;
    let len = 0;
    let dots = 0;
    while (i < n) {
      const c = s.charCodeAt(i);
      if (!isZoneChar(c)) break;
      if (c === CHAR_DOT) dots += 1;
      len += 1;
      i += 1;
    }
    if (len === dots && len <= 2) return false;
    if (i >= n) return true;
    if (s.charCodeAt(i) === CHAR_SLASH) {
      i += 1;
      continue;
    }
    return false;
  }
}

// The bracket content before a `]` is either an offset time zone (starts with
// `+`/`-`) or an IANA-style time-zone-name. Returns the name, or null.
function validateZoneToken(token) {
  if (token.length === 0) return null;
  const c0 = token.charCodeAt(0);
  if (c0 === CHAR_PLUS || c0 === CHAR_MINUS) {
    return validNumoffset(token) ? token : null;
  }
  return validZoneName(token) ? token : null;
}

// Scans a tag value up to its closing `]`, validates it, and advances past
// the `]`. Returns the value string, or null.
function scanValue(str, state, len) {
  const start = state.i;
  while (state.i < len && str.charCodeAt(state.i) !== CHAR_RBRACKET) {
    state.i += 1;
  }
  if (state.i >= len) return null;
  const value = str.slice(start, state.i);
  state.i += 1;
  return validValues(value) ? value : null;
}

// Parses every `[key=value]` tag from state.i to the end, pushing onto `tags`.
// Returns false on any malformed group or trailing junk.
function parseTags(str, state, len, tags) {
  while (state.i < len) {
    if (str.charCodeAt(state.i) !== CHAR_LBRACKET) return false;
    state.i += 1;

    let critical = false;
    if (str.charCodeAt(state.i) === CHAR_BANG) {
      critical = true;
      state.i += 1;
    }

    const start = state.i;
    let c;
    for (;;) {
      if (state.i >= len) return false;
      c = str.charCodeAt(state.i);
      if (c === CHAR_EQUALS || c === CHAR_RBRACKET) break;
      state.i += 1;
    }
    const key = str.slice(start, state.i);
    state.i += 1;

    // A later group with no `=` would be a second time-zone (forbidden).
    if (c !== CHAR_EQUALS || !validKey(key)) return false;
    const value = scanValue(str, state, len);
    if (value === null) return false;
    tags.push(new Tag(critical, key, value));
  }
  return true;
}

// Parses the whole suffix from state.i. Returns { zone, tags } (Gleam values)
// or null on any structural failure.
function parseSuffix(str, state) {
  const len = str.length;
  if (state.i === len) {
    return { zone: SHARED_NONE, tags: EMPTY_TAGS };
  }
  if (str.charCodeAt(state.i) !== CHAR_LBRACKET) return null;
  state.i += 1;

  let critical = false;
  if (str.charCodeAt(state.i) === CHAR_BANG) {
    critical = true;
    state.i += 1;
  }

  const start = state.i;
  let c;
  for (;;) {
    if (state.i >= len) return null;
    c = str.charCodeAt(state.i);
    if (c === CHAR_EQUALS || c === CHAR_RBRACKET) break;
    state.i += 1;
  }
  const token = str.slice(start, state.i);
  state.i += 1;

  const tags = [];
  let zone;
  if (c === CHAR_RBRACKET) {
    // No `=` in the first group -> it is the time-zone.
    const name = validateZoneToken(token);
    if (name === null) return null;
    zone = new Some(new Zone(critical, name));
  } else {
    // `=` present -> the first group is a tag and there is no time-zone.
    if (!validKey(token)) return null;
    const value = scanValue(str, state, len);
    if (value === null) return null;
    tags.push(new Tag(critical, token, value));
    zone = new None();
  }

  if (!parseTags(str, state, len, tags)) return null;
  return { zone, tags: toList(tags) };
}

// Fast path for the overwhelmingly common canonical shape:
//
//   YYYY-MM-DD (T|t|_|space) HH:MM:SS[.frac] (Z|z|±HH:MM)   with no suffix
//
// It is a single flat scan over locals (no `state` object, no per-field
// helper calls) and reuses the shared empty-suffix singletons, so it never
// allocates until the final `Ok(Ixdtf)`. Anything that deviates -- a compact
// form, a short/no-colon offset, any RFC 9557 suffix, or malformed input --
// returns `null` and lets the fully general parser below handle it. The two
// paths are kept behaviorally identical (verified by fuzzing); this only
// removes overhead from the case that dominates real input.
//
// Digit tests use `>= 0 && <= 9` (not the `(c >>> 0) > 9` trick): past the
// end of the string `charCodeAt` yields `NaN`, and `NaN >>> 0` is `0`, which
// would read as a digit and spin the fraction loop forever. `NaN >= 0` is
// `false`, so this form stops correctly at end-of-input.
function parseIxdtfFast(str) {
  const n = str.length;

  const y1 = str.charCodeAt(0) - CHAR_0;
  const y2 = str.charCodeAt(1) - CHAR_0;
  const y3 = str.charCodeAt(2) - CHAR_0;
  const y4 = str.charCodeAt(3) - CHAR_0;
  if ((y1 | y2 | y3 | y4) < 0 || y1 > 9 || y2 > 9 || y3 > 9 || y4 > 9) {
    return null;
  }
  const year = y1 * 1000 + y2 * 100 + y3 * 10 + y4;
  if (str.charCodeAt(4) !== CHAR_MINUS) return null;

  const mo1 = str.charCodeAt(5) - CHAR_0;
  const mo2 = str.charCodeAt(6) - CHAR_0;
  if (mo1 < 0 || mo1 > 9 || mo2 < 0 || mo2 > 9) return null;
  if (str.charCodeAt(7) !== CHAR_MINUS) return null;

  const d1 = str.charCodeAt(8) - CHAR_0;
  const d2 = str.charCodeAt(9) - CHAR_0;
  if (d1 < 0 || d1 > 9 || d2 < 0 || d2 > 9) return null;
  const month = mo1 * 10 + mo2;
  const day = d1 * 10 + d2;

  let c = str.charCodeAt(10);
  if (!isDatetimeSep(c)) return null;

  const h1 = str.charCodeAt(11) - CHAR_0;
  const h2 = str.charCodeAt(12) - CHAR_0;
  if (h1 < 0 || h1 > 9 || h2 < 0 || h2 > 9) return null;
  if (str.charCodeAt(13) !== CHAR_COLON) return null;

  const mi1 = str.charCodeAt(14) - CHAR_0;
  const mi2 = str.charCodeAt(15) - CHAR_0;
  if (mi1 < 0 || mi1 > 9 || mi2 < 0 || mi2 > 9) return null;
  if (str.charCodeAt(16) !== CHAR_COLON) return null;

  const s1 = str.charCodeAt(17) - CHAR_0;
  const s2 = str.charCodeAt(18) - CHAR_0;
  if (s1 < 0 || s1 > 9 || s2 < 0 || s2 > 9) return null;
  const hour = h1 * 10 + h2;
  const minute = mi1 * 10 + mi2;
  const second = s1 * 10 + s2;

  let i = 19;
  let nanosecond = 0;
  c = str.charCodeAt(19);
  if (c === CHAR_DOT) {
    let j = 20;
    let acc = 0;
    let count = 0;
    let cc;
    while (count < 9 && (cc = str.charCodeAt(j) - CHAR_0) >= 0 && cc <= 9) {
      acc = acc * 10 + cc;
      j += 1;
      count += 1;
    }
    if (count === 0) return null; // "." with no digits
    while ((cc = str.charCodeAt(j) - CHAR_0) >= 0 && cc <= 9) j += 1; // truncate
    nanosecond = acc * POW10[count];
    i = j;
    c = str.charCodeAt(i);
  }

  let offsetMinutes;
  if (c === CHAR_Z_UPPER || c === CHAR_Z_LOWER) {
    offsetMinutes = 0;
    i += 1;
  } else if (c === CHAR_PLUS || c === CHAR_MINUS) {
    const sign = c === CHAR_MINUS ? -1 : 1;
    const oh1 = str.charCodeAt(i + 1) - CHAR_0;
    const oh2 = str.charCodeAt(i + 2) - CHAR_0;
    if (oh1 < 0 || oh1 > 9 || oh2 < 0 || oh2 > 9) return null;
    if (str.charCodeAt(i + 3) !== CHAR_COLON) return null;
    const om1 = str.charCodeAt(i + 4) - CHAR_0;
    const om2 = str.charCodeAt(i + 5) - CHAR_0;
    if (om1 < 0 || om1 > 9 || om2 < 0 || om2 > 9) return null;
    const oh = oh1 * 10 + oh2;
    const om = om1 * 10 + om2;
    if (oh > 24 || om > 60) return null;
    offsetMinutes = sign * (oh * 60 + om);
    i += 6;
  } else {
    return null;
  }

  if (i !== n) return null; // any suffix (or trailing junk) -> general parser

  return new Ok(
    new Ixdtf(
      year,
      month,
      day,
      hour,
      minute,
      second,
      nanosecond,
      offsetMinutes,
      SHARED_NONE,
      EMPTY_TAGS,
    ),
  );
}

export function parse_ixdtf(str) {
  const fast = parseIxdtfFast(str);
  if (fast !== null) return fast;

  const state = { i: 0 };
  if (!parseDate(str, state)) return new Error(undefined);

  if (!isDatetimeSep(str.charCodeAt(state.i))) return new Error(undefined);
  state.i += 1;

  if (!parseTime(str, state)) return new Error(undefined);
  if (!parseOffset(str, state)) return new Error(undefined);

  const suffix = parseSuffix(str, state);
  if (suffix === null) return new Error(undefined);

  return new Ok(
    new Ixdtf(
      state.year,
      state.month,
      state.day,
      state.hour,
      state.minute,
      state.second,
      state.nanosecond,
      state.offsetMinutes,
      suffix.zone,
      suffix.tags,
    ),
  );
}

// --- Fused parse+validate paths (JS `osler.parse_timestamp` / `parse_ixdtf`) -
//
// `scanCanonicalInstant` parses AND validates AND computes the epoch seconds of
// the canonical suffix-free shape in a single pass, never allocating the
// intermediate `Ixdtf` the two-step path pays for. `fast_timestamp` and
// `fast_ixdtf` share it and differ only in how they wrap the result -- this is
// what lets the fully-validated JS paths beat `Temporal.Instant.from`.
//
// They succeed ONLY for a canonical, fully-valid input; for anything else --
// non-canonical shape, any suffix, or a failed calendar/time check -- they
// return the `FALLBACK` sentinel so the Gleam caller drops to the general body.
// (A canonical-but-invalid input is simply re-decided as `Error` by the slow
// path -- correct, just off the hot path.)

function isLeapYear(y) {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

function daysInMonth(month, year) {
  switch (month) {
    case 1: case 3: case 5: case 7: case 8: case 10: case 12:
      return 31;
    case 4: case 6: case 9: case 11:
      return 30;
    case 2:
      return isLeapYear(year) ? 29 : 28;
    default:
      return 0; // invalid month -> no day can be <= 0
  }
}

// Filled by `scanCanonicalInstant` on success and read back by its callers.
// Reused across calls (single-threaded JS) so the scan allocates nothing; the
// same mutable-state technique the rest of this file already uses.
const INSTANT = { seconds: 0, nanosecond: 0, offsetMinutes: 0 };

// Returns true and fills `INSTANT` on a canonical, fully-valid parse; false to
// signal "fall back". Kept allocation-free so both fused paths stay hot.
function scanCanonicalInstant(str) {
  const n = str.length;

  const y1 = str.charCodeAt(0) - CHAR_0;
  const y2 = str.charCodeAt(1) - CHAR_0;
  const y3 = str.charCodeAt(2) - CHAR_0;
  const y4 = str.charCodeAt(3) - CHAR_0;
  if ((y1 | y2 | y3 | y4) < 0 || y1 > 9 || y2 > 9 || y3 > 9 || y4 > 9) return false;
  const year = y1 * 1000 + y2 * 100 + y3 * 10 + y4;
  if (str.charCodeAt(4) !== CHAR_MINUS) return false;

  const mo1 = str.charCodeAt(5) - CHAR_0;
  const mo2 = str.charCodeAt(6) - CHAR_0;
  if (mo1 < 0 || mo1 > 9 || mo2 < 0 || mo2 > 9) return false;
  if (str.charCodeAt(7) !== CHAR_MINUS) return false;

  const d1 = str.charCodeAt(8) - CHAR_0;
  const d2 = str.charCodeAt(9) - CHAR_0;
  if (d1 < 0 || d1 > 9 || d2 < 0 || d2 > 9) return false;
  const month = mo1 * 10 + mo2;
  const day = d1 * 10 + d2;

  let c = str.charCodeAt(10);
  if (!isDatetimeSep(c)) return false;

  const h1 = str.charCodeAt(11) - CHAR_0;
  const h2 = str.charCodeAt(12) - CHAR_0;
  if (h1 < 0 || h1 > 9 || h2 < 0 || h2 > 9) return false;
  if (str.charCodeAt(13) !== CHAR_COLON) return false;

  const mi1 = str.charCodeAt(14) - CHAR_0;
  const mi2 = str.charCodeAt(15) - CHAR_0;
  if (mi1 < 0 || mi1 > 9 || mi2 < 0 || mi2 > 9) return false;
  if (str.charCodeAt(16) !== CHAR_COLON) return false;

  const s1 = str.charCodeAt(17) - CHAR_0;
  const s2 = str.charCodeAt(18) - CHAR_0;
  if (s1 < 0 || s1 > 9 || s2 < 0 || s2 > 9) return false;
  const hour = h1 * 10 + h2;
  const minute = mi1 * 10 + mi2;
  const second = s1 * 10 + s2;

  let i = 19;
  let nanosecond = 0;
  c = str.charCodeAt(19);
  if (c === CHAR_DOT) {
    let j = 20;
    let acc = 0;
    let count = 0;
    let cc;
    while (count < 9 && (cc = str.charCodeAt(j) - CHAR_0) >= 0 && cc <= 9) {
      acc = acc * 10 + cc;
      j += 1;
      count += 1;
    }
    if (count === 0) return false;
    while ((cc = str.charCodeAt(j) - CHAR_0) >= 0 && cc <= 9) j += 1;
    nanosecond = acc * POW10[count];
    i = j;
    c = str.charCodeAt(i);
  }

  let offsetMinutes;
  if (c === CHAR_Z_UPPER || c === CHAR_Z_LOWER) {
    offsetMinutes = 0;
    i += 1;
  } else if (c === CHAR_PLUS || c === CHAR_MINUS) {
    const sign = c === CHAR_MINUS ? -1 : 1;
    const oh1 = str.charCodeAt(i + 1) - CHAR_0;
    const oh2 = str.charCodeAt(i + 2) - CHAR_0;
    if (oh1 < 0 || oh1 > 9 || oh2 < 0 || oh2 > 9) return false;
    if (str.charCodeAt(i + 3) !== CHAR_COLON) return false;
    const om1 = str.charCodeAt(i + 4) - CHAR_0;
    const om2 = str.charCodeAt(i + 5) - CHAR_0;
    if (om1 < 0 || om1 > 9 || om2 < 0 || om2 > 9) return false;
    const oh = oh1 * 10 + oh2;
    const om = om1 * 10 + om2;
    if (oh > 24 || om > 60) return false;
    offsetMinutes = sign * (oh * 60 + om);
    i += 6;
  } else {
    return false;
  }

  if (i !== n) return false; // a suffix is present -> let the general path decide

  // Calendar/time validation, matching `osler`'s `valid_date`/`is_valid_time`
  // (leap-aware day count; the `24:00:00` and `23:59:60` special cases).
  if (day < 1 || day > daysInMonth(month, year)) return false;
  const timeOk =
    (hour <= 23 && minute <= 59 && second <= 59) ||
    (hour === 24 && minute === 0 && second === 0) ||
    (hour === 23 && minute === 59 && second === 60);
  if (!timeOk) return false;

  // Seconds since the Unix epoch. Same Julian-day result as `osler`'s
  // `seconds_since_epoch` (byte-identical `Timestamp`), but with the five
  // integer divisions of that formula reduced to one: `adjustment` is a
  // `month <= 2` test, `(153*am+2)/5` is the `DAYS_BEFORE_MONTH` lookup, and --
  // since `ay > 0` always -- `ay/4` is `ay >> 2` while `ay/400` is `(ay/100) >> 2`
  // by the nested-floor identity `floor(floor(x/100)/4) === floor(x/400)`. The
  // one surviving division (`ay/100`) V8 already strength-reduces to a multiply.
  // Verified bit-identical to the direct formula across every date 0000-9999.
  const adjustment = month <= 2 ? 1 : 0;
  const ay = year + 4800 - adjustment;
  const am = month + 12 * adjustment - 3;
  const ayDiv100 = Math.trunc(ay / 100);
  const julianDay =
    day +
    DAYS_BEFORE_MONTH[am] +
    365 * ay +
    (ay >> 2) -
    ayDiv100 +
    (ayDiv100 >> 2) -
    32045;
  INSTANT.seconds =
    julianDay * 86400 +
    hour * 3600 +
    minute * 60 +
    second -
    210866803200 -
    offsetMinutes * 60;
  INSTANT.nanosecond = nanosecond;
  INSTANT.offsetMinutes = offsetMinutes;
  return true;
}

export function fast_timestamp(str) {
  if (!scanCanonicalInstant(str)) return FALLBACK;
  return new Ok(
    from_unix_seconds_and_nanoseconds(INSTANT.seconds, INSTANT.nanosecond),
  );
}

export function fast_ixdtf(str) {
  if (!scanCanonicalInstant(str)) return FALLBACK;
  // Mirrors `osler.parse_ixdtf`'s success tuple `#(Timestamp, Duration, zone,
  // tags)`; canonical input is suffix-free, so zone is `None` and tags empty.
  return new Ok([
    from_unix_seconds_and_nanoseconds(INSTANT.seconds, INSTANT.nanosecond),
    duration_minutes(INSTANT.offsetMinutes),
    SHARED_NONE,
    EMPTY_TAGS,
  ]);
}

// --- Custom format engine ---------------------------------------------------
//
// Hand mirror of `osler/parser`'s directive-driven `parse`/`format`. A format
// is a Gleam `List(Directive)`; directives are dispatched on their variant
// name (`d.constructor.name`), which Gleam's non-minified JS codegen keeps
// stable. `Parts` fields are Gleam `Option`s, so absent stays distinct from
// zero.

function some(v) {
  return new Some(v);
}

function optVal(o) {
  return o instanceof Some ? o[0] : undefined;
}

const MONTHS_SHORT = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const MONTHS_LONG = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];
const WEEKDAY_2 = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
const WEEKDAY_3 = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const WEEKDAY_LONG = [
  "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
];
// index 1..7 = Mon..Sun (ISO)
const WEEKDAY_SHORT_ISO = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const WEEKDAY_LONG_ISO = [
  "", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  "Sunday",
];

// exactly n digits
function parseN(str, state, n) {
  let acc = 0;
  for (let k = 0; k < n; k += 1) {
    const c = str.charCodeAt(state.i + k);
    if (!isDigit(c)) return undefined;
    acc = acc * 10 + (c - CHAR_0);
  }
  state.i += n;
  return acc;
}

// try each name in `table` at the cursor; returns its index (0-based) or -1
function matchName(str, state, table) {
  for (let k = 0; k < table.length; k += 1) {
    if (str.startsWith(table[k], state.i)) {
      state.i += table[k].length;
      return k;
    }
  }
  return -1;
}

// Optional leading RFC 9557 zone group. Returns {zone} (Zone or undefined) or
// null on a malformed zone.
function parseOptionalZone(str, state) {
  const len = str.length;
  if (str.charCodeAt(state.i) !== CHAR_LBRACKET) return { zone: undefined };
  const save = state.i;
  state.i += 1;
  let critical = false;
  if (str.charCodeAt(state.i) === CHAR_BANG) {
    critical = true;
    state.i += 1;
  }
  const start = state.i;
  let c;
  for (;;) {
    if (state.i >= len) return null;
    c = str.charCodeAt(state.i);
    if (c === CHAR_EQUALS || c === CHAR_RBRACKET) break;
    state.i += 1;
  }
  const tok = str.slice(start, state.i);
  if (c === CHAR_RBRACKET) {
    state.i += 1;
    const name = validateZoneToken(tok);
    if (name === null) return null;
    return { zone: new Zone(critical, name) };
  }
  // `=` -> it is a tag; leave the whole group for the tags directive.
  state.i = save;
  return { zone: undefined };
}

// Run of `[key=value]` tags, stopping at the first non-`[`. Returns an array
// of Tag, or null on a malformed group.
function parseTagRun(str, state) {
  const len = str.length;
  const tags = [];
  while (state.i < len && str.charCodeAt(state.i) === CHAR_LBRACKET) {
    state.i += 1;
    let critical = false;
    if (str.charCodeAt(state.i) === CHAR_BANG) {
      critical = true;
      state.i += 1;
    }
    const start = state.i;
    let c;
    for (;;) {
      if (state.i >= len) return null;
      c = str.charCodeAt(state.i);
      if (c === CHAR_EQUALS || c === CHAR_RBRACKET) break;
      state.i += 1;
    }
    const key = str.slice(start, state.i);
    if (c !== CHAR_EQUALS || !validKey(key)) return null;
    state.i += 1;
    const value = scanValue(str, state, len);
    if (value === null) return null;
    tags.push(new Tag(critical, key, value));
  }
  return tags;
}

function isDateSep(c) {
  return isDateDelim(c);
}

function isTimeSep(c) {
  return c === CHAR_COLON || c === CHAR_UNDERSCORE || c === CHAR_SPACE;
}


// --- directive dispatch ------------------------------------------------------
//
// `stepParse` used to switch on `d.constructor.name`. That cost ~530ns of a
// 3000ns 14-directive parse, for two reasons: `Function.prototype.name` is a
// lazy accessor in V8 rather than a plain slot, and a 35-case string switch is
// a chain of comparisons whose late entries (`Literal`, `IsoDate`) are exactly
// the ones a real format list uses most. Mapping the constructor *object* to a
// dense small integer once, then switching on that, gives V8 a jump table and
// never touches `.name`.
// Built lazily, not at module load: `osler/parser.mjs` imports this module
// for its `@external`s, so the directive classes are still in their temporal
// dead zone while this module's top level runs. One null check per directive
// is a perfectly predicted branch.
let D_TAGS = null;

function buildDTags() {
  D_TAGS = new Map([
  [Year4, 0],
  [Month, 1],
  [Month2, 2],
  [MonthShortName, 3],
  [MonthLongName, 4],
  [Day, 5],
  [Day2, 6],
  [WeekdayNumber, 7],
  [WeekdayShortName2, 8],
  [WeekdayShortName, 9],
  [WeekdayLongName, 10],
  [Hour24, 11],
  [Hour24Padded, 12],
  [Hour12, 13],
  [Hour12Padded, 14],
  [MeridiemLower, 15],
  [MeridiemUpper, 16],
  [Minute, 17],
  [Minute2, 18],
  [Second, 19],
  [Second2, 20],
  [Milli, 21],
  [Micro, 22],
  [Nano, 23],
  [Offset, 24],
  [OffsetZulu, 25],
  [OffsetColon, 26],
  [OffsetNoColon, 27],
  [IsoOffset, 28],
  [Gmt, 29],
  [ZoneName, 30],
  [ExtensionTags, 31],
  [Literal, 32],
  [Separator, 33],
  [TimeSeparator, 34],
  [DateTimeSeparator, 35],
  [EndOfInput, 36],
  [IsoDate, 37],
  [IsoTime, 38],
  [IsoNaiveDateTime, 39],
  ]);
}

const D_YEAR4 = 0;
const D_MONTH = 1;
const D_MONTH2 = 2;
const D_MONTHSHORTNAME = 3;
const D_MONTHLONGNAME = 4;
const D_DAY = 5;
const D_DAY2 = 6;
const D_WEEKDAYNUMBER = 7;
const D_WEEKDAYSHORTNAME2 = 8;
const D_WEEKDAYSHORTNAME = 9;
const D_WEEKDAYLONGNAME = 10;
const D_HOUR24 = 11;
const D_HOUR24PADDED = 12;
const D_HOUR12 = 13;
const D_HOUR12PADDED = 14;
const D_MERIDIEMLOWER = 15;
const D_MERIDIEMUPPER = 16;
const D_MINUTE = 17;
const D_MINUTE2 = 18;
const D_SECOND = 19;
const D_SECOND2 = 20;
const D_MILLI = 21;
const D_MICRO = 22;
const D_NANO = 23;
const D_OFFSET = 24;
const D_OFFSETZULU = 25;
const D_OFFSETCOLON = 26;
const D_OFFSETNOCOLON = 27;
const D_ISOOFFSET = 28;
const D_GMT = 29;
const D_ZONENAME = 30;
const D_EXTENSIONTAGS = 31;
const D_LITERAL = 32;
const D_SEPARATOR = 33;
const D_TIMESEPARATOR = 34;
const D_DATETIMESEPARATOR = 35;
const D_ENDOFINPUT = 36;
const D_ISODATE = 37;
const D_ISOTIME = 38;
const D_ISONAIVEDATETIME = 39;
// One parse directive. Mutates state.i and the `p` scratch object; returns
// false on failure.
function stepParse(d, str, state, p) {
  if (D_TAGS === null) buildDTags();
  switch (D_TAGS.get(d.constructor)) {
    case D_YEAR4: {
      const v = parseN(str, state, 4);
      if (v === undefined) return false;
      p.year = v;
      return true;
    }
    case D_MONTH: {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.month = v;
      return true;
    }
    case D_MONTH2: {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.month = v;
      return true;
    }
    case D_MONTHSHORTNAME: {
      const k = matchName(str, state, MONTHS_SHORT);
      if (k < 0) return false;
      p.month = k + 1;
      return true;
    }
    case D_MONTHLONGNAME: {
      const k = matchName(str, state, MONTHS_LONG);
      if (k < 0) return false;
      p.month = k + 1;
      return true;
    }
    case D_DAY: {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.day = v;
      return true;
    }
    case D_DAY2: {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.day = v;
      return true;
    }
    case D_WEEKDAYNUMBER: {
      const c = str.charCodeAt(state.i);
      if (c < CHAR_0 || c > CHAR_0 + 6) return false;
      state.i += 1;
      return true;
    }
    case D_WEEKDAYSHORTNAME2:
      return matchName(str, state, WEEKDAY_2) >= 0;
    case D_WEEKDAYSHORTNAME:
      return matchName(str, state, WEEKDAY_3) >= 0;
    case D_WEEKDAYLONGNAME:
      return matchName(str, state, WEEKDAY_LONG) >= 0;
    case D_HOUR24: {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.hour = v;
      return true;
    }
    case D_HOUR24PADDED: {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.hour = v;
      return true;
    }
    case D_HOUR12: {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.twelveHour = v;
      return true;
    }
    case D_HOUR12PADDED: {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.twelveHour = v;
      return true;
    }
    case D_MERIDIEMLOWER: {
      if (str.startsWith("am", state.i)) { state.i += 2; p.period = Am; return true; }
      if (str.startsWith("pm", state.i)) { state.i += 2; p.period = Pm; return true; }
      return false;
    }
    case D_MERIDIEMUPPER: {
      if (str.startsWith("AM", state.i)) { state.i += 2; p.period = Am; return true; }
      if (str.startsWith("PM", state.i)) { state.i += 2; p.period = Pm; return true; }
      return false;
    }
    case D_MINUTE: {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.minute = v;
      return true;
    }
    case D_MINUTE2: {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.minute = v;
      return true;
    }
    case D_SECOND: {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.second = v;
      return true;
    }
    case D_SECOND2: {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.second = v;
      return true;
    }
    case D_MILLI: {
      const v = parseN(str, state, 3);
      if (v === undefined) return false;
      p.nanosecond = v * 1000000;
      return true;
    }
    case D_MICRO: {
      const v = parseN(str, state, 6);
      if (v === undefined) return false;
      p.nanosecond = v * 1000;
      return true;
    }
    case D_NANO: {
      const v = parseN(str, state, 9);
      if (v === undefined) return false;
      p.nanosecond = v;
      return true;
    }
    case D_OFFSET:
    case D_OFFSETZULU:
    case D_OFFSETCOLON:
    case D_OFFSETNOCOLON:
    case D_ISOOFFSET: {
      if (!parseOffset(str, state)) return false;
      p.offsetMinutes = state.offsetMinutes;
      return true;
    }
    case D_GMT: {
      if (!str.startsWith("GMT", state.i)) return false;
      state.i += 3;
      p.offsetMinutes = 0;
      return true;
    }
    case D_ZONENAME: {
      const res = parseOptionalZone(str, state);
      if (res === null) return false;
      if (res.zone !== undefined) p.zone = res.zone;
      return true;
    }
    case D_EXTENSIONTAGS: {
      const tags = parseTagRun(str, state);
      if (tags === null) return false;
      p.tags = tags;
      return true;
    }
    case D_LITERAL: {
      const lit = d[0];
      if (!str.startsWith(lit, state.i)) return false;
      state.i += lit.length;
      return true;
    }
    case D_SEPARATOR: {
      if (isDateSep(str.charCodeAt(state.i))) state.i += 1;
      return true;
    }
    case D_TIMESEPARATOR: {
      if (isTimeSep(str.charCodeAt(state.i))) state.i += 1;
      return true;
    }
    case D_DATETIMESEPARATOR: {
      const c = str.charCodeAt(state.i);
      if (
        c === CHAR_T_UPPER || c === CHAR_T_LOWER ||
        c === CHAR_UNDERSCORE || c === CHAR_SPACE
      ) {
        state.i += 1;
        return true;
      }
      return false;
    }
    case D_ENDOFINPUT:
      return state.i === str.length;
    case D_ISODATE: {
      if (!parseDate(str, state)) return false;
      p.year = state.year;
      p.month = state.month;
      p.day = state.day;
      return true;
    }
    case D_ISOTIME: {
      if (!parseTime(str, state)) return false;
      p.hour = state.hour;
      p.minute = state.minute;
      p.second = state.second;
      p.nanosecond = state.nanosecond;
      return true;
    }
    case D_ISONAIVEDATETIME: {
      if (!parseDate(str, state)) return false;
      p.year = state.year;
      p.month = state.month;
      p.day = state.day;
      const c = str.charCodeAt(state.i);
      if (isDatetimeSep(c)) {
        state.i += 1;
        if (!parseTime(str, state)) return false;
        p.hour = state.hour;
        p.minute = state.minute;
        p.second = state.second;
        p.nanosecond = state.nanosecond;
      }
      return true;
    }
    default:
      return false;
  }
}

// `SHARED_NONE`, not `new None()`: an absent field is the common case in a
// real format list (a date-only format leaves eight of the twelve empty), and
// `None` carries no payload, so a fresh one per absent field was pure garbage.
// Same reasoning as the `parse_ixdtf` path, which has used the singleton all
// along -- this function simply never got the treatment.
function optOf(v) {
  return v === undefined ? SHARED_NONE : new Some(v);
}

// Interned `Some` for small non-negative integers.
//
// `new Some(v)` measured ~155ns -- twenty times a 12-field `new Parts(...)` at
// 8ns. The reason is the representation: Gleam gives positional variant fields
// integer keys (`this[0] = x`), and an integer-keyed property lands in V8's
// *elements* backing store, so every `Some` allocates a JSObject **and** a
// FixedArray and takes the indexed-store slow path. Named fields, as `Parts`
// has, are in-object slots. Eight `Some`s were 1586ns of a 2267ns parse -- far
// more than the scanning.
//
// They can safely be shared: a Gleam `Option` is immutable, `==` on it is
// structural (`isEqual`), and no identity comparison is exposed, which is the
// same argument that already justifies `SHARED_NONE`. The table is filled
// lazily, so a program pays only for the values it actually parses.
//
// 4096 covers every time field (month, day, hour, minute, second), positive
// offsets, and the years anyone is realistically parsing. Anything else falls
// through to a fresh `Some`, which is merely the old behaviour.
const SOME_INT_MAX = 4096;
const SOME_INT = new Array(SOME_INT_MAX);

function someInt(v) {
  if (v >= 0 && v < SOME_INT_MAX) {
    const hit = SOME_INT[v];
    if (hit !== undefined) return hit;
    return (SOME_INT[v] = new Some(v));
  }
  return new Some(v);
}

function optInt(v) {
  return v === undefined ? SHARED_NONE : someInt(v);
}

export function parse(input, directives) {
  const state = { i: 0 };
  const p = {};
  // Walk the Gleam list by `head`/`tail` rather than `for...of`. The list's
  // `Symbol.iterator` allocates a `ListIterator` plus a `{value, done}` object
  // per element -- 15 objects to walk 14 directives, ~136ns of a 3000ns parse.
  for (let c = directives; c instanceof NonEmpty; c = c.tail) {
    if (!stepParse(c.head, input, state, p)) return FALLBACK;
  }
  const period =
    p.period === undefined ? SHARED_NONE : new Some(new p.period());
  return new Ok(
    new Parts(
      optInt(p.year),
      optInt(p.month),
      optInt(p.day),
      optInt(p.hour),
      optInt(p.twelveHour),
      period,
      optInt(p.minute),
      optInt(p.second),
      optInt(p.nanosecond),
      optInt(p.offsetMinutes),
      p.zone === undefined ? SHARED_NONE : new Some(p.zone),
      p.tags === undefined ? EMPTY_TAGS : toList(p.tags),
    ),
  );
}

// --- format -----------------------------------------------------------------

function pad(n, width) {
  return String(n).padStart(width, "0");
}

function to12(hour) {
  if (hour === 0) return 12;
  if (hour > 12) return hour - 12;
  return hour;
}

function daysFromCivil(year, month, day) {
  const y = month <= 2 ? year - 1 : year;
  const era = Math.trunc((y >= 0 ? y : y - 399) / 400);
  const yoe = y - era * 400;
  const mp = month > 2 ? month - 3 : month + 9;
  const doy = Math.trunc((153 * mp + 2) / 5) + day - 1;
  const doe = yoe * 365 + Math.trunc(yoe / 4) - Math.trunc(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

function isoWeekday(year, month, day) {
  const days = daysFromCivil(year, month, day);
  const w = (((days + 4) % 7) + 7) % 7;
  return w === 0 ? 7 : w;
}

function renderOffsetHm(minutes, colon) {
  const sign = minutes < 0 ? "-" : "+";
  const abs = Math.abs(minutes);
  const hh = pad(Math.trunc(abs / 60), 2);
  const mm = pad(abs % 60, 2);
  return colon ? sign + hh + ":" + mm : sign + hh + mm;
}

function renderOffsetZulu(minutes) {
  return minutes === 0 ? "Z" : renderOffsetHm(minutes, true);
}

function renderOffsetCondensed(minutes) {
  if (minutes === 0) return "Z";
  const abs = Math.abs(minutes);
  if (abs % 60 === 0) {
    return (minutes < 0 ? "-" : "+") + pad(Math.trunc(abs / 60), 2);
  }
  return renderOffsetHm(minutes, true);
}

function renderFraction(ns) {
  if (ns === 0) return "";
  if (ns % 1000000 === 0) return "." + pad(Math.trunc(ns / 1000000), 3);
  if (ns % 1000 === 0) return "." + pad(Math.trunc(ns / 1000), 6);
  return "." + pad(ns, 9);
}

function weekdayOf(parts) {
  const y = optVal(parts.year);
  const m = optVal(parts.month);
  const d = optVal(parts.day);
  if (y === undefined || m === undefined || d === undefined) return undefined;
  return isoWeekday(y, m, d);
}

function monthName(month, table) {
  return month >= 1 && month <= 12 ? table[month - 1] : undefined;
}

// One render directive. Returns a string, or null on a missing field.
function stepFormat(d, parts) {
  const req = (o) => optVal(o);
  switch (d.constructor.name) {
    case "Year4": { const v = req(parts.year); return v === undefined ? null : pad(v, 4); }
    case "Month": { const v = req(parts.month); return v === undefined ? null : String(v); }
    case "Month2": { const v = req(parts.month); return v === undefined ? null : pad(v, 2); }
    case "MonthShortName": { const v = req(parts.month); if (v === undefined) return null; const n = monthName(v, MONTHS_SHORT); return n === undefined ? null : n; }
    case "MonthLongName": { const v = req(parts.month); if (v === undefined) return null; const n = monthName(v, MONTHS_LONG); return n === undefined ? null : n; }
    case "Day": { const v = req(parts.day); return v === undefined ? null : String(v); }
    case "Day2": { const v = req(parts.day); return v === undefined ? null : pad(v, 2); }
    case "WeekdayNumber": { const w = weekdayOf(parts); return w === undefined ? null : String(w); }
    case "WeekdayShortName2": { const w = weekdayOf(parts); return w === undefined ? null : WEEKDAY_SHORT_ISO[w].slice(0, 2); }
    case "WeekdayShortName": { const w = weekdayOf(parts); return w === undefined ? null : WEEKDAY_SHORT_ISO[w]; }
    case "WeekdayLongName": { const w = weekdayOf(parts); return w === undefined ? null : WEEKDAY_LONG_ISO[w]; }
    case "Hour24": { const v = req(parts.hour); return v === undefined ? null : String(v); }
    case "Hour24Padded": { const v = req(parts.hour); return v === undefined ? null : pad(v, 2); }
    case "Hour12": { const v = req(parts.hour); return v === undefined ? null : String(to12(v)); }
    case "Hour12Padded": { const v = req(parts.hour); return v === undefined ? null : pad(to12(v), 2); }
    case "MeridiemLower": { const v = req(parts.hour); return v === undefined ? null : v >= 12 ? "pm" : "am"; }
    case "MeridiemUpper": { const v = req(parts.hour); return v === undefined ? null : v >= 12 ? "PM" : "AM"; }
    case "Minute": { const v = req(parts.minute); return v === undefined ? null : String(v); }
    case "Minute2": { const v = req(parts.minute); return v === undefined ? null : pad(v, 2); }
    case "Second": { const v = req(parts.second); return v === undefined ? null : String(v); }
    case "Second2": { const v = req(parts.second); return v === undefined ? null : pad(v, 2); }
    case "Milli": { const v = req(parts.nanosecond); return v === undefined ? null : pad(Math.trunc(v / 1000000), 3); }
    case "Micro": { const v = req(parts.nanosecond); return v === undefined ? null : pad(Math.trunc(v / 1000), 6); }
    case "Nano": { const v = req(parts.nanosecond); return v === undefined ? null : pad(v, 9); }
    case "Offset": { const v = req(parts.offset_minutes); return v === undefined ? null : renderOffsetCondensed(v); }
    case "OffsetZulu": { const v = req(parts.offset_minutes); return v === undefined ? null : renderOffsetZulu(v); }
    case "OffsetColon": { const v = req(parts.offset_minutes); return v === undefined ? null : renderOffsetHm(v, true); }
    case "OffsetNoColon": { const v = req(parts.offset_minutes); return v === undefined ? null : renderOffsetHm(v, false); }
    case "Gmt": return "GMT";
    case "ZoneName": {
      const z = parts.zone;
      if (z instanceof Some) {
        const zone = z[0];
        return "[" + (zone.critical ? "!" : "") + zone.name + "]";
      }
      return "";
    }
    case "ExtensionTags": {
      let out = "";
      for (const tag of parts.tags.toArray()) {
        out += "[" + (tag.critical ? "!" : "") + tag.key + "=" + tag.value + "]";
      }
      return out;
    }
    case "Literal": return d[0];
    case "Separator": return "-";
    case "TimeSeparator": return ":";
    case "DateTimeSeparator": return "T";
    case "EndOfInput": return "";
    case "IsoDate": {
      const y = req(parts.year), m = req(parts.month), dd = req(parts.day);
      if (y === undefined || m === undefined || dd === undefined) return null;
      return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(dd, 2);
    }
    case "IsoTime": {
      const h = req(parts.hour), mi = req(parts.minute), s = req(parts.second);
      if (h === undefined || mi === undefined || s === undefined) return null;
      const ns = req(parts.nanosecond);
      return pad(h, 2) + ":" + pad(mi, 2) + ":" + pad(s, 2) + renderFraction(ns === undefined ? 0 : ns);
    }
    case "IsoOffset": { const v = req(parts.offset_minutes); return v === undefined ? null : renderOffsetZulu(v); }
    case "IsoNaiveDateTime": {
      const y = req(parts.year), m = req(parts.month), dd = req(parts.day);
      const h = req(parts.hour), mi = req(parts.minute), s = req(parts.second);
      if (y === undefined || m === undefined || dd === undefined) return null;
      if (h === undefined || mi === undefined || s === undefined) return null;
      const ns = req(parts.nanosecond);
      return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(dd, 2) + "T" +
        pad(h, 2) + ":" + pad(mi, 2) + ":" + pad(s, 2) + renderFraction(ns === undefined ? 0 : ns);
    }
    default:
      return null;
  }
}

export function format(parts, directives) {
  let out = "";
  for (const d of directives) {
    const chunk = stepFormat(d, parts);
    if (chunk === null) return new Error(undefined);
    out += chunk;
  }
  return new Ok(out);
}

// --- parse_any ---------------------------------------------------------------
//
// A charCodeAt mirror of `osler.parse_any`. The Gleam version consumes its
// `BitArray` one byte at a time, and on JS every `<<b, rest:bytes>>` calls
// `bitArraySlice`, which allocates a `Uint8Array` view *and* a `BitArray`
// wrapper -- two heavyweight allocations per byte position, across five
// scanning passes. That was the whole reason `parse_any` ran ~10x slower here
// than on BEAM. This version never slices: it walks indices into the string
// and reads code units, so a rejected position costs a comparison.
//
// Everything below mirrors the Gleam function-for-function, and the two are
// checked against each other over 2244 inputs by `test/differential.gleam`.
// Keep them in step: this is a heuristic, so a divergence shows up as a
// *different guess*, not as an error.
//
// One deliberate difference: the Gleam counts UTF-8 bytes and this counts
// UTF-16 code units, so the two disagree about *indices* on non-ASCII input.
// They still agree about results, because every byte of a non-ASCII UTF-8
// sequence and every unit of a non-ASCII UTF-16 sequence is outside the ASCII
// ranges these scanners test, so both treat such text as an opaque
// non-alphanumeric run. The corpus includes non-ASCII cases to hold that to
// account rather than trust it.

// Scan classes, mirroring `candidate/3`. Each is a *necessary* condition on
// the byte at the cursor and the one before it.
const A_NUMERIC_DATE = 0;
const A_NAMED_DATE = 1;
const A_OFFSET = 2;
const A_ZULU = 3;
const A_TIME = 4;

const CHAR_COMMA = 0x2c;
const CHAR_TAB = 0x09;

// A non-digit, non-alpha byte, seeding `prev` so a component anchored to the
// string start counts as bounded.
const A_BOUNDARY = 0x20;

function aIsDateSep(c) {
  return (
    c === CHAR_MINUS ||
    c === CHAR_SLASH ||
    c === CHAR_DOT ||
    c === CHAR_UNDERSCORE ||
    c === CHAR_SPACE ||
    c === CHAR_COMMA
  );
}

function aToLower(c) {
  return c >= CHAR_A_UPPER && c <= CHAR_Z_UPPER ? c + 32 : c;
}

// `charCodeAt` past the end is NaN, and every comparison against NaN is false,
// which is exactly the "no more bytes" answer the Gleam gives.
function aNotDigitHead(str, i) {
  return !isDigit(str.charCodeAt(i));
}

function aNotAlphaHead(str, i) {
  return !isAlpha(str.charCodeAt(i));
}

function aDropOneSep(str, i) {
  return aIsDateSep(str.charCodeAt(i)) ? i + 1 : i;
}

// Up to two leading separators, as `drop_seps`.
function aDropSeps(str, i) {
  return aDropOneSep(str, aDropOneSep(str, i));
}

function aSkipSpaces(str, i) {
  let c = str.charCodeAt(i);
  while (c === CHAR_SPACE || c === CHAR_TAB) {
    i += 1;
    c = str.charCodeAt(i);
  }
  return i;
}

// Case-insensitive literal match of a lowercase ASCII `pattern`. Returns the
// index after it, or -1.
function aCiPrefix(str, i, pattern) {
  for (let k = 0; k < pattern.length; k += 1) {
    if (aToLower(str.charCodeAt(i + k)) !== pattern.charCodeAt(k)) return -1;
  }
  return i + pattern.length;
}

function aDropOrdinal(str, i) {
  let j = aCiPrefix(str, i, "st");
  if (j >= 0) return j;
  j = aCiPrefix(str, i, "nd");
  if (j >= 0) return j;
  j = aCiPrefix(str, i, "rd");
  if (j >= 0) return j;
  j = aCiPrefix(str, i, "th");
  return j >= 0 ? j : i;
}

// Fixed-width digit reads. `A_END` carries the index after the match, so these
// return a plain number and allocate nothing.
let A_END = 0;

function aDigits(str, i, n) {
  let acc = 0;
  for (let k = 0; k < n; k += 1) {
    const c = str.charCodeAt(i + k);
    if (!isDigit(c)) return -1;
    acc = acc * 10 + (c - CHAR_0);
  }
  A_END = i + n;
  return acc;
}

function aDigits1or2(str, i) {
  const c1 = str.charCodeAt(i);
  if (!isDigit(c1)) return -1;
  const c2 = str.charCodeAt(i + 1);
  if (isDigit(c2)) {
    A_END = i + 2;
    return (c1 - CHAR_0) * 10 + (c2 - CHAR_0);
  }
  A_END = i + 1;
  return c1 - CHAR_0;
}

// --- month names, grouped by first letter, long before short ----------------

const A_MONTHS_J = [["january", 1], ["june", 6], ["july", 7], ["jan", 1],
  ["jun", 6], ["jul", 7]];
const A_MONTHS_F = [["february", 2], ["feb", 2]];
const A_MONTHS_M = [["march", 3], ["may", 5], ["mar", 3]];
const A_MONTHS_A = [["april", 4], ["august", 8], ["apr", 4], ["aug", 8]];
const A_MONTHS_S = [["september", 9], ["sep", 9]];
const A_MONTHS_O = [["october", 10], ["oct", 10]];
const A_MONTHS_N = [["november", 11], ["nov", 11]];
const A_MONTHS_D = [["december", 12], ["dec", 12]];

function aMatchFirst(str, i, table) {
  for (let k = 0; k < table.length; k += 1) {
    const j = aCiPrefix(str, i, table[k][0]);
    if (j >= 0) {
      A_END = j;
      return table[k][1];
    }
  }
  return -1;
}

function aReadMonthName(str, i) {
  switch (aToLower(str.charCodeAt(i))) {
    case 0x6a: return aMatchFirst(str, i, A_MONTHS_J);
    case 0x66: return aMatchFirst(str, i, A_MONTHS_F);
    case 0x6d: return aMatchFirst(str, i, A_MONTHS_M);
    case 0x61: return aMatchFirst(str, i, A_MONTHS_A);
    case 0x73: return aMatchFirst(str, i, A_MONTHS_S);
    case 0x6f: return aMatchFirst(str, i, A_MONTHS_O);
    case 0x6e: return aMatchFirst(str, i, A_MONTHS_N);
    case 0x64: return aMatchFirst(str, i, A_MONTHS_D);
    default: return -1;
  }
}

function aReadMonthToken(str, i) {
  const m = aReadMonthName(str, i);
  return m >= 0 ? m : aDigits1or2(str, i);
}

// --- calendar validation ----------------------------------------------------

function aIsLeapYear(y) {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

function aValidDate(year, month, day) {
  switch (month) {
    case 1: case 3: case 5: case 7: case 8: case 10: case 12:
      return day >= 1 && day <= 31;
    case 4: case 6: case 9: case 11:
      return day >= 1 && day <= 30;
    case 2:
      return (day >= 1 && day <= 28) || (day === 29 && aIsLeapYear(year));
    default:
      return false;
  }
}

function aIsValidTime(hour, minute, second) {
  return (
    (hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 &&
      second >= 0 && second <= 59) ||
    (hour === 24 && minute === 0 && second === 0) ||
    (hour === 23 && minute === 59 && second === 60)
  );
}

// Built lazily for the same reason `D_TAGS` is: keeps module top-level free of
// work and of ordering assumptions.
let A_MONTH_VALUES = null;

function aMonthValue(m) {
  if (A_MONTH_VALUES === null) {
    A_MONTH_VALUES = [
      null, new January(), new February(), new March(), new April(),
      new May(), new June(), new July(), new August(), new September(),
      new October(), new November(), new December(),
    ];
  }
  return A_MONTH_VALUES[m];
}

// --- the five attempts ------------------------------------------------------
//
// Each returns the number of code units consumed, or -1, and leaves its value
// in `A_VALUE`. Mutable scratch rather than a returned pair: the scans run
// strictly one after another, and the point of this module is not allocating.
let A_VALUE = null;

function aFinishDate(year, month, day, start, end) {
  if (year < 1000 || year > 9999) return -1;
  if (!aValidDate(year, month, day)) return -1;
  A_VALUE = new CalendarDate(year, aMonthValue(month), day);
  return end - start;
}

function aTryNumericDate(str, i, prev) {
  if (isDigit(prev)) return -1;
  const year = aDigits(str, i, 4);
  if (year < 0) return -1;
  let j = A_END;
  if (aIsDateSep(str.charCodeAt(j))) {
    j = aDropSeps(str, j);
    const month = aDigits1or2(str, j);
    if (month < 0) return -1;
    j = aDropSeps(str, A_END);
    const day = aDigits1or2(str, j);
    if (day < 0) return -1;
    return aFinishDate(year, month, day, i, A_END);
  }
  // Compact `YYYYMMDD`.
  const month = aDigits(str, j, 2);
  if (month < 0) return -1;
  const day = aDigits(str, j + 2, 2);
  if (day < 0) return -1;
  const after = j + 4;
  if (!aNotDigitHead(str, after)) return -1;
  return aFinishDate(year, month, day, i, after);
}

function aTryNamedDate(str, i, prev) {
  if (isDigit(prev) || isAlpha(prev)) return -1;
  const month = aReadMonthToken(str, i);
  if (month < 0) return -1;
  let j = aDropSeps(str, A_END);
  const day = aDigits1or2(str, j);
  if (day < 0) return -1;
  j = aDropSeps(str, aDropOrdinal(str, A_END));
  const year = aDigits(str, j, 4);
  if (year < 0) return -1;
  j = A_END;
  if (!aNotDigitHead(str, j)) return -1;
  return aFinishDate(year, month, day, i, j);
}

function aTryNumericOffset(str, i) {
  const sign = str.charCodeAt(i);
  if (sign !== CHAR_PLUS && sign !== CHAR_MINUS) return -1;
  const signum = sign === CHAR_MINUS ? -1 : 1;
  const hour = aDigits(str, i + 1, 2);
  if (hour < 0) return -1;
  let j = A_END;
  // `:MM`, a bare `MM`, or nothing.
  let minute;
  if (
    str.charCodeAt(j) === CHAR_COLON &&
    isDigit(str.charCodeAt(j + 1)) && isDigit(str.charCodeAt(j + 2))
  ) {
    minute = (str.charCodeAt(j + 1) - CHAR_0) * 10 +
      (str.charCodeAt(j + 2) - CHAR_0);
    j += 3;
  } else if (isDigit(str.charCodeAt(j)) && isDigit(str.charCodeAt(j + 1))) {
    minute = (str.charCodeAt(j) - CHAR_0) * 10 +
      (str.charCodeAt(j + 1) - CHAR_0);
    j += 2;
  } else {
    minute = 0;
  }
  if (!aNotDigitHead(str, j)) return -1;
  const minutes = signum * (hour * 60 + minute);
  if (minutes < -720 || minutes > 840) return -1;
  A_VALUE = minutes;
  return j - i;
}

function aTryZulu(str, i, prev) {
  if (isAlpha(prev)) return -1;
  const c = str.charCodeAt(i);
  if (c !== CHAR_Z_UPPER && c !== CHAR_Z_LOWER) return -1;
  if (!aNotAlphaHead(str, i + 1)) return -1;
  A_VALUE = 0;
  return 1;
}

// `HHMMSS`, or `HH:MM[:SS]`. `A_HOUR`/`A_MINUTE`/`A_SECOND` carry the fields.
let A_HOUR = 0;
let A_MINUTE = 0;
let A_SECOND = 0;

function aCompactHms(str, i) {
  for (let k = 0; k < 6; k += 1) {
    if (!isDigit(str.charCodeAt(i + k))) return -1;
  }
  if (!aNotDigitHead(str, i + 6)) return -1;
  A_HOUR = (str.charCodeAt(i) - CHAR_0) * 10 + (str.charCodeAt(i + 1) - CHAR_0);
  A_MINUTE = (str.charCodeAt(i + 2) - CHAR_0) * 10 +
    (str.charCodeAt(i + 3) - CHAR_0);
  A_SECOND = (str.charCodeAt(i + 4) - CHAR_0) * 10 +
    (str.charCodeAt(i + 5) - CHAR_0);
  return i + 6;
}

function aColonHms(str, i) {
  const hour = aDigits1or2(str, i);
  if (hour < 0) return -1;
  let j = A_END;
  if (str.charCodeAt(j) !== CHAR_COLON) return -1;
  const minute = aDigits1or2(str, j + 1);
  if (minute < 0) return -1;
  j = A_END;
  A_HOUR = hour;
  A_MINUTE = minute;
  // A second `:` may be followed by seconds -- or by nothing, in which case
  // the Gleam leaves the cursor *at* the colon, not after it.
  if (str.charCodeAt(j) === CHAR_COLON) {
    const second = aDigits1or2(str, j + 1);
    if (second >= 0) {
      A_SECOND = second;
      return A_END;
    }
  }
  A_SECOND = 0;
  return j;
}

function aReadHms(str, i) {
  const j = aCompactHms(str, i);
  return j >= 0 ? j : aColonHms(str, i);
}

// Optional `.` plus 1..9+ fraction digits, truncated to nanoseconds. -1 means
// a `.` with no digits after it, which fails the whole time.
function aFractionNs(str, i) {
  if (str.charCodeAt(i) !== CHAR_DOT) {
    A_VALUE = 0;
    return i;
  }
  let j = i + 1;
  let acc = 0;
  let count = 0;
  for (;;) {
    const c = str.charCodeAt(j);
    if (!isDigit(c)) break;
    if (count < 9) {
      acc = acc * 10 + (c - CHAR_0);
      count += 1;
    }
    j += 1;
  }
  if (count === 0) return -1;
  A_VALUE = acc * POW10[count];
  return j;
}

function aMeridiemAm(str, i) {
  const j = aCiPrefix(str, i, "am");
  if (j >= 0) {
    A_VALUE = 1;
    return j;
  }
  const k = aCiPrefix(str, i, "pm");
  if (k >= 0) {
    A_VALUE = 0;
    return k;
  }
  return -1;
}

function aAdjustTo24Hour(hour, am) {
  if (am) return hour === 12 ? 0 : hour;
  return hour === 12 ? 12 : hour + 12;
}

// Returns the index after a consumed meridiem, leaving the hour in `A_HOUR`.
// On no match the cursor goes back to `i`, *before* any skipped whitespace.
function aApplyMeridiem(hour, str, i) {
  const afterWs = aSkipSpaces(str, i);
  const j = aMeridiemAm(str, afterWs);
  if (j < 0) {
    A_HOUR = hour;
    return i;
  }
  const am = A_VALUE === 1;
  if (!aNotAlphaHead(str, j)) {
    A_HOUR = hour;
    return i;
  }
  A_HOUR = aAdjustTo24Hour(hour, am);
  return j;
}

function aTryTime(str, i, prev) {
  if (isDigit(prev)) return -1;
  let j = aReadHms(str, i);
  if (j < 0) return -1;
  const hour = A_HOUR;
  const minute = A_MINUTE;
  const second = A_SECOND;
  j = aFractionNs(str, j);
  if (j < 0) return -1;
  const nanosecond = A_VALUE;
  j = aApplyMeridiem(hour, str, j);
  if (!aIsValidTime(A_HOUR, minute, second)) return -1;
  A_VALUE = new TimeOfDay(A_HOUR, minute, second, nanosecond);
  return j - i;
}

// --- scanning ---------------------------------------------------------------

function aCandidate(cls, b, prev) {
  switch (cls) {
    case A_NUMERIC_DATE:
    case A_TIME:
      return isDigit(b) && !isDigit(prev);
    case A_NAMED_DATE:
      return (isAlpha(b) || isDigit(b)) && !(isDigit(prev) || isAlpha(prev));
    case A_OFFSET:
      return b === CHAR_PLUS || b === CHAR_MINUS;
    default:
      return (b === CHAR_Z_UPPER || b === CHAR_Z_LOWER) && !isAlpha(prev);
  }
}

// `A_START`/`A_END_SPAN` hold the matched span; the return says whether there
// was one.
let A_START = 0;
let A_END_SPAN = 0;

function aScan(str, cls, attempt) {
  const len = str.length;
  let prev = A_BOUNDARY;
  for (let i = 0; i < len; i += 1) {
    const b = str.charCodeAt(i);
    if (aCandidate(cls, b, prev)) {
      const consumed = attempt(str, i, prev);
      if (consumed >= 0) {
        A_START = i;
        A_END_SPAN = i + consumed;
        return true;
      }
    }
    prev = b;
  }
  return false;
}

// Replaces the matched span with a single space, so it leaves a clean word
// boundary and cannot be re-read by a later scan.
function aBlank(str) {
  return str.slice(0, A_START) + " " + str.slice(A_END_SPAN);
}

export function parse_any(str) {
  let date = SHARED_NONE;
  if (aScan(str, A_NUMERIC_DATE, aTryNumericDate)) {
    date = new Some(A_VALUE);
    str = aBlank(str);
  } else if (aScan(str, A_NAMED_DATE, aTryNamedDate)) {
    date = new Some(A_VALUE);
    str = aBlank(str);
  }

  let offset = SHARED_NONE;
  if (aScan(str, A_OFFSET, aTryNumericOffset)) {
    offset = new Some(duration_minutes(A_VALUE));
    str = aBlank(str);
  } else if (aScan(str, A_ZULU, aTryZulu)) {
    offset = new Some(duration_minutes(A_VALUE));
    str = aBlank(str);
  }

  let time = SHARED_NONE;
  if (aScan(str, A_TIME, aTryTime)) time = new Some(A_VALUE);

  return [date, time, offset];
}
