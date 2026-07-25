//// Differential harness: parses a large, deterministic set of IXDTF-ish
//// strings with `parser.parse_ixdtf` and prints a canonical representation
//// of each result. Running this on the Erlang and JavaScript targets and
//// diffing the two outputs proves the hand-written Gleam and FFI parsers
//// agree on every input.
////
////   gleam run -m differential --target erlang > /tmp/erl.txt
////   gleam run -m differential --target javascript > /tmp/js.txt
////   diff /tmp/erl.txt /tmp/js.txt

import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import osler
import osler/parser.{type Ixdtf, type Tag, type Zone, Ixdtf, Tag, Zone}

pub fn main() {
  any_main()
  directives_main()
  inputs()
  |> list.each(fn(input) {
    io.println(input <> " => " <> format(parser.parse_ixdtf(input)))
    // Also cover the fully-validated instant path: on JS this exercises the
    // fused `fast_timestamp` FFI, on Erlang the general body -- diffing the two
    // runs proves they agree across the whole corpus.
    io.println(input <> " ts=> " <> format_ts(osler.parse_timestamp(input)))
    // And the fused validated `osler.parse_ixdtf` (Timestamp + offset + suffix).
    io.println(input <> " ix=> " <> format_full(osler.parse_ixdtf(input)))
  })
}

fn format_full(
  result: Result(
    #(timestamp.Timestamp, duration.Duration, Option(Zone), List(Tag)),
    Nil,
  ),
) -> String {
  case result {
    Error(Nil) -> "Error"
    Ok(#(ts, offset, zone, tags)) -> {
      let #(secs, ns) = timestamp.to_unix_seconds_and_nanoseconds(ts)
      "Ok "
      <> int.to_string(secs)
      <> "|"
      <> int.to_string(ns)
      <> "|"
      <> int.to_string(duration.to_seconds(offset) |> float.round)
      <> "|"
      <> format_zone(zone)
      <> "|"
      <> format_tags(tags)
    }
  }
}

fn format_ts(result: Result(timestamp.Timestamp, Nil)) -> String {
  case result {
    Error(Nil) -> "Error"
    Ok(ts) -> {
      let #(secs, ns) = timestamp.to_unix_seconds_and_nanoseconds(ts)
      "Ok " <> int.to_string(secs) <> "|" <> int.to_string(ns)
    }
  }
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
  let criticals = list.map(group_bodies(), fn(body) { "[!" <> body <> "]" })

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

// --- directive engine -------------------------------------------------------
//
// The `parse_ixdtf` corpus above exercises the fixed grammar. The directive
// engine is a separate implementation on each target -- hand-written Gleam
// with inlined byte patterns on Erlang, a hand-written `stepParse` in
// `osler_ffi.mjs` on JS -- so it needs its own cross-target corpus. Every
// directive list is run against every input, valid or not, and the `Parts`
// rendered field by field.
pub fn directives_main() {
  list.each(directive_formats(), fn(named) {
    let #(name, directives) = named
    list.each(directive_inputs(), fn(input) {
      io.println(
        name
        <> " | "
        <> input
        <> " => "
        <> format_parts(parser.parse(input, directives)),
      )
    })
  })
}

fn format_parts(result: Result(parser.Parts, Nil)) -> String {
  case result {
    Error(Nil) -> "Error"
    Ok(p) ->
      "Ok "
      <> opt_int(p.year)
      <> "|"
      <> opt_int(p.month)
      <> "|"
      <> opt_int(p.day)
      <> "|"
      <> opt_int(p.hour)
      <> "|"
      <> opt_int(p.twelve_hour)
      <> "|"
      <> period(p.period)
      <> "|"
      <> opt_int(p.minute)
      <> "|"
      <> opt_int(p.second)
      <> "|"
      <> opt_int(p.nanosecond)
      <> "|"
      <> opt_int(p.offset_minutes)
      <> "|"
      <> format_zone(p.zone)
      <> "|"
      <> format_tags(p.tags)
  }
}

fn opt_int(v: Option(Int)) -> String {
  case v {
    None -> "."
    Some(n) -> int.to_string(n)
  }
}

fn period(v: Option(parser.AmPm)) -> String {
  case v {
    None -> "."
    Some(parser.Am) -> "am"
    Some(parser.Pm) -> "pm"
  }
}

fn directive_formats() -> List(#(String, List(parser.Directive))) {
  [
    #("iso-compound", [
      parser.IsoDate,
      parser.DateTimeSeparator,
      parser.IsoTime,
      parser.IsoOffset,
    ]),
    #("iso-naive", [parser.IsoNaiveDateTime, parser.IsoOffset]),
    #("fine", [
      parser.Year4,
      parser.Literal("-"),
      parser.Month2,
      parser.Literal("-"),
      parser.Day2,
      parser.Literal("T"),
      parser.Hour24Padded,
      parser.Literal(":"),
      parser.Minute2,
      parser.Literal(":"),
      parser.Second2,
      parser.Literal("."),
      parser.Milli,
      parser.OffsetColon,
    ]),
    // Unpadded / 1-or-2-digit variants, which take different code paths.
    #("loose", [
      parser.Year4,
      parser.Separator,
      parser.Month,
      parser.Separator,
      parser.Day,
      parser.DateTimeSeparator,
      parser.Hour24,
      parser.TimeSeparator,
      parser.Minute,
      parser.TimeSeparator,
      parser.Second,
    ]),
    #("names", [
      parser.WeekdayShortName,
      parser.Literal(", "),
      parser.Day2,
      parser.Literal(" "),
      parser.MonthShortName,
      parser.Literal(" "),
      parser.Year4,
    ]),
    #("long-names", [
      parser.WeekdayLongName,
      parser.Literal(" "),
      parser.MonthLongName,
      parser.Literal(" "),
      parser.Day,
    ]),
    #("12h", [
      parser.Hour12Padded,
      parser.Literal(":"),
      parser.Minute2,
      parser.MeridiemLower,
    ]),
    #("12h-upper", [
      parser.Hour12,
      parser.Literal(":"),
      parser.Minute2,
      parser.MeridiemUpper,
    ]),
    #("micro", [parser.IsoNaiveDateTime, parser.Literal("."), parser.Micro]),
    #("nano", [parser.Year4, parser.Literal("-"), parser.Month2, parser.Nano]),
    #("offsets", [parser.IsoNaiveDateTime, parser.Offset]),
    #("offset-nocolon", [parser.IsoNaiveDateTime, parser.OffsetNoColon]),
    #("offset-zulu", [parser.IsoNaiveDateTime, parser.OffsetZulu]),
    #("gmt", [parser.IsoNaiveDateTime, parser.Gmt]),
    #("zone-tags", [
      parser.IsoNaiveDateTime,
      parser.IsoOffset,
      parser.ZoneName,
      parser.ExtensionTags,
    ]),
    #("weekday-num", [parser.WeekdayNumber, parser.Literal("|"), parser.Year4]),
    #("weekday-2", [parser.WeekdayShortName2, parser.Literal("|"), parser.Year4]),
    #("iso-date", [parser.IsoDate]),
    #("multi-literal", [parser.Year4, parser.Literal("ABC"), parser.Month2]),
    #("empty", []),
  ]
}

