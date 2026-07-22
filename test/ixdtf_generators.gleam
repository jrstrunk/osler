//// qcheck generators for RFC 9557 (IXDTF) suffixes, used by the property
//// tests. Each generator produces *structured* `parser.Zone` / `parser.Tag`
//// values built only from grammar-valid bytes, so serializing them (see
//// `serialize`) always yields a valid IXDTF suffix. Parsing that suffix back
//// and comparing to the original structure is what proves losslessness.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string
import osler/parser.{type Tag, type Zone, Tag, Zone}
import qcheck

// --- Character-class codepoint generators -----------------------------------

fn cp(ints: List(Int)) -> qcheck.Generator(UtfCodepoint) {
  let assert [first, ..rest] = ints
  qcheck.codepoint_from_ints(first, rest)
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

fn lower() -> List(Int) {
  range(0x61, 0x7a)
}

fn upper() -> List(Int) {
  range(0x41, 0x5a)
}

fn digits() -> List(Int) {
  range(0x30, 0x39)
}

fn letters() -> List(Int) {
  list.append(lower(), upper())
}

fn alphanum() -> List(Int) {
  list.append(letters(), digits())
}

// --- String-piece generators ------------------------------------------------

fn fixed(
  gen: qcheck.Generator(UtfCodepoint),
  length: Int,
) -> qcheck.Generator(String) {
  qcheck.fixed_length_string_from(gen, length)
}

fn bounded(
  gen: qcheck.Generator(UtfCodepoint),
  min: Int,
  max: Int,
) -> qcheck.Generator(String) {
  qcheck.generic_string(gen, qcheck.bounded_int(min, max))
}

// time-zone-part = time-zone-initial *time-zone-char, but never "." / "..".
// Forcing the initial byte to be a letter or "_" (never ".") means the part
// can never be all-dots, so it is always valid by construction.
fn zone_part() -> qcheck.Generator(String) {
  let initial = cp(list.append(letters(), [0x5f]))
  let rest = cp(list.flatten([letters(), digits(), [0x2e, 0x5f, 0x2d, 0x2b]]))
  qcheck.map2(fixed(initial, 1), bounded(rest, 0, 12), fn(i, tail) { i <> tail })
}

fn named_zone_name() -> qcheck.Generator(String) {
  qcheck.generic_list(zone_part(), qcheck.bounded_int(1, 3))
  |> qcheck.map(fn(parts) { string.join(parts, "/") })
}

fn offset_zone_name() -> qcheck.Generator(String) {
  let sign =
    qcheck.from_generators(qcheck.constant("+"), [qcheck.constant("-")])
  let two = fixed(cp(digits()), 2)
  qcheck.map3(sign, two, two, fn(s, hh, mm) { s <> hh <> ":" <> mm })
}

fn zone_name() -> qcheck.Generator(String) {
  qcheck.from_generators(named_zone_name(), [offset_zone_name()])
}

pub fn zone() -> qcheck.Generator(Zone) {
  qcheck.map2(qcheck.bool(), zone_name(), fn(critical, name) {
    Zone(critical, name)
  })
}

// suffix-key = key-initial *key-char; key-initial = lcalpha / "_".
fn key() -> qcheck.Generator(String) {
  let initial = cp(list.append(lower(), [0x5f]))
  let rest = cp(list.flatten([lower(), [0x5f], digits(), [0x2d]]))
  qcheck.map2(fixed(initial, 1), bounded(rest, 0, 8), fn(i, tail) { i <> tail })
}

// suffix-values = suffix-value *("-" suffix-value); suffix-value = 1*alphanum.
fn values() -> qcheck.Generator(String) {
  let value = bounded(cp(alphanum()), 1, 6)
  qcheck.generic_list(value, qcheck.bounded_int(1, 3))
  |> qcheck.map(fn(tokens) { string.join(tokens, "-") })
}

pub fn tag() -> qcheck.Generator(Tag) {
  qcheck.map3(qcheck.bool(), key(), values(), fn(critical, k, v) {
    Tag(critical, k, v)
  })
}

pub fn tags() -> qcheck.Generator(List(Tag)) {
  qcheck.generic_list(tag(), qcheck.bounded_int(0, 3))
}

/// A valid RFC 3339 date-time prefix (with the required offset) to hang a
/// suffix off of.
pub fn datetime_prefix() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.constant("2024-06-13T23:04:00.009+10:00"), [
    qcheck.constant("1996-12-19T16:39:57-08:00"),
    qcheck.constant("2022-07-08T00:14:07Z"),
    qcheck.constant("2024-06-13T13:42:11+00:00"),
    qcheck.constant("20240613T134211.314-04:00"),
  ])
}

