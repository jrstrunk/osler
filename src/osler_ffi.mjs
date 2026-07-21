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
import { Ixdtf, Zone, Tag } from "./osler/parser.mjs";

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

export function parse_date(str) {
  const state = { i: 0 };
  if (!parseDate(str, state)) return new Error(undefined);
  if (state.i !== str.length) return new Error(undefined);
  return new Ok([state.year, state.month, state.day]);
}

export function parse_time(str) {
  const state = { i: 0 };
  if (!parseTime(str, state)) return new Error(undefined);
  if (state.i !== str.length) return new Error(undefined);
  return new Ok([state.hour, state.minute, state.second, state.nanosecond]);
}

export function parse_offset(str) {
  const state = { i: 0 };
  if (!parseOffset(str, state)) return new Error(undefined);
  if (state.i !== str.length) return new Error(undefined);
  return new Ok(state.offsetMinutes);
}

export function parse_naive_datetime(str) {
  const state = { i: 0 };
  if (!parseDate(str, state)) return new Error(undefined);

  if (state.i === str.length) {
    return new Ok([state.year, state.month, state.day, 0, 0, 0, 0]);
  }

  if (!isDatetimeSep(str.charCodeAt(state.i))) return new Error(undefined);
  state.i += 1;

  if (!parseTime(str, state)) return new Error(undefined);
  if (state.i !== str.length) return new Error(undefined);

  return new Ok([
    state.year,
    state.month,
    state.day,
    state.hour,
    state.minute,
    state.second,
    state.nanosecond,
  ]);
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
    return { zone: new None(), tags: toList([]) };
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

export function parse_ixdtf(str) {
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
