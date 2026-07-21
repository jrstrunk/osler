import gleam/option.{None}
import gleam/time/timestamp
import ixdtf_generators as gen
import osler
import osler/parser
import qcheck

/// Differential test against the reference: for any strict RFC 3339 string,
/// `osler.parse_ixdtf` must land on the exact same `Timestamp` as
/// `gleam_time`'s own `timestamp.parse_rfc3339`.
pub fn parse_ixdtf_matches_gleam_time_rfc3339_property_test() {
  use str <- qcheck.given(gen.rfc3339())

  let assert Ok(#(osler_instant, _offset, _zone, _tags)) =
    osler.parse_ixdtf(str)
  let assert Ok(reference_instant) = timestamp.parse_rfc3339(str)

  assert osler_instant == reference_instant
}

/// The core losslessness guarantee: for any grammar-valid suffix, parsing it
/// recovers exactly the structured zone/tags it was built from, and
/// re-serializing them reproduces the original suffix text byte-for-byte.
pub fn ixdtf_suffix_roundtrip_property_test() {
  use parts <- qcheck.given(gen.ixdtf_parts())
  let #(prefix, zone, tags) = parts

  let suffix = gen.serialize(zone, tags)
  let assert Ok(ix) = parser.parse_ixdtf(prefix <> suffix)

  assert ix.zone == zone
  assert ix.tags == tags
  assert gen.serialize(ix.zone, ix.tags) == suffix
}

/// On a plain RFC 3339 string (no suffix), `parse_ixdtf` succeeds with no
/// zone and no tags.
pub fn ixdtf_no_suffix_has_empty_suffix_property_test() {
  use prefix <- qcheck.given(gen.datetime_prefix())

  let assert Ok(ix) = parser.parse_ixdtf(prefix)
  assert ix.zone == None
  assert ix.tags == []
}

/// A grammar-valid zone on its own always round-trips through a named-zone
/// serialization.
pub fn ixdtf_zone_roundtrip_property_test() {
  use zone <- qcheck.given(gen.zone())

  let input = "2022-07-08T00:14:07Z[" <> zone.name <> "]"
  let input = case zone.critical {
    True -> "2022-07-08T00:14:07Z[!" <> zone.name <> "]"
    False -> input
  }

  let assert Ok(ix) = parser.parse_ixdtf(input)
  assert ix.zone == option.Some(zone)
  assert ix.tags == []
}

/// A single grammar-valid tag always round-trips.
pub fn ixdtf_tag_roundtrip_property_test() {
  use tag <- qcheck.given(gen.tag())

  let body = tag.key <> "=" <> tag.value
  let input = case tag.critical {
    True -> "2022-07-08T00:14:07Z[!" <> body <> "]"
    False -> "2022-07-08T00:14:07Z[" <> body <> "]"
  }

  let assert Ok(ix) = parser.parse_ixdtf(input)
  assert ix.zone == None
  assert ix.tags == [tag]
}

/// The chance of a random string being a valid IXDTF timestamp is vanishingly
/// small, so it should essentially always fail to parse (mirrors gleam_time's
/// `parse_rfc3339_fails_for_invalid_inputs_test`).
pub fn ixdtf_random_string_fails_property_test() {
  use string <- qcheck.given(qcheck.string())
  assert parser.parse_ixdtf(string) == Error(Nil)
}
