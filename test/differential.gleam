//// Differential harness: parses a large, deterministic set of IXDTF-ish
//// strings with `parser.parse_ixdtf` and prints a canonical representation
//// of each result. Running this on the Erlang and JavaScript targets and
//// diffing the two outputs proves the hand-written Gleam and FFI parsers
//// agree on every input.
////
////   gleam run -m differential --target erlang > /tmp/erl.txt
////   gleam run -m differential --target javascript > /tmp/js.txt
////   diff /tmp/erl.txt /tmp/js.txt

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import osler/parser.{type Ixdtf, type Tag, type Zone, Ixdtf, Tag, Zone}

pub fn main() {
  inputs()
  |> list.each(fn(input) {
    io.println(input <> " => " <> format(parser.parse_ixdtf(input)))
  })
}

// A canonical, target-stable rendering (unlike `string.inspect`, which shows
// record field labels on JS but not on Erlang), so a diff of the two runs
// reflects only genuine semantic divergence.
fn format(result: Result(Ixdtf, Nil)) -> String {
  case result {
    Error(Nil) -> "Error"
    Ok(Ixdtf(y, mo, d, h, mi, s, ns, off, zone, tags)) ->
      "Ok "
      <> int.to_string(y)
      <> "|"
      <> int.to_string(mo)
      <> "|"
      <> int.to_string(d)
      <> "|"
      <> int.to_string(h)
      <> "|"
      <> int.to_string(mi)
      <> "|"
      <> int.to_string(s)
      <> "|"
      <> int.to_string(ns)
      <> "|"
      <> int.to_string(off)
      <> "|"
      <> format_zone(zone)
      <> "|"
      <> format_tags(tags)
  }
}

fn format_zone(zone: Option(Zone)) -> String {
  case zone {
    None -> "-"
    Some(Zone(critical, name)) -> bool_str(critical) <> ":" <> name
  }
}

fn format_tags(tags: List(Tag)) -> String {
  tags
  |> list.map(fn(tag) {
    let Tag(critical, key, value) = tag
    bool_str(critical) <> ":" <> key <> "=" <> value
  })
  |> list.map(fn(s) { "{" <> s <> "}" })
  |> list.fold("", fn(acc, s) { acc <> s })
}

fn bool_str(b: Bool) -> String {
  case b {
    True -> "!"
    False -> "."
  }
}

fn inputs() -> List(String) {
  // A handful of valid RFC 3339 prefixes (with the required offset) that the
  // suffixes get appended to, plus a couple of bad ones.
  let prefixes = [
    "2024-06-13T23:04:00.009+10:00",
    "1996-12-19T16:39:57-08:00",
    "2022-07-08T00:14:07Z",
    "20240613T134211.314-04:00",
    "2024-06-13 13:42:11z",
    // Bad prefixes: no offset, garbage, empty.
    "2024-06-13T13:42:11",
    "garbage",
    "",
  ]

  list.flat_map(prefixes, fn(prefix) {
    list.map(suffixes(), fn(suffix) { prefix <> suffix })
  })
}

fn suffixes() -> List(String) {
  let brackets =
    list.flat_map(group_bodies(), fn(body) { ["[" <> body <> "]"] })

  // Every single group on its own...
  let singles = brackets

  // ...a leading `!` critical variant of each single group...
  let criticals =
    list.map(group_bodies(), fn(body) { "[!" <> body <> "]" })

  // ...pairs of groups (zone-ish followed by tag-ish, and tag+tag)...
  let pairs =
    list.flat_map(zone_bodies(), fn(z) {
      list.map(tag_bodies(), fn(t) { "[" <> z <> "][" <> t <> "]" })
    })

  let tag_pairs =
    list.flat_map(tag_bodies(), fn(a) {
      list.map(tag_bodies(), fn(b) { "[" <> a <> "][" <> b <> "]" })
    })

  // ...and structurally broken suffixes.
  let broken = [
    "",
    "[",
    "]",
    "[]",
    "[!]",
    "[Europe/Paris",
    "[Europe/Paris]]",
    "[Europe/Paris]x",
    "[Europe/Paris]]",
    "x[Europe/Paris]",
    " [Europe/Paris]",
    "[u-ca=hebrew][Europe/Paris]",
    "[Europe/Paris][Asia/Tokyo]",
    "[[Europe/Paris]]",
    "[u=ca=hebrew]",
    "[u-ca==hebrew]",
    "[=hebrew]",
    "[u-ca]",
    "[u-ca=]",
    "[!!Europe/Paris]",
    "[ Europe/Paris]",
    "[Europe/Paris ]",
    "[u-ca= hebrew]",
    "[u-ca=hebrew ]",
  ]

  list.flatten([singles, criticals, pairs, tag_pairs, broken])
}

fn group_bodies() -> List(String) {
  list.flatten([zone_bodies(), tag_bodies()])
}

fn zone_bodies() -> List(String) {
  [
    "Europe/Paris",
    "America/Los_Angeles",
    "Asia/Tokyo",
    "UTC",
    "Z",
    "GMT+0",
    "Etc/GMT-14",
    "_foo",
    "a",
    "a.b",
    "a...b",
    "a.../b..c",
    ".",
    "..",
    "...",
    "a/",
    "/a",
    "a//b",
    "America/./Foo",
    "Foo/BAR/baz",
    "+08:45",
    "-05:00",
    "+00:00",
    "-00:00",
    "+0845",
    "+8:45",
    "+08:5",
    "+08:456",
    "z",
    "1abc",
    "-abc",
    "a b",
    "a=b",
    "Aa+9-._/Bb",
  ]
}

fn tag_bodies() -> List(String) {
  [
    "u-ca=hebrew",
    "u-ca=islamic-civil",
    "u-ca=islamic-umalqura",
    "_foo=bar",
    "_baz=bat",
    "a=b",
    "a1-b2=c3",
    "k=1",
    "k=A",
    "k=a-b-c",
    "k=a--b",
    "k=-a",
    "k=a-",
    "k=",
    "=v",
    "U-CA=hebrew",
    "u_ca=hebrew",
    "u-ca=he brew",
    "u-ca=hébrew",
    "1ca=x",
    "u-ca=islamic_civil",
  ]
}