/// A prefix plus a full structured suffix (optional zone + tags).
pub fn ixdtf_parts() -> qcheck.Generator(#(String, Option(Zone), List(Tag))) {
  qcheck.map3(
    datetime_prefix(),
    qcheck.option_from(zone()),
    tags(),
    fn(prefix, z, ts) { #(prefix, z, ts) },
  )
}

// --- Serialization (inverse of parsing) -------------------------------------

/// Renders a structured suffix back to its canonical IXDTF text. Parsing this
/// and getting the same `zone`/`tags` back is the losslessness guarantee.
pub fn serialize(zone: Option(Zone), tags: List(Tag)) -> String {
  serialize_zone(zone) <> string.concat(list.map(tags, serialize_tag))
}

fn serialize_zone(zone: Option(Zone)) -> String {
  case zone {
    option.None -> ""
    option.Some(Zone(critical, name)) -> "[" <> flag(critical) <> name <> "]"
  }
}

fn serialize_tag(tag: Tag) -> String {
  let Tag(critical, key, value) = tag
  "[" <> flag(critical) <> key <> "=" <> value <> "]"
}

fn flag(critical: Bool) -> String {
  case critical {
    True -> "!"
    False -> ""
  }
}

// --- Strict RFC 3339 strings ------------------------------------------------
//
// Generates the subset of RFC 3339 that both `osler.parse_ixdtf` and
// `gleam_time`'s `timestamp.parse_rfc3339` accept and must agree on: no
// suffix, 2-digit zero-padded fields, `Z`/`z`/`±HH:MM` offsets. Hours stay
// 00-23 and seconds 00-59 (no `24:00:00`, no `23:59:60` leap second), since
// those are exactly the values where the two parsers' handling could
// legitimately differ -- they are covered separately in the unit tests.

/// A valid strict RFC 3339 date-time string (no IXDTF suffix).
pub fn rfc3339() -> qcheck.Generator(String) {
  use date <- qcheck.bind(full_date())
  use sep <- qcheck.bind(separator())
  use time <- qcheck.map(full_time())
  date <> sep <> time
}

fn full_date() -> qcheck.Generator(String) {
  use year <- qcheck.bind(qcheck.bounded_int(0, 9999))
  use month <- qcheck.bind(qcheck.bounded_int(1, 12))
  use day <- qcheck.map(qcheck.bounded_int(1, max_day(year, month)))
  pad(year, 4) <> "-" <> pad(month, 2) <> "-" <> pad(day, 2)
}

fn full_time() -> qcheck.Generator(String) {
  use hour <- qcheck.bind(qcheck.bounded_int(0, 23))
  use minute <- qcheck.bind(qcheck.bounded_int(0, 59))
  use second <- qcheck.bind(qcheck.bounded_int(0, 59))
  use fraction <- qcheck.bind(qcheck.option_from(second_fraction()))
  use offset <- qcheck.map(offset())
  pad(hour, 2)
  <> ":"
  <> pad(minute, 2)
  <> ":"
  <> pad(second, 2)
  <> optional(fraction)
  <> offset
}

fn second_fraction() -> qcheck.Generator(String) {
  qcheck.generic_string(cp(digits()), qcheck.bounded_int(1, 9))
  |> qcheck.map(fn(digits) { "." <> digits })
}

fn offset() -> qcheck.Generator(String) {
  qcheck.from_generators(
    qcheck.from_generators(qcheck.constant("Z"), [qcheck.constant("z")]),
    [numeric_offset()],
  )
}

fn numeric_offset() -> qcheck.Generator(String) {
  use sign <- qcheck.bind(
    qcheck.from_generators(qcheck.constant("+"), [qcheck.constant("-")]),
  )
  use hour <- qcheck.bind(qcheck.bounded_int(0, 23))
  use minute <- qcheck.map(qcheck.bounded_int(0, 59))
  sign <> pad(hour, 2) <> ":" <> pad(minute, 2)
}

fn separator() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.constant("T"), [
    qcheck.constant("t"),
    qcheck.constant(" "),
  ])
}

fn pad(n: Int, width: Int) -> String {
  int.to_string(n) |> string.pad_start(width, "0")
}

fn max_day(year: Int, month: Int) -> Int {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    4 | 6 | 9 | 11 -> 30
    2 ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
    _ -> 28
  }
}

fn is_leap_year(year: Int) -> Bool {
  year % 4 == 0 && { year % 100 != 0 || year % 400 == 0 }
}

fn optional(value: Option(String)) -> String {
  case value {
    option.Some(s) -> s
    option.None -> ""
  }
}
