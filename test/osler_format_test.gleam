import gleam/option.{None, Some}
import osler/parser.{
  type Directive, Am, Day, Day2, EndOfInput, ExtensionTags, Hour12, Hour12Padded,
  Hour24, Hour24Padded, IsoDate, IsoNaiveDateTime, IsoTime, Literal,
  MeridiemLower, MeridiemUpper, Micro, Milli, Minute, Minute2, Month, Month2,
  MonthLongName, MonthShortName, Offset, OffsetColon, OffsetNoColon, Parts, Pm,
  Second, Second2, Separator, Tag, WeekdayLongName, WeekdayNumber,
  WeekdayShortName, WeekdayShortName2, Year4, Zone, ZoneName,
}

fn sp(items: List(Directive)) -> List(Directive) {
  // interleave a literal space between directives
  case items {
    [] -> []
    [last] -> [last]
    [first, ..rest] -> [first, Literal(" "), ..sp(rest)]
  }
}

// --- fine-grained parse -----------------------------------------------------

pub fn parse_date_literals_test() {
  let assert Ok(p) =
    parser.parse("2024/06/08, 13:42:11", [
      Year4,
      Literal("/"),
      Month2,
      Literal("/"),
      Day2,
    ])
  // trailing ", 13:42:11" is ignored
  assert p.year == Some(2024)
  assert p.month == Some(6)
  assert p.day == Some(8)
}

pub fn parse_long_month_name_test() {
  let assert Ok(p) =
    parser.parse("January 13, 2024", [
      MonthLongName,
      Literal(" "),
      Day2,
      Literal(", "),
      Year4,
    ])
  assert p.month == Some(1)
  assert p.day == Some(13)
  assert p.year == Some(2024)
}

pub fn parse_short_month_name_test() {
  let assert Ok(p) =
    parser.parse("Jan 3, 1998", [
      MonthShortName,
      Literal(" "),
      Day,
      Literal(", "),
      Year4,
    ])
  assert p.month == Some(1)
  assert p.day == Some(3)
  assert p.year == Some(1998)
}

pub fn parse_twelve_hour_am_test() {
  let assert Ok(p) =
    parser.parse("12 2 am", [
      Hour12,
      Literal(" "),
      Minute,
      Literal(" "),
      MeridiemLower,
    ])
  assert p.twelve_hour == Some(12)
  assert p.minute == Some(2)
  assert p.period == Some(Am)
  // hour is not resolved at the raw layer
  assert p.hour == None
}

pub fn parse_twelve_hour_pm_test() {
  let assert Ok(p) =
    parser.parse("2 42 pm", [
      Hour12,
      Literal(" "),
      Minute,
      Literal(" "),
      MeridiemLower,
    ])
  assert p.twelve_hour == Some(2)
  assert p.period == Some(Pm)
}

pub fn parse_offset_condensed_test() {
  let assert Ok(a) = parser.parse("-04:00", [Offset])
  assert a.offset_minutes == Some(-240)

  let assert Ok(b) = parser.parse("Z", [Offset])
  assert b.offset_minutes == Some(0)

  let assert Ok(c) = parser.parse("-04", [Offset])
  assert c.offset_minutes == Some(-240)
}

pub fn parse_literal_mismatch_fails_test() {
  assert parser.parse("2024-06-08", [Year4, Literal("/"), Month2]) == Error(Nil)
}

// --- flexible separators ----------------------------------------------------

pub fn parse_separator_delimited_test() {
  let ds = [Year4, Separator, Month, Separator, Day]
  let assert Ok(a) = parser.parse("2024-6-3", ds)
  assert a
    == Parts(
      Some(2024),
      Some(6),
      Some(3),
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      [],
    )

  let assert Ok(b) = parser.parse("2024/6/7", ds)
  assert b.month == Some(6)
  assert b.day == Some(7)

  let assert Ok(c) = parser.parse("2024.11.13", ds)
  assert c.month == Some(11)
  assert c.day == Some(13)
}

pub fn parse_separator_compact_test() {
  let assert Ok(p) =
    parser.parse("20240613", [Year4, Separator, Month2, Separator, Day2])
  assert p.year == Some(2024)
  assert p.month == Some(6)
  assert p.day == Some(13)
}

// --- compound ISO directives ------------------------------------------------

pub fn parse_iso_date_flexible_test() {
  let assert Ok(a) = parser.parse("2024-06-13", [IsoDate])
  assert a.year == Some(2024)

  let assert Ok(b) = parser.parse("2024/06/13", [IsoDate])
  assert b.month == Some(6)

  let assert Ok(c) = parser.parse("20240613", [IsoDate])
  assert c.day == Some(13)
}

pub fn parse_iso_time_test() {
  let assert Ok(a) = parser.parse("13:42:11.354", [IsoTime])
  assert a.hour == Some(13)
  assert a.minute == Some(42)
  assert a.second == Some(11)
  assert a.nanosecond == Some(354_000_000)

  let assert Ok(b) = parser.parse("13:42", [IsoTime])
  assert b.second == Some(0)
}

