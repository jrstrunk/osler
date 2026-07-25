//// Bare structural parsing, for libraries that want to build their own
//// domain types (with their own validation policy) instead of `gleam_time`
//// calendar types. This is what `osler`'s own higher-level, calendar-type
//// returning functions are built on top of -- if you're not sure whether
//// you want this module or `osler` itself, you probably want `osler`.
////
//// Every function here accepts the same broad set of shapes described in
//// the `osler` module's documentation, and returns `Error(Nil)` on any
//// structural failure. Unlike `osler`'s functions, **the returned values
//// are not validated at all**: a date's day and month are whatever digits
//// were present (a day of `54` or a month of `13` parses fine), an
//// offset's hour/minute only get the loose shape check described in
//// `parse_offset`'s docs, and there's no month-length/leap-year/offset-
//// range checking whatsoever. This module's only job is turning bytes
//// into raw ints as cheaply as possible; if you don't have your own
//// validation logic already, use `osler`'s functions instead.
////
//// Sub-second fractions are always returned in nanoseconds (truncating
//// anything past the 9th digit), regardless of what precision your own
//// type stores -- divide by the appropriate power of 10 yourself if you
//// need coarser precision.
////
//// `parse_ixdtf` parses a full date, time, and offset followed by the
//// optional RFC 9557 (IXDTF) suffix -- a time zone name (or offset zone)
//// and any number of `[key=value]` extension tags -- capturing them
//// losslessly so the suffix can be reproduced exactly. Unlike the numeric
//// fields, the suffix *is* checked against the RFC 9557 grammar: a
//// malformed suffix fails the parse.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The optional time zone from an RFC 9557 (IXDTF) suffix -- the first
/// `[...]` group when it has no `=`, e.g. `[Europe/Paris]`, `[!Asia/Tokyo]`,
/// or an offset time zone `[+08:45]`.
///
/// `name` is captured verbatim -- either an IANA-style time zone name
/// (`America/Los_Angeles`) or an offset time zone (`+08:45`) -- so the
/// original suffix can be reproduced exactly. This module does **not**
/// look the name up in the IANA database, interpret an offset zone's
/// numeric value, or check it for consistency with the timestamp's own
/// offset (see RFC 9557 §3.4); that is the caller's job.
///
/// `critical` is `True` when the group carried a leading `!` critical flag
/// (`[!Europe/Paris]`). A critical flag means a recipient MUST NOT act on
/// the timestamp unless it can process the tag (RFC 9557 §3.3); osler
/// merely records the flag and leaves that policy to the caller.
pub type Zone {
  Zone(critical: Bool, name: String)
}

/// One `[key=value]` extension tag from an RFC 9557 (IXDTF) suffix, e.g.
/// `[u-ca=hebrew]`, `[!u-ca=islamic-civil]`, or an experimental
/// `[_foo=bar]`.
///
/// `value` is the raw `suffix-values` text with its internal hyphens
/// preserved (`islamic-civil` stays `islamic-civil`, rather than being
/// split into `["islamic", "civil"]`), captured verbatim for lossless
/// reproduction. `critical` records a leading `!` as for `Zone`.
///
/// Tags are returned in the order they appeared, duplicates and all. RFC
/// 9557 §3.3 says a consumer that does not want to act on a duplicate key
/// MUST use the first occurrence; osler leaves that policy to the caller.
pub type Tag {
  Tag(critical: Bool, key: String, value: String)
}

/// A fully-parsed RFC 9557 (IXDTF) timestamp: the raw, unvalidated
/// RFC 3339 date-time ints (year through offset in minutes), plus the
/// optional time `zone` and any extension `tags` from the suffix.
///
/// As with the rest of this module the numeric fields are **not**
/// validated -- see the module docs. The suffix, on the other hand, is
/// checked against the RFC 9557 grammar: a structurally malformed suffix
/// makes the whole parse fail.
pub type Ixdtf {
  Ixdtf(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    nanosecond: Int,
    offset_minutes: Int,
    zone: Option(Zone),
    tags: List(Tag),
  )
}

/// Parses a full RFC 9557 (IXDTF) string -- an RFC 3339 date-time (date,
/// time, and a **required** offset, in any of the shapes the other
/// functions accept) followed by an optional suffix -- into an `Ixdtf`.
///
/// The suffix is `[time-zone]` (an IANA name or `±HH:MM` offset zone,
/// optionally `!`-critical) followed by any number of `[key=value]` tags,
/// each optionally `!`-critical. It is parsed losslessly: the zone name
/// and each tag's key and value are captured exactly as written, so the
/// suffix can be reproduced verbatim.
///
/// ## Examples
///
/// ```gleam
/// parser.parse_ixdtf("1996-12-19T16:39:57-08:00[America/Los_Angeles]")
/// // -> Ok(Ixdtf(1996, 12, 19, 16, 39, 57, 0, -480,
/// //             Some(Zone(False, "America/Los_Angeles")), []))
/// ```
///
/// ```gleam
/// parser.parse_ixdtf("2022-07-08T00:14:07Z[!Europe/Paris][u-ca=hebrew]")
/// // -> Ok(Ixdtf(2022, 7, 8, 0, 14, 7, 0, 0,
/// //             Some(Zone(True, "Europe/Paris")),
/// //             [Tag(False, "u-ca", "hebrew")]))
/// ```
@external(javascript, "../osler_ffi.mjs", "parse_ixdtf_parts")
pub fn parse_ixdtf(str: String) -> Result(Ixdtf, Nil) {
  case parse_ixdtf_raw(bit_array.from_string(str)) {
    Error(Nil) -> Error(Nil)
    Ok(#(
      year,
      month,
      day,
      hour,
      minute,
      second,
      nanosecond,
      offset_minutes,
      zone,
      tags,
    )) ->
      Ok(Ixdtf(
        year:,
        month:,
        day:,
        hour:,
        minute:,
        second:,
        nanosecond:,
        offset_minutes:,
        zone: wrap_zone(zone),
        tags: wrap_tags(tags),
      ))
  }
}

