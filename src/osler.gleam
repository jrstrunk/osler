//// Fast parsing and rendering of date/time strings.
////
//// This module is centered around the `gleam_time` `Timestamp` type and exists
//// for convenience and as an example of how to use the underlying parsers and
//// formatters. If you want an unopinionated parser and formatter to build your
//// application or library around, see the `parser` module.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import osler/parser

/// Parses a full RFC 9557 (IXDTF) timestamp, which is an RFC 3339 date-time
/// followed by an optional time zone and/or any number of `[key=value]`
/// extension tags.
///
/// Returns the absolute `Timestamp`, the parsed offset (handed back
/// alongside since a `Timestamp` alone can't tell you what offset the string
/// was written in), and the suffix: an optional `parser.Zone` and a list of
/// `parser.Tag`s in the order they appeared.
///
/// This function does not validate the zone or any tags in the suffix,
/// assuring only that they are well-formed.
///
/// ## Examples
///
/// ```gleam
/// osler.parse_ixdtf(
///   "1996-12-19T16:39:57-08:00[America/Los_Angeles][u-ca=hebrew]",
/// )
/// // -> Ok(#(
/// //   some_timestamp,
/// //   duration.minutes(-480),
/// //   option.Some(parser.Zone(False, "America/Los_Angeles")),
/// //   [parser.Tag(False, "u-ca", "hebrew")],
/// // ))
/// ```
/// The JavaScript target has its own implementation in `osler_ffi.mjs`; this
/// body is the Erlang one. It validates and builds the `Timestamp` straight
/// from the raw ints -- no intermediate `calendar.Date`/`TimeOfDay`, and no
/// second pass of calendar arithmetic on top of the validation. The seconds
/// come from the same Julian-day formula `gleam/time/timestamp` applies
/// internally, so the `Timestamp` is identical to `from_calendar`'s, including
/// the `24:00` and leap-second folds.
@external(javascript, "./osler_ffi.mjs", "parse_ixdtf")
pub fn parse_ixdtf(
  str: String,
) -> Result(#(Timestamp, Duration, Option(parser.Zone), List(parser.Tag)), Nil) {
  case parser.parse_ixdtf(str) {
    Error(Nil) -> Error(Nil)
    Ok(i) ->
      case valid_fields(i) {
        False -> Error(Nil)
        True ->
          Ok(#(
            to_timestamp(i),
            duration.minutes(i.offset_minutes),
            i.zone,
            i.tags,
          ))
      }
  }
}

fn to_timestamp(i: parser.Ixdtf) -> Timestamp {
  timestamp.from_unix_seconds_and_nanoseconds(
    seconds_since_epoch(
      i.year,
      i.month,
      i.day,
      i.hour,
      i.minute,
      i.second,
      i.offset_minutes,
    ),
    i.nanosecond,
  )
}

// Month 1-12, a day within that month's real length, and an hour/minute/second
// in range. Checked off the raw ints, with no `calendar.Date`/`TimeOfDay`
// construction.
fn valid_fields(i: parser.Ixdtf) -> Bool {
  valid_date(i.year, i.month, i.day)
  && is_valid_time(i.hour, i.minute, i.second)
}