pub fn parse_iso_naive_test() {
  let assert Ok(a) =
    parser.parse("2024-06-13T13:42:11", [IsoNaiveDateTime, EndOfInput])
  assert a.year == Some(2024)
  assert a.hour == Some(13)

  let assert Ok(b) =
    parser.parse("2024-06-13 13:42:11", [IsoNaiveDateTime, EndOfInput])
  assert b.hour == Some(13)

  let assert Ok(c) = parser.parse("2024-06-13", [IsoNaiveDateTime, EndOfInput])
  assert c.hour == None
  assert c.day == Some(13)
}

// --- EndOfInput -------------------------------------------------------------

pub fn parse_end_of_input_test() {
  assert parser.parse("2024-06-13xyz", [IsoDate, EndOfInput]) == Error(Nil)

  let assert Ok(_) = parser.parse("2024-06-13", [IsoDate, EndOfInput])
  Nil
}

pub fn parse_full_datetime_test() {
  let assert Ok(p) =
    parser.parse("2024/06/08, 13:42:11, -04:00", [
      Year4,
      Literal("/"),
      Month2,
      Literal("/"),
      Day2,
      Literal(", "),
      Hour24Padded,
      Literal(":"),
      Minute2,
      Literal(":"),
      Second2,
      Literal(", "),
      Offset,
    ])
  assert p.year == Some(2024)
  assert p.month == Some(6)
  assert p.day == Some(8)
  assert p.hour == Some(13)
  assert p.minute == Some(42)
  assert p.second == Some(11)
  assert p.offset_minutes == Some(-240)
}

// --- rendering --------------------------------------------------------------

pub fn format_all_tokens_test() {
  // 2024-06-03T09:02:01.014920-04:00 (a Monday). Pins every render directive.
  let parts =
    Parts(
      year: Some(2024),
      month: Some(6),
      day: Some(3),
      hour: Some(9),
      twelve_hour: None,
      period: None,
      minute: Some(2),
      second: Some(1),
      nanosecond: Some(14_920_000),
      offset_minutes: Some(-240),
      zone: None,
      tags: [],
    )

  let directives =
    sp([
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
      OffsetColon,
      OffsetNoColon,
      Offset,
    ])

  assert parser.format(parts, directives)
    == Ok(
      "2024 6 06 Jun June 3 03 1 Mo Mon Monday 9 09 9 09 am AM 2 02 1 01 014 014920 -04:00 -0400 -04",
    )
}

pub fn format_pm_and_zero_offset_test() {
  // 22:52:21 -> h/hh = 10 pm ; zero offset -> Z / +00:00 / +0000.
  let parts =
    Parts(
      year: Some(2001),
      month: Some(12),
      day: Some(25),
      hour: Some(22),
      twelve_hour: None,
      period: None,
      minute: Some(52),
      second: Some(21),
      nanosecond: Some(0),
      offset_minutes: Some(0),
      zone: None,
      tags: [],
    )

  assert parser.format(parts, [Hour12, Literal(" "), MeridiemLower])
    == Ok("10 pm")
  assert parser.format(parts, [OffsetColon]) == Ok("+00:00")
  assert parser.format(parts, [OffsetNoColon]) == Ok("+0000")
  assert parser.format(parts, [Offset]) == Ok("Z")
  // 2001-12-25 is a Tuesday
  assert parser.format(parts, [WeekdayNumber, Literal(" "), WeekdayShortName2])
    == Ok("2 Tu")
}

pub fn format_midnight_noon_test() {
  let midnight =
    Parts(
      Some(2024),
      Some(1),
      Some(1),
      Some(0),
      None,
      None,
      Some(42),
      Some(0),
      Some(0),
      Some(0),
      None,
      [],
    )
  assert parser.format(midnight, [
      Hour12,
      Literal(":"),
      Minute2,
      Literal(" "),
      MeridiemLower,
    ])
    == Ok("12:42 am")

  let noon = Parts(..midnight, hour: Some(12))
  assert parser.format(noon, [Hour12, Literal(" "), MeridiemLower])
    == Ok("12 pm")
}

pub fn format_missing_field_fails_test() {
  let parts = parser.empty_parts()
  assert parser.format(parts, [Year4]) == Error(Nil)
}

pub fn format_weekday_friday_test() {
  // 2024-06-21 is a Friday.
  let parts =
    Parts(
      Some(2024),
      Some(6),
      Some(21),
      Some(13),
      None,
      None,
      Some(42),
      Some(11),
      Some(0),
      None,
      None,
      [],
    )
  assert parser.format(parts, [
      WeekdayShortName,
      Literal(" @ "),
      Hour12,
      Literal(":"),
      Minute2,
      Literal(" "),
      MeridiemUpper,
    ])
    == Ok("Fri @ 1:42 PM")
}

// --- round trips ------------------------------------------------------------

pub fn round_trip_iso_test() {
  let directives = [
    Year4,
    Literal("-"),
    Month2,
    Literal("-"),
    Day2,
    Literal("T"),
    Hour24Padded,
    Literal(":"),
    Minute2,
    Literal(":"),
    Second2,
    Literal("."),
    Milli,
    OffsetColon,
  ]
  let input = "2025-03-09T14:53:45.123-05:00"
  let assert Ok(parts) = parser.parse(input, directives)
  assert parser.format(parts, directives) == Ok(input)
}