fn wrap_zone(raw: Option(#(Bool, String))) -> Option(Zone) {
  case raw {
    None -> None
    Some(#(critical, name)) -> Some(Zone(critical:, name:))
  }
}

fn wrap_tags(raw: List(#(Bool, String, String))) -> List(Tag) {
  case raw {
    [] -> []
    [#(critical, key, value), ..rest] -> [
      Tag(critical:, key:, value:),
      ..wrap_tags(rest)
    ]
  }
}

// --- Custom format parsing --------------------------------------------------

/// The AM/PM period parsed from a `MeridiemLower`/`MeridiemUpper` directive
/// (or rendered from the hour of the day).
pub type AmPm {
  Am
  Pm
}

/// A single directive making up a custom parse/render format. A format is an
/// ordered `List(Directive)`; `parse`/`format` walk it against the input.
///
/// The field directives cover the individual calendar and clock fields (year,
/// month, day, weekday, hour, minute, second, fraction, meridiem, offset),
/// with explicit variants for the padded and unpadded forms. Beyond those
/// there are two extra kinds:
///
///   * **flexible separators** (`Separator`, `TimeSeparator`,
///     `DateTimeSeparator`) match a *class* of delimiter characters so a
///     single format accepts `2024-06-13`, `2024/06/13`, and compact
///     `20240613` alike -- flexibility is opt-in, per position;
///   * **compound ISO directives** (`IsoDate`, `IsoTime`, `IsoOffset`,
///     `IsoNaiveDateTime`) dispatch to osler's fast, delimiter-flexible
///     byte scanners, for lenient ISO-8601-ish parsing in one directive.
pub type Directive {
  /// Four-digit year.
  Year4
  /// One or two digit month.
  Month
  /// Two-digit month.
  Month2
  /// Short English month name (`Jan`..`Dec`).
  MonthShortName
  /// Full English month name (`January`..`December`).
  MonthLongName
  /// One or two digit day of month.
  Day
  /// Two-digit day of month.
  Day2
  /// ISO day-of-week number, `1` (Mon) .. `7` (Sun) (parse: a single `1`-`7`
  /// digit, matched then discarded; render derives it from the date).
  WeekdayNumber
  /// Two-letter English weekday (`Su`..`Sa`); discarded on parse.
  WeekdayShortName2
  /// Short English weekday (`Sun`..`Sat`); discarded on parse.
  WeekdayShortName
  /// Full English weekday (`Sunday`..`Saturday`); discarded on parse.
  WeekdayLongName
  /// One or two digit 24-hour hour.
  Hour24
  /// Two-digit 24-hour hour.
  Hour24Padded
  /// One or two digit 12-hour hour.
  Hour12
  /// Two-digit 12-hour hour.
  Hour12Padded
  /// Lowercase meridiem (`am`/`pm`).
  MeridiemLower
  /// Uppercase meridiem (`AM`/`PM`).
  MeridiemUpper
  /// One or two digit minute.
  Minute
  /// Two-digit minute.
  Minute2
  /// One or two digit second.
  Second
  /// Two-digit second.
  Second2
  /// Three fractional digits (milliseconds), stored as nanoseconds.
  Milli
  /// Six fractional digits (microseconds), stored as nanoseconds.
  Micro
  /// Nine fractional digits (nanoseconds).
  Nano
  /// Offset, condensed: `Z`, `±HH`, `±HH:MM`.
  Offset
  /// Offset: `Z` when zero, otherwise `±HH:MM`.
  OffsetZulu
  /// Offset, always `±HH:MM`.
  OffsetColon
  /// Offset, always `±HHMM`.
  OffsetNoColon
  /// The literal string `GMT`, meaning a zero offset.
  Gmt
  /// An RFC 9557 time zone group, e.g. `[America/Los_Angeles]` or `[!+08:45]`.
  ZoneName
  /// A run of RFC 9557 `[key=value]` extension tags.
  ExtensionTags
  /// A literal string that must appear verbatim in the input.
  Literal(String)
  /// Zero or one of `-` `/` `.` `_` space -- a flexible date delimiter.
  Separator
  /// Zero or one of `:` `_` space -- a flexible time delimiter.
  TimeSeparator
  /// Exactly one of `T` `t` `_` space -- a date/time delimiter.
  DateTimeSeparator
  /// A full delimiter-flexible ISO date (`2024-06-13`, `2024/06/13`, compact
  /// `20240613`, ...).
  IsoDate
  /// A full delimiter-flexible ISO time (`13:42:11.500`, `13:42`, compact
  /// `134211`, ...).
  IsoTime
  /// A full ISO offset (`Z`, `±HH:MM`, `±HHMM`, `±HH`, `±H`).
  IsoOffset
  /// A full ISO naive date-time: an `IsoDate` optionally followed by a
  /// delimiter and an `IsoTime`.
  IsoNaiveDateTime
}

/// The raw, unvalidated parts produced by `parse`. Every field is `Option`,
/// present only when a directive filled it, so an absent field is
/// distinguishable from a zero one. Values are captured verbatim -- a month
/// of `13` or a day of `54` is returned as-is; validation is the caller's
/// job (see `osler`). `hour`/`twelve_hour`/`period` are kept separate so no
/// information is lost when a 12-hour clock is parsed.
pub type Parts {
  Parts(
    year: Option(Int),
    month: Option(Int),
    day: Option(Int),
    hour: Option(Int),
    twelve_hour: Option(Int),
    period: Option(AmPm),
    minute: Option(Int),
    second: Option(Int),
    nanosecond: Option(Int),
    offset_minutes: Option(Int),
    zone: Option(Zone),
    tags: List(Tag),
  )
}

/// A `Parts` with every field absent.
pub fn empty_parts() -> Parts {
  Parts(None, None, None, None, None, None, None, None, None, None, None, [])
}

/// Parses `input` against the ordered `directives`, returning the raw,
/// unvalidated `Parts` each directive filled in. The whole input must be
/// consumed: any bytes left over after the last directive fail the parse, so
/// the directives have to account for the input exactly.
@external(javascript, "../osler_ffi.mjs", "parse")
pub fn parse(input: String, directives: List(Directive)) -> Result(Parts, Nil) {
  case run(bit_array.from_string(input), directives, empty_parts()) {
    Ok(#(parts, <<>>)) -> Ok(parts)
    _ -> Error(Nil)
  }
}

// `run` and `step` are mutually recursive: each branch tail-calls `run` with
// the remaining directives rather than returning an `Ok(#(parts, bytes))` for
// `run` to unpack. Nothing is allocated to mean "continue" -- only a genuine
// failure allocates, and `Error(Nil)` is a constant. The helpers below
// (`with_int`, `keep`, `with_ampm`, and the `consume_*` family) take `ds` and
// tail-call `run` for the same reason.
//
// `step`'s `case directive` is exhaustive over all 39 variants with no
// catch-all, so adding a `Directive` is a compile error until it is handled
// here.
fn run(
  bytes: BitArray,
  directives: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case directives {
    [] -> Ok(#(parts, bytes))
    [directive, ..ds] -> step(directive, ds, bytes, parts)
  }
}

fn step(
  directive: Directive,
  ds: List(Directive),
  bytes: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case directive {
    Year4 ->
      case bytes {
        <<b1, b2, b3, b4, rest:bytes>>
          if b1 >= 0x30
          && b1 <= 0x39
          && b2 >= 0x30
          && b2 <= 0x39
          && b3 >= 0x30
          && b3 <= 0x39
          && b4 >= 0x30
          && b4 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(
              ..parts,
              year: Some(
                { b1 - 0x30 }
                * 1000
                + { b2 - 0x30 }
                * 100
                + { b3 - 0x30 }
                * 10
                + { b4 - 0x30 },
              ),
            ),
          )
        _ -> Error(Nil)
      }
    Month ->
      with_int(parse_1_or_2_digits(bytes), ds, fn(v) {
        Parts(..parts, month: Some(v))
      })
    Month2 ->
      case bytes {
        <<b1, b2, rest:bytes>>
          if b1 >= 0x30 && b1 <= 0x39 && b2 >= 0x30 && b2 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(..parts, month: Some({ b1 - 0x30 } * 10 + { b2 - 0x30 })),
          )
        _ -> Error(Nil)
      }
    MonthShortName ->
      with_int(consume_month_short(bytes), ds, fn(v) {
        Parts(..parts, month: Some(v))
      })
    MonthLongName ->
      with_int(consume_month_long(bytes), ds, fn(v) {
        Parts(..parts, month: Some(v))
      })
    Day ->
      with_int(parse_1_or_2_digits(bytes), ds, fn(v) {
        Parts(..parts, day: Some(v))
      })
    Day2 ->
      case bytes {
        <<b1, b2, rest:bytes>>
          if b1 >= 0x30 && b1 <= 0x39 && b2 >= 0x30 && b2 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(..parts, day: Some({ b1 - 0x30 } * 10 + { b2 - 0x30 })),
          )
        _ -> Error(Nil)
      }
    WeekdayNumber -> keep(consume_weekday_number(bytes), ds, parts)
    WeekdayShortName2 -> keep(consume_weekday_2(bytes), ds, parts)
    WeekdayShortName -> keep(consume_weekday_3(bytes), ds, parts)
    WeekdayLongName -> keep(consume_weekday_long(bytes), ds, parts)
    Hour24 ->
      with_int(parse_1_or_2_digits(bytes), ds, fn(v) {
        Parts(..parts, hour: Some(v))
      })
    Hour24Padded ->
      case bytes {
        <<b1, b2, rest:bytes>>
          if b1 >= 0x30 && b1 <= 0x39 && b2 >= 0x30 && b2 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(..parts, hour: Some({ b1 - 0x30 } * 10 + { b2 - 0x30 })),
          )
        _ -> Error(Nil)
      }
    Hour12 ->
      with_int(parse_1_or_2_digits(bytes), ds, fn(v) {
        Parts(..parts, twelve_hour: Some(v))
      })
    Hour12Padded ->
      case bytes {
        <<b1, b2, rest:bytes>>
          if b1 >= 0x30 && b1 <= 0x39 && b2 >= 0x30 && b2 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(
              ..parts,
              twelve_hour: Some({ b1 - 0x30 } * 10 + { b2 - 0x30 }),
            ),
          )
        _ -> Error(Nil)
      }
    MeridiemLower -> with_ampm(consume_meridiem_lower(bytes), ds, parts)
    MeridiemUpper -> with_ampm(consume_meridiem_upper(bytes), ds, parts)
    Minute ->
      with_int(parse_1_or_2_digits(bytes), ds, fn(v) {
        Parts(..parts, minute: Some(v))
      })
    Minute2 ->
      case bytes {
        <<b1, b2, rest:bytes>>
          if b1 >= 0x30 && b1 <= 0x39 && b2 >= 0x30 && b2 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(..parts, minute: Some({ b1 - 0x30 } * 10 + { b2 - 0x30 })),
          )
        _ -> Error(Nil)
      }
    Second ->
      with_int(parse_1_or_2_digits(bytes), ds, fn(v) {
        Parts(..parts, second: Some(v))
      })
    Second2 ->
      case bytes {
        <<b1, b2, rest:bytes>>
          if b1 >= 0x30 && b1 <= 0x39 && b2 >= 0x30 && b2 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(..parts, second: Some({ b1 - 0x30 } * 10 + { b2 - 0x30 })),
          )
        _ -> Error(Nil)
      }
    Milli ->
      case bytes {
        <<b1, b2, b3, rest:bytes>>
          if b1 >= 0x30
          && b1 <= 0x39
          && b2 >= 0x30
          && b2 <= 0x39
          && b3 >= 0x30
          && b3 <= 0x39
        ->
          run(
            rest,
            ds,
            Parts(
              ..parts,
              nanosecond: Some(
                { { b1 - 0x30 } * 100 + { b2 - 0x30 } * 10 + { b3 - 0x30 } }
                * 1_000_000,
              ),
            ),
          )
        _ -> Error(Nil)
      }
    Micro ->
      with_int(parse_n_digits(bytes, 6), ds, fn(v) {
        Parts(..parts, nanosecond: Some(v * 1000))
      })
    Nano ->
      with_int(parse_n_digits(bytes, 9), ds, fn(v) {
        Parts(..parts, nanosecond: Some(v))
      })
    // `Z` and `(+-)HH:MM` inline; every other offset shape falls through to
    // the general scanner.
    Offset | OffsetZulu | OffsetColon | OffsetNoColon | IsoOffset ->
      case bytes {
        <<b, rest:bytes>> if b == 0x5A || b == 0x7A ->
          run(rest, ds, Parts(..parts, offset_minutes: Some(0)))

        <<sg, h1, h2, 0x3A, m1, m2, rest:bytes>>
          if { sg == 0x2B || sg == 0x2D }
          && h1 >= 0x30
          && h1 <= 0x39
          && h2 >= 0x30
          && h2 <= 0x39
          && m1 >= 0x30
          && m1 <= 0x39
          && m2 >= 0x30
          && m2 <= 0x39
        -> {
          let oh = { h1 - 0x30 } * 10 + { h2 - 0x30 }
          let om = { m1 - 0x30 } * 10 + { m2 - 0x30 }
          case oh > 24 || om > 60 {
            True -> Error(Nil)
            False ->
              run(
                rest,
                ds,
                Parts(
                  ..parts,
                  offset_minutes: Some(case sg == 0x2D {
                    True -> -{ oh * 60 + om }
                    False -> oh * 60 + om
                  }),
                ),
              )
          }
        }

        _ ->
          with_int(parse_offset(bytes), ds, fn(v) {
            Parts(..parts, offset_minutes: Some(v))
          })
      }
    Gmt -> consume_gmt(bytes, ds, parts)
    ZoneName -> consume_zone(bytes, ds, parts)
    ExtensionTags -> consume_tags(bytes, ds, parts)
    // Single-byte literals -- `"-"`, `":"`, `"."`, `"T"` -- are what format
    // lists are mostly made of, and matching one inline avoids handing `bytes`
    // to `consume_literal`. Longer literals go the general way.
    Literal(lit) ->
      case bit_array.from_string(lit) {
        <<b>> ->
          case bytes {
            <<c, rest:bytes>> if c == b -> run(rest, ds, parts)
            _ -> Error(Nil)
          }
        lit_bytes -> consume_literal(bytes, lit_bytes, ds, parts)
      }
    Separator -> run(consume_separator(bytes), ds, parts)
    TimeSeparator -> run(consume_time_separator(bytes), ds, parts)
    DateTimeSeparator -> consume_datetime_separator(bytes, ds, parts)
    IsoDate -> consume_iso_date(bytes, ds, parts)
    IsoTime -> consume_iso_time(bytes, ds, parts)
    IsoNaiveDateTime -> consume_iso_naive(bytes, ds, parts)
  }
}

