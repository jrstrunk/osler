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
//// through Gleam's `BitArray` -- mirroring these per-field *primitives*
//// byte-for-byte in hand-written Erlang made no measurable difference (BEAM
//// already compiles `BitArray` matching to near-native binary instructions),
//// but Gleam's JS `BitArray` is a heavy general-purpose class, so bypassing
//// it on JS is worth ~4-5x.
////
//// What *does* help on BEAM is structural, not byte-level. `parse_ixdtf_fast`
//// matches the canonical date-time in a single binary pattern rather than one
//// field at a time, and the common fraction/offset tails are matched in that
//// same `case` rather than passed to a continuation -- so the VM builds no
//// intermediate match contexts, sub-binaries, or `#(value, rest)` tuples for
//// the whole string. That is worth ~8x on the canonical shape. The RFC 9557
//// suffix scanners (`scan_group`, `scan_value`) apply the same idea: one pass
//// that locates a token *and* decides its grammar, with the char classes
//// written inline in pattern guards instead of called in body position.
////
//// Both are the BEAM analogue of the JS FFI's inlining win; they come from
//// collapsing per-field work, not from how bytes are read. Note the inverse
//// does not hold for cheap *integer* helpers: `digit_value` and friends are
//// same-module calls on `Int`s and cost nothing measurable. It is specifically
//// handing a `BitArray` across a function boundary that pays. See
//// `docs/erlang-perf-playbook.md` and `test/bench_erl_decompose.gleam`.

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

/// Parses exactly `n` digits into a single int, failing if fewer than `n`
/// digits are present. Used by the fixed-width format directives (a 4-digit
/// year, a 3-digit `SSS`, a 9-digit `Nano`, etc).
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
//
// Gleam guards cannot call functions, so the char classes below are *not*
// factored into `is_alpha`/`is_zone_char`-style predicates: each one is
// written out inline in the pattern's `if`. That reads worse and matters a
// lot -- a guard compiles to inline BEAM comparisons, while the same test in
// branch-body position is a real call, and these run once per byte of the
// suffix. The classes, for reference:
//
//   time-zone-initial = ALPHA / "." / "_"
//   time-zone-char    = time-zone-initial / DIGIT / "-" / "+"
//   key-initial       = lcalpha / "_"
//   key-char          = key-initial / DIGIT / "-"
//   suffix-value      = 1*alphanum
//
// `is_digit` survives because `valid_numoffset` tests a fixed six bytes in
// body position, where the call overhead is bounded and the clarity is worth
// more than six inline comparisons.

fn is_digit(b: Int) -> Bool {
  b >= byte_zero && b <= byte_nine
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
  // Fast path for the canonical, padded, dash/colon-delimited, suffix-free
  // shape `YYYY-MM-DD?HH:MM:SS[.frac](offset)`. The fixed 19-byte prefix is
  // matched in ONE binary pattern, so BEAM builds no intermediate match
  // contexts, sub-binaries, or `#(value, rest)` tuples for it -- the same
  // "collapse the per-field allocations" win the JS FFI path gets from
  // inlining. Anything that doesn't fit (compact forms, 1-digit fields, other
  // delimiters, or any RFC 9557 suffix) falls straight through to the fully
  // general parser below, so behavior is unchanged.
  // The `0x2D` (`-`) and `0x3A` (`:`) are literal byte patterns, not the named
  // constants: a bare identifier in a bit-array pattern *binds* rather than
  // *matches*, so the delimiters must be spelled as literals to be enforced.
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
      // The tail (fraction + offset) is matched in this same `case`, not
      // handed to `parse_optional_fraction_ns` / `parse_offset_fast`. Passing
      // `rest` to a function materialises a heap sub-binary and makes the
      // callee re-enter `bs_start_match`; keeping the match inline lets the
      // compiler carry one live match context across the whole string. Those
      // two calls measured ~108ns of the 170ns bare parse -- see
      // `test/bench_erl_decompose.gleam`. Only the common shapes are inlined
      // (`Z`/`z`/`(+-)HH:MM`, with no fraction or a 3/6/9-digit one); every
      // other canonical shape falls to `ixdtf_tail`, which is exactly the
      // cascade that used to be here, so nothing gets slower.
      case rest {
        <<0x5A>> ->
          mk(y1, y2, y3, y4, mo1, mo2, d1, d2, h1, h2, mi1, mi2, s1, s2, 0, 0)
        <<0x7A>> ->
          mk(y1, y2, y3, y4, mo1, mo2, d1, d2, h1, h2, mi1, mi2, s1, s2, 0, 0)
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
              mk(
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
              mk(
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
              mk(
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
                  mk(
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
              mk(
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
              mk(
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
                  mk(
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
              mk(
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
              mk(
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
                  mk(
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

// The pre-existing fraction/offset cascade, kept for the canonical shapes the
// patterns above do not inline (`(+-)HHMM`, `(+-)HH`, 1/2/4/5/7/8-digit
// fractions, and anything with an RFC 9557 suffix).
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
      case parse_offset_fast(rest) {
        Error(Nil) -> parse_ixdtf_general(bytes)
        Ok(#(offset_minutes, rest)) ->
          case rest {
            // Empty tail -> no suffix: build the result directly.
            <<>> ->
              mk(
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

            // A suffix is present. This used to hand the *whole* string to
            // `parse_ixdtf_general`, which re-parsed the date, time, fraction
            // and offset from scratch -- work already done twice over by the
            // time we get here. It is provably redundant: on a 19-byte
            // canonical prefix, `parse_date_fast` and `parse_time_fast` read
            // the same fields the monolithic pattern matched (a 2-digit field
            // is what `parse_1_or_2_digits` takes greedily), and they finish
            // by calling the very `parse_optional_fraction_ns` and
            // `parse_offset_fast` that just succeeded above. So the ints are
            // identical and only the suffix is left to parse -- worth ~400ns
            // on the most ordinary IXDTF shape there is, `<canonical>[Zone]`.
            _ ->
              case parse_suffix(rest) {
                Error(Nil) -> Error(Nil)
                Ok(#(zone, tags)) ->
                  mk_suffix(
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

// Builds the fast-path result from the raw digit bytes. Every argument is an
// `Int`, so this stays a free local call -- a same-module function taking only
// integers costs nothing measurable, unlike one taking a `BitArray`.
fn mk(
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
// That last flag is why the scan and the validation are one pass rather than
// two: the group's bytes used to be walked once to find the terminator and
// again to validate, and the validating walk classified each byte through
// `is_zone_char` -> `is_zone_initial` -> `is_alpha`, three nested calls in
// *body* position. Guards compile to inline BEAM instructions and cost
// nothing; body calls do not. Together the fusion and the guards took this
// stage from ~567ns to ~310ns on `[Australia/Sydney]` -- see
// `test/bench_erl_decompose.gleam`.
//
// The caller only reads `zone_ok` when the terminator is `]` (a tag key is
// validated separately by `valid_key`), so tracking it costs one extra
// register on a path that has to walk the bytes anyway.
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

// As `mk`, but for a fast-path prefix that carried an RFC 9557 suffix.
fn mk_suffix(
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
