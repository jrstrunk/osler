import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import osler
import osler/parser.{
  Day2, ExtensionTags, Hour24Padded, Literal, Milli, Minute2, Month2,
  OffsetColon, Second2, Tag, Year4, Zone, ZoneName,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// --- parse_ixdtf ------------------------------------------------------------

fn parse_instant(
  str: String,
) -> Result(#(timestamp.Timestamp, duration.Duration), Nil) {
  case osler.parse_ixdtf(str) {
    Error(Nil) -> Error(Nil)
    Ok(#(ts, offset, _zone, _tags)) -> Ok(#(ts, offset))
  }
}

pub fn parse_ixdtf_basic_test() {
  let assert Ok(#(ts, offset)) = parse_instant("2024-06-13T23:04:00.009+10:00")
  assert offset == duration.minutes(600)
  assert timestamp.to_rfc3339(ts, offset) == "2024-06-13T23:04:00.009+10:00"
}

pub fn parse_ixdtf_suffix_test() {
  let assert Ok(#(_ts, offset, zone, tags)) =
    osler.parse_ixdtf(
      "1996-12-19T16:39:57-08:00[America/Los_Angeles][u-ca=hebrew]",
    )
  assert offset == duration.minutes(-480)
  assert zone == Some(Zone(False, "America/Los_Angeles"))
  assert tags == [Tag(False, "u-ca", "hebrew")]
}

pub fn parse_ixdtf_normalizes_end_of_day_test() {
  // 24:00:00 on the 30th is the exact same instant as 00:00:00 on the 1st.
  let assert Ok(#(ts, offset)) = parse_instant("2024-06-30T24:00:00Z")
  assert timestamp.to_rfc3339(ts, offset) == "2024-07-01T00:00:00Z"
}

pub fn parse_ixdtf_utc_test() {
  let assert Ok(#(ts, offset)) = parse_instant("2024-06-13T03:42:01.32Z")
  assert offset == duration.minutes(0)
  assert timestamp.to_rfc3339(ts, offset) == "2024-06-13T03:42:01.32Z"
}

pub fn parse_ixdtf_condensed_test() {
  let assert Ok(#(ts, offset)) = parse_instant("20240613T134211.314-04:00")
  assert offset == duration.minutes(-240)
  assert timestamp.to_rfc3339(ts, offset) == "2024-06-13T13:42:11.314-04:00"
}

pub fn parse_ixdtf_validates_date_test() {
  // Calendar validation happens at the osler layer (leap year, month/day
  // range) even though the raw parser accepts any shape.
  let assert Ok(_) = osler.parse_ixdtf("2000-02-29T00:00:00Z")
  assert osler.parse_ixdtf("2023-02-29T00:00:00Z") == Error(Nil)
  assert osler.parse_ixdtf("2024-06-54T00:00:00Z") == Error(Nil)
  assert osler.parse_ixdtf("2024-13-01T00:00:00Z") == Error(Nil)
}

pub fn parse_ixdtf_out_of_bounds_time_test() {
  assert parse_instant("2024-06-21T13:99:11-04:00") == Error(Nil)
}

pub fn parse_ixdtf_no_offset_test() {
  assert parse_instant("2024-06-13T13:42:11") == Error(Nil)
}

pub fn parse_ixdtf_invalid_test() {
  assert parse_instant("garbage") == Error(Nil)
  assert parse_instant("") == Error(Nil)
  assert parse_instant("2024-06-13T13:42:11 -04:00") == Error(Nil)
  assert parse_instant("2024-06-13T13:42:11Zjunk") == Error(Nil)
}

// --- format -----------------------------------------------------------------

pub fn format_basic_test() {
  let assert Ok(#(ts, offset, zone, tags)) =
    osler.parse_ixdtf("2024-06-13T23:04:00.009+10:00")
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
  assert osler.format(ts, in: directives, offset:, zone:, tags:)
    == Ok("2024-06-13T23:04:00.009+10:00")
}

pub fn format_local_offset_test() {
  // The timestamp is rendered against the given offset's local wall clock.
  let assert Ok(#(ts, _offset, zone, tags)) =
    osler.parse_ixdtf("2024-06-13T03:42:01Z")
  let directives = [
    Year4,
    Literal("-"),
    Month2,
    Literal("-"),
    Day2,
    Literal(" "),
    Hour24Padded,
    Literal(":"),
    Minute2,
  ]
  assert osler.format(
      ts,
      in: directives,
      offset: duration.minutes(600),
      zone:,
      tags:,
    )
    == Ok("2024-06-13 13:42")
  // sanity: the None/[] suffix from the parse
  assert #(zone, tags) == #(None, [])
}

pub fn format_ixdtf_round_trip_test() {
  let input = "1996-12-19T16:39:57-08:00[America/Los_Angeles][u-ca=hebrew]"
  let assert Ok(#(ts, offset, zone, tags)) = osler.parse_ixdtf(input)
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
    OffsetColon,
    ZoneName,
    ExtensionTags,
  ]
  assert osler.format(ts, in: directives, offset:, zone:, tags:) == Ok(input)
}

pub fn format_missing_field_test() {
  let assert Ok(#(ts, offset, zone, tags)) =
    osler.parse_ixdtf("2024-06-13T03:42:01Z")
  // The `Nano` directive needs sub-second precision, which is present (0) --
  // but `ZoneName` with no zone renders nothing rather than failing.
  let directives = [ZoneName]
  assert osler.format(ts, in: directives, offset:, zone:, tags:) == Ok("")
}

// --- parse_timestamp --------------------------------------------------------

pub fn parse_timestamp_basic_test() {
  let assert Ok(ts) = osler.parse_timestamp("2024-06-13T23:04:00.009+10:00")
  assert timestamp.to_rfc3339(ts, duration.minutes(600))
    == "2024-06-13T23:04:00.009+10:00"
  // identical to the Timestamp parse_ixdtf yields
  let assert Ok(#(ts2, _, _, _)) =
    osler.parse_ixdtf("2024-06-13T23:04:00.009+10:00")
  assert ts == ts2
}

pub fn parse_timestamp_ignores_noncritical_suffix_test() {
  let assert Ok(ts) =
    osler.parse_timestamp("2024-06-13T23:04:00Z[Europe/Paris][u-ca=hebrew]")
  assert timestamp.to_rfc3339(ts, duration.minutes(0)) == "2024-06-13T23:04:00Z"
}

pub fn parse_timestamp_rejects_critical_zone_test() {
  assert osler.parse_timestamp("2024-06-13T23:04:00Z[!Europe/Paris]")
    == Error(Nil)
}

pub fn parse_timestamp_rejects_critical_tag_test() {
  assert osler.parse_timestamp("2024-06-13T23:04:00Z[!u-ca=hebrew]")
    == Error(Nil)
  // a critical tag among non-critical ones still rejects
  assert osler.parse_timestamp("2024-06-13T23:04:00Z[u-ca=hebrew][!x-foo=bar]")
    == Error(Nil)
}

pub fn parse_timestamp_validates_and_normalizes_test() {
  // invalid date rejected
  assert osler.parse_timestamp("2023-02-29T00:00:00Z") == Error(Nil)
  // offset required
  assert osler.parse_timestamp("2024-06-13T23:04:00") == Error(Nil)
  // 24:00:00 normalizes to the next day, like parse_ixdtf
  let assert Ok(ts) = osler.parse_timestamp("2024-06-30T24:00:00Z")
  assert timestamp.to_rfc3339(ts, duration.minutes(0)) == "2024-07-01T00:00:00Z"
}
