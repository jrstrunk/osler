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
import osler/internal

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
@external(javascript, "../osler_ffi.mjs", "parse_ixdtf")
pub fn parse_ixdtf(str: String) -> Result(Ixdtf, Nil) {
  case internal.parse_ixdtf_fast(bit_array.from_string(str)) {
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

/// The AM/PM period parsed from an `a`/`A` meridiem directive (or rendered
/// from the hour of the day).
pub type AmPm {
  Am
  Pm
}

/// A single directive making up a custom parse/render format. A format is an
/// ordered `List(Directive)`; `parse`/`format` walk it against the input.
///
/// The field directives mirror the moment.js / Day.js vocabulary, with
/// explicit variants for the padded and unpadded forms. Beyond those there
/// are three extra kinds:
///
///   * **flexible separators** (`Separator`, `TimeSeparator`,
///     `DateTimeSeparator`) match a *class* of delimiter characters so a
///     single format accepts `2024-06-13`, `2024/06/13`, and compact
///     `20240613` alike -- flexibility is opt-in, per position;
///   * **compound ISO directives** (`IsoDate`, `IsoTime`, `IsoOffset`,
///     `IsoNaiveDateTime`) dispatch to osler's fast, delimiter-flexible
///     byte scanners, for lenient ISO-8601-ish parsing in one token;
///   * `EndOfInput` asserts the input is fully consumed (by default a parse
///     ignores any trailing input, matching moment-style parsers).
pub type Directive {
  /// `YYYY` -- four-digit year.
  Year4
  /// `M` -- one or two digit month.
  Month
  /// `MM` -- two-digit month.
  Month2
  /// `MMM` -- short English month name (`Jan`..`Dec`).
  MonthShortName
  /// `MMMM` -- full English month name (`January`..`December`).
  MonthLongName
  /// `D` -- one or two digit day of month.
  Day
  /// `DD` -- two-digit day of month.
  Day2
  /// `d` -- ISO day-of-week number (parse: a single `0`-`6` digit, matched
  /// then discarded; render: `1` (Mon) .. `7` (Sun)).
  WeekdayNumber
  /// `dd` -- two-letter English weekday (`Su`..`Sa`); discarded on parse.
  WeekdayShortName2
  /// `ddd` -- short English weekday (`Sun`..`Sat`); discarded on parse.
  WeekdayShortName
  /// `dddd` -- full English weekday (`Sunday`..`Saturday`); discarded on parse.
  WeekdayLongName
  /// `H` -- one or two digit 24-hour hour.
  Hour24
  /// `HH` -- two-digit 24-hour hour.
  Hour24Padded
  /// `h` -- one or two digit 12-hour hour.
  Hour12
  /// `hh` -- two-digit 12-hour hour.
  Hour12Padded
  /// `a` -- lowercase meridiem (`am`/`pm`).
  MeridiemLower
  /// `A` -- uppercase meridiem (`AM`/`PM`).
  MeridiemUpper
  /// `m` -- one or two digit minute.
  Minute
  /// `mm` -- two-digit minute.
  Minute2
  /// `s` -- one or two digit second.
  Second
  /// `ss` -- two-digit second.
  Second2
  /// `SSS` -- three fractional digits (milliseconds), stored as nanoseconds.
  Milli
  /// `SSSS` -- six fractional digits (microseconds), stored as nanoseconds.
  Micro
  /// Nine fractional digits (nanoseconds).
  Nano
  /// `z` -- offset, condensed: `Z`, `±HH`, `±HH:MM`.
  Offset
  /// `zz` -- offset: `Z` when zero, otherwise `±HH:MM`.
  OffsetZulu
  /// `Z` -- offset, always `±HH:MM`.
  OffsetColon
  /// `ZZ` -- offset, always `±HHMM`.
  OffsetNoColon
  /// The literal string `GMT`, meaning a zero offset.
  Gmt
  /// An RFC 9557 time zone group, e.g. `[America/Los_Angeles]` or `[!+08:45]`.
  ZoneName
  /// A run of RFC 9557 `[key=value]` extension tags.
  ExtensionTags
  /// A literal string that must appear verbatim in the input (this is what an
  /// escaped `[..]` group and any non-directive characters become).
  Literal(String)
  /// Zero or one of `-` `/` `.` `_` space -- a flexible date delimiter.
  Separator
  /// Zero or one of `:` `_` space -- a flexible time delimiter.
  TimeSeparator
  /// Exactly one of `T` `t` `_` space -- a date/time delimiter.
  DateTimeSeparator
  /// Matches only at the end of the input.
  EndOfInput
  /// A full delimiter-flexible ISO date (`YYYY-MM-DD`, `YYYY/MM/DD`,
  /// compact `YYYYMMDD`, ...).
  IsoDate
  /// A full delimiter-flexible ISO time (`HH:MM:SS.fff`, `HH:MM`, compact
  /// `HHMMSS`, ...).
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
/// unvalidated `Parts` each directive filled in. Any input left over after
/// the last directive is ignored; add a trailing `EndOfInput` to require the
/// whole input to be consumed.
@external(javascript, "../osler_ffi.mjs", "parse")
pub fn parse(input: String, directives: List(Directive)) -> Result(Parts, Nil) {
  case run(bit_array.from_string(input), directives, empty_parts()) {
    Ok(#(parts, _rest)) -> Ok(parts)
    Error(Nil) -> Error(Nil)
  }
}

fn run(
  bytes: BitArray,
  directives: List(Directive),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case directives {
    [] -> Ok(#(parts, bytes))
    [directive, ..rest] ->
      case step(directive, bytes, parts) {
        Ok(#(parts, bytes)) -> run(bytes, rest, parts)
        Error(Nil) -> Error(Nil)
      }
  }
}

fn step(
  directive: Directive,
  bytes: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case directive {
    Year4 ->
      with_int(internal.parse_4_digits(bytes), fn(v) {
        Parts(..parts, year: Some(v))
      })
    Month ->
      with_int(internal.parse_1_or_2_digits(bytes), fn(v) {
        Parts(..parts, month: Some(v))
      })
    Month2 ->
      with_int(internal.parse_2_digits(bytes), fn(v) {
        Parts(..parts, month: Some(v))
      })
    MonthShortName ->
      with_int(consume_month_short(bytes), fn(v) {
        Parts(..parts, month: Some(v))
      })
    MonthLongName ->
      with_int(consume_month_long(bytes), fn(v) {
        Parts(..parts, month: Some(v))
      })
    Day ->
      with_int(internal.parse_1_or_2_digits(bytes), fn(v) {
        Parts(..parts, day: Some(v))
      })
    Day2 ->
      with_int(internal.parse_2_digits(bytes), fn(v) {
        Parts(..parts, day: Some(v))
      })
    WeekdayNumber -> keep(consume_weekday_number(bytes), parts)
    WeekdayShortName2 -> keep(consume_weekday_2(bytes), parts)
    WeekdayShortName -> keep(consume_weekday_3(bytes), parts)
    WeekdayLongName -> keep(consume_weekday_long(bytes), parts)
    Hour24 ->
      with_int(internal.parse_1_or_2_digits(bytes), fn(v) {
        Parts(..parts, hour: Some(v))
      })
    Hour24Padded ->
      with_int(internal.parse_2_digits(bytes), fn(v) {
        Parts(..parts, hour: Some(v))
      })
    Hour12 ->
      with_int(internal.parse_1_or_2_digits(bytes), fn(v) {
        Parts(..parts, twelve_hour: Some(v))
      })
    Hour12Padded ->
      with_int(internal.parse_2_digits(bytes), fn(v) {
        Parts(..parts, twelve_hour: Some(v))
      })
    MeridiemLower -> with_ampm(consume_meridiem_lower(bytes), parts)
    MeridiemUpper -> with_ampm(consume_meridiem_upper(bytes), parts)
    Minute ->
      with_int(internal.parse_1_or_2_digits(bytes), fn(v) {
        Parts(..parts, minute: Some(v))
      })
    Minute2 ->
      with_int(internal.parse_2_digits(bytes), fn(v) {
        Parts(..parts, minute: Some(v))
      })
    Second ->
      with_int(internal.parse_1_or_2_digits(bytes), fn(v) {
        Parts(..parts, second: Some(v))
      })
    Second2 ->
      with_int(internal.parse_2_digits(bytes), fn(v) {
        Parts(..parts, second: Some(v))
      })
    Milli ->
      with_int(internal.parse_n_digits(bytes, 3), fn(v) {
        Parts(..parts, nanosecond: Some(v * 1_000_000))
      })
    Micro ->
      with_int(internal.parse_n_digits(bytes, 6), fn(v) {
        Parts(..parts, nanosecond: Some(v * 1000))
      })
    Nano ->
      with_int(internal.parse_n_digits(bytes, 9), fn(v) {
        Parts(..parts, nanosecond: Some(v))
      })
    Offset | OffsetZulu | OffsetColon | OffsetNoColon | IsoOffset ->
      with_int(internal.parse_offset_fast(bytes), fn(v) {
        Parts(..parts, offset_minutes: Some(v))
      })
    Gmt -> consume_gmt(bytes, parts)
    ZoneName -> consume_zone(bytes, parts)
    ExtensionTags -> consume_tags(bytes, parts)
    Literal(lit) -> consume_literal(bytes, bit_array.from_string(lit), parts)
    Separator -> Ok(#(parts, consume_separator(bytes)))
    TimeSeparator -> Ok(#(parts, consume_time_separator(bytes)))
    DateTimeSeparator -> consume_datetime_separator(bytes, parts)
    EndOfInput ->
      case internal.accept_end(bytes) {
        Ok(Nil) -> Ok(#(parts, bytes))
        Error(Nil) -> Error(Nil)
      }
    IsoDate -> consume_iso_date(bytes, parts)
    IsoTime -> consume_iso_time(bytes, parts)
    IsoNaiveDateTime -> consume_iso_naive(bytes, parts)
  }
}

fn with_int(
  res: Result(#(Int, BitArray), Nil),
  set: fn(Int) -> Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case res {
    Ok(#(v, rest)) -> Ok(#(set(v), rest))
    Error(Nil) -> Error(Nil)
  }
}

fn with_ampm(
  res: Result(#(AmPm, BitArray), Nil),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case res {
    Ok(#(period, rest)) -> Ok(#(Parts(..parts, period: Some(period)), rest))
    Error(Nil) -> Error(Nil)
  }
}

fn keep(
  res: Result(BitArray, Nil),
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case res {
    Ok(rest) -> Ok(#(parts, rest))
    Error(Nil) -> Error(Nil)
  }
}

fn consume_literal(
  bytes: BitArray,
  lit: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case lit {
    <<>> -> Ok(#(parts, bytes))
    <<b, lit_rest:bytes>> ->
      case bytes {
        <<c, rest:bytes>> if c == b -> consume_literal(rest, lit_rest, parts)
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
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case bytes {
    <<0x54, rest:bytes>> -> Ok(#(parts, rest))
    <<0x74, rest:bytes>> -> Ok(#(parts, rest))
    <<0x5F, rest:bytes>> -> Ok(#(parts, rest))
    <<0x20, rest:bytes>> -> Ok(#(parts, rest))
    _ -> Error(Nil)
  }
}

fn consume_gmt(
  bytes: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case bytes {
    <<"GMT":utf8, rest:bytes>> ->
      Ok(#(Parts(..parts, offset_minutes: Some(0)), rest))
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
    <<b, rest:bytes>> if b >= 0x30 && b <= 0x36 -> Ok(rest)
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
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case internal.parse_date_fast(bytes) {
    Ok(#(year, month, day, rest)) ->
      Ok(#(
        Parts(..parts, year: Some(year), month: Some(month), day: Some(day)),
        rest,
      ))
    Error(Nil) -> Error(Nil)
  }
}

fn consume_iso_time(
  bytes: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case internal.parse_time_fast(bytes) {
    Ok(#(hour, minute, second, nanosecond, rest)) ->
      Ok(#(
        Parts(
          ..parts,
          hour: Some(hour),
          minute: Some(minute),
          second: Some(second),
          nanosecond: Some(nanosecond),
        ),
        rest,
      ))
    Error(Nil) -> Error(Nil)
  }
}

fn consume_iso_naive(
  bytes: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case internal.parse_date_fast(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(year, month, day, rest)) -> {
      let parts =
        Parts(..parts, year: Some(year), month: Some(month), day: Some(day))
      case rest {
        <<0x54, rest:bytes>>
        | <<0x74, rest:bytes>>
        | <<0x5F, rest:bytes>>
        | <<0x20, rest:bytes>> -> consume_iso_time(rest, parts)
        _ -> Ok(#(parts, rest))
      }
    }
  }
}

fn consume_zone(
  bytes: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case internal.parse_optional_zone(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(None, rest)) -> Ok(#(parts, rest))
    Ok(#(Some(#(critical, name)), rest)) ->
      Ok(#(Parts(..parts, zone: Some(Zone(critical:, name:))), rest))
  }
}

fn consume_tags(
  bytes: BitArray,
  parts: Parts,
) -> Result(#(Parts, BitArray), Nil) {
  case internal.parse_tag_run(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(raw, rest)) -> Ok(#(Parts(..parts, tags: wrap_tags(raw)), rest))
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
    EndOfInput -> Ok("")
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