// --- RFC 9557 zone + tags directives ---------------------------------------

pub fn parse_zone_and_tags_test() {
  let ds = [IsoDate, Literal("T"), IsoTime, Offset, ZoneName, ExtensionTags]
  let assert Ok(p) =
    parser.parse(
      "1996-12-19T16:39:57-08:00[America/Los_Angeles][u-ca=hebrew]",
      ds,
    )
  assert p.zone == Some(Zone(False, "America/Los_Angeles"))
  assert p.tags == [Tag(False, "u-ca", "hebrew")]
  assert p.offset_minutes == Some(-480)
}

pub fn parse_critical_zone_test() {
  let ds = [IsoDate, Literal("T"), IsoTime, Offset, ZoneName, ExtensionTags]
  let assert Ok(p) =
    parser.parse("2022-07-08T00:14:07Z[!Europe/Paris][u-ca=hebrew]", ds)
  assert p.zone == Some(Zone(True, "Europe/Paris"))
  assert p.tags == [Tag(False, "u-ca", "hebrew")]
}

pub fn parse_tags_only_no_zone_test() {
  let ds = [IsoDate, Literal("T"), IsoTime, Offset, ZoneName, ExtensionTags]
  let assert Ok(p) = parser.parse("2022-07-08T00:14:07Z[u-ca=hebrew]", ds)
  assert p.zone == None
  assert p.tags == [Tag(False, "u-ca", "hebrew")]
}

pub fn render_zone_and_tags_test() {
  let parts =
    Parts(
      year: Some(1996),
      month: Some(12),
      day: Some(19),
      hour: Some(16),
      twelve_hour: None,
      period: None,
      minute: Some(39),
      second: Some(57),
      nanosecond: Some(0),
      offset_minutes: Some(-480),
      zone: Some(Zone(False, "America/Los_Angeles")),
      tags: [Tag(False, "u-ca", "hebrew")],
    )
  let ds = [
    IsoDate,
    Literal("T"),
    IsoTime,
    OffsetColon,
    ZoneName,
    ExtensionTags,
  ]
  assert parser.format(parts, ds)
    == Ok("1996-12-19T16:39:57-08:00[America/Los_Angeles][u-ca=hebrew]")
}

pub fn suffix_round_trip_test() {
  let ds = [IsoDate, Literal("T"), IsoTime, Offset, ZoneName, ExtensionTags]
  let input = "2022-07-08T00:14:07Z[!Europe/Paris][u-ca=hebrew][x-foo=bar-baz]"
  let assert Ok(parts) = parser.parse(input, ds)
  assert parser.format(parts, ds) == Ok(input)
}

// --- render coverage for the remaining directives ---------------------------

pub fn format_remaining_directives_test() {
  let parts =
    Parts(
      year: Some(2024),
      month: Some(6),
      day: Some(13),
      hour: Some(13),
      twelve_hour: None,
      period: None,
      minute: Some(42),
      second: Some(11),
      nanosecond: Some(123_456_789),
      offset_minutes: Some(330),
      zone: None,
      tags: [],
    )

  assert parser.format(parts, [parser.Nano]) == Ok("123456789")
  assert parser.format(parts, [parser.OffsetZulu]) == Ok("+05:30")
  assert parser.format(parts, [parser.Gmt]) == Ok("GMT")
  assert parser.format(parts, [parser.Separator]) == Ok("-")
  assert parser.format(parts, [parser.TimeSeparator]) == Ok(":")
  assert parser.format(parts, [parser.DateTimeSeparator]) == Ok("T")
  assert parser.format(parts, [parser.IsoDate]) == Ok("2024-06-13")
  assert parser.format(parts, [parser.IsoTime]) == Ok("13:42:11.123456789")
  assert parser.format(parts, [parser.IsoOffset]) == Ok("+05:30")
  assert parser.format(parts, [parser.IsoNaiveDateTime])
    == Ok("2024-06-13T13:42:11.123456789")
}

pub fn format_zero_offset_zulu_and_iso_test() {
  let parts = parser.Parts(..parser.empty_parts(), offset_minutes: Some(0))
  assert parser.format(parts, [parser.OffsetZulu]) == Ok("Z")
  assert parser.format(parts, [parser.IsoOffset]) == Ok("Z")
}

pub fn parse_format_round_trip_test() {
  let directives = [
    WeekdayShortName,
    Literal(", "),
    Day2,
    Literal(" "),
    MonthShortName,
    Literal(" "),
    Year4,
    Literal(" "),
    Hour24Padded,
    Literal(":"),
    Minute2,
    Literal(":"),
    Second2,
  ]
  let assert Ok(p) = parser.parse("Thu, 13 Jun 2024 13:42:11", directives)
  assert p.day == Some(13)
  assert p.month == Some(6)
  assert p.year == Some(2024)
  assert parser.format(p, directives) == Ok("Thu, 13 Jun 2024 13:42:11")
}