// Seconds since the Unix epoch, using the same Julian-day formula
// `gleam/time/timestamp` applies internally (so a `Timestamp` built from it is
// identical to `from_calendar`'s, incl. the `24:00` / leap-second fold).
//
// The straightforward formula does five integer divisions; this does none.
// `adjustment` is a `month <= 2` test (not `(14-month)/12`), `(153*am+2)/5` is
// the `days_before_month` lookup, and `/400` reuses `/100` via the identity
// `floor(floor(x/100)/4) == floor(x/400)` (exact for the always-positive
// `adjusted_year`). The three divisions that remained are then strength-reduced:
// `/4` on a non-negative value is an arithmetic shift, and `/100` is the usual
// multiply-shift, `(v * 5243) >> 19`.
//
// The multiply-shift is only exact over a bounded domain. `year` comes from a
// 4-digit field, so `adjusted_year` is confined to 4799..14799, and
// `(v * 5243) >> 19 == v / 100` is verified for **every** value in that range,
// as is `>> 2 == / 4` for both `adjusted_year` and `ay_div_100`. If the parser
// ever accepts years outside 0000-9999, re-verify or revert to `/`.
fn seconds_since_epoch(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
  offset_minutes: Int,
) -> Int {
  let adjustment = case month <= 2 {
    True -> 1
    False -> 0
  }
  let adjusted_year = year + 4800 - adjustment
  let adjusted_month = month + { 12 * adjustment } - 3
  let ay_div_100 = int.bitwise_shift_right(adjusted_year * 5243, 19)
  let julian_day =
    day
    + days_before_month(adjusted_month)
    + { 365 * adjusted_year }
    + int.bitwise_shift_right(adjusted_year, 2)
    - ay_div_100
    + int.bitwise_shift_right(ay_div_100, 2)
    - 32_045
  { julian_day * 86_400 }
  + { hour * 3600 }
  + { minute * 60 }
  + second
  - 210_866_803_200
  - { offset_minutes * 60 }
}

// Days of the (March-based) year before month `am`, i.e. `(153 * am + 2) / 5`
// for `am` in 0..11, as a lookup rather than a division. See `seconds_since_epoch`.
fn days_before_month(am: Int) -> Int {
  case am {
    0 -> 0
    1 -> 31
    2 -> 61
    3 -> 92
    4 -> 122
    5 -> 153
    6 -> 184
    7 -> 214
    8 -> 245
    9 -> 275
    10 -> 306
    _ -> 337
  }
}

/// Parses a full RFC 9557 (IXDTF) timestamp like `parse_ixdtf`, but returns
/// **only** the absolute `Timestamp` -- no offset, zone, or tags. When the
/// instant is all you need this is the leaner, faster path: it skips
/// allocating the offset `Duration`, the suffix values, and the result tuple.
///
/// Because it discards the RFC 9557 suffix, it **rejects** any suffix carrying
/// the `!` critical flag -- a critical time zone (`[!Europe/Paris]`) or a
/// critical tag (`[!u-ca=hebrew]`). RFC 9557 §3.3 requires a consumer that
/// will not act on a critical item to treat the whole timestamp as invalid,
/// and dropping it is precisely not acting on it. Non-critical zones and tags
/// are parsed for well-formedness and then silently ignored. Use `parse_ixdtf`
/// if you need to see the suffix.
///
/// ## Examples
///
/// ```gleam
/// osler.parse_timestamp("2024-06-13T23:04:00.009+10:00")
/// // -> Ok(some_timestamp)
///
/// osler.parse_timestamp("2024-06-13T23:04:00Z[u-ca=hebrew]")
/// // -> Ok(some_timestamp)   // non-critical tag ignored
///
/// osler.parse_timestamp("2024-06-13T23:04:00Z[!u-ca=hebrew]")
/// // -> Error(Nil)           // critical tag cannot be dropped
/// ```
/// As with `parse_ixdtf`, the JavaScript target implements this in
/// `osler_ffi.mjs` and this body is the Erlang one.
@external(javascript, "./osler_ffi.mjs", "parse_timestamp")
pub fn parse_timestamp(str: String) -> Result(Timestamp, Nil) {
  case parser.parse_ixdtf(str) {
    Error(Nil) -> Error(Nil)
    Ok(i) ->
      case valid_fields(i) && no_critical_flags(i.zone, i.tags) {
        False -> Error(Nil)
        True -> Ok(to_timestamp(i))
      }
  }
}

// True unless the suffix carries a critical (`!`) time zone or tag, which a
// suffix-dropping parse must not silently discard (RFC 9557 §3.3).
//
// Walks the list directly rather than via `list.all`, whose callback would
// allocate a closure on every call -- including the common suffix-free one,
// where `tags` is `[]` and there is nothing to check.
fn no_critical_flags(
  zone: Option(parser.Zone),
  tags: List(parser.Tag),
) -> Bool {
  case zone {
    Some(parser.Zone(critical: True, ..)) -> False
    _ -> no_critical_tags(tags)
  }
}

