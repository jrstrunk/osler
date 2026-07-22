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
import { Ok, Error, toList } from "./gleam.mjs";
import { Some, None } from "../gleam_stdlib/gleam/option.mjs";
import { Ixdtf, Zone, Tag, Parts, Am, Pm } from "./osler/parser.mjs";
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

// One parse directive. Mutates state.i and the `p` scratch object; returns
// false on failure.
function stepParse(d, str, state, p) {
  switch (d.constructor.name) {
    case "Year4": {
      const v = parseN(str, state, 4);
      if (v === undefined) return false;
      p.year = v;
      return true;
    }
    case "Month": {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.month = v;
      return true;
    }
    case "Month2": {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.month = v;
      return true;
    }
    case "MonthShortName": {
      const k = matchName(str, state, MONTHS_SHORT);
      if (k < 0) return false;
      p.month = k + 1;
      return true;
    }
    case "MonthLongName": {
      const k = matchName(str, state, MONTHS_LONG);
      if (k < 0) return false;
      p.month = k + 1;
      return true;
    }
    case "Day": {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.day = v;
      return true;
    }
    case "Day2": {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.day = v;
      return true;
    }
    case "WeekdayNumber": {
      const c = str.charCodeAt(state.i);
      if (c < CHAR_0 || c > CHAR_0 + 6) return false;
      state.i += 1;
      return true;
    }
    case "WeekdayShortName2":
      return matchName(str, state, WEEKDAY_2) >= 0;
    case "WeekdayShortName":
      return matchName(str, state, WEEKDAY_3) >= 0;
    case "WeekdayLongName":
      return matchName(str, state, WEEKDAY_LONG) >= 0;
    case "Hour24": {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.hour = v;
      return true;
    }
    case "Hour24Padded": {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.hour = v;
      return true;
    }
    case "Hour12": {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.twelveHour = v;
      return true;
    }
    case "Hour12Padded": {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.twelveHour = v;
      return true;
    }
    case "MeridiemLower": {
      if (str.startsWith("am", state.i)) { state.i += 2; p.period = Am; return true; }
      if (str.startsWith("pm", state.i)) { state.i += 2; p.period = Pm; return true; }
      return false;
    }
    case "MeridiemUpper": {
      if (str.startsWith("AM", state.i)) { state.i += 2; p.period = Am; return true; }
      if (str.startsWith("PM", state.i)) { state.i += 2; p.period = Pm; return true; }
      return false;
    }
    case "Minute": {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.minute = v;
      return true;
    }
    case "Minute2": {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.minute = v;
      return true;
    }
    case "Second": {
      const v = parse1or2(str, state);
      if (v === undefined) return false;
      p.second = v;
      return true;
    }
    case "Second2": {
      const v = parse2(str, state);
      if (v === undefined) return false;
      p.second = v;
      return true;
    }
    case "Milli": {
      const v = parseN(str, state, 3);
      if (v === undefined) return false;
      p.nanosecond = v * 1000000;
      return true;
    }
    case "Micro": {
      const v = parseN(str, state, 6);
      if (v === undefined) return false;
      p.nanosecond = v * 1000;
      return true;
    }
    case "Nano": {
      const v = parseN(str, state, 9);
      if (v === undefined) return false;
      p.nanosecond = v;
      return true;
    }
    case "Offset":
    case "OffsetZulu":
    case "OffsetColon":
    case "OffsetNoColon":
    case "IsoOffset": {
      if (!parseOffset(str, state)) return false;
      p.offsetMinutes = state.offsetMinutes;
      return true;
    }
    case "Gmt": {
      if (!str.startsWith("GMT", state.i)) return false;
      state.i += 3;
      p.offsetMinutes = 0;
      return true;
    }
    case "ZoneName": {
      const res = parseOptionalZone(str, state);
      if (res === null) return false;
      if (res.zone !== undefined) p.zone = res.zone;
      return true;
    }
    case "ExtensionTags": {
      const tags = parseTagRun(str, state);
      if (tags === null) return false;
      p.tags = tags;
      return true;
    }
    case "Literal": {
      const lit = d[0];
      if (!str.startsWith(lit, state.i)) return false;
      state.i += lit.length;
      return true;
    }
    case "Separator": {
      if (isDateSep(str.charCodeAt(state.i))) state.i += 1;
      return true;
    }
    case "TimeSeparator": {
      if (isTimeSep(str.charCodeAt(state.i))) state.i += 1;
      return true;
    }
    case "DateTimeSeparator": {
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
    case "EndOfInput":
      return state.i === str.length;
    case "IsoDate": {
      if (!parseDate(str, state)) return false;
      p.year = state.year;
      p.month = state.month;
      p.day = state.day;
      return true;
    }
    case "IsoTime": {
      if (!parseTime(str, state)) return false;
      p.hour = state.hour;
      p.minute = state.minute;
      p.second = state.second;
      p.nanosecond = state.nanosecond;
      return true;
    }
    case "IsoNaiveDateTime": {
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

function optOf(v) {
  return v === undefined ? new None() : new Some(v);
}

export function parse(input, directives) {
  const state = { i: 0 };
  const p = {};
  for (const d of directives) {
    if (!stepParse(d, input, state, p)) return new Error(undefined);
  }
  const period =
    p.period === undefined ? new None() : new Some(new p.period());
  return new Ok(
    new Parts(
      optOf(p.year),
      optOf(p.month),
      optOf(p.day),
      optOf(p.hour),
      optOf(p.twelveHour),
      period,
      optOf(p.minute),
      optOf(p.second),
      optOf(p.nanosecond),
      optOf(p.offsetMinutes),
      p.zone === undefined ? new None() : new Some(p.zone),
      p.tags === undefined ? toList([]) : toList(p.tags),
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
