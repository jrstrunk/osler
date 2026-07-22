import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import osler
import osler/parser.{Ixdtf, Tag, Zone}

pub fn ixdtf_no_suffix_test() {
  assert parser.parse_ixdtf("1996-12-19T16:39:57-08:00")
    == Ok(Ixdtf(1996, 12, 19, 16, 39, 57, 0, -480, None, []))
}

pub fn ixdtf_named_zone_test() {
  assert parser.parse_ixdtf("1996-12-19T16:39:57-08:00[America/Los_Angeles]")
    == Ok(
      Ixdtf(
        1996,
        12,
        19,
        16,
        39,
        57,
        0,
        -480,
        Some(Zone(False, "America/Los_Angeles")),
        [],
      ),
    )
}

pub fn ixdtf_critical_zone_and_tag_test() {
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[!Europe/Paris][u-ca=hebrew]")
    == Ok(
      Ixdtf(2022, 7, 8, 0, 14, 7, 0, 0, Some(Zone(True, "Europe/Paris")), [
        Tag(False, "u-ca", "hebrew"),
      ]),
    )
}

pub fn ixdtf_offset_zone_test() {
  assert parser.parse_ixdtf("2022-07-08T00:14:07+08:45[+08:45]")
    == Ok(Ixdtf(2022, 7, 8, 0, 14, 7, 0, 525, Some(Zone(False, "+08:45")), []))
}

pub fn ixdtf_tag_only_no_zone_test() {
  assert parser.parse_ixdtf("1996-12-19T16:39:57-08:00[u-ca=hebrew]")
    == Ok(
      Ixdtf(1996, 12, 19, 16, 39, 57, 0, -480, None, [
        Tag(False, "u-ca", "hebrew"),
      ]),
    )
}

pub fn ixdtf_hyphenated_value_preserved_test() {
  let assert Ok(ix) =
    parser.parse_ixdtf("2022-07-08T00:14:07Z[u-ca=islamic-civil]")
  assert ix.tags == [Tag(False, "u-ca", "islamic-civil")]
}

pub fn ixdtf_multiple_tags_test() {
  let assert Ok(ix) =
    parser.parse_ixdtf("1996-12-19T16:39:57-08:00[_foo=bar][_baz=bat]")
  assert ix.tags == [Tag(False, "_foo", "bar"), Tag(False, "_baz", "bat")]
}

pub fn ixdtf_dotted_zone_parts_test() {
  let assert Ok(ix) = parser.parse_ixdtf("2022-07-08T00:14:07Z[a.../b..c]")
  assert ix.zone == Some(Zone(False, "a.../b..c"))
}

pub fn ixdtf_rejects_bare_dot_part_test() {
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[America/./Foo]") == Error(Nil)
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[.]") == Error(Nil)
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[..]") == Error(Nil)
}

