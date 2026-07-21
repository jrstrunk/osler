import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import osler

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_date_basic_test() {
  let assert Ok(d) = osler.parse_date("2024-06-13")
  assert d == calendar.Date(2024, calendar.June, 13)
}

pub fn parse_date_delimiters_test() {
  let assert Ok(d1) = osler.parse_date("2024/6/7")
  assert d1 == calendar.Date(2024, calendar.June, 7)

  let assert Ok(d2) = osler.parse_date("2024.06.13")
  assert d2 == calendar.Date(2024, calendar.June, 13)

  let assert Ok(d3) = osler.parse_date("2024_06_13")
  assert d3 == calendar.Date(2024, calendar.June, 13)

  let assert Ok(d4) = osler.parse_date("2024 5 6")
  assert d4 == calendar.Date(2024, calendar.May, 6)

  let assert Ok(d5) = osler.parse_date("20240613")
  assert d5 == calendar.Date(2024, calendar.June, 13)
}

pub fn parse_date_leap_year_test() {
  let assert Ok(d) = osler.parse_date("2000-02-29")
  assert d == calendar.Date(2000, calendar.February, 29)

  assert osler.parse_date("2023-02-29") == Error(Nil)
}

pub fn parse_date_out_of_range_test() {
  assert osler.parse_date("2024-06-54") == Error(Nil)
  assert osler.parse_date("2024-15-13") == Error(Nil)
  assert osler.parse_date("2024-01-33") == Error(Nil)
}

pub fn parse_date_no_arbitrary_year_bound_test() {
  // osler does not enforce tempo's 1000..9999 policy; that is the
  // caller's job. Note this is about *value* range, not string length --
  // the year is always exactly 4 digits structurally (same as gtempo's
  // original fast parser), so a 3-digit year like "999" parses fine
  // (padded to "0999" it's exactly 4 digits) but a genuine 5-digit year
  // string does not match the grammar at all.
  assert osler.parse_date("0999-01-01")
    == Ok(calendar.Date(999, calendar.January, 1))
  assert osler.parse_date("0001-01-01")
    == Ok(calendar.Date(1, calendar.January, 1))
}

pub fn parse_date_invalid_format_test() {
  assert osler.parse_date("") == Error(Nil)
  assert osler.parse_date("2024-06-13a") == Error(Nil)
  assert osler.parse_date("2046") == Error(Nil)
  assert osler.parse_date("20-06-13") == Error(Nil)
}

pub fn parse_time_basic_test() {
  let assert Ok(t) = osler.parse_time("13:42:11")
  assert t == calendar.TimeOfDay(13, 42, 11, 0)
}

pub fn parse_time_fraction_test() {
  let assert Ok(t) = osler.parse_time("13:42:11.354")
  assert t == calendar.TimeOfDay(13, 42, 11, 354_000_000)
}

pub fn parse_time_nanosecond_precision_test() {
  let assert Ok(t) = osler.parse_time("00:00:00.000000300")
  assert t == calendar.TimeOfDay(0, 0, 0, 300)
}

pub fn parse_time_truncates_past_nanosecond_test() {
  let assert Ok(t) = osler.parse_time("00:00:00.1234567891234")
  assert t == calendar.TimeOfDay(0, 0, 0, 123_456_789)
}

pub fn parse_time_compact_test() {
  let assert Ok(t) = osler.parse_time("134211.314")
  assert t == calendar.TimeOfDay(13, 42, 11, 314_000_000)

  let assert Ok(t2) = osler.parse_time("1342")
  assert t2 == calendar.TimeOfDay(13, 42, 0, 0)
}

pub fn parse_time_single_digit_test() {
  let assert Ok(t) = osler.parse_time("4:0:1")
  assert t == calendar.TimeOfDay(4, 0, 1, 0)
}

pub fn parse_time_end_of_day_test() {
  let assert Ok(t) = osler.parse_time("24:00:00")
  assert t == calendar.TimeOfDay(24, 0, 0, 0)
}

pub fn parse_time_leap_second_test() {
  let assert Ok(t) = osler.parse_time("23:59:60")
  assert t == calendar.TimeOfDay(23, 59, 60, 0)
}

pub fn parse_time_out_of_range_test() {
  assert osler.parse_time("23:60:00") == Error(Nil)
  assert osler.parse_time("50:18:50") == Error(Nil)
  assert osler.parse_time("19") == Error(Nil)
  assert osler.parse_time("") == Error(Nil)
}

pub fn parse_offset_basic_test() {
  assert osler.parse_offset("-04:00") == Ok(duration.minutes(-240))
  assert osler.parse_offset("+01:10") == Ok(duration.minutes(70))
  assert osler.parse_offset("Z") == Ok(duration.minutes(0))
  assert osler.parse_offset("z") == Ok(duration.minutes(0))
}

pub fn parse_offset_condensed_test() {
  assert osler.parse_offset("-0451") == Ok(duration.minutes(-291))
  assert osler.parse_offset("+11") == Ok(duration.minutes(660))
  assert osler.parse_offset("+1") == Ok(duration.minutes(60))
}

pub fn parse_offset_no_arbitrary_range_bound_test() {
  // osler does not enforce tempo's -12:00..+14:00 policy.
  assert osler.parse_offset("+20:00") == Ok(duration.minutes(1200))
}

pub fn parse_offset_minute_sixty_quirk_test() {
  assert osler.parse_offset("+00:60") == Ok(duration.minutes(60))
  assert osler.parse_offset("+00:61") == Error(Nil)
}

pub fn parse_offset_invalid_test() {
  assert osler.parse_offset(":") == Error(Nil)
  assert osler.parse_offset("14:00") == Error(Nil)
  assert osler.parse_offset("") == Error(Nil)
}