fn directive_inputs() -> List(String) {
  [
    "2024-06-13T23:04:00.009+10:00", "1996-12-19T16:39:57-08:00",
    "2022-07-08T00:14:07Z", "2022-07-08T00:14:07z", "20240613T134211.314-04:00",
    "2024-06-13 13:42:11z", "2024-06-13T13:42:11", "2024/06/13T13:42:11+0530",
    "2024.6.3 4:2:1", "2024_06_13_13_42_11",
    "2024-06-13T23:04:00.009+10:00[Europe/Paris]",
    "2024-06-13T23:04:00Z[!Asia/Tokyo][u-ca=hebrew]",
    "2024-06-13T23:04:00Z[u-ca=islamic-civil]",
    "2024-06-13T23:04:00Z[bad//zone]", "2024-06-13T23:04:00Z[k=a--b]",
    "Thu, 13 Jun 2024", "Thursday June 3", "Wed, 05 Feb 2020", "01:30pm",
    "1:30PM", "13:30am", "12:00am", "12:00pm", "2024-06-13T13:42:11.123456",
    "2024-06-1300000000", "2024-06-13T13:42:11+05", "2024-06-13T13:42:11+0530",
    "2024-06-13T13:42:11GMT", "2024-06-13T13:42:11-14:00",
    "2024-06-13T13:42:11+25:00", "2024-06-13T13:42:11+10:99", "3|2024", "9|2024",
    "Su|2024", "Xx|2024", "2024-06-13", "2024-06-13trailing", "2024ABC06",
    "2024XYZ06", "garbage", "", "2", "20", "2024", "2024-", "2024-0",
    "0000-01-01T00:00:00Z", "9999-12-31T23:59:60+14:00", "2024-02-29T00:00:00Z",
    "2023-02-29T00:00:00Z",
  ]
}

// --- parse_any --------------------------------------------------------------
//
// The heuristic scanner has no cross-target coverage otherwise: it is shared
// Gleam on both targets today, but that is exactly the sort of thing an FFI
// fast path gets added to, and the failure mode of a heuristic is a silently
// different guess rather than an error.
pub fn any_main() {
  list.each(any_inputs(), fn(input) {
    io.println(input <> " any=> " <> format_any(osler.parse_any(input)))
  })
}