pub fn ixdtf_rejects_malformed_test() {
  // Empty brackets / empty pieces.
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[]") == Error(Nil)
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[!]") == Error(Nil)
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[=x]") == Error(Nil)
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[u-ca=]") == Error(Nil)
  // Uppercase key is not allowed.
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[U-CA=hebrew]") == Error(Nil)
  // Unterminated bracket.
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[Europe/Paris") == Error(Nil)
  // Second zone (no `=`) after the first group.
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[u-ca=hebrew][Europe/Paris]")
    == Error(Nil)
  // Trailing junk after the suffix.
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[Europe/Paris]x") == Error(Nil)
  // A bare RFC 3339 timestamp with no offset is not a valid IXDTF.
  assert parser.parse_ixdtf("2022-07-08T00:14:07") == Error(Nil)
  // Doubled / leading / trailing hyphen in the value.
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[u-ca=a--b]") == Error(Nil)
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[u-ca=-a]") == Error(Nil)
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[u-ca=a-]") == Error(Nil)
}

// --- Examples straight from RFC 9557 ---------------------------------------

// Figure 4: a bare RFC 3339 date-time with a time zone offset (no suffix).
pub fn rfc_figure_4_test() {
  assert parser.parse_ixdtf("1996-12-19T16:39:57-08:00")
    == Ok(Ixdtf(1996, 12, 19, 16, 39, 57, 0, -480, None, []))
}

// Figure 5: adding a time zone name.
pub fn rfc_figure_5_test() {
  assert parser.parse_ixdtf("1996-12-19T16:39:57-08:00[America/Los_Angeles]")
    == Ok(
      Ixdtf(
        1996,
        12,
        19,
        16,
        39,
        57,
        0,
        -480,
        Some(Zone(False, "America/Los_Angeles")),
        [],
      ),
    )
}

// Figure 6: projecting to the Hebrew calendar (zone + u-ca tag).
pub fn rfc_figure_6_test() {
  assert parser.parse_ixdtf(
      "1996-12-19T16:39:57-08:00[America/Los_Angeles][u-ca=hebrew]",
    )
    == Ok(
      Ixdtf(
        1996,
        12,
        19,
        16,
        39,
        57,
        0,
        -480,
        Some(Zone(False, "America/Los_Angeles")),
        [Tag(False, "u-ca", "hebrew")],
      ),
    )
}

// Figure 7: experimental tags (leading underscore), no zone.
pub fn rfc_figure_7_test() {
  assert parser.parse_ixdtf("1996-12-19T16:39:57-08:00[_foo=bar][_baz=bat]")
    == Ok(
      Ixdtf(1996, 12, 19, 16, 39, 57, 0, -480, None, [
        Tag(False, "_foo", "bar"),
        Tag(False, "_baz", "bat"),
      ]),
    )
}

// Section 3.3 / 3.4: critical flags are recorded (osler leaves acting on them
// to the caller). Z is a known-UTC-offset-unknown local offset.
pub fn rfc_critical_zone_test() {
  assert parser.parse_ixdtf("2022-07-08T00:14:07+01:00[!Europe/Paris]")
    == Ok(
      Ixdtf(2022, 7, 8, 0, 14, 7, 0, 60, Some(Zone(True, "Europe/Paris")), []),
    )
}

pub fn rfc_critical_tags_test() {
  // [!u-ca=chinese][u-ca=japanese] -- both tags kept, in order, first critical.
  assert parser.parse_ixdtf(
      "2022-07-08T00:14:07Z[!u-ca=chinese][u-ca=japanese]",
    )
    == Ok(
      Ixdtf(2022, 7, 8, 0, 14, 7, 0, 0, None, [
        Tag(True, "u-ca", "chinese"),
        Tag(False, "u-ca", "japanese"),
      ]),
    )
}

pub fn rfc_duplicate_keys_kept_in_order_test() {
  // Section 3.3: the parser keeps every duplicate; choosing the first is the
  // caller's policy, not ours.
  let assert Ok(ix) =
    parser.parse_ixdtf("2022-07-08T00:14:07Z[u-ca=chinese][u-ca=japanese]")
  assert ix.tags
    == [Tag(False, "u-ca", "chinese"), Tag(False, "u-ca", "japanese")]
}

pub fn rfc_unknown_critical_tag_recorded_test() {
  // [!knort=blargel] -- an unknown critical tag still parses; acting on the
  // critical flag is the caller's job.
  assert parser.parse_ixdtf("2022-07-08T00:14:07Z[!knort=blargel]")
    == Ok(
      Ixdtf(2022, 7, 8, 0, 14, 7, 0, 0, None, [Tag(True, "knort", "blargel")]),
    )
}

// osler.parse_ixdtf: Timestamp + offset + suffix, with date/time validation.
pub fn osler_parse_ixdtf_test() {
  let assert Ok(#(ts, offset, zone, tags)) =
    osler.parse_ixdtf(
      "1996-12-19T16:39:57-08:00[America/Los_Angeles][u-ca=hebrew]",
    )
  assert offset == duration.minutes(-480)
  assert timestamp.to_rfc3339(ts, offset) == "1996-12-19T16:39:57-08:00"
  assert zone == Some(Zone(False, "America/Los_Angeles"))
  assert tags == [Tag(False, "u-ca", "hebrew")]
}

pub fn osler_parse_ixdtf_validates_date_test() {
  // A structurally fine suffix does not rescue an out-of-range date.
  assert osler.parse_ixdtf("2023-02-29T00:00:00Z[Europe/London]") == Error(Nil)
}

pub fn osler_parse_ixdtf_accepts_and_normalizes_leap_second_test() {
  // The leap second is accepted, then normalized into the instant (a
  // Timestamp cannot represent :60). Use `parse_datetime_parts` to keep :60.
  let assert Ok(#(ts, offset, _zone, _tags)) =
    osler.parse_ixdtf("2024-06-30T23:59:60Z[Europe/London]")
  assert timestamp.to_rfc3339(ts, offset) == "2024-07-01T00:00:00Z"
}

pub fn osler_parse_ixdtf_accepts_and_normalizes_end_of_day_test() {
  let assert Ok(#(ts, offset, _zone, _tags)) =
    osler.parse_ixdtf("2024-06-30T24:00:00-05:00[America/New_York]")
  assert timestamp.to_rfc3339(ts, offset) == "2024-07-01T00:00:00-05:00"
}

// The suffix grammar is strict, but the date-time part keeps osler's broad
// shape acceptance (compact form, space separator, lowercase z, ...).
pub fn ixdtf_accepts_loose_datetime_forms_test() {
  let assert Ok(a) = parser.parse_ixdtf("20240613T134211.314-04:00[UTC]")
  assert a.zone == Some(Zone(False, "UTC"))
  assert #(a.year, a.month, a.day, a.hour, a.minute, a.second, a.nanosecond)
    == #(2024, 6, 13, 13, 42, 11, 314_000_000)

  let assert Ok(b) =
    parser.parse_ixdtf("2024-06-13 13:42:11z[Australia/Sydney][u-ca=hebrew]")
  assert b.offset_minutes == 0
  assert b.zone == Some(Zone(False, "Australia/Sydney"))
  assert b.tags == [Tag(False, "u-ca", "hebrew")]
}

pub fn ixdtf_critical_offset_zone_test() {
  assert parser.parse_ixdtf("2022-07-08T00:14:07+08:45[!+08:45]")
    == Ok(Ixdtf(2022, 7, 8, 0, 14, 7, 0, 525, Some(Zone(True, "+08:45")), []))
}

pub fn ixdtf_mixed_critical_tags_test() {
  let assert Ok(ix) =
    parser.parse_ixdtf("2022-07-08T00:14:07Z[Europe/Paris][!a=1][b=2-3]")
  assert ix.zone == Some(Zone(False, "Europe/Paris"))
  assert ix.tags == [Tag(True, "a", "1"), Tag(False, "b", "2-3")]
}

// A single-letter time-zone-name is structurally valid per the ABNF, so it is
// captured (osler does not judge whether it names a real zone).
pub fn ixdtf_single_letter_zone_test() {
  let assert Ok(ix) = parser.parse_ixdtf("2022-07-08T00:14:07Z[z]")
  assert ix.zone == Some(Zone(False, "z"))
}
