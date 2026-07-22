import gleam/option.{None, Some}
import gleam/time/calendar.{December, February, July, June, May, TimeOfDay}
import gleam/time/duration
import osler

fn date(year, month, day) {
  Some(calendar.Date(year, month, day))
}

fn time(hour, minute, second, nanosecond) {
  Some(TimeOfDay(hour, minute, second, nanosecond))
}

fn offset(minutes) {
  Some(duration.minutes(minutes))
}

// --- ported tempo.parse_any contract ----------------------------------------

pub fn all_components_test() {
  assert osler.parse_any("2024/06/22 at 13:42:11.314 in +05:00")
    == #(date(2024, June, 22), time(13, 42, 11, 314_000_000), offset(300))
}

pub fn american_with_pm_test() {
  assert osler.parse_any("06/22/2024 at 1:42:11 PM in -04:00")
    == #(date(2024, June, 22), time(13, 42, 11, 0), offset(-240))
}

pub fn z_upper_offset_test() {
  assert osler.parse_any("12-10-2024T00:00:00Z")
    == #(date(2024, December, 10), time(0, 0, 0, 0), offset(0))
}

pub fn z_lower_offset_test() {
  assert osler.parse_any("12/10/2024 00:00:00 z")
    == #(date(2024, December, 10), time(0, 0, 0, 0), offset(0))
}

pub fn zero_offset_test() {
  assert osler.parse_any("12-10-2024T00:00:00+00:00")
    == #(date(2024, December, 10), time(0, 0, 0, 0), offset(0))
}

pub fn date_only_test() {
  assert osler.parse_any("2024/06/22") == #(date(2024, June, 22), None, None)
}

pub fn date_single_digit_test() {
  assert osler.parse_any("2024/6/2") == #(date(2024, June, 2), None, None)
}

pub fn date_single_digit_us_test() {
  assert osler.parse_any("7/8/2024") == #(date(2024, July, 8), None, None)
}

pub fn date_ordinal_test() {
  assert osler.parse_any("June 21st, 2024")
    == #(date(2024, June, 21), None, None)
}

pub fn date_single_digit_ordinal_test() {
  assert osler.parse_any("July 8th, 2024") == #(date(2024, July, 8), None, None)
}

pub fn time_only_test() {
  assert osler.parse_any("13:42:11") == #(None, time(13, 42, 11, 0), None)
}

pub fn time_am_test() {
  assert osler.parse_any("1:42:11 AM") == #(None, time(1, 42, 11, 0), None)
}

pub fn time_pm_test() {
  assert osler.parse_any("1:42:11 PM") == #(None, time(13, 42, 11, 0), None)
}

pub fn time_hour_min_test() {
  assert osler.parse_any("01:42 PM") == #(None, time(13, 42, 0, 0), None)
}

pub fn offset_only_test() {
  assert osler.parse_any("+05:00") == #(None, None, offset(300))
}

pub fn serial_number_is_not_a_date_test() {
  assert osler.parse_any("20240422012333") == #(None, None, None)
}

pub fn squished_iso_test() {
  assert osler.parse_any("20240622_134211")
    == #(date(2024, June, 22), time(13, 42, 11, 0), None)
}

pub fn squished_american_test() {
  assert osler.parse_any("06222024_134211")
    == #(date(2024, June, 22), time(13, 42, 11, 0), None)
}

pub fn dot_separators_test() {
  assert osler.parse_any("2024.06.22") == #(date(2024, June, 22), None, None)
}

pub fn written_date_test() {
  assert osler.parse_any("June 21, 2024") == #(date(2024, June, 21), None, None)
}

pub fn written_short_date_test() {
  assert osler.parse_any("Dec 25, 2024 at 6:00 AM")
    == #(date(2024, December, 25), time(6, 0, 0, 0), None)
}

pub fn offset_condensed_test() {
  assert osler.parse_any("2025-02-11T06:00:00-05")
    == #(date(2025, February, 11), time(6, 0, 0, 0), offset(-300))
}

// --- deliberate improvements over tempo.parse_any ---------------------------

pub fn full_nanosecond_precision_test() {
  // tempo truncates the fraction to microseconds (123_456_000); osler is
  // nanosecond-native and keeps all nine digits.
  assert osler.parse_any("2025-02-11T06:00:00.123456789Z")
    == #(date(2025, February, 11), time(6, 0, 0, 123_456_789), offset(0))
}

pub fn negative_offset_with_minutes_is_correct_test() {
  // tempo's parse_any applies the sign only to the hour, giving -270; the
  // correct value is -(5*60 + 30) = -330.
  assert osler.parse_any("2024-06-13T00:00:00-05:30")
    == #(date(2024, June, 13), time(0, 0, 0, 0), offset(-330))
}

pub fn any_fraction_length_test() {
  // tempo only accepts 3/6/9-digit fractions and returns None otherwise; osler
  // accepts any length.
  assert osler.parse_any("12:30:45.5")
    == #(None, time(12, 30, 45, 500_000_000), None)
}

pub fn case_insensitive_month_names_test() {
  // tempo drops lowercase names (they fail its Title-case lookup) and never
  // matches all-caps; osler accepts any case.
  assert osler.parse_any("june 21, 2024") == #(date(2024, June, 21), None, None)
  assert osler.parse_any("JUNE 21, 2024") == #(date(2024, June, 21), None, None)
  assert osler.parse_any("dec 25, 2024")
    == #(date(2024, December, 25), None, None)
}

pub fn date_alongside_serial_test() {
  // tempo bails entirely on any 10+ digit run; osler only requires the date
  // itself to be a clean token, so a real date beside a long id is still found.
  assert osler.parse_any("order 1234567890 shipped 2024-06-13")
    == #(date(2024, June, 13), None, None)
}

pub fn skips_invalid_and_keeps_scanning_test() {
  // tempo takes the first structural match and gives up if it is out of range;
  // osler scans past the invalid 2024-13-45 to the valid date.
  assert osler.parse_any("2024-13-45 or maybe 2024-05-06")
    == #(date(2024, May, 6), None, None)
}

// --- nothing to find --------------------------------------------------------

pub fn no_components_test() {
  assert osler.parse_any("just some words here") == #(None, None, None)
}

pub fn empty_string_test() {
  assert osler.parse_any("") == #(None, None, None)
}