pub fn parse_naive_datetime_basic_test() {
  let assert Ok(#(d, t)) = osler.parse_naive_datetime("2024-06-13T13:42:11")
  assert d == calendar.Date(2024, calendar.June, 13)
  assert t == calendar.TimeOfDay(13, 42, 11, 0)
}

pub fn parse_naive_datetime_space_delim_test() {
  let assert Ok(#(d, t)) = osler.parse_naive_datetime("2024-06-13 13:42:11")
  assert d == calendar.Date(2024, calendar.June, 13)
  assert t == calendar.TimeOfDay(13, 42, 11, 0)
}

pub fn parse_naive_datetime_date_only_test() {
  let assert Ok(#(d, t)) = osler.parse_naive_datetime("2024-06-13")
  assert d == calendar.Date(2024, calendar.June, 13)
  assert t == calendar.TimeOfDay(0, 0, 0, 0)
}

pub fn parse_naive_datetime_invalid_test() {
  assert osler.parse_naive_datetime("2024-06-13|13:42:11") == Error(Nil)
  assert osler.parse_naive_datetime("2024-06") == Error(Nil)
  assert osler.parse_naive_datetime("13:42:11") == Error(Nil)
  assert osler.parse_naive_datetime("") == Error(Nil)
}

// `osler.parse_datetime` was removed in favour of `parse_ixdtf`, which now
// returns the `Timestamp` directly; this drops the (unused here) suffix.
fn parse_instant(
  str: String,
) -> Result(#(timestamp.Timestamp, duration.Duration), Nil) {
  case osler.parse_ixdtf(str) {
    Error(Nil) -> Error(Nil)
    Ok(#(ts, offset, _zone, _tags)) -> Ok(#(ts, offset))
  }
}

pub fn parse_datetime_basic_test() {
  let assert Ok(#(ts, offset)) = parse_instant("2024-06-13T23:04:00.009+10:00")
  assert offset == duration.minutes(600)
  assert timestamp.to_rfc3339(ts, offset) == "2024-06-13T23:04:00.009+10:00"
}

pub fn parse_datetime_normalizes_end_of_day_test() {
  // 24:00:00 on the 30th is the exact same instant as 00:00:00 on the 1st
  // -- a Timestamp can't tell the two apart.
  let assert Ok(#(ts, offset)) = parse_instant("2024-06-30T24:00:00Z")
  assert timestamp.to_rfc3339(ts, offset) == "2024-07-01T00:00:00Z"
}

pub fn parse_datetime_parts_preserves_end_of_day_test() {
  let assert Ok(#(date, time, offset)) =
    osler.parse_datetime_parts("2024-06-30T24:00:00Z")
  assert date == calendar.Date(2024, calendar.June, 30)
  assert time == calendar.TimeOfDay(24, 0, 0, 0)
  assert offset == duration.minutes(0)
}

pub fn parse_datetime_parts_preserves_leap_second_test() {
  let assert Ok(#(date, time, offset)) =
    osler.parse_datetime_parts("2024-06-30T23:59:60Z")
  assert date == calendar.Date(2024, calendar.June, 30)
  assert time == calendar.TimeOfDay(23, 59, 60, 0)
  assert offset == duration.minutes(0)
}

pub fn parse_datetime_parts_matches_instant_otherwise_test() {
  let assert Ok(#(ts, offset1)) = parse_instant("2024-06-13T23:04:00.009+10:00")
  let assert Ok(#(date, time, offset2)) =
    osler.parse_datetime_parts("2024-06-13T23:04:00.009+10:00")
  assert offset1 == offset2
  assert timestamp.from_calendar(date:, time:, offset: offset2) == ts
}

pub fn parse_datetime_utc_test() {
  let assert Ok(#(ts, offset)) = parse_instant("2024-06-13T03:42:01.32Z")
  assert offset == duration.minutes(0)
  assert timestamp.to_rfc3339(ts, offset) == "2024-06-13T03:42:01.32Z"
}

pub fn parse_datetime_condensed_test() {
  let assert Ok(#(ts, offset)) = parse_instant("20240613T134211.314-04:00")
  assert offset == duration.minutes(-240)
  assert timestamp.to_rfc3339(ts, offset) == "2024-06-13T13:42:11.314-04:00"
}

pub fn parse_datetime_no_offset_test() {
  assert parse_instant("2024-06-13T13:42:11") == Error(Nil)
}

pub fn parse_datetime_out_of_bounds_test() {
  assert parse_instant("2024-06-54T13:42:11-04:00") == Error(Nil)
  assert parse_instant("2024-06-21T13:99:11-04:00") == Error(Nil)
}

pub fn parse_datetime_invalid_test() {
  assert parse_instant("garbage") == Error(Nil)
  assert parse_instant("") == Error(Nil)
  assert parse_instant("2024-06-13T13:42:11 -04:00") == Error(Nil)
  assert parse_instant("2024-06-13T13:42:11Zjunk") == Error(Nil)
}

pub fn parse_datetime_parts_tolerates_and_drops_suffix_test() {
  // `parse_datetime_parts` accepts an RFC 9557 suffix but drops it -- the
  // instant is fully determined without it. Use `osler.parse_ixdtf` to
  // capture the zone/tags. A malformed suffix still fails.
  let assert Ok(#(date, time, off)) =
    osler.parse_datetime_parts(
      "2024-06-30T23:59:60Z[!Europe/London][u-ca=hebrew]",
    )
  assert date == calendar.Date(2024, calendar.June, 30)
  assert time == calendar.TimeOfDay(23, 59, 60, 0)
  assert off == duration.minutes(0)

  assert osler.parse_datetime_parts("2024-06-13T23:04:00.009+10:00[bad zone]")
    == Error(Nil)
}
