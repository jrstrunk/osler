//// Bare structural parsing, for libraries that want to build their own
//// domain types (with their own validation policy) instead of `gleam_time`
//// calendar types. This is what `osler`'s own higher-level, calendar-type
//// returning functions are built on top of -- if you're not sure whether
//// you want this module or `osler` itself, you probably want `osler`.
////
//// Every function here accepts the same broad set of shapes described in
//// the `osler` module's documentation, and returns `Error(Nil)` on any
//// structural failure. Unlike `osler`'s functions, **the returned values
//// are not validated at all**: a date's day and month are whatever digits
//// were present (a day of `54` or a month of `13` parses fine), an
//// offset's hour/minute only get the loose shape check described in
//// `parse_offset`'s docs, and there's no month-length/leap-year/offset-
//// range checking whatsoever. This module's only job is turning bytes
//// into raw ints as cheaply as possible; if you don't have your own
//// validation logic already, use `osler`'s functions instead.
////
//// Sub-second fractions are always returned in nanoseconds (truncating
//// anything past the 9th digit), regardless of what precision your own
//// type stores -- divide by the appropriate power of 10 yourself if you
//// need coarser precision.
////
//// `parse_ixdtf` parses a full date, time, and offset followed by the
//// optional RFC 9557 (IXDTF) suffix -- a time zone name (or offset zone)
//// and any number of `[key=value]` extension tags -- capturing them
//// losslessly so the suffix can be reproduced exactly. Unlike the numeric
//// fields, the suffix *is* checked against the RFC 9557 grammar: a
//// malformed suffix fails the parse.

import gleam/bit_array
import gleam/option.{type Option, None, Some}
import osler/internal

/// The optional time zone from an RFC 9557 (IXDTF) suffix -- the first
/// `[...]` group when it has no `=`, e.g. `[Europe/Paris]`, `[!Asia/Tokyo]`,
/// or an offset time zone `[+08:45]`.
///
/// `name` is captured verbatim -- either an IANA-style time zone name
/// (`America/Los_Angeles`) or an offset time zone (`+08:45`) -- so the
/// original suffix can be reproduced exactly. This module does **not**
/// look the name up in the IANA database, interpret an offset zone's
/// numeric value, or check it for consistency with the timestamp's own
/// offset (see RFC 9557 §3.4); that is the caller's job.
///
/// `critical` is `True` when the group carried a leading `!` critical flag
/// (`[!Europe/Paris]`). A critical flag means a recipient MUST NOT act on
/// the timestamp unless it can process the tag (RFC 9557 §3.3); osler
/// merely records the flag and leaves that policy to the caller.
pub type Zone {
  Zone(critical: Bool, name: String)
}

/// One `[key=value]` extension tag from an RFC 9557 (IXDTF) suffix, e.g.
/// `[u-ca=hebrew]`, `[!u-ca=islamic-civil]`, or an experimental
/// `[_foo=bar]`.
///
/// `value` is the raw `suffix-values` text with its internal hyphens
/// preserved (`islamic-civil` stays `islamic-civil`, rather than being
/// split into `["islamic", "civil"]`), captured verbatim for lossless
/// reproduction. `critical` records a leading `!` as for `Zone`.
///
/// Tags are returned in the order they appeared, duplicates and all. RFC
/// 9557 §3.3 says a consumer that does not want to act on a duplicate key
/// MUST use the first occurrence; osler leaves that policy to the caller.
pub type Tag {
  Tag(critical: Bool, key: String, value: String)
}

/// A fully-parsed RFC 9557 (IXDTF) timestamp: the raw, unvalidated
/// RFC 3339 date-time ints (year through offset in minutes), plus the
/// optional time `zone` and any extension `tags` from the suffix.
///
/// As with the rest of this module the numeric fields are **not**
/// validated -- see the module docs. The suffix, on the other hand, is
/// checked against the RFC 9557 grammar: a structurally malformed suffix
/// makes the whole parse fail.
pub type Ixdtf {
  Ixdtf(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    nanosecond: Int,
    offset_minutes: Int,
    zone: Option(Zone),
    tags: List(Tag),
  )
}

