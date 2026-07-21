//// Shared byte-level parsing primitives for `osler`'s date/time/offset
//// parsers. These parse directly from a `BitArray`, without regex or
//// `gleam/string` splitting. Every parser here only extracts and
//// range-checks byte *shapes*; it never validates calendar semantics
//// (month lengths, leap years, hour/offset bounds, etc) -- that's the
//// caller's job (see `osler.gleam`), so this module has one job: turn
//// bytes into raw ints as cheaply as possible.
////
//// This is the Erlang-target implementation. On the JavaScript target,
//// `osler.gleam`'s public functions are overridden by `osler_ffi.mjs`,
//// which reads character codes directly off the string instead of going
//// through Gleam's `BitArray` -- a hand-written Erlang mirror of this
//// module made no measurable difference there (BEAM already compiles
//// `BitArray` matching to near-native binary instructions), but Gleam's JS
//// `BitArray` is a heavy general-purpose class, so bypassing it on JS is
//// worth ~4-5x.

import gleam/bit_array
import gleam/option.{type Option, None, Some}

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

pub fn accept_byte(bytes: BitArray, value: Int) -> Result(BitArray, Nil) {
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
pub fn parse_date_fast(
  bytes: BitArray,
) -> Result(#(Int, Int, Int, BitArray), Nil) {
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
pub fn parse_time_fast(
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
pub fn parse_offset_fast(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
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

/// Parses a full date, separator, and time (no offset). Returns the raw,
/// unvalidated year/month/day/hour/minute/second/nanosecond ints.
pub fn parse_naive_datetime_fast(
  bytes: BitArray,
) -> Result(#(Int, Int, Int, Int, Int, Int, Int), Nil) {
  case parse_date_fast(bytes) {
    Error(Nil) -> Error(Nil)

    Ok(#(year, month, day, bytes)) ->
      case bytes {
        <<>> -> Ok(#(year, month, day, 0, 0, 0, 0))

        <<b, rest:bytes>>
          if b == byte_t_upper
          || b == byte_t_lower
          || b == byte_underscore
          || b == byte_space
        ->
          case parse_time_fast(rest) {
            Error(Nil) -> Error(Nil)
            Ok(#(hour, minute, second, nanosecond, rest)) ->
              case accept_end(rest) {
                Error(Nil) -> Error(Nil)
                Ok(Nil) ->
                  Ok(#(year, month, day, hour, minute, second, nanosecond))
              }
          }

        _ -> Error(Nil)
      }
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
// None of the char-class tests live in `case` guards (Gleam guards cannot
// call functions), so each byte is destructured first and classified in the
// branch body.

fn is_alpha(b: Int) -> Bool {
  { b >= 0x41 && b <= 0x5A } || { b >= 0x61 && b <= 0x7A }
}

fn is_lcalpha(b: Int) -> Bool {
  b >= 0x61 && b <= 0x7A
}

fn is_digit(b: Int) -> Bool {
  b >= byte_zero && b <= byte_nine
}

fn is_alphanum(b: Int) -> Bool {
  is_alpha(b) || is_digit(b)
}

// time-zone-initial = ALPHA / "." / "_"
fn is_zone_initial(b: Int) -> Bool {
  is_alpha(b) || b == byte_dot || b == byte_underscore
}

// time-zone-char = time-zone-initial / DIGIT / "-" / "+"
fn is_zone_char(b: Int) -> Bool {
  is_zone_initial(b) || is_digit(b) || b == byte_minus || b == byte_plus
}

// key-initial = lcalpha / "_"
fn is_key_initial(b: Int) -> Bool {
  is_lcalpha(b) || b == byte_underscore
}

// key-char = key-initial / DIGIT / "-"
fn is_key_char(b: Int) -> Bool {
  is_key_initial(b) || is_digit(b) || b == byte_minus
}

/// Parses a full RFC 9557 (IXDTF) string: an RFC 3339 date-time followed by
/// an optional suffix. Returns the raw datetime ints plus the parsed suffix
/// -- an optional `#(critical, name)` time zone and a list of
/// `#(critical, key, value)` tags -- all captured verbatim.
pub fn parse_ixdtf_fast(
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
  case parse_date_fast(bytes) {
    Error(Nil) -> Error(Nil)

    Ok(#(year, month, day, bytes)) ->
      case bytes {
        <<b, bytes:bytes>>
          if b == byte_t_upper
          || b == byte_t_lower
          || b == byte_underscore
          || b == byte_space
        ->
          case parse_time_fast(bytes) {
            Error(Nil) -> Error(Nil)

            Ok(#(hour, minute, second, nanosecond, bytes)) ->
              case parse_offset_fast(bytes) {
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
  case take_token(bytes) {
    Error(Nil) -> Error(Nil)
    Ok(#(tok, term, rest)) ->
      case term == byte_rbracket {
        // No `=` in this group -> it is the time-zone.
        True ->
          case zone_name_string(tok) {
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
                Ok(#(value_tok, rest)) ->
                  case values_string(value_tok) {
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

fn parse_tags(
  bytes: BitArray,
) -> Result(List(#(Bool, String, String)), Nil) {
  case bytes {
    <<>> -> Ok([])
    <<b, rest:bytes>> ->
      case b == byte_lbracket {
        True -> {
          let #(critical, rest) = take_critical(rest)
          case take_token(rest) {
            Error(Nil) -> Error(Nil)
            Ok(#(tok, term, rest)) ->
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
                        Ok(#(value_tok, rest)) ->
                          case values_string(value_tok) {
                            Error(Nil) -> Error(Nil)
                            Ok(value) ->
                              case parse_tags(rest) {
                                Error(Nil) -> Error(Nil)
                                Ok(tags) -> Ok([#(critical, key, value), ..tags])
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
// returning them with the terminator and the bytes after it. The slice keeps
// this O(n): the scan only counts, and the token is extracted once.
fn take_token(bytes: BitArray) -> Result(#(BitArray, Int, BitArray), Nil) {
  case token_len(bytes, 0) {
    Error(Nil) -> Error(Nil)
    Ok(#(len, term, rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> Error(Nil)
        Ok(tok) -> Ok(#(tok, term, rest))
      }
  }
}

fn token_len(bytes: BitArray, n: Int) -> Result(#(Int, Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == byte_equals || b == byte_rbracket ->
      Ok(#(n, b, rest))
    <<_b, rest:bytes>> -> token_len(rest, n + 1)
    _ -> Error(Nil)
  }
}

// Scans a tag value up to its closing `]`.
fn take_value(bytes: BitArray) -> Result(#(BitArray, BitArray), Nil) {
  case value_len(bytes, 0) {
    Error(Nil) -> Error(Nil)
    Ok(#(len, rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> Error(Nil)
        Ok(tok) -> Ok(#(tok, rest))
      }
  }
}

fn value_len(bytes: BitArray, n: Int) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == byte_rbracket -> Ok(#(n, rest))
    <<_b, rest:bytes>> -> value_len(rest, n + 1)
    _ -> Error(Nil)
  }
}

// The bracket content before a `]` is either an offset time zone (starts with
// `+`/`-`) or an IANA-style time-zone-name.
fn zone_name_string(tok: BitArray) -> Result(String, Nil) {
  case tok {
    <<b, _:bytes>> ->
      case b == byte_plus || b == byte_minus {
        True ->
          case valid_numoffset(tok) {
            True -> bit_array.to_string(tok)
            False -> Error(Nil)
          }
        False ->
          case valid_zone_name(tok) {
            True -> bit_array.to_string(tok)
            False -> Error(Nil)
          }
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

fn values_string(tok: BitArray) -> Result(String, Nil) {
  case valid_values(tok) {
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

// suffix-key = key-initial *key-char
fn valid_key(tok: BitArray) -> Bool {
  case tok {
    <<b, rest:bytes>> ->
      case is_key_initial(b) {
        True -> valid_key_rest(rest)
        False -> False
      }
    _ -> False
  }
}

fn valid_key_rest(tok: BitArray) -> Bool {
  case tok {
    <<>> -> True
    <<b, rest:bytes>> ->
      case is_key_char(b) {
        True -> valid_key_rest(rest)
        False -> False
      }
    _ -> False
  }
}

// suffix-values = suffix-value *("-" suffix-value); suffix-value = 1*alphanum.
// Hyphens are only allowed *between* alphanum runs (no leading, trailing, or
// doubled `-`). `need_alnum` is True whenever the next byte must be alphanum.
fn valid_values(tok: BitArray) -> Bool {
  valid_values_loop(tok, True)
}

fn valid_values_loop(tok: BitArray, need_alnum: Bool) -> Bool {
  case tok {
    <<>> ->
      case need_alnum {
        True -> False
        False -> True
      }
    <<b, rest:bytes>> ->
      case is_alphanum(b) {
        True -> valid_values_loop(rest, False)
        False ->
          case b == byte_minus && need_alnum == False {
            True -> valid_values_loop(rest, True)
            False -> False
          }
      }
    _ -> False
  }
}

// time-zone-name = time-zone-part *("/" time-zone-part)
fn valid_zone_name(tok: BitArray) -> Bool {
  case parse_zone_part(tok) {
    Error(Nil) -> False
    Ok(rest) ->
      case rest {
        <<>> -> True
        <<b, rest:bytes>> ->
          case b == byte_slash {
            True -> valid_zone_name(rest)
            False -> False
          }
        _ -> False
      }
  }
}

// time-zone-part = time-zone-initial *time-zone-char, but not "." or "..".
// Consumes one part and returns the bytes after it (at a `/` or the end).
fn parse_zone_part(tok: BitArray) -> Result(BitArray, Nil) {
  case tok {
    <<b, rest:bytes>> ->
      case is_zone_initial(b) {
        True ->
          case b == byte_dot {
            True -> zone_part_chars(rest, 1, 1)
            False -> zone_part_chars(rest, 1, 0)
          }
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn zone_part_chars(
  tok: BitArray,
  len: Int,
  dots: Int,
) -> Result(BitArray, Nil) {
  case tok {
    <<b, rest:bytes>> ->
      case is_zone_char(b) {
        True ->
          case b == byte_dot {
            True -> zone_part_chars(rest, len + 1, dots + 1)
            False -> zone_part_chars(rest, len + 1, dots)
          }
        // Not a part char (a `/` or the end of the name); the part is done.
        False -> end_zone_part(tok, len, dots)
      }
    _ -> end_zone_part(tok, len, dots)
  }
}

// A part made up entirely of one or two dots ("." or "..") is forbidden;
// three-or-more dots ("...") is allowed by the ABNF.
fn end_zone_part(rest: BitArray, len: Int, dots: Int) -> Result(BitArray, Nil) {
  case len == dots && len <= 2 {
    True -> Error(Nil)
    False -> Ok(rest)
  }
}