fn no_critical_tags(tags: List(parser.Tag)) -> Bool {
  case tags {
    [] -> True
    [parser.Tag(critical: True, ..), ..] -> False
    [_, ..rest] -> no_critical_tags(rest)
  }
}

/// Renders an absolute `timestamp` through the ordered `directives`, the
/// inverse of `parser.parse`. The `timestamp` is resolved to a calendar
/// date/time in `offset`, so date and time directives read the *local*
/// wall-clock in that offset; `zone` and `tags` supply the `ZoneName` and
/// `ExtensionTags` directives. Fails with `Error(Nil)` if a directive
/// references a part that can't be produced.
///
/// This is the counterpart to `parse_ixdtf`: feeding its four results back
/// in reproduces the original string, given a matching format.
///
/// ## Examples
///
/// ```gleam
/// import osler/parser.{Year4, Month2, Day2, Literal, Hour24Padded, Minute2,
///   Second2, OffsetColon} as _
///
/// let directives = [
///   Year4, Literal("-"), Month2, Literal("-"), Day2, Literal("T"),
///   Hour24Padded, Literal(":"), Minute2, Literal(":"), Second2, OffsetColon,
/// ]
/// osler.format(
///   some_timestamp,
///   in: directives,
///   offset: duration.minutes(-480),
///   zone: option.None,
///   tags: [],
/// )
/// // -> Ok("1996-12-19T16:39:57-08:00")
/// ```
pub fn format(
  timestamp: Timestamp,
  in directives: List(parser.Directive),
  offset offset: Duration,
  zone zone: Option(parser.Zone),
  tags tags: List(parser.Tag),
) -> Result(String, Nil) {
  let #(date, time) = timestamp.to_calendar(timestamp, offset)
  let parts =
    parser.Parts(
      year: Some(date.year),
      month: Some(calendar.month_to_int(date.month)),
      day: Some(date.day),
      hour: Some(time.hours),
      twelve_hour: option.None,
      period: option.None,
      minute: Some(time.minutes),
      second: Some(time.seconds),
      nanosecond: Some(time.nanoseconds),
      offset_minutes: Some(duration_to_minutes(offset)),
      zone:,
      tags:,
    )
  parser.format(parts, directives)
}

fn duration_to_minutes(offset: Duration) -> Int {
  float.round(duration.to_seconds(offset) /. 60.0)
}

// Month 1-12 and a day within that month's real length, leap-year aware.
// The month length is compared inline in each arm, so `is_leap_year`'s three
// `rem` operations only run for a February 29th.
fn valid_date(year: Int, month: Int, day: Int) -> Bool {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> day >= 1 && day <= 31
    4 | 6 | 9 | 11 -> day >= 1 && day <= 30
    2 -> { day >= 1 && day <= 28 } || { day == 29 && is_leap_year(year) }
    // Any other month is invalid.
    _ -> False
  }
}

fn is_leap_year(year: Int) -> Bool {
  { year % 4 == 0 && year % 100 != 0 } || year % 400 == 0
}

/// An ordinary time of day, plus ISO 8601's two special values: `24:00:00`
/// (end of day) and `23:59:60` (leap second).
fn is_valid_time(hour: Int, minute: Int, second: Int) -> Bool {
  {
    hour >= 0
    && hour <= 23
    && minute >= 0
    && minute <= 59
    && second >= 0
    && second <= 59
  }
  || { hour == 24 && minute == 0 && second == 0 }
  || { hour == 23 && minute == 59 && second == 60 }
}

// --- parse_any --------------------------------------------------------------