/// Parses a full RFC 9557 (IXDTF) string -- an RFC 3339 date-time (date,
/// time, and a **required** offset, in any of the shapes the other
/// functions accept) followed by an optional suffix -- into an `Ixdtf`.
///
/// The suffix is `[time-zone]` (an IANA name or `±HH:MM` offset zone,
/// optionally `!`-critical) followed by any number of `[key=value]` tags,
/// each optionally `!`-critical. It is parsed losslessly: the zone name
/// and each tag's key and value are captured exactly as written, so the
/// suffix can be reproduced verbatim.
///
/// ## Examples
///
/// ```gleam
/// parser.parse_ixdtf("1996-12-19T16:39:57-08:00[America/Los_Angeles]")
/// // -> Ok(Ixdtf(1996, 12, 19, 16, 39, 57, 0, -480,
/// //             Some(Zone(False, "America/Los_Angeles")), []))
/// ```
///
/// ```gleam
/// parser.parse_ixdtf("2022-07-08T00:14:07Z[!Europe/Paris][u-ca=hebrew]")
/// // -> Ok(Ixdtf(2022, 7, 8, 0, 14, 7, 0, 0,
/// //             Some(Zone(True, "Europe/Paris")),
/// //             [Tag(False, "u-ca", "hebrew")]))
/// ```
@external(javascript, "../osler_ffi.mjs", "parse_ixdtf")
pub fn parse_ixdtf(str: String) -> Result(Ixdtf, Nil) {
  case internal.parse_ixdtf_fast(bit_array.from_string(str)) {
    Error(Nil) -> Error(Nil)
    Ok(#(
      year,
      month,
      day,
      hour,
      minute,
      second,
      nanosecond,
      offset_minutes,
      zone,
      tags,
    )) ->
      Ok(Ixdtf(
        year:,
        month:,
        day:,
        hour:,
        minute:,
        second:,
        nanosecond:,
        offset_minutes:,
        zone: wrap_zone(zone),
        tags: wrap_tags(tags),
      ))
  }
}

fn wrap_zone(raw: Option(#(Bool, String))) -> Option(Zone) {
  case raw {
    None -> None
    Some(#(critical, name)) -> Some(Zone(critical:, name:))
  }
}

fn wrap_tags(raw: List(#(Bool, String, String))) -> List(Tag) {
  case raw {
    [] -> []
    [#(critical, key, value), ..rest] -> [
      Tag(critical:, key:, value:),
      ..wrap_tags(rest)
    ]
  }
}

/// Parses a date string into raw `#(year, month, day)` ints. `month` is
/// whatever digits were present -- it is not even checked to be 1-12.
///
/// ## Examples
///
/// ```gleam
/// parser.parse_date("2024-06-13")
/// // -> Ok(#(2024, 6, 13))
/// ```
///
/// ```gleam
/// parser.parse_date("2024-02-30")
/// // -> Ok(#(2024, 2, 30))
/// ```
@external(javascript, "../osler_ffi.mjs", "parse_date")
pub fn parse_date(str: String) -> Result(#(Int, Int, Int), Nil) {
  case internal.parse_date_fast(bit_array.from_string(str)) {
    Error(Nil) -> Error(Nil)
    Ok(#(year, month, day, rest)) ->
      case internal.accept_end(rest) {
        Error(Nil) -> Error(Nil)
        Ok(Nil) -> Ok(#(year, month, day))
      }
  }
}

/// Parses a time-of-day string into raw `#(hour, minute, second,
/// nanosecond)` ints.
///
/// ## Examples
///
/// ```gleam
/// parser.parse_time("13:42:11.354")
/// // -> Ok(#(13, 42, 11, 354_000_000))
/// ```
@external(javascript, "../osler_ffi.mjs", "parse_time")
pub fn parse_time(str: String) -> Result(#(Int, Int, Int, Int), Nil) {
  case internal.parse_time_fast(bit_array.from_string(str)) {
    Error(Nil) -> Error(Nil)
    Ok(#(hour, minute, second, nanosecond, rest)) ->
      case internal.accept_end(rest) {
        Error(Nil) -> Error(Nil)
        Ok(Nil) -> Ok(#(hour, minute, second, nanosecond))
      }
  }
}

/// Parses a UTC offset string into total signed minutes. Only checks the
/// loose per-field `hour <= 24 && minute <= 60` shape; range validation
/// (e.g. a realistic "-12:00..+14:00" policy) is the caller's job.
///
/// ## Examples
///
/// ```gleam
/// parser.parse_offset("-04:00")
/// // -> Ok(-240)
/// ```
@external(javascript, "../osler_ffi.mjs", "parse_offset")
pub fn parse_offset(str: String) -> Result(Int, Nil) {
  case internal.parse_offset_fast(bit_array.from_string(str)) {
    Error(Nil) -> Error(Nil)
    Ok(#(minutes, rest)) ->
      case internal.accept_end(rest) {
        Error(Nil) -> Error(Nil)
        Ok(Nil) -> Ok(minutes)
      }
  }
}

/// Parses a date and time with no offset into raw
/// `#(year, month, day, hour, minute, second, nanosecond)` ints.
///
/// ## Examples
///
/// ```gleam
/// parser.parse_naive_datetime("2024-06-13T13:42:11")
/// // -> Ok(#(2024, 6, 13, 13, 42, 11, 0))
/// ```
@external(javascript, "../osler_ffi.mjs", "parse_naive_datetime")
pub fn parse_naive_datetime(
  str: String,
) -> Result(#(Int, Int, Int, Int, Int, Int, Int), Nil) {
  internal.parse_naive_datetime_fast(bit_array.from_string(str))
}
