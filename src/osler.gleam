//// Fast parsing of date/time (IXDTF and more) strings.
////
//// `parse_ixdtf` parses the full RFC 9557 (IXDTF) format, returning a
//// `Timestamp` plus any time zone name and `[key=value]` extension tags from
//// the suffix.
////
//// If you would like to build a time library with custom types or semantics
//// on top of osler's parsing logic, `osler/parser` exposes the raw
//// parts of the internal parsing with no type construction or validation.

import gleam/option.{type Option}
import gleam/result
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import osler/parser

/// Parses a full RFC 9557 (IXDTF) timestamp: an RFC 3339 date-time (with a
/// **required** offset) followed by an optional suffix -- a time zone and/or
/// any number of `[key=value]` extension tags.
///
/// Returns the absolute `Timestamp`, the parsed offset (handed back
/// alongside since a `Timestamp` alone can't tell you what offset the string
/// was written in), and the suffix: an optional `parser.Zone` and a list of
/// `parser.Tag`s in the order they appeared.
///
/// Because a `Timestamp` is an absolute instant, ISO 8601's two special time
/// values -- `24:00:00` (end of day) and `23:59:60` (leap second) -- are
/// normalized to their equivalent ordinary instant (e.g.
/// `2024-06-30T24:00:00Z` becomes the same `Timestamp` as
/// `2024-07-01T00:00:00Z`). Use `parse_datetime_parts` if you need those
/// preserved verbatim.
///
/// The suffix is captured losslessly -- the zone name and each tag's key and
/// value come back exactly as written, so the original suffix can be
/// reproduced. osler does **not** resolve the zone against a time zone
/// database or check it for consistency with the offset (RFC 9557 §3.4);
/// that policy, along with any handling of `critical` tags and duplicate
/// keys, is left to the caller.
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
pub fn parse_ixdtf(
  str: String,
) -> Result(
  #(Timestamp, Duration, Option(parser.Zone), List(parser.Tag)),
  Nil,
) {
  use ixdtf <- result.try(parser.parse_ixdtf(str))
  use date <- result.try(validate_date(#(ixdtf.year, ixdtf.month, ixdtf.day)))
  use time <- result.try(
    validate_time(#(ixdtf.hour, ixdtf.minute, ixdtf.second, ixdtf.nanosecond)),
  )
  let offset = duration.minutes(ixdtf.offset_minutes)
  Ok(#(
    timestamp.from_calendar(date:, time:, offset:),
    offset,
    ixdtf.zone,
    ixdtf.tags,
  ))
}

fn validate_date(fields: #(Int, Int, Int)) -> Result(calendar.Date, Nil) {
  let #(year, month, day) = fields
  case calendar.month_from_int(month) {
    Error(Nil) -> Error(Nil)
    Ok(month) -> {
      let date = calendar.Date(year:, month:, day:)
      case calendar.is_valid_date(date) {
        True -> Ok(date)
        False -> Error(Nil)
      }
    }
  }
}

fn validate_time(
  fields: #(Int, Int, Int, Int),
) -> Result(calendar.TimeOfDay, Nil) {
  let #(hour, minute, second, nanosecond) = fields
  case is_valid_time(hour, minute, second) {
    True ->
      Ok(calendar.TimeOfDay(
        hours: hour,
        minutes: minute,
        seconds: second,
        nanoseconds: nanosecond,
      ))
    False -> Error(Nil)
  }
}

/// `gleam/time/calendar.is_valid_time_of_day` is stricter than this --
/// it doesn't allow ISO 8601's two special cases, `24:00:00` (end of day)
/// and `23:59:60` (leap second), which osler does accept.
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