/// Heuristically pulls a date, a time, and an offset out of an arbitrary
/// string, returning whichever were found. Each is independent: a bare date, a
/// bare time, a full timestamp buried in a sentence, or nothing at all. It is
/// a best-effort guesser -- prefer `parse_ixdtf` or `parser.parse` with an
/// explicit format when you know the shape.
///
/// Like the rest of osler this is regex-free. It scans left-to-right for the
/// first *valid* date, removes it, then the first valid offset, then the first
/// valid time (offset before time so a `+10:00` is not misread as a time). A
/// component that matches structurally but is out of range (a 13th month, a
/// `+18:00` offset) is skipped rather than returned.
///
/// Accepted, leniently:
///
///   * dates: `YYYY-MM-DD` and friends (any of `- / . _ space ,` as
///     separators, or none: `20240613`); US month-first `MM/DD/YYYY` /
///     `06222024`; and written months `June 21st, 2024`, `Dec 25, 2024`
///     (month names are case-insensitive). The year is always four digits, in
///     `1000..9999`.
///   * times: `HH:MM`, `HH:MM:SS`, `HH:MM:SS.fraction` (any fraction length,
///     kept to nanosecond precision), compact `HHMMSS`, and a trailing
///     `AM`/`PM` (case-insensitive) which maps a 12-hour clock to 24.
///   * offsets: `±HH`, `±HHMM`, `±HH:MM`, and a standalone `Z`/`z`.
///
/// ## Examples
///
/// ```gleam
/// osler.parse_any("Meeting on 2024/06/22 at 1:42 PM in -04:00")
/// // -> #(
/// //   Some(calendar.Date(2024, calendar.June, 22)),
/// //   Some(calendar.TimeOfDay(13, 42, 0, 0)),
/// //   Some(duration.minutes(-240)),
/// // )
/// ```
///
/// ```gleam
/// osler.parse_any("just some words")
/// // -> #(None, None, None)
/// ```
@external(javascript, "./osler_ffi.mjs", "parse_any")
pub fn parse_any(
  str: String,
) -> #(Option(calendar.Date), Option(calendar.TimeOfDay), Option(Duration)) {
  let bits = bit_array.from_string(str)
  let #(date, bits) = extract_date(bits)
  let #(offset, bits) = extract_offset(bits)
  let time = extract_time(bits)
  #(date, time, offset)
}

fn extract_date(bits: BitArray) -> #(Option(calendar.Date), BitArray) {
  case scan(bits, byte_boundary, 0, class_numeric_date, try_numeric_date) {
    Ok(#(date, start, end)) -> #(Some(date), blank(bits, start, end))
    Error(Nil) ->
      case scan(bits, byte_boundary, 0, class_named_date, try_named_date) {
        Ok(#(date, start, end)) -> #(Some(date), blank(bits, start, end))
        Error(Nil) -> #(None, bits)
      }
  }
}

fn extract_offset(bits: BitArray) -> #(Option(Duration), BitArray) {
  case scan(bits, byte_boundary, 0, class_offset, try_numeric_offset) {
    Ok(#(minutes, start, end)) -> #(
      Some(duration.minutes(minutes)),
      blank(bits, start, end),
    )
    Error(Nil) ->
      case scan(bits, byte_boundary, 0, class_zulu, try_zulu) {
        Ok(#(minutes, start, end)) -> #(
          Some(duration.minutes(minutes)),
          blank(bits, start, end),
        )
        Error(Nil) -> #(None, bits)
      }
  }
}