fn format_any(
  r: #(
    Option(calendar.Date),
    Option(calendar.TimeOfDay),
    Option(duration.Duration),
  ),
) -> String {
  let #(date, time, offset) = r
  let d = case date {
    None -> "."
    Some(calendar.Date(y, m, dd)) ->
      int.to_string(y)
      <> "-"
      <> int.to_string(month_num(m))
      <> "-"
      <> int.to_string(dd)
  }
  let t = case time {
    None -> "."
    Some(calendar.TimeOfDay(h, mi, s, ns)) ->
      int.to_string(h)
      <> ":"
      <> int.to_string(mi)
      <> ":"
      <> int.to_string(s)
      <> "."
      <> int.to_string(ns)
  }
  let o = case offset {
    None -> "."
    Some(dur) -> int.to_string(float.round(duration.to_seconds(dur)))
  }
  d <> " | " <> t <> " | " <> o
}

fn month_num(m: calendar.Month) -> Int {
  case m {
    calendar.January -> 1
    calendar.February -> 2
    calendar.March -> 3
    calendar.April -> 4
    calendar.May -> 5
    calendar.June -> 6
    calendar.July -> 7
    calendar.August -> 8
    calendar.September -> 9
    calendar.October -> 10
    calendar.November -> 11
    calendar.December -> 12
  }
}

fn any_inputs() -> List(String) {
  // Generated combinations rather than a hand list: `parse_any` is a heuristic
  // with five interacting scanners, and the JS FFI mirror of it has to agree
  // on every corner, including the ones nobody would think to write down.
  let dates = [
    "2024-06-13", "2024/06/13", "2024.6.3", "2024_06_13", "2024 06 13",
    "20240613", "06/22/2024", "06222024", "6/2/2024", "June 21st, 2024",
    "Dec 25, 2024", "december 25 2024", "DECEMBER 25 2024", "Sept 1 2024",
    "May 1st 2024", "march 3rd 2024", "aug 22nd 2024", "2024-02-29",
    "2023-02-29", "2024-13-01", "2024-00-01", "2024-06-31", "0999-01-01",
    "1000-01-01", "9999-12-31",
  ]
  let times = [
    "13:42:11", "1:42", "13:42:11.314", "13:42:11.123456789", "134211",
    "1:42:11 PM", "01:42 am", "12:00 AM", "12:00 PM", "24:00:00", "23:59:60",
    "25:00:00", "12:60:00", "0:0:0",
  ]
  let offsets = [
    "+05:00", "-04:00", "+0530", "+05", "Z", "z", "+18:00", "-13:00", "+14:00",
    "-12:00", "+00:00", "-00:00",
  ]
  let joins = ["T", " ", " at "]

  let date_time =
    list.flat_map(dates, fn(d) {
      list.flat_map(times, fn(t) { list.map(joins, fn(j) { d <> j <> t }) })
    })
  let date_offset =
    list.flat_map(dates, fn(d) { list.map(offsets, fn(o) { d <> " " <> o }) })
  let full =
    list.flat_map(dates, fn(d) {
      list.map(offsets, fn(o) { d <> "T13:42:11" <> o })
    })
  let time_offset =
    list.flat_map(times, fn(t) { list.map(offsets, fn(o) { t <> " " <> o }) })
  // The same full timestamps buried in prose, which exercises the word-boundary
  // rules and the blanking that runs between the three extractions.
  let wrapped = list.map(full, fn(x) { "Meeting on " <> x <> " in the office" })

  list.flatten([
    dates,
    times,
    offsets,
    date_time,
    date_offset,
    full,
    time_offset,
    wrapped,
    adversarial(),
  ])
}

// Cases chosen to break things rather than to be parsed: ambiguity, boundary
// conditions, things that look like a component but are not, and non-ASCII
// (where the Gleam implementation counts UTF-8 *bytes* and the JS FFI counts
// UTF-16 code units -- the claim is that the parse still agrees, so it is
// checked rather than assumed).
fn adversarial() -> List(String) {
  [
    "", " ", "  ", "no date here", "just some words with nothing in them",
    "2024", "2024-", "2024-0", "20", "2", "1234567890", "99999999",
    "123456789012345", "0000-00-00", "a2024-06-13", "2024-06-13z", "x13:42:11x",
    "  2024-06-13  ", "2024-06-13 2025-07-14", "13:42:11 14:43:12",
    "+05:00 +06:00", "Zulu", "zulu time", "z", "Z", "Zz", "aZ", "Za", "June",
    "Jun", "Ju", "J", "may", "May", "MAY", "mayonnaise 5 2024",
    "januaryy 1 2024", "2024 June 21", "21 Jun 2024 13:42 +0100",
    "the 5th of never", "1st 2nd 3rd 4th", "12am", "12pm", "12 am", "12  am",
    "1amx", "1am", "1pm", "+", "-", "+0", "+05:", "+05:0", "-99:99", "+99", "T",
    "TT", "2024-06-13T", "T13:42:11", ":13:42", "13:", "13::42",
    "..2024-06-13..", "--2024-06-13--", "//2024//06//13//", "2024,06,13",
    "2024, 06, 13", "June,21,2024", "café 2024-06-13 münchen", "日本 2024-06-13",
    "naïve 13:42:11 +05:00", "2024-06-13\u{00e9}", "\u{00e9}2024-06-13",
    "tab\t2024-06-13\ttab", "line\n2024-06-13\nline",
  ]
}
