import gleam/option.{None, Some}
import osler/parser.{EndOfInput, IsoDate, IsoNaiveDateTime, IsoOffset, IsoTime}

// The raw `parser.parse` returns unvalidated `Parts`; these cover the
// structural parsing the deleted `parse_date`/`parse_time`/`parse_offset`/
// `parse_naive_datetime` functions used to, now reached through the compound
// ISO directives. A trailing `EndOfInput` is used wherever full consumption
// matters (a bare `parse` ignores trailing input).

pub fn iso_date_basic_test() {
  let assert Ok(a) = parser.parse("2024-06-13", [IsoDate])
  assert #(a.year, a.month, a.day) == #(Some(2024), Some(6), Some(13))

  let assert Ok(b) = parser.parse("20240613", [IsoDate])
  assert #(b.year, b.month, b.day) == #(Some(2024), Some(6), Some(13))

  let assert Ok(c) = parser.parse("2024/6/7", [IsoDate])
  assert #(c.year, c.month, c.day) == #(Some(2024), Some(6), Some(7))
}

pub fn iso_date_delimiters_test() {
  let for = fn(s) {
    let assert Ok(p) = parser.parse(s, [IsoDate, EndOfInput])
    #(p.year, p.month, p.day)
  }
  assert for("2024.06.13") == #(Some(2024), Some(6), Some(13))
  assert for("2024_06_13") == #(Some(2024), Some(6), Some(13))
  assert for("2024 5 6") == #(Some(2024), Some(5), Some(6))
}

pub fn iso_date_no_semantic_validation_test() {
  // The raw parser only checks the shape -- out-of-range values pass through.
  let assert Ok(a) = parser.parse("2024-02-30", [IsoDate])
  assert #(a.month, a.day) == #(Some(2), Some(30))

  let assert Ok(b) = parser.parse("2024-13-99", [IsoDate])
  assert #(b.month, b.day) == #(Some(13), Some(99))
}

pub fn iso_date_invalid_shape_test() {
  assert parser.parse("", [IsoDate, EndOfInput]) == Error(Nil)
  assert parser.parse("2024-06-13a", [IsoDate, EndOfInput]) == Error(Nil)
  assert parser.parse("2046", [IsoDate, EndOfInput]) == Error(Nil)
  assert parser.parse("20-06-13", [IsoDate, EndOfInput]) == Error(Nil)
}

pub fn iso_time_basic_test() {
  let assert Ok(a) = parser.parse("13:42:11", [IsoTime])
  assert #(a.hour, a.minute, a.second, a.nanosecond)
    == #(Some(13), Some(42), Some(11), Some(0))

  let assert Ok(b) = parser.parse("13:42:11.354", [IsoTime])
  assert b.nanosecond == Some(354_000_000)
}

pub fn iso_time_nanosecond_precision_test() {
  let assert Ok(a) = parser.parse("00:00:00.000000300", [IsoTime])
  assert a.nanosecond == Some(300)

  // digits past the 9th are truncated
  let assert Ok(b) = parser.parse("00:00:00.1234567891234", [IsoTime])
  assert b.nanosecond == Some(123_456_789)
}

pub fn iso_time_compact_test() {
  let assert Ok(a) = parser.parse("134211.314", [IsoTime])
  assert #(a.hour, a.minute, a.second, a.nanosecond)
    == #(Some(13), Some(42), Some(11), Some(314_000_000))

  let assert Ok(b) = parser.parse("1342", [IsoTime])
  assert #(b.hour, b.minute, b.second) == #(Some(13), Some(42), Some(0))
}

pub fn iso_time_single_digit_test() {
  let assert Ok(a) = parser.parse("4:0:1", [IsoTime])
  assert #(a.hour, a.minute, a.second) == #(Some(4), Some(0), Some(1))
}

pub fn iso_time_special_values_preserved_test() {
  // The raw parser keeps 24:00:00 and 23:59:60 verbatim (unlike `parse_ixdtf`,
  // which normalizes them into an absolute Timestamp).
  let assert Ok(a) = parser.parse("24:00:00", [IsoTime])
  assert #(a.hour, a.minute, a.second) == #(Some(24), Some(0), Some(0))

  let assert Ok(b) = parser.parse("23:59:60", [IsoTime])
  assert #(b.hour, b.minute, b.second) == #(Some(23), Some(59), Some(60))
}

pub fn iso_time_no_semantic_validation_test() {
  let assert Ok(a) = parser.parse("99:99:99", [IsoTime])
  assert #(a.hour, a.minute, a.second) == #(Some(99), Some(99), Some(99))
}

pub fn iso_time_invalid_shape_test() {
  assert parser.parse("19", [IsoTime, EndOfInput]) == Error(Nil)
  assert parser.parse("", [IsoTime, EndOfInput]) == Error(Nil)
}

pub fn iso_offset_basic_test() {
  let assert Ok(a) = parser.parse("-04:00", [IsoOffset])
  assert a.offset_minutes == Some(-240)

  let assert Ok(b) = parser.parse("Z", [IsoOffset])
  assert b.offset_minutes == Some(0)
}

pub fn iso_offset_condensed_test() {
  let assert Ok(a) = parser.parse("-0451", [IsoOffset])
  assert a.offset_minutes == Some(-291)

  let assert Ok(b) = parser.parse("+11", [IsoOffset])
  assert b.offset_minutes == Some(660)

  let assert Ok(c) = parser.parse("+1", [IsoOffset])
  assert c.offset_minutes == Some(60)
}

pub fn iso_offset_no_range_validation_test() {
  // osler does not enforce tempo's -12:00..+14:00 policy at the raw layer.
  let assert Ok(a) = parser.parse("+20:00", [IsoOffset])
  assert a.offset_minutes == Some(1200)
}

pub fn iso_offset_minute_sixty_quirk_test() {
  let assert Ok(a) = parser.parse("+00:60", [IsoOffset])
  assert a.offset_minutes == Some(60)

  assert parser.parse("+00:61", [IsoOffset, EndOfInput]) == Error(Nil)
}

pub fn iso_naive_datetime_test() {
  let assert Ok(a) =
    parser.parse("2024-06-13T13:42:11", [IsoNaiveDateTime, EndOfInput])
  assert #(a.year, a.month, a.day, a.hour, a.minute, a.second)
    == #(Some(2024), Some(6), Some(13), Some(13), Some(42), Some(11))

  let assert Ok(b) =
    parser.parse("2024-06-13 13:42:11", [IsoNaiveDateTime, EndOfInput])
  assert b.hour == Some(13)

  let assert Ok(c) = parser.parse("2024-06-13", [IsoNaiveDateTime, EndOfInput])
  assert #(c.day, c.hour) == #(Some(13), None)
}

pub fn iso_naive_datetime_invalid_test() {
  assert parser.parse("2024-06-13|13:42:11", [IsoNaiveDateTime, EndOfInput])
    == Error(Nil)
  assert parser.parse("2024-06", [IsoNaiveDateTime, EndOfInput]) == Error(Nil)
  assert parser.parse("13:42:11", [IsoNaiveDateTime, EndOfInput]) == Error(Nil)
  assert parser.parse("", [IsoNaiveDateTime, EndOfInput]) == Error(Nil)
}