fn extract_time(bits: BitArray) -> Option(calendar.TimeOfDay) {
  case scan(bits, byte_boundary, 0, class_time, try_time) {
    Ok(#(time, _start, _end)) -> Some(time)
    Error(Nil) -> None
  }
}

// A non-digit, non-alpha byte to seed the "previous byte" at the very start of
// a scan, so a component anchored to the string start is treated as bounded.
const byte_boundary = 0x20

// Each attempt has a cheap necessary condition on the byte at the cursor and
// the one before it. Checking that inline keeps the loop to a comparison or
// two per position: `attempt` is a function *value*, so calling it hands
// `bits` across a boundary, which materialises a sub-binary on BEAM and a
// `BitArray` wrapper on JS.
//
// The conditions must stay *necessary* -- never reject a position the attempt
// would have accepted:
//
//   0 numeric date  digit at cursor (needs 4), previous byte not a digit
//   1 named date    alpha or digit (a month name or a numeric month),
//                   previous byte neither alpha nor digit
//   2 offset        `+` or `-` (no constraint on the previous byte: an offset
//                   legitimately abuts the time, `00:00:00+05:00`)
//   3 zulu          `Z`/`z`, previous byte not alpha (so `Zulu` is skipped)
//   4 time          digit at cursor, previous byte not a digit
//
// The class is a literal `Int` rather than a second closure, and it is matched
// with literal patterns: a bare constant name in a Gleam pattern binds a fresh
// variable instead of matching the constant's value.
const class_numeric_date = 0

const class_named_date = 1

const class_offset = 2

const class_zulu = 3

const class_time = 4

// Walks the input left-to-right, calling `attempt` at each *plausible* byte
// position with the preceding byte (for word-boundary checks). Returns the
// first match with its [start, end) byte span, or Error if none. Every attempt
// needs at least one byte, so running off the end simply fails.
fn scan(
  bits: BitArray,
  prev: Int,
  pos: Int,
  class: Int,
  attempt: fn(BitArray, Int) -> Result(#(a, Int), Nil),
) -> Result(#(a, Int, Int), Nil) {
  case bits {
    <<b, rest:bytes>> ->
      case candidate(class, b, prev) {
        False -> scan(rest, b, pos + 1, class, attempt)
        True ->
          case attempt(bits, prev) {
            Ok(#(value, consumed)) -> Ok(#(value, pos, pos + consumed))
            Error(Nil) -> scan(rest, b, pos + 1, class, attempt)
          }
      }
    _ -> Error(Nil)
  }
}

fn candidate(class: Int, b: Int, prev: Int) -> Bool {
  case class {
    0 | 4 -> is_digit(b) && !is_digit(prev)
    1 -> { is_alpha(b) || is_digit(b) } && !{ is_digit(prev) || is_alpha(prev) }
    2 -> b == 0x2B || b == 0x2D
    _ -> { b == 0x5A || b == 0x7A } && !is_alpha(prev)
  }
}

// Replaces the [start, end) span with a single space, so a consumed component
// leaves a clean word boundary and cannot be re-read by a later scan.
fn blank(bits: BitArray, start: Int, end: Int) -> BitArray {
  let total = bit_array.byte_size(bits)
  let assert Ok(before) = bit_array.slice(bits, 0, start)
  let assert Ok(after) = bit_array.slice(bits, end, total - end)
  <<before:bits, byte_boundary, after:bits>>
}

// --- date scanning ----------------------------------------------------------

fn try_numeric_date(
  bits: BitArray,
  prev: Int,
) -> Result(#(calendar.Date, Int), Nil) {
  case is_digit(prev) {
    True -> Error(Nil)
    False ->
      case parser.parse_4_digits(bits) {
        Error(Nil) -> Error(Nil)
        Ok(#(year, rest)) ->
          case is_date_sep_head(rest) {
            True -> {
              let rest = drop_seps(rest)
              use #(month, rest) <- result.try(parser.parse_1_or_2_digits(rest))
              let rest = drop_seps(rest)
              use #(day, rest) <- result.try(parser.parse_1_or_2_digits(rest))
              finish_date(year, month, day, bits, rest)
            }
            False ->
              case rest {
                <<m1, m2, d1, d2, after:bytes>>
                  if m1 >= 0x30
                  && m1 <= 0x39
                  && m2 >= 0x30
                  && m2 <= 0x39
                  && d1 >= 0x30
                  && d1 <= 0x39
                  && d2 >= 0x30
                  && d2 <= 0x39
                ->
                  case not_digit_head(after) {
                    True ->
                      finish_date(
                        year,
                        digits2(m1, m2),
                        digits2(d1, d2),
                        bits,
                        after,
                      )
                    False -> Error(Nil)
                  }
                _ -> Error(Nil)
              }
          }
      }
  }
}

// Month-first: `<month> <day><ordinal?> <year>`, where `<month>` is a
// case-insensitive English name or a 1-2 digit number (this covers US
// `MM/DD/YYYY` and `June 21st, 2024` alike).
fn try_named_date(
  bits: BitArray,
  prev: Int,
) -> Result(#(calendar.Date, Int), Nil) {
  case is_digit(prev) || is_alpha(prev) {
    True -> Error(Nil)
    False -> {
      use #(month, rest) <- result.try(read_month_token(bits))
      let rest = drop_seps(rest)
      use #(day, rest) <- result.try(parser.parse_1_or_2_digits(rest))
      let rest = rest |> drop_ordinal |> drop_seps
      use #(year, rest) <- result.try(parser.parse_4_digits(rest))
      case not_digit_head(rest) {
        True -> finish_date(year, month, day, bits, rest)
        False -> Error(Nil)
      }
    }
  }
}

fn read_month_token(bits: BitArray) -> Result(#(Int, BitArray), Nil) {
  case read_month_name(bits) {
    Ok(found) -> Ok(found)
    Error(Nil) -> parser.parse_1_or_2_digits(bits)
  }
}

// Month names, grouped by first letter and ordered long-before-short within a
// group so `Jan` cannot shadow `January`. `read_month_name` dispatches on the
// first byte, so a word start costs a handful of comparisons rather than all
// twenty-four names -- and the prefilter in `scan` lets every word start
// through by design, since that is exactly where a month name would be.
//
// Grouping is safe because names in different groups start with different
// letters, so no cross-group shadowing is possible, and `may` is identical in
// the long and short forms.
const months_j = [
  #("january", 1),
  #("june", 6),
  #("july", 7),
  #("jan", 1),
  #("jun", 6),
  #("jul", 7),
]

const months_f = [#("february", 2), #("feb", 2)]

const months_m = [#("march", 3), #("may", 5), #("mar", 3)]

const months_a = [#("april", 4), #("august", 8), #("apr", 4), #("aug", 8)]

const months_s = [#("september", 9), #("sep", 9)]

const months_o = [#("october", 10), #("oct", 10)]

const months_n = [#("november", 11), #("nov", 11)]

const months_d = [#("december", 12), #("dec", 12)]

fn read_month_name(bits: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bits {
    <<c, _:bytes>> ->
      case to_lower(c) {
        0x6A -> match_first(bits, months_j)
        0x66 -> match_first(bits, months_f)
        0x6D -> match_first(bits, months_m)
        0x61 -> match_first(bits, months_a)
        0x73 -> match_first(bits, months_s)
        0x6F -> match_first(bits, months_o)
        0x6E -> match_first(bits, months_n)
        0x64 -> match_first(bits, months_d)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn match_first(
  bits: BitArray,
  table: List(#(String, Int)),
) -> Result(#(Int, BitArray), Nil) {
  case table {
    [] -> Error(Nil)
    [#(name, value), ..rest] ->
      case ci_prefix(bits, bit_array.from_string(name)) {
        Ok(remaining) -> Ok(#(value, remaining))
        Error(Nil) -> match_first(bits, rest)
      }
  }
}

fn finish_date(
  year: Int,
  month: Int,
  day: Int,
  original: BitArray,
  rest: BitArray,
) -> Result(#(calendar.Date, Int), Nil) {
  case year >= 1000 && year <= 9999 && valid_date(year, month, day) {
    False -> Error(Nil)
    True ->
      case calendar.month_from_int(month) {
        Ok(month) ->
          Ok(#(calendar.Date(year:, month:, day:), consumed(original, rest)))
        Error(Nil) -> Error(Nil)
      }
  }
}

// --- offset scanning --------------------------------------------------------

// The offset legitimately abuts the preceding digit (`00:00:00+05:00`), so
// there is no leading-boundary check; the `[-12:00, +14:00]` range check plus
// the trailing-boundary check keep stray numbers from matching.
fn try_numeric_offset(bits: BitArray, _prev: Int) -> Result(#(Int, Int), Nil) {
  case bits {
    <<sign, rest:bytes>> if sign == 0x2B || sign == 0x2D -> {
      let signum = case sign == 0x2D {
        True -> -1
        False -> 1
      }
      use #(hour, rest) <- result.try(parser.parse_2_digits(rest))
      let #(minute, rest) = read_offset_minutes(rest)
      case not_digit_head(rest) {
        True -> {
          let minutes = signum * { hour * 60 + minute }
          case minutes >= -720 && minutes <= 840 {
            True -> Ok(#(minutes, consumed(bits, rest)))
            False -> Error(Nil)
          }
        }
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

// `:MM`, or a bare `MM`, or nothing (minutes default to 0).
fn read_offset_minutes(bits: BitArray) -> #(Int, BitArray) {
  case bits {
    <<0x3A, m1, m2, rest:bytes>>
      if m1 >= 0x30 && m1 <= 0x39 && m2 >= 0x30 && m2 <= 0x39
    -> #(digits2(m1, m2), rest)
    <<m1, m2, rest:bytes>>
      if m1 >= 0x30 && m1 <= 0x39 && m2 >= 0x30 && m2 <= 0x39
    -> #(digits2(m1, m2), rest)
    _ -> #(0, bits)
  }
}

// A standalone `Z`/`z` (UTC), not adjacent to letters (so `Zulu` is skipped).
fn try_zulu(bits: BitArray, prev: Int) -> Result(#(Int, Int), Nil) {
  case is_alpha(prev) {
    True -> Error(Nil)
    False ->
      case bits {
        <<z, rest:bytes>> if z == 0x5A || z == 0x7A ->
          case not_alpha_head(rest) {
            True -> Ok(#(0, 1))
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
  }
}

// --- time scanning ----------------------------------------------------------

fn try_time(
  bits: BitArray,
  prev: Int,
) -> Result(#(calendar.TimeOfDay, Int), Nil) {
  case is_digit(prev) {
    True -> Error(Nil)
    False -> {
      use #(hour, minute, second, rest) <- result.try(read_hms(bits))
      use #(nanosecond, rest) <- result.try(parser.parse_optional_fraction_ns(
        rest,
      ))
      let #(hour, rest) = apply_meridiem(hour, rest)
      case is_valid_time(hour, minute, second) {
        True ->
          Ok(#(
            calendar.TimeOfDay(hour, minute, second, nanosecond),
            consumed(bits, rest),
          ))
        False -> Error(Nil)
      }
    }
  }
}

// `HH:MM`, `HH:MM:SS` (1-2 digit fields), or a compact `HHMMSS`.
fn read_hms(bits: BitArray) -> Result(#(Int, Int, Int, BitArray), Nil) {
  case compact_hms(bits) {
    Ok(found) -> Ok(found)
    Error(Nil) -> colon_hms(bits)
  }
}

fn compact_hms(bits: BitArray) -> Result(#(Int, Int, Int, BitArray), Nil) {
  case bits {
    <<h1, h2, m1, m2, s1, s2, after:bytes>>
      if h1 >= 0x30
      && h1 <= 0x39
      && h2 >= 0x30
      && h2 <= 0x39
      && m1 >= 0x30
      && m1 <= 0x39
      && m2 >= 0x30
      && m2 <= 0x39
      && s1 >= 0x30
      && s1 <= 0x39
      && s2 >= 0x30
      && s2 <= 0x39
    ->
      case not_digit_head(after) {
        True -> Ok(#(digits2(h1, h2), digits2(m1, m2), digits2(s1, s2), after))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn colon_hms(bits: BitArray) -> Result(#(Int, Int, Int, BitArray), Nil) {
  use #(hour, rest) <- result.try(parser.parse_1_or_2_digits(bits))
  case rest {
    <<0x3A, rest:bytes>> -> {
      use #(minute, rest) <- result.try(parser.parse_1_or_2_digits(rest))
      case rest {
        <<0x3A, after_colon:bytes>> ->
          case parser.parse_1_or_2_digits(after_colon) {
            Ok(#(second, rest)) -> Ok(#(hour, minute, second, rest))
            Error(Nil) -> Ok(#(hour, minute, 0, rest))
          }
        _ -> Ok(#(hour, minute, 0, rest))
      }
    }
    _ -> Error(Nil)
  }
}

// Consumes an optional trailing `AM`/`PM` (case-insensitive, and only when it
// is a standalone token) and maps the hour to 24-hour form.
fn apply_meridiem(hour: Int, bits: BitArray) -> #(Int, BitArray) {
  let after_ws = skip_spaces(bits)
  case meridiem(after_ws) {
    Ok(#(am, rest)) ->
      case not_alpha_head(rest) {
        True -> #(adjust_to_24_hour(hour, am), rest)
        False -> #(hour, bits)
      }
    Error(Nil) -> #(hour, bits)
  }
}

fn meridiem(bits: BitArray) -> Result(#(Bool, BitArray), Nil) {
  case ci_prefix(bits, <<"am">>) {
    Ok(rest) -> Ok(#(True, rest))
    Error(Nil) ->
      case ci_prefix(bits, <<"pm">>) {
        Ok(rest) -> Ok(#(False, rest))
        Error(Nil) -> Error(Nil)
      }
  }
}

fn adjust_to_24_hour(hour: Int, am: Bool) -> Int {
  case am, hour {
    True, 12 -> 0
    True, _ -> hour
    False, 12 -> 12
    False, _ -> hour + 12
  }
}

// --- byte helpers -----------------------------------------------------------

fn is_digit(b: Int) -> Bool {
  b >= 0x30 && b <= 0x39
}

fn is_alpha(b: Int) -> Bool {
  { b >= 0x41 && b <= 0x5A } || { b >= 0x61 && b <= 0x7A }
}

fn digits2(b1: Int, b2: Int) -> Int {
  parser.digit_value(b1) * 10 + parser.digit_value(b2)
}

fn consumed(original: BitArray, rest: BitArray) -> Int {
  bit_array.byte_size(original) - bit_array.byte_size(rest)
}

fn not_digit_head(bits: BitArray) -> Bool {
  case bits {
    <<b, _:bytes>> if b >= 0x30 && b <= 0x39 -> False
    _ -> True
  }
}

fn not_alpha_head(bits: BitArray) -> Bool {
  case bits {
    <<b, _:bytes>> ->
      case is_alpha(b) {
        True -> False
        False -> True
      }
    _ -> True
  }
}

fn is_date_sep_head(bits: BitArray) -> Bool {
  case bits {
    <<b, _:bytes>>
      if b == 0x2D
      || b == 0x2F
      || b == 0x2E
      || b == 0x5F
      || b == 0x20
      || b == 0x2C
    -> True
    _ -> False
  }
}

// Drops up to two leading date separators (`- / . _ space ,`).
fn drop_seps(bits: BitArray) -> BitArray {
  drop_one_sep(drop_one_sep(bits))
}

fn drop_one_sep(bits: BitArray) -> BitArray {
  case bits {
    <<b, rest:bytes>>
      if b == 0x2D
      || b == 0x2F
      || b == 0x2E
      || b == 0x5F
      || b == 0x20
      || b == 0x2C
    -> rest
    _ -> bits
  }
}

fn drop_ordinal(bits: BitArray) -> BitArray {
  case ordinal(bits) {
    Ok(rest) -> rest
    Error(Nil) -> bits
  }
}

fn ordinal(bits: BitArray) -> Result(BitArray, Nil) {
  case ci_prefix(bits, <<"st">>) {
    Ok(rest) -> Ok(rest)
    Error(Nil) ->
      case ci_prefix(bits, <<"nd">>) {
        Ok(rest) -> Ok(rest)
        Error(Nil) ->
          case ci_prefix(bits, <<"rd">>) {
            Ok(rest) -> Ok(rest)
            Error(Nil) -> ci_prefix(bits, <<"th">>)
          }
      }
  }
}

fn skip_spaces(bits: BitArray) -> BitArray {
  case bits {
    <<0x20, rest:bytes>> -> skip_spaces(rest)
    <<0x09, rest:bytes>> -> skip_spaces(rest)
    _ -> bits
  }
}

// Case-insensitively matches `pattern` (assumed lowercase ASCII) at the start
// of `bits`, returning the remaining bytes.
fn ci_prefix(bits: BitArray, pattern: BitArray) -> Result(BitArray, Nil) {
  case pattern, bits {
    <<>>, _ -> Ok(bits)
    <<p, pattern_rest:bytes>>, <<b, bits_rest:bytes>> ->
      case to_lower(b) == p {
        True -> ci_prefix(bits_rest, pattern_rest)
        False -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

fn to_lower(b: Int) -> Int {
  case b >= 0x41 && b <= 0x5A {
    True -> b + 32
    False -> b
  }
}