fn with_int(
  res: Result(#(Int, BitArray), Nil),
  ds: List(Directive),
  set: fn(Int) -> Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case res {
    Ok(#(v, rest)) -> run(rest, ds, set(v))
    Error(Nil) -> Error(Nil)
  }
}

fn with_ampm(
  res: Result(#(AmPm, BitArray), Nil),
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case res {
    Ok(#(period, rest)) -> run(rest, ds, Parts(..parts, period: Some(period)))
    Error(Nil) -> Error(Nil)
  }
}

fn keep(
  res: Result(BitArray, Nil),
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case res {
    Ok(rest) -> run(rest, ds, parts)
    Error(Nil) -> Error(Nil)
  }
}

fn consume_literal(
  bytes: BitArray,
  lit: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case lit {
    <<>> -> run(bytes, ds, parts)
    <<b, lit_rest:bytes>> ->
      case bytes {
        <<c, rest:bytes>> if c == b ->
          consume_literal(rest, lit_rest, ds, parts)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn consume_separator(bytes: BitArray) -> BitArray {
  case bytes {
    <<0x2D, rest:bytes>> -> rest
    <<0x2F, rest:bytes>> -> rest
    <<0x2E, rest:bytes>> -> rest
    <<0x5F, rest:bytes>> -> rest
    <<0x20, rest:bytes>> -> rest
    _ -> bytes
  }
}

fn consume_time_separator(bytes: BitArray) -> BitArray {
  case bytes {
    <<0x3A, rest:bytes>> -> rest
    <<0x5F, rest:bytes>> -> rest
    <<0x20, rest:bytes>> -> rest
    _ -> bytes
  }
}

fn consume_datetime_separator(
  bytes: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case bytes {
    <<0x54, rest:bytes>> -> run(rest, ds, parts)
    <<0x74, rest:bytes>> -> run(rest, ds, parts)
    <<0x5F, rest:bytes>> -> run(rest, ds, parts)
    <<0x20, rest:bytes>> -> run(rest, ds, parts)
    _ -> Error(Nil)
  }
}

fn consume_gmt(
  bytes: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case bytes {
    <<"GMT":utf8, rest:bytes>> ->
      run(rest, ds, Parts(..parts, offset_minutes: Some(0)))
    _ -> Error(Nil)
  }
}

fn consume_month_short(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<"Jan":utf8, rest:bytes>> -> Ok(#(1, rest))
    <<"Feb":utf8, rest:bytes>> -> Ok(#(2, rest))
    <<"Mar":utf8, rest:bytes>> -> Ok(#(3, rest))
    <<"Apr":utf8, rest:bytes>> -> Ok(#(4, rest))
    <<"May":utf8, rest:bytes>> -> Ok(#(5, rest))
    <<"Jun":utf8, rest:bytes>> -> Ok(#(6, rest))
    <<"Jul":utf8, rest:bytes>> -> Ok(#(7, rest))
    <<"Aug":utf8, rest:bytes>> -> Ok(#(8, rest))
    <<"Sep":utf8, rest:bytes>> -> Ok(#(9, rest))
    <<"Oct":utf8, rest:bytes>> -> Ok(#(10, rest))
    <<"Nov":utf8, rest:bytes>> -> Ok(#(11, rest))
    <<"Dec":utf8, rest:bytes>> -> Ok(#(12, rest))
    _ -> Error(Nil)
  }
}

fn consume_month_long(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<"January":utf8, rest:bytes>> -> Ok(#(1, rest))
    <<"February":utf8, rest:bytes>> -> Ok(#(2, rest))
    <<"March":utf8, rest:bytes>> -> Ok(#(3, rest))
    <<"April":utf8, rest:bytes>> -> Ok(#(4, rest))
    <<"May":utf8, rest:bytes>> -> Ok(#(5, rest))
    <<"June":utf8, rest:bytes>> -> Ok(#(6, rest))
    <<"July":utf8, rest:bytes>> -> Ok(#(7, rest))
    <<"August":utf8, rest:bytes>> -> Ok(#(8, rest))
    <<"September":utf8, rest:bytes>> -> Ok(#(9, rest))
    <<"October":utf8, rest:bytes>> -> Ok(#(10, rest))
    <<"November":utf8, rest:bytes>> -> Ok(#(11, rest))
    <<"December":utf8, rest:bytes>> -> Ok(#(12, rest))
    _ -> Error(Nil)
  }
}

fn consume_weekday_number(bytes: BitArray) -> Result(BitArray, Nil) {
  case bytes {
    <<b, rest:bytes>> if b >= 0x31 && b <= 0x37 -> Ok(rest)
    _ -> Error(Nil)
  }
}

fn consume_weekday_2(bytes: BitArray) -> Result(BitArray, Nil) {
  case bytes {
    <<"Su":utf8, rest:bytes>> -> Ok(rest)
    <<"Mo":utf8, rest:bytes>> -> Ok(rest)
    <<"Tu":utf8, rest:bytes>> -> Ok(rest)
    <<"We":utf8, rest:bytes>> -> Ok(rest)
    <<"Th":utf8, rest:bytes>> -> Ok(rest)
    <<"Fr":utf8, rest:bytes>> -> Ok(rest)
    <<"Sa":utf8, rest:bytes>> -> Ok(rest)
    _ -> Error(Nil)
  }
}

fn consume_weekday_3(bytes: BitArray) -> Result(BitArray, Nil) {
  case bytes {
    <<"Sun":utf8, rest:bytes>> -> Ok(rest)
    <<"Mon":utf8, rest:bytes>> -> Ok(rest)
    <<"Tue":utf8, rest:bytes>> -> Ok(rest)
    <<"Wed":utf8, rest:bytes>> -> Ok(rest)
    <<"Thu":utf8, rest:bytes>> -> Ok(rest)
    <<"Fri":utf8, rest:bytes>> -> Ok(rest)
    <<"Sat":utf8, rest:bytes>> -> Ok(rest)
    _ -> Error(Nil)
  }
}

fn consume_weekday_long(bytes: BitArray) -> Result(BitArray, Nil) {
  case bytes {
    <<"Sunday":utf8, rest:bytes>> -> Ok(rest)
    <<"Monday":utf8, rest:bytes>> -> Ok(rest)
    <<"Tuesday":utf8, rest:bytes>> -> Ok(rest)
    <<"Wednesday":utf8, rest:bytes>> -> Ok(rest)
    <<"Thursday":utf8, rest:bytes>> -> Ok(rest)
    <<"Friday":utf8, rest:bytes>> -> Ok(rest)
    <<"Saturday":utf8, rest:bytes>> -> Ok(rest)
    _ -> Error(Nil)
  }
}

fn consume_meridiem_lower(bytes: BitArray) -> Result(#(AmPm, BitArray), Nil) {
  case bytes {
    <<"am":utf8, rest:bytes>> -> Ok(#(Am, rest))
    <<"pm":utf8, rest:bytes>> -> Ok(#(Pm, rest))
    _ -> Error(Nil)
  }
}

fn consume_meridiem_upper(bytes: BitArray) -> Result(#(AmPm, BitArray), Nil) {
  case bytes {
    <<"AM":utf8, rest:bytes>> -> Ok(#(Am, rest))
    <<"PM":utf8, rest:bytes>> -> Ok(#(Pm, rest))
    _ -> Error(Nil)
  }
}

fn consume_iso_date(
  bytes: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case parse_date(bytes) {
    Ok(#(year, month, day, rest)) ->
      run(
        rest,
        ds,
        Parts(..parts, year: Some(year), month: Some(month), day: Some(day)),
      )
    Error(Nil) -> Error(Nil)
  }
}

fn consume_iso_time(
  bytes: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case parse_time(bytes) {
    Ok(#(hour, minute, second, nanosecond, rest)) ->
      run(
        rest,
        ds,
        Parts(
          ..parts,
          hour: Some(hour),
          minute: Some(minute),
          second: Some(second),
          nanosecond: Some(nanosecond),
        ),
      )
    Error(Nil) -> Error(Nil)
  }
}

fn consume_iso_naive(
  bytes: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case parse_date(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(year, month, day, rest)) -> {
      let parts =
        Parts(..parts, year: Some(year), month: Some(month), day: Some(day))
      case rest {
        <<0x54, rest:bytes>>
        | <<0x74, rest:bytes>>
        | <<0x5F, rest:bytes>>
        | <<0x20, rest:bytes>> -> consume_iso_time(rest, ds, parts)
        _ -> run(rest, ds, parts)
      }
    }
  }
}

fn consume_zone(
  bytes: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case parse_optional_zone(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(None, rest)) -> run(rest, ds, parts)
    Ok(#(Some(#(critical, name)), rest)) ->
      run(rest, ds, Parts(..parts, zone: Some(Zone(critical:, name:))))
  }
}

fn consume_tags(
  bytes: BitArray,
  ds: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case parse_tag_run(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(raw, rest)) -> run(rest, ds, Parts(..parts, tags: wrap_tags(raw)))
  }
}

// --- Custom format rendering ------------------------------------------------

/// Renders `parts` according to the ordered `directives`, the inverse of
/// `parse`. Fails with `Error(Nil)` if a directive references a field that is
/// absent from `parts` (e.g. rendering `Month2` when `parts.month` is `None`).
/// Weekday directives are derived from `year`/`month`/`day`.
@external(javascript, "../osler_ffi.mjs", "format")
pub fn format(
  parts: Parts,
  directives: List(Directive),
) -> Result(String, Nil) {
  format_loop(directives, parts, [])
  |> result.map(fn(chunks) { chunks |> list.reverse |> string.concat })
}

fn format_loop(
  directives: List(Directive),
  parts: Parts,
  acc: List(String),
) -> Result(List(String), Nil) {
  case directives {
    [] -> Ok(acc)
    [directive, ..rest] ->
      case render(directive, parts) {
        Ok(chunk) -> format_loop(rest, parts, [chunk, ..acc])
        Error(Nil) -> Error(Nil)
      }
  }
}

fn render(directive: Directive, parts: Parts) -> Result(String, Nil) {
  case directive {
    Year4 -> parts.year |> req |> result.map(pad(_, 4))
    Month -> parts.month |> req |> result.map(int.to_string)
    Month2 -> parts.month |> req |> result.map(pad(_, 2))
    MonthShortName -> parts.month |> req |> result.try(month_short_name)
    MonthLongName -> parts.month |> req |> result.try(month_long_name)
    Day -> parts.day |> req |> result.map(int.to_string)
    Day2 -> parts.day |> req |> result.map(pad(_, 2))
    WeekdayNumber -> weekday(parts) |> result.map(int.to_string)
    WeekdayShortName2 ->
      weekday(parts)
      |> result.map(fn(w) { string.slice(weekday_short(w), 0, 2) })
    WeekdayShortName -> weekday(parts) |> result.map(weekday_short)
    WeekdayLongName -> weekday(parts) |> result.map(weekday_long)
    Hour24 -> parts.hour |> req |> result.map(int.to_string)
    Hour24Padded -> parts.hour |> req |> result.map(pad(_, 2))
    Hour12 -> parts.hour |> req |> result.map(fn(h) { int.to_string(to_12(h)) })
    Hour12Padded -> parts.hour |> req |> result.map(fn(h) { pad(to_12(h), 2) })
    MeridiemLower -> parts.hour |> req |> result.map(meridiem(_, "am", "pm"))
    MeridiemUpper -> parts.hour |> req |> result.map(meridiem(_, "AM", "PM"))
    Minute -> parts.minute |> req |> result.map(int.to_string)
    Minute2 -> parts.minute |> req |> result.map(pad(_, 2))
    Second -> parts.second |> req |> result.map(int.to_string)
    Second2 -> parts.second |> req |> result.map(pad(_, 2))
    Milli ->
      parts.nanosecond |> req |> result.map(fn(ns) { pad(ns / 1_000_000, 3) })
    Micro -> parts.nanosecond |> req |> result.map(fn(ns) { pad(ns / 1000, 6) })
    Nano -> parts.nanosecond |> req |> result.map(fn(ns) { pad(ns, 9) })
    Offset -> parts.offset_minutes |> req |> result.map(render_offset_condensed)
    OffsetZulu -> parts.offset_minutes |> req |> result.map(render_offset_zulu)
    OffsetColon ->
      parts.offset_minutes |> req |> result.map(render_offset_hm(_, True))
    OffsetNoColon ->
      parts.offset_minutes |> req |> result.map(render_offset_hm(_, False))
    Gmt -> Ok("GMT")
    ZoneName -> render_zone(parts)
    ExtensionTags -> render_tags(parts)
    Literal(lit) -> Ok(lit)
    Separator -> Ok("-")
    TimeSeparator -> Ok(":")
    DateTimeSeparator -> Ok("T")
    IsoDate -> render_iso_date(parts)
    IsoTime -> render_iso_time(parts)
    IsoOffset -> parts.offset_minutes |> req |> result.map(render_offset_zulu)
    IsoNaiveDateTime -> render_iso_naive(parts)
  }
}

fn req(o: Option(Int)) -> Result(Int, Nil) {
  case o {
    Some(v) -> Ok(v)
    None -> Error(Nil)
  }
}

fn pad(n: Int, width: Int) -> String {
  int.to_string(n) |> string.pad_start(to: width, with: "0")
}

fn to_12(hour: Int) -> Int {
  case hour {
    0 -> 12
    h if h > 12 -> h - 12
    h -> h
  }
}

fn meridiem(hour: Int, am: String, pm: String) -> String {
  case hour >= 12 {
    True -> pm
    False -> am
  }
}

fn month_short_name(month: Int) -> Result(String, Nil) {
  case month {
    1 -> Ok("Jan")
    2 -> Ok("Feb")
    3 -> Ok("Mar")
    4 -> Ok("Apr")
    5 -> Ok("May")
    6 -> Ok("Jun")
    7 -> Ok("Jul")
    8 -> Ok("Aug")
    9 -> Ok("Sep")
    10 -> Ok("Oct")
    11 -> Ok("Nov")
    12 -> Ok("Dec")
    _ -> Error(Nil)
  }
}

fn month_long_name(month: Int) -> Result(String, Nil) {
  case month {
    1 -> Ok("January")
    2 -> Ok("February")
    3 -> Ok("March")
    4 -> Ok("April")
    5 -> Ok("May")
    6 -> Ok("June")
    7 -> Ok("July")
    8 -> Ok("August")
    9 -> Ok("September")
    10 -> Ok("October")
    11 -> Ok("November")
    12 -> Ok("December")
    _ -> Error(Nil)
  }
}

fn weekday(parts: Parts) -> Result(Int, Nil) {
  case parts.year, parts.month, parts.day {
    Some(y), Some(m), Some(d) -> Ok(iso_weekday(y, m, d))
    _, _, _ -> Error(Nil)
  }
}

// ISO weekday number: Monday = 1 .. Sunday = 7.
fn iso_weekday(year: Int, month: Int, day: Int) -> Int {
  let days = days_from_civil(year, month, day)
  case int.modulo(days + 4, 7) |> result.unwrap(0) {
    0 -> 7
    n -> n
  }
}

// Howard Hinnant's civil-to-days: days since 1970-01-01 (proleptic Gregorian).
fn days_from_civil(year: Int, month: Int, day: Int) -> Int {
  let y = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era =
    case y >= 0 {
      True -> y
      False -> y - 399
    }
    / 400
  let yoe = y - era * 400
  let mp = case month > 2 {
    True -> month - 3
    False -> month + 9
  }
  let doy = { 153 * mp + 2 } / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146_097 + doe - 719_468
}

fn weekday_short(iso: Int) -> String {
  case iso {
    1 -> "Mon"
    2 -> "Tue"
    3 -> "Wed"
    4 -> "Thu"
    5 -> "Fri"
    6 -> "Sat"
    _ -> "Sun"
  }
}

fn weekday_long(iso: Int) -> String {
  case iso {
    1 -> "Monday"
    2 -> "Tuesday"
    3 -> "Wednesday"
    4 -> "Thursday"
    5 -> "Friday"
    6 -> "Saturday"
    _ -> "Sunday"
  }
}

fn render_offset_hm(minutes: Int, colon: Bool) -> String {
  let sign = case minutes < 0 {
    True -> "-"
    False -> "+"
  }
  let abs = int.absolute_value(minutes)
  let hh = pad(abs / 60, 2)
  let mm = pad(abs % 60, 2)
  case colon {
    True -> sign <> hh <> ":" <> mm
    False -> sign <> hh <> mm
  }
}

fn render_offset_zulu(minutes: Int) -> String {
  case minutes {
    0 -> "Z"
    _ -> render_offset_hm(minutes, True)
  }
}

fn render_offset_condensed(minutes: Int) -> String {
  case minutes {
    0 -> "Z"
    _ ->
      case int.absolute_value(minutes) % 60 {
        0 -> {
          let sign = case minutes < 0 {
            True -> "-"
            False -> "+"
          }
          sign <> pad(int.absolute_value(minutes) / 60, 2)
        }
        _ -> render_offset_hm(minutes, True)
      }
  }
}

fn render_fraction(nanosecond: Int) -> String {
  case nanosecond {
    0 -> ""
    _ ->
      case nanosecond % 1_000_000 {
        0 -> "." <> pad(nanosecond / 1_000_000, 3)
        _ ->
          case nanosecond % 1000 {
            0 -> "." <> pad(nanosecond / 1000, 6)
            _ -> "." <> pad(nanosecond, 9)
          }
      }
  }
}

fn render_iso_date(parts: Parts) -> Result(String, Nil) {
  case parts.year, parts.month, parts.day {
    Some(y), Some(m), Some(d) ->
      Ok(pad(y, 4) <> "-" <> pad(m, 2) <> "-" <> pad(d, 2))
    _, _, _ -> Error(Nil)
  }
}

fn render_iso_time(parts: Parts) -> Result(String, Nil) {
  case parts.hour, parts.minute, parts.second {
    Some(h), Some(mi), Some(s) ->
      Ok(
        pad(h, 2)
        <> ":"
        <> pad(mi, 2)
        <> ":"
        <> pad(s, 2)
        <> render_fraction(option.unwrap(parts.nanosecond, 0)),
      )
    _, _, _ -> Error(Nil)
  }
}

fn render_iso_naive(parts: Parts) -> Result(String, Nil) {
  use date <- result.try(render_iso_date(parts))
  use time <- result.map(render_iso_time(parts))
  date <> "T" <> time
}

// An absent zone renders nothing (the zone is optional).
fn render_zone(parts: Parts) -> Result(String, Nil) {
  case parts.zone {
    None -> Ok("")
    Some(Zone(critical:, name:)) ->
      Ok("[" <> critical_flag(critical) <> name <> "]")
  }
}

fn render_tags(parts: Parts) -> Result(String, Nil) {
  Ok(
    list.fold(parts.tags, "", fn(acc, tag) {
      let Tag(critical:, key:, value:) = tag
      acc <> "[" <> critical_flag(critical) <> key <> "=" <> value <> "]"
    }),
  )
}

fn critical_flag(critical: Bool) -> String {
  case critical {
    True -> "!"
    False -> ""
  }
}

// --- Byte-level primitives --------------------------------------------------
//
// Everything below parses directly from a `BitArray`, without regex or
// `gleam/string` splitting. These helpers only extract and range-check byte
// *shapes*; they never validate calendar semantics (month lengths, leap
// years, hour/offset bounds, etc) -- that's the caller's job (see
// `osler.gleam`).
//
// This code backs the Erlang target; `osler_ffi.mjs` provides the JavaScript
// equivalent.
//
// Two invariants shape it, and both are load-bearing:
//
//   * **Match as much as possible in one pattern.** `parse_ixdtf_raw` matches
//     the canonical date-time and its common fraction/offset tails in a
//     single `case`, so the VM carries one live match context across the
//     whole string.
//   * **Never hand a `BitArray` across a function boundary on a hot path.**
//     Doing so materialises a heap sub-binary and makes the callee re-enter
//     `bs_start_match`. Passing `Int`s costs nothing, so byte values are
//     threaded as integers and char classes are written inline in pattern
//     guards rather than called as predicates.
//
// See `docs/erlang-perf-playbook.md` for the measurements behind them.

pub const byte_zero = 0x30

pub const byte_nine = 0x39

pub const byte_colon = 0x3A

pub const byte_dot = 0x2E

pub const byte_plus = 0x2B

pub const byte_minus = 0x2D

pub const byte_slash = 0x2F

pub const byte_underscore = 0x5F

pub const byte_space = 0x20

pub const byte_t_upper = 0x54

pub const byte_t_lower = 0x74

pub const byte_z_upper = 0x5A

pub const byte_z_lower = 0x7A

pub const byte_lbracket = 0x5B

pub const byte_rbracket = 0x5D

pub const byte_bang = 0x21

pub const byte_equals = 0x3D

pub fn digit_value(b: Int) -> Int {
  b - byte_zero
}

fn accept_byte(bytes: BitArray, value: Int) -> Result(BitArray, Nil) {
  case bytes {
    <<b, rest:bytes>> if b == value -> Ok(rest)
    _ -> Error(Nil)
  }
}

pub fn accept_end(bytes: BitArray) -> Result(Nil, Nil) {
  case bytes {
    <<>> -> Ok(Nil)
    _ -> Error(Nil)
  }
}

pub fn parse_2_digits(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b1, b2, rest:bytes>>
      if b1 >= byte_zero
      && b1 <= byte_nine
      && b2 >= byte_zero
      && b2 <= byte_nine
    -> Ok(#(digit_value(b1) * 10 + digit_value(b2), rest))
    _ -> Error(Nil)
  }
}

pub fn parse_4_digits(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b1, b2, b3, b4, rest:bytes>>
      if b1 >= byte_zero
      && b1 <= byte_nine
      && b2 >= byte_zero
      && b2 <= byte_nine
      && b3 >= byte_zero
      && b3 <= byte_nine
      && b4 >= byte_zero
      && b4 <= byte_nine
    ->
      Ok(#(
        digit_value(b1)
          * 1000
          + digit_value(b2)
          * 100
          + digit_value(b3)
          * 10
          + digit_value(b4),
        rest,
      ))
    _ -> Error(Nil)
  }
}

pub fn parse_1_or_2_digits(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b1, b2, rest:bytes>>
      if b1 >= byte_zero
      && b1 <= byte_nine
      && b2 >= byte_zero
      && b2 <= byte_nine
    -> Ok(#(digit_value(b1) * 10 + digit_value(b2), rest))
    <<b1, rest:bytes>> if b1 >= byte_zero && b1 <= byte_nine ->
      Ok(#(digit_value(b1), rest))
    _ -> Error(Nil)
  }
}

/// Parses exactly `n` digits into a single int, failing if fewer than `n`
/// digits are present. Used by the fixed-width format directives (a 4-digit
/// `Year4`, a 3-digit `Milli`, a 9-digit `Nano`, etc).
pub fn parse_n_digits(
  bytes: BitArray,
  n: Int,
) -> Result(#(Int, BitArray), Nil) {
  parse_n_digits_loop(bytes, n, 0)
}

fn parse_n_digits_loop(
  bytes: BitArray,
  remaining: Int,
  acc: Int,
) -> Result(#(Int, BitArray), Nil) {
  case remaining {
    0 -> Ok(#(acc, bytes))
    _ ->
      case bytes {
        <<b, rest:bytes>> if b >= byte_zero && b <= byte_nine ->
          parse_n_digits_loop(rest, remaining - 1, acc * 10 + digit_value(b))
        _ -> Error(Nil)
      }
  }
}

fn pow10(n: Int) -> Int {
  case n {
    0 -> 1
    1 -> 10
    2 -> 100
    3 -> 1000
    4 -> 10_000
    5 -> 100_000
    6 -> 1_000_000
    7 -> 10_000_000
    8 -> 100_000_000
    _ -> 1_000_000_000
  }
}

fn skip_digits(bytes: BitArray) -> BitArray {
  case bytes {
    <<b, rest:bytes>> if b >= byte_zero && b <= byte_nine -> skip_digits(rest)
    _ -> bytes
  }
}

fn parse_fraction_digits(
  bytes: BitArray,
  acc: Int,
  count: Int,
) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b >= byte_zero && b <= byte_nine && count < 9 ->
      parse_fraction_digits(rest, acc * 10 + digit_value(b), count + 1)
    // Full nanosecond precision already reached -- truncate any remaining
    // digits, matching `gleam_time`'s own `parse_rfc3339` behavior.
    <<b, rest:bytes>> if b >= byte_zero && b <= byte_nine ->
      Ok(#(acc, skip_digits(rest)))
    _ ->
      case count {
        0 -> Error(Nil)
        _ -> Ok(#(acc * pow10(9 - count), bytes))
      }
  }
}

/// Parses an optional `.` followed by 1-9+ fraction digits, truncated to
/// nanosecond precision (i.e. `"1"` becomes `100_000_000`, and any digits
/// past the 9th are dropped). Returns `0` and the input unchanged when
/// there is no `.`.
pub fn parse_optional_fraction_ns(
  bytes: BitArray,
) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == byte_dot -> parse_fraction_digits(rest, 0, 0)
    _ -> Ok(#(0, bytes))
  }
}

/// Parses a date in any of `YYYY-MM-DD`, `YYYY/MM/DD`, `YYYY.MM.DD`,
/// `YYYY_MM_DD`, `YYYY MM DD` (1 or 2 digit month/day, uniform delimiter), or
/// the compact `YYYYMMDD` form. Returns the raw, unvalidated year/month/day
/// ints -- callers are responsible for bounds-checking them.
pub fn parse_date(bytes: BitArray) -> Result(#(Int, Int, Int, BitArray), Nil) {
  case parse_4_digits(bytes) {
    Error(Nil) -> Error(Nil)

    Ok(#(year, bytes)) ->
      case bytes {
        <<b, _:bytes>> if b >= byte_zero && b <= byte_nine ->
          // Compact form: YYYYMMDD
          case parse_2_digits(bytes) {
            Error(Nil) -> Error(Nil)
            Ok(#(month, bytes)) ->
              case parse_2_digits(bytes) {
                Error(Nil) -> Error(Nil)
                Ok(#(day, bytes)) -> Ok(#(year, month, day, bytes))
              }
          }

        <<delim, rest:bytes>>
          if delim == byte_minus
          || delim == byte_slash
          || delim == byte_dot
          || delim == byte_underscore
          || delim == byte_space
        ->
          case parse_1_or_2_digits(rest) {
            Error(Nil) -> Error(Nil)
            Ok(#(month, rest)) ->
              case accept_byte(rest, delim) {
                Error(Nil) -> Error(Nil)
                Ok(rest) ->
                  case parse_1_or_2_digits(rest) {
                    Error(Nil) -> Error(Nil)
                    Ok(#(day, rest)) -> Ok(#(year, month, day, rest))
                  }
              }
          }

        _ -> Error(Nil)
      }
  }
}

/// Parses a time in any of `HH:MM:SS.frac`, `HH:MM:SS`, `HH:MM` (1 or 2
/// digit fields), or the compact `HHMMSS.frac`/`HHMMSS`/`HHMM` forms.
/// Returns the raw, unvalidated hour/minute/second/nanosecond ints.
pub fn parse_time(
  bytes: BitArray,
) -> Result(#(Int, Int, Int, Int, BitArray), Nil) {
  case parse_1_or_2_digits(bytes) {
    Error(Nil) -> Error(Nil)

    Ok(#(hour, bytes)) ->
      case bytes {
        <<b, rest:bytes>> if b == byte_colon ->
          case parse_1_or_2_digits(rest) {
            Error(Nil) -> Error(Nil)

            Ok(#(minute, rest)) ->
              case rest {
                <<b2, rest2:bytes>> if b2 == byte_colon ->
                  case parse_1_or_2_digits(rest2) {
                    Error(Nil) -> Error(Nil)
                    Ok(#(second, rest2)) ->
                      case parse_optional_fraction_ns(rest2) {
                        Error(Nil) -> Error(Nil)
                        Ok(#(nanosecond, rest2)) ->
                          Ok(#(hour, minute, second, nanosecond, rest2))
                      }
                  }
                _ -> Ok(#(hour, minute, 0, 0, rest))
              }
          }

        // Compact form: HHMM or HHMMSS(.frac). A fraction is only valid
        // when seconds are present.
        <<b, _:bytes>> if b >= byte_zero && b <= byte_nine ->
          case parse_2_digits(bytes) {
            Error(Nil) -> Error(Nil)

            Ok(#(minute, bytes)) ->
              case bytes {
                <<b2, _:bytes>> if b2 >= byte_zero && b2 <= byte_nine ->
                  case parse_2_digits(bytes) {
                    Error(Nil) -> Error(Nil)
                    Ok(#(second, bytes)) ->
                      case parse_optional_fraction_ns(bytes) {
                        Error(Nil) -> Error(Nil)
                        Ok(#(nanosecond, bytes)) ->
                          Ok(#(hour, minute, second, nanosecond, bytes))
                      }
                  }
                <<b2, _:bytes>> if b2 == byte_dot -> Error(Nil)
                _ -> Ok(#(hour, minute, 0, 0, bytes))
              }
          }

        _ -> Error(Nil)
      }
  }
}

fn parse_offset_digits(bytes: BitArray) -> Result(#(Int, Int, BitArray), Nil) {
  case bytes {
    <<b1, rest:bytes>> if b1 >= byte_zero && b1 <= byte_nine ->
      case rest {
        <<b2, rest2:bytes>> if b2 >= byte_zero && b2 <= byte_nine -> {
          let hour = digit_value(b1) * 10 + digit_value(b2)

          case rest2 {
            <<b3, rest3:bytes>> if b3 == byte_colon ->
              case parse_2_digits(rest3) {
                Error(Nil) -> Error(Nil)
                Ok(#(minute, rest4)) -> Ok(#(hour, minute, rest4))
              }

            <<b3, rest3:bytes>> if b3 >= byte_zero && b3 <= byte_nine ->
              case rest3 {
                <<b4, rest4:bytes>> if b4 >= byte_zero && b4 <= byte_nine ->
                  Ok(#(hour, digit_value(b3) * 10 + digit_value(b4), rest4))
                _ -> Error(Nil)
              }

            _ -> Ok(#(hour, 0, rest2))
          }
        }

        _ -> Ok(#(digit_value(b1), 0, rest))
      }

    _ -> Error(Nil)
  }
}

/// Parses an offset in any of `Z`, `z`, `(+-)HH:MM`, `(+-)HHMM`, `(+-)HH`, or
/// `(+-)H` form, returned as total signed minutes. Only checks the loose
/// per-field `hour <= 24 && minute <= 60` shape; range validation (e.g.
/// tempo's -12:00..+14:00 policy) is the caller's job.
pub fn parse_offset(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == byte_z_upper || b == byte_z_lower ->
      Ok(#(0, rest))

    <<b, rest:bytes>> if b == byte_plus || b == byte_minus -> {
      let sign = case b == byte_minus {
        True -> -1
        False -> 1
      }

      case parse_offset_digits(rest) {
        Error(Nil) -> Error(Nil)
        Ok(#(hour, minute, rest)) ->
          case hour > 24 || minute > 60 {
            True -> Error(Nil)
            False -> Ok(#(sign * { hour * 60 + minute }, rest))
          }
      }
    }

    _ -> Error(Nil)
  }
}

// --- RFC 9557 (IXDTF) suffix parsing ----------------------------------------
//
// After the RFC 3339 date-time (with its required offset), an IXDTF string
// may carry a suffix:
//
//   suffix     = [time-zone] *suffix-tag
//   time-zone  = "[" critical-flag (time-zone-name / time-numoffset) "]"
//   suffix-tag = "[" critical-flag suffix-key "=" suffix-values "]"
//
// These helpers validate that grammar and capture the zone name and each
// tag's key/value verbatim, so the suffix can be reproduced losslessly.
//
// Gleam guards cannot call functions, so each char class is written out
// inline in the pattern's `if` rather than factored into a predicate: these
// run once per byte of the suffix, and a guard compiles to inline comparisons
// where a body-position call does not. The classes, for reference:
//
//   time-zone-initial = ALPHA / "." / "_"
//   time-zone-char    = time-zone-initial / DIGIT / "-" / "+"
//   key-initial       = lcalpha / "_"
//   key-char          = key-initial / DIGIT / "-"
//   suffix-value      = 1*alphanum
//
// `is_digit` stays a function because `valid_numoffset` tests a fixed six
// bytes, where clarity is worth more than six inline comparisons.

fn is_digit(b: Int) -> Bool {
  b >= byte_zero && b <= byte_nine
}

/// Parses a full RFC 9557 (IXDTF) string: an RFC 3339 date-time followed by
/// an optional suffix. Returns the raw datetime ints plus the parsed suffix
/// -- an optional `#(critical, name)` time zone and a list of
/// `#(critical, key, value)` tags -- all captured verbatim.
pub fn parse_ixdtf_raw(
  bytes: BitArray,
) -> Result(
  #(
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Option(#(Bool, String)),
    List(#(Bool, String, String)),
  ),
  Nil,
) {
  // The canonical, padded, dash/colon-delimited shape
  // `YYYY-MM-DD?HH:MM:SS[.frac](offset)` is matched in one binary pattern.
  // Compact forms, 1-digit fields, other delimiters and anything the inlined
  // tails below do not cover fall through to `parse_ixdtf_general`.
  //
  // `0x2D` (`-`) and `0x3A` (`:`) must be spelled as literal bytes, not as the
  // named constants: a bare identifier in a bit-array pattern *binds* a fresh
  // variable rather than matching the constant's value, so a named delimiter
  // would silently match any byte.
  case bytes {
    <<
      y1,
      y2,
      y3,
      y4,
      0x2D,
      mo1,
      mo2,
      0x2D,
      d1,
      d2,
      sep,
      h1,
      h2,
      0x3A,
      mi1,
      mi2,
      0x3A,
      s1,
      s2,
      rest:bytes,
    >>
      if y1 >= byte_zero
      && y1 <= byte_nine
      && y2 >= byte_zero
      && y2 <= byte_nine
      && y3 >= byte_zero
      && y3 <= byte_nine
      && y4 >= byte_zero
      && y4 <= byte_nine
      && mo1 >= byte_zero
      && mo1 <= byte_nine
      && mo2 >= byte_zero
      && mo2 <= byte_nine
      && d1 >= byte_zero
      && d1 <= byte_nine
      && d2 >= byte_zero
      && d2 <= byte_nine
      && h1 >= byte_zero
      && h1 <= byte_nine
      && h2 >= byte_zero
      && h2 <= byte_nine
      && mi1 >= byte_zero
      && mi1 <= byte_nine
      && mi2 >= byte_zero
      && mi2 <= byte_nine
      && s1 >= byte_zero
      && s1 <= byte_nine
      && s2 >= byte_zero
      && s2 <= byte_nine
      && {
        sep == byte_t_upper
        || sep == byte_t_lower
        || sep == byte_underscore
        || sep == byte_space
      }
    ->
      // The tail is matched in this same `case` so the whole string stays
      // under one match context. Inlined here are the shapes that dominate
      // real input -- `Z`/`z`/`(+-)HH:MM`, with no fraction or a 3-, 6- or
      // 9-digit one. Every other canonical shape falls to `ixdtf_tail`.
      case rest {
        <<0x5A>> ->
          ixdtf_result(
            y1,
            y2,
            y3,
            y4,
            mo1,
            mo2,
            d1,
            d2,
            h1,
            h2,
            mi1,
            mi2,
            s1,
            s2,
            0,
            0,
          )
        <<0x7A>> ->
          ixdtf_result(
            y1,
            y2,
            y3,
            y4,
            mo1,
            mo2,
            d1,
            d2,
            h1,
            h2,
            mi1,
            mi2,
            s1,
            s2,
            0,
            0,
          )
        <<osign, oh1, oh2, 0x3A, om1, om2>>
          if { osign == 0x2B || osign == 0x2D }
          && oh1 >= byte_zero
          && oh1 <= byte_nine
          && oh2 >= byte_zero
          && oh2 <= byte_nine
          && om1 >= byte_zero
          && om1 <= byte_nine
          && om2 >= byte_zero
          && om2 <= byte_nine
        -> {
          let oh = { oh1 - 0x30 } * 10 + { oh2 - 0x30 }
          let om = { om1 - 0x30 } * 10 + { om2 - 0x30 }
          case oh > 24 || om > 60 {
            True -> Error(Nil)
            False ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                0,
                case osign == 0x2D {
                  True -> -{ oh * 60 + om }
                  False -> oh * 60 + om
                },
              )
          }
        }
        <<0x2E, f1, f2, f3, f4, f5, f6, f7, f8, f9, tail:bytes>>
          if f1 >= byte_zero
          && f1 <= byte_nine
          && f2 >= byte_zero
          && f2 <= byte_nine
          && f3 >= byte_zero
          && f3 <= byte_nine
          && f4 >= byte_zero
          && f4 <= byte_nine
          && f5 >= byte_zero
          && f5 <= byte_nine
          && f6 >= byte_zero
          && f6 <= byte_nine
          && f7 >= byte_zero
          && f7 <= byte_nine
          && f8 >= byte_zero
          && f8 <= byte_nine
          && f9 >= byte_zero
          && f9 <= byte_nine
        ->
          case tail {
            <<0x5A>> ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                { f1 - 0x30 }
                  * 100_000_000
                  + { f2 - 0x30 }
                  * 10_000_000
                  + { f3 - 0x30 }
                  * 1_000_000
                  + { f4 - 0x30 }
                  * 100_000
                  + { f5 - 0x30 }
                  * 10_000
                  + { f6 - 0x30 }
                  * 1000
                  + { f7 - 0x30 }
                  * 100
                  + { f8 - 0x30 }
                  * 10
                  + { f9 - 0x30 },
                0,
              )
            <<0x7A>> ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                { f1 - 0x30 }
                  * 100_000_000
                  + { f2 - 0x30 }
                  * 10_000_000
                  + { f3 - 0x30 }
                  * 1_000_000
                  + { f4 - 0x30 }
                  * 100_000
                  + { f5 - 0x30 }
                  * 10_000
                  + { f6 - 0x30 }
                  * 1000
                  + { f7 - 0x30 }
                  * 100
                  + { f8 - 0x30 }
                  * 10
                  + { f9 - 0x30 },
                0,
              )
            <<osign, oh1, oh2, 0x3A, om1, om2>>
              if { osign == 0x2B || osign == 0x2D }
              && oh1 >= byte_zero
              && oh1 <= byte_nine
              && oh2 >= byte_zero
              && oh2 <= byte_nine
              && om1 >= byte_zero
              && om1 <= byte_nine
              && om2 >= byte_zero
              && om2 <= byte_nine
            -> {
              let oh = { oh1 - 0x30 } * 10 + { oh2 - 0x30 }
              let om = { om1 - 0x30 } * 10 + { om2 - 0x30 }
              case oh > 24 || om > 60 {
                True -> Error(Nil)
                False ->
                  ixdtf_result(
                    y1,
                    y2,
                    y3,
                    y4,
                    mo1,
                    mo2,
                    d1,
                    d2,
                    h1,
                    h2,
                    mi1,
                    mi2,
                    s1,
                    s2,
                    { f1 - 0x30 }
                      * 100_000_000
                      + { f2 - 0x30 }
                      * 10_000_000
                      + { f3 - 0x30 }
                      * 1_000_000
                      + { f4 - 0x30 }
                      * 100_000
                      + { f5 - 0x30 }
                      * 10_000
                      + { f6 - 0x30 }
                      * 1000
                      + { f7 - 0x30 }
                      * 100
                      + { f8 - 0x30 }
                      * 10
                      + { f9 - 0x30 },
                    case osign == 0x2D {
                      True -> -{ oh * 60 + om }
                      False -> oh * 60 + om
                    },
                  )
              }
            }
            _ ->
              ixdtf_tail(
                bytes,
                rest,
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
              )
          }
        <<0x2E, f1, f2, f3, f4, f5, f6, tail:bytes>>
          if f1 >= byte_zero
          && f1 <= byte_nine
          && f2 >= byte_zero
          && f2 <= byte_nine
          && f3 >= byte_zero
          && f3 <= byte_nine
          && f4 >= byte_zero
          && f4 <= byte_nine
          && f5 >= byte_zero
          && f5 <= byte_nine
          && f6 >= byte_zero
          && f6 <= byte_nine
        ->
          case tail {
            <<0x5A>> ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                {
                  { f1 - 0x30 }
                  * 100_000
                  + { f2 - 0x30 }
                  * 10_000
                  + { f3 - 0x30 }
                  * 1000
                  + { f4 - 0x30 }
                  * 100
                  + { f5 - 0x30 }
                  * 10
                  + { f6 - 0x30 }
                }
                  * 1000,
                0,
              )
            <<0x7A>> ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                {
                  { f1 - 0x30 }
                  * 100_000
                  + { f2 - 0x30 }
                  * 10_000
                  + { f3 - 0x30 }
                  * 1000
                  + { f4 - 0x30 }
                  * 100
                  + { f5 - 0x30 }
                  * 10
                  + { f6 - 0x30 }
                }
                  * 1000,
                0,
              )
            <<osign, oh1, oh2, 0x3A, om1, om2>>
              if { osign == 0x2B || osign == 0x2D }
              && oh1 >= byte_zero
              && oh1 <= byte_nine
              && oh2 >= byte_zero
              && oh2 <= byte_nine
              && om1 >= byte_zero
              && om1 <= byte_nine
              && om2 >= byte_zero
              && om2 <= byte_nine
            -> {
              let oh = { oh1 - 0x30 } * 10 + { oh2 - 0x30 }
              let om = { om1 - 0x30 } * 10 + { om2 - 0x30 }
              case oh > 24 || om > 60 {
                True -> Error(Nil)
                False ->
                  ixdtf_result(
                    y1,
                    y2,
                    y3,
                    y4,
                    mo1,
                    mo2,
                    d1,
                    d2,
                    h1,
                    h2,
                    mi1,
                    mi2,
                    s1,
                    s2,
                    {
                      { f1 - 0x30 }
                      * 100_000
                      + { f2 - 0x30 }
                      * 10_000
                      + { f3 - 0x30 }
                      * 1000
                      + { f4 - 0x30 }
                      * 100
                      + { f5 - 0x30 }
                      * 10
                      + { f6 - 0x30 }
                    }
                      * 1000,
                    case osign == 0x2D {
                      True -> -{ oh * 60 + om }
                      False -> oh * 60 + om
                    },
                  )
              }
            }
            _ ->
              ixdtf_tail(
                bytes,
                rest,
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
              )
          }
        <<0x2E, f1, f2, f3, tail:bytes>>
          if f1 >= byte_zero
          && f1 <= byte_nine
          && f2 >= byte_zero
          && f2 <= byte_nine
          && f3 >= byte_zero
          && f3 <= byte_nine
        ->
          case tail {
            <<0x5A>> ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                { { f1 - 0x30 } * 100 + { f2 - 0x30 } * 10 + { f3 - 0x30 } }
                  * 1_000_000,
                0,
              )
            <<0x7A>> ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                { { f1 - 0x30 } * 100 + { f2 - 0x30 } * 10 + { f3 - 0x30 } }
                  * 1_000_000,
                0,
              )
            <<osign, oh1, oh2, 0x3A, om1, om2>>
              if { osign == 0x2B || osign == 0x2D }
              && oh1 >= byte_zero
              && oh1 <= byte_nine
              && oh2 >= byte_zero
              && oh2 <= byte_nine
              && om1 >= byte_zero
              && om1 <= byte_nine
              && om2 >= byte_zero
              && om2 <= byte_nine
            -> {
              let oh = { oh1 - 0x30 } * 10 + { oh2 - 0x30 }
              let om = { om1 - 0x30 } * 10 + { om2 - 0x30 }
              case oh > 24 || om > 60 {
                True -> Error(Nil)
                False ->
                  ixdtf_result(
                    y1,
                    y2,
                    y3,
                    y4,
                    mo1,
                    mo2,
                    d1,
                    d2,
                    h1,
                    h2,
                    mi1,
                    mi2,
                    s1,
                    s2,
                    { { f1 - 0x30 } * 100 + { f2 - 0x30 } * 10 + { f3 - 0x30 } }
                      * 1_000_000,
                    case osign == 0x2D {
                      True -> -{ oh * 60 + om }
                      False -> oh * 60 + om
                    },
                  )
              }
            }
            _ ->
              ixdtf_tail(
                bytes,
                rest,
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
              )
          }
        _ ->
          ixdtf_tail(
            bytes,
            rest,
            y1,
            y2,
            y3,
            y4,
            mo1,
            mo2,
            d1,
            d2,
            h1,
            h2,
            mi1,
            mi2,
            s1,
            s2,
          )
      }

    _ -> parse_ixdtf_general(bytes)
  }
}

// Fraction and offset for the canonical shapes the inlined tails do not
// cover: `(+-)HHMM`, `(+-)HH`, fractions of 1, 2, 4, 5, 7 or 8 digits, and
// anything carrying an RFC 9557 suffix.
fn ixdtf_tail(
  bytes: BitArray,
  rest: BitArray,
  y1: Int,
  y2: Int,
  y3: Int,
  y4: Int,
  mo1: Int,
  mo2: Int,
  d1: Int,
  d2: Int,
  h1: Int,
  h2: Int,
  mi1: Int,
  mi2: Int,
  s1: Int,
  s2: Int,
) -> Result(
  #(
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Option(#(Bool, String)),
    List(#(Bool, String, String)),
  ),
  Nil,
) {
  case parse_optional_fraction_ns(rest) {
    Error(Nil) -> parse_ixdtf_general(bytes)
    Ok(#(nanosecond, rest)) ->
      case parse_offset(rest) {
        Error(Nil) -> parse_ixdtf_general(bytes)
        Ok(#(offset_minutes, rest)) ->
          case rest {
            // Empty tail -> no suffix: build the result directly.
            <<>> ->
              ixdtf_result(
                y1,
                y2,
                y3,
                y4,
                mo1,
                mo2,
                d1,
                d2,
                h1,
                h2,
                mi1,
                mi2,
                s1,
                s2,
                nanosecond,
                offset_minutes,
              )

            // A suffix is present, but the date-time is already parsed, so
            // only the suffix is left to do. Re-running the general parser
            // over the prefix would be redundant: on a canonical 19-byte
            // prefix `parse_date` and `parse_time` read exactly the fields
            // the pattern above matched (`parse_1_or_2_digits` takes two
            // digits greedily), and they finish by calling the same
            // `parse_optional_fraction_ns` and `parse_offset` that just
            // succeeded here.
            _ ->
              case parse_suffix(rest) {
                Error(Nil) -> Error(Nil)
                Ok(#(zone, tags)) ->
                  ixdtf_suffixed(
                    y1,
                    y2,
                    y3,
                    y4,
                    mo1,
                    mo2,
                    d1,
                    d2,
                    h1,
                    h2,
                    mi1,
                    mi2,
                    s1,
                    s2,
                    nanosecond,
                    offset_minutes,
                    zone,
                    tags,
                  )
              }
          }
      }
  }
}

// Builds the result from the raw digit bytes. Every argument is an `Int`, so
// this stays a free local call.
fn ixdtf_result(
  y1: Int,
  y2: Int,
  y3: Int,
  y4: Int,
  mo1: Int,
  mo2: Int,
  d1: Int,
  d2: Int,
  h1: Int,
  h2: Int,
  mi1: Int,
  mi2: Int,
  s1: Int,
  s2: Int,
  nanosecond: Int,
  offset_minutes: Int,
) -> Result(
  #(
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Option(#(Bool, String)),
    List(#(Bool, String, String)),
  ),
  Nil,
) {
  Ok(
    #(
      digit_value(y1)
        * 1000
        + digit_value(y2)
        * 100
        + digit_value(y3)
        * 10
        + digit_value(y4),
      digit_value(mo1) * 10 + digit_value(mo2),
      digit_value(d1) * 10 + digit_value(d2),
      digit_value(h1) * 10 + digit_value(h2),
      digit_value(mi1) * 10 + digit_value(mi2),
      digit_value(s1) * 10 + digit_value(s2),
      nanosecond,
      offset_minutes,
      None,
      [],
    ),
  )
}

fn parse_ixdtf_general(
  bytes: BitArray,
) -> Result(
  #(
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Option(#(Bool, String)),
    List(#(Bool, String, String)),
  ),
  Nil,
) {
  case parse_date(bytes) {
    Error(Nil) -> Error(Nil)

    Ok(#(year, month, day, bytes)) ->
      case bytes {
        <<b, bytes:bytes>>
          if b == byte_t_upper
          || b == byte_t_lower
          || b == byte_underscore
          || b == byte_space
        ->
          case parse_time(bytes) {
            Error(Nil) -> Error(Nil)

            Ok(#(hour, minute, second, nanosecond, bytes)) ->
              case parse_offset(bytes) {
                Error(Nil) -> Error(Nil)

                Ok(#(offset_minutes, bytes)) ->
                  case parse_suffix(bytes) {
                    Error(Nil) -> Error(Nil)
                    Ok(#(zone, tags)) ->
                      Ok(#(
                        year,
                        month,
                        day,
                        hour,
                        minute,
                        second,
                        nanosecond,
                        offset_minutes,
                        zone,
                        tags,
                      ))
                  }
              }
          }

        _ -> Error(Nil)
      }
  }
}

/// Parses an optional leading RFC 9557 time-zone group for the `ZoneName`
/// format directive. If the next `[..]` group is a time zone (has no `=`) it
/// is returned with the bytes after it; if the next group is a `key=value`
/// tag, or there is no bracket, `None` is returned with the input unchanged
/// (so the tags directive can handle it). A malformed zone group fails.
pub fn parse_optional_zone(
  bytes: BitArray,
) -> Result(#(Option(#(Bool, String)), BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == byte_lbracket -> {
      let #(critical, after_bang) = take_critical(rest)
      case take_group(after_bang) {
        Error(Nil) -> Error(Nil)
        Ok(#(tok, term, after, zone_ok)) ->
          case term == byte_rbracket {
            // No `=` -> the group is a time zone.
            True ->
              case zone_name_string(tok, zone_ok) {
                Error(Nil) -> Error(Nil)
                Ok(name) -> Ok(#(Some(#(critical, name)), after))
              }
            // `=` -> the group is a tag; leave it for the tags directive.
            False -> Ok(#(None, bytes))
          }
      }
    }
    _ -> Ok(#(None, bytes))
  }
}

/// Parses a run of RFC 9557 `[key=value]` extension tags for the
/// `ExtensionTags` directive, stopping at the first byte that is not `[`.
/// Returns the tags (verbatim, in order) and the remaining bytes. A `[..]`
/// group that is not a well-formed tag fails.
pub fn parse_tag_run(
  bytes: BitArray,
) -> Result(#(List(#(Bool, String, String)), BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == byte_lbracket -> {
      let #(critical, after_bang) = take_critical(rest)
      case take_group(after_bang) {
        Error(Nil) -> Error(Nil)
        Ok(#(tok, term, after, _zone_ok)) ->
          case term == byte_equals {
            False -> Error(Nil)
            True ->
              case key_string(tok) {
                Error(Nil) -> Error(Nil)
                Ok(key) ->
                  case take_value(after) {
                    Error(Nil) -> Error(Nil)
                    Ok(#(value_tok, after_value, values_ok)) ->
                      case values_string(value_tok, values_ok) {
                        Error(Nil) -> Error(Nil)
                        Ok(value) ->
                          case parse_tag_run(after_value) {
                            Error(Nil) -> Error(Nil)
                            Ok(#(tags, final)) ->
                              Ok(#([#(critical, key, value), ..tags], final))
                          }
                      }
                  }
              }
          }
      }
    }
    _ -> Ok(#([], bytes))
  }
}

fn parse_suffix(
  bytes: BitArray,
) -> Result(#(Option(#(Bool, String)), List(#(Bool, String, String))), Nil) {
  case bytes {
    <<>> -> Ok(#(None, []))
    <<b, rest:bytes>> ->
      case b == byte_lbracket {
        True -> parse_first_bracket(rest)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// The first bracket group is the only one that may be a `time-zone` (a group
// with no `=`); every later group must be a `key=value` tag.
fn parse_first_bracket(
  bytes: BitArray,
) -> Result(#(Option(#(Bool, String)), List(#(Bool, String, String))), Nil) {
  let #(critical, bytes) = take_critical(bytes)
  case take_group(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(tok, term, rest, zone_ok)) ->
      case term == byte_rbracket {
        // No `=` in this group -> it is the time-zone.
        True ->
          case zone_name_string(tok, zone_ok) {
            Error(Nil) -> Error(Nil)
            Ok(name) ->
              case parse_tags(rest) {
                Error(Nil) -> Error(Nil)
                Ok(tags) -> Ok(#(Some(#(critical, name)), tags))
              }
          }
        // `=` present -> the group is a tag and there is no time-zone.
        False ->
          case key_string(tok) {
            Error(Nil) -> Error(Nil)
            Ok(key) ->
              case take_value(rest) {
                Error(Nil) -> Error(Nil)
                Ok(#(value_tok, rest, values_ok)) ->
                  case values_string(value_tok, values_ok) {
                    Error(Nil) -> Error(Nil)
                    Ok(value) ->
                      case parse_tags(rest) {
                        Error(Nil) -> Error(Nil)
                        Ok(tags) ->
                          Ok(#(None, [#(critical, key, value), ..tags]))
                      }
                  }
              }
          }
      }
  }
}

fn parse_tags(bytes: BitArray) -> Result(List(#(Bool, String, String)), Nil) {
  case bytes {
    <<>> -> Ok([])
    <<b, rest:bytes>> ->
      case b == byte_lbracket {
        True -> {
          let #(critical, rest) = take_critical(rest)
          case take_group(rest) {
            Error(Nil) -> Error(Nil)
            Ok(#(tok, term, rest, _zone_ok)) ->
              // A later group with no `=` would be a second time-zone, which
              // the grammar forbids.
              case term == byte_equals {
                False -> Error(Nil)
                True ->
                  case key_string(tok) {
                    Error(Nil) -> Error(Nil)
                    Ok(key) ->
                      case take_value(rest) {
                        Error(Nil) -> Error(Nil)
                        Ok(#(value_tok, rest, values_ok)) ->
                          case values_string(value_tok, values_ok) {
                            Error(Nil) -> Error(Nil)
                            Ok(value) ->
                              case parse_tags(rest) {
                                Error(Nil) -> Error(Nil)
                                Ok(tags) ->
                                  Ok([#(critical, key, value), ..tags])
                              }
                          }
                      }
                  }
              }
          }
        }
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn take_critical(bytes: BitArray) -> #(Bool, BitArray) {
  case bytes {
    <<b, rest:bytes>> ->
      case b == byte_bang {
        True -> #(True, rest)
        False -> #(False, bytes)
      }
    _ -> #(False, bytes)
  }
}

// Scans up to the first `=` or `]`, slicing out the raw token bytes and
// returning them with the terminator, the bytes after it, and whether the
// token satisfies the `time-zone-name` grammar.
//
// That last flag keeps the scan and the grammar check to a single pass, with
// each byte classified inline in the pattern guards. The caller only reads
// `zone_ok` when the terminator is `]` -- a tag key is validated separately by
// `valid_key` -- so tracking it costs one extra register on a walk that has to
// happen anyway.
fn take_group(
  bytes: BitArray,
) -> Result(#(BitArray, Int, BitArray, Bool), Nil) {
  case scan_group(bytes, 0, 0, 0, True, True) {
    Error(Nil) -> Error(Nil)
    Ok(#(len, term, rest, zone_ok)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> Error(Nil)
        Ok(tok) -> Ok(#(tok, term, rest, zone_ok))
      }
  }
}

// `len`/`dots` count the current `time-zone-part`; `initial` marks that the
// next byte begins a part; `ok` latches to False on the first violation and
// the scan continues purely to locate the terminator.
fn scan_group(
  bytes: BitArray,
  n: Int,
  len: Int,
  dots: Int,
  initial: Bool,
  ok: Bool,
) -> Result(#(Int, Int, BitArray, Bool), Nil) {
  case bytes {
    <<0x5D, rest:bytes>> ->
      Ok(#(
        n,
        byte_rbracket,
        rest,
        ok && !initial && !{ len == dots && len <= 2 },
      ))

    // A `=` makes this a tag group, so the zone-name verdict is irrelevant.
    <<0x3D, rest:bytes>> -> Ok(#(n, byte_equals, rest, False))

    // End of a part: it must be non-empty and not be "." or "..".
    <<0x2F, rest:bytes>> ->
      scan_group(
        rest,
        n + 1,
        0,
        0,
        True,
        ok && !initial && !{ len == dots && len <= 2 },
      )

    // `.` is a time-zone-initial as well as a time-zone-char.
    <<0x2E, rest:bytes>> ->
      scan_group(rest, n + 1, len + 1, dots + 1, False, ok)

    // ALPHA / "_" -- valid anywhere in a part, including first.
    <<b, rest:bytes>>
      if { b >= 0x41 && b <= 0x5A }
      || { b >= 0x61 && b <= 0x7A }
      || b == byte_underscore
    -> scan_group(rest, n + 1, len + 1, dots, False, ok)

    // DIGIT / "-" / "+" -- time-zone-chars, but not time-zone-initials.
    <<b, rest:bytes>>
      if { b >= byte_zero && b <= byte_nine }
      || b == byte_minus
      || b == byte_plus
    -> scan_group(rest, n + 1, len + 1, dots, False, ok && !initial)

    <<_b, rest:bytes>> -> scan_group(rest, n + 1, len + 1, dots, False, False)

    // No terminator before the end of input.
    _ -> Error(Nil)
  }
}

// Scans a tag value up to its closing `]`, validating `suffix-values` in the
// same pass. `need_alnum` is True whenever the next byte must be alphanum,
// i.e. at the start and immediately after a `-`.
fn take_value(bytes: BitArray) -> Result(#(BitArray, BitArray, Bool), Nil) {
  case scan_value(bytes, 0, True, True) {
    Error(Nil) -> Error(Nil)
    Ok(#(len, rest, ok)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> Error(Nil)
        Ok(tok) -> Ok(#(tok, rest, ok))
      }
  }
}

fn scan_value(
  bytes: BitArray,
  n: Int,
  need_alnum: Bool,
  ok: Bool,
) -> Result(#(Int, BitArray, Bool), Nil) {
  case bytes {
    <<0x5D, rest:bytes>> -> Ok(#(n, rest, ok && !need_alnum))

    <<b, rest:bytes>>
      if { b >= 0x41 && b <= 0x5A }
      || { b >= 0x61 && b <= 0x7A }
      || { b >= byte_zero && b <= byte_nine }
    -> scan_value(rest, n + 1, False, ok)

    // Hyphens separate alphanum runs: never leading, trailing, or doubled.
    <<0x2D, rest:bytes>> -> scan_value(rest, n + 1, True, ok && !need_alnum)

    <<_b, rest:bytes>> -> scan_value(rest, n + 1, False, False)

    _ -> Error(Nil)
  }
}

// The bracket content before a `]` is either an offset time zone (starts with
// `+`/`-`) or an IANA-style time-zone-name. `name_ok` is the time-zone-name
// verdict `scan_group` already computed while locating the `]`; only the
// numoffset form still needs a look at the bytes, and it is a fixed 6.
fn zone_name_string(tok: BitArray, name_ok: Bool) -> Result(String, Nil) {
  case tok {
    <<b, _:bytes>> if b == byte_plus || b == byte_minus ->
      case valid_numoffset(tok) {
        True -> bit_array.to_string(tok)
        False -> Error(Nil)
      }

    <<_b, _:bytes>> ->
      case name_ok {
        True -> bit_array.to_string(tok)
        False -> Error(Nil)
      }

    // Empty content, e.g. `[]` or `[!]`.
    _ -> Error(Nil)
  }
}

fn key_string(tok: BitArray) -> Result(String, Nil) {
  case valid_key(tok) {
    True -> bit_array.to_string(tok)
    False -> Error(Nil)
  }
}

// `ok` is `scan_value`'s verdict, computed while locating the `]`.
fn values_string(tok: BitArray, ok: Bool) -> Result(String, Nil) {
  case ok {
    True -> bit_array.to_string(tok)
    False -> Error(Nil)
  }
}

// time-numoffset = ("+" / "-") time-hour ":" time-minute -- exactly `±HH:MM`.
// Structural only (no hour/minute range check), matching this module's
// no-validation policy.
fn valid_numoffset(tok: BitArray) -> Bool {
  case tok {
    <<sign, h1, h2, colon, m1, m2>> ->
      { sign == byte_plus || sign == byte_minus }
      && is_digit(h1)
      && is_digit(h2)
      && colon == byte_colon
      && is_digit(m1)
      && is_digit(m2)
    _ -> False
  }
}

// suffix-key = key-initial *key-char. Keys are short and the terminator is
// already known, so this stays a separate pass -- but the char classes are
// written inline in the guards rather than called as functions.
fn valid_key(tok: BitArray) -> Bool {
  case tok {
    <<b, rest:bytes>> if { b >= 0x61 && b <= 0x7A } || b == byte_underscore ->
      valid_key_rest(rest)
    _ -> False
  }
}

fn valid_key_rest(tok: BitArray) -> Bool {
  case tok {
    <<>> -> True
    <<b, rest:bytes>>
      if { b >= 0x61 && b <= 0x7A }
      || { b >= byte_zero && b <= byte_nine }
      || b == byte_underscore
      || b == byte_minus
    -> valid_key_rest(rest)
    _ -> False
  }
}

// As `ixdtf_result`, but for a prefix that carried an RFC 9557 suffix.
fn ixdtf_suffixed(
  y1: Int,
  y2: Int,
  y3: Int,
  y4: Int,
  mo1: Int,
  mo2: Int,
  d1: Int,
  d2: Int,
  h1: Int,
  h2: Int,
  mi1: Int,
  mi2: Int,
  s1: Int,
  s2: Int,
  nanosecond: Int,
  offset_minutes: Int,
  zone: Option(#(Bool, String)),
  tags: List(#(Bool, String, String)),
) -> Result(
  #(
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Option(#(Bool, String)),
    List(#(Bool, String, String)),
  ),
  Nil,
) {
  Ok(#(
    digit_value(y1)
      * 1000
      + digit_value(y2)
      * 100
      + digit_value(y3)
      * 10
      + digit_value(y4),
    digit_value(mo1) * 10 + digit_value(mo2),
    digit_value(d1) * 10 + digit_value(d2),
    digit_value(h1) * 10 + digit_value(h2),
    digit_value(mi1) * 10 + digit_value(mi2),
    digit_value(s1) * 10 + digit_value(s2),
    nanosecond,
    offset_minutes,
    zone,
    tags,
  ))
}
