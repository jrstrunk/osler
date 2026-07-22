//// Step 1 of `docs/erlang-perf-playbook.md`: cost decomposition of the BEAM
//// ixdtf parse paths.
////
//// glychee's per-call harness overhead swamps the sub-100ns deltas we are
//// looking for, so this is a tight min-of-N loop instead: each variant runs
//// `iterations` times in a monomorphic recursive loop, the whole loop is
//// timed, and the minimum over `rounds` repetitions is reported. A `noop`
//// baseline measures the loop + closure-call overhead itself and is
//// subtracted from every other row.
////
//// Each rung of the ladder adds exactly one layer over the rung below, so
//// the deltas attribute cost to: BitArray conversion, the byte scan,
//// calendar validation, the Julian-day arithmetic, and each layer of
//// construction (raw tuple, `Ixdtf` record, `Timestamp`, public result).
////
//// Noise: sub-20ns deltas are at this harness's floor, and a few rows are
//// position-sensitive -- `L9` has been seen to swing 176-240ns depending on
//// where in the run it is measured, while `L8` sits at 196-212ns wherever it
//// goes. `L8'`/`L9'` re-measure those two later in the same run precisely so
//// that instability is visible rather than mistaken for a real difference.
//// Trust a delta only if it reproduces across runs.
////
//// Run with:
////   gleam run --target erlang -m bench_erl_decompose

@target(erlang)
import bench_native
@target(erlang)
import gleam/bit_array
@target(erlang)
import gleam/float
@target(erlang)
import gleam/int
@target(erlang)
import gleam/io
@target(erlang)
import gleam/list
@target(erlang)
import gleam/string
@target(erlang)
import gleam/time/duration
@target(erlang)
import gleam/time/timestamp.{type Timestamp}
@target(erlang)
import osler
@target(erlang)
import osler/internal.{
  byte_nine, byte_space, byte_t_lower, byte_t_upper, byte_underscore, byte_zero,
}

@target(erlang)
import osler/parser

@target(erlang)
const input = "2024-06-13T23:04:00.009+10:00"

// A suffixed input, which falls off the monolithic fast path entirely.
@target(erlang)
const input_suffix = "2024-06-13T23:04:00.009+10:00[Australia/Sydney][u-ca=hebrew]"

// --- The ladder -------------------------------------------------------------

// L0: loop + closure-call overhead only.
@target(erlang)
fn l0_noop(_str: String) -> Int {
  1
}

// L1: `String` -> `BitArray` conversion, which every Erlang entry point pays
// before it can match a single byte.
@target(erlang)
fn l1_from_string(str: String) -> Int {
  bit_array.byte_size(bit_array.from_string(str))
}

// L2: the full canonical scan -- monolithic 19-byte match, fraction, offset --
// reduced to a single Int. No tuple, no Option, no List, no Result.
@target(erlang)
fn l2_scan_int(str: String) -> Int {
  case scan(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) -> y + mo + d + h + mi + s + ns + off
  }
}

// L2b: identical to L2, but the fraction/offset continuations are same-module,
// so BEAM can thread the match context instead of building a sub-binary.
@target(erlang)
fn l2b_scan_int_local(str: String) -> Int {
  case scan_local(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) -> y + mo + d + h + mi + s + ns + off
  }
}

// L2c: one monolithic pattern covering the whole 29-byte string, no
// continuation calls at all -- the floor for this input shape.
@target(erlang)
fn l2c_scan_int_mono(str: String) -> Int {
  case scan_mono(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) -> y + mo + d + h + mi + s + ns + off
  }
}

// L2d: L2c, but the digit arithmetic goes through a tiny local function
// instead of being written inline.
@target(erlang)
fn l2d_scan_int_mono_dv(str: String) -> Int {
  case scan_mono_dv(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) -> y + mo + d + h + mi + s + ns + off
  }
}

// L3: L2 plus the calendar validation `parse_timestamp_slow` performs.
@target(erlang)
fn l3_scan_validate_int(str: String) -> Int {
  case scan(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) ->
      case valid_date(y, mo, d) && is_valid_time(h, mi, s) {
        False -> 0
        True -> y + mo + d + h + mi + s + ns + off
      }
  }
}

// L4: L3 plus the Julian-day arithmetic, still returning an Int -- so the
// delta over L3 is the arithmetic alone, with no `Timestamp` allocated.
@target(erlang)
fn l4_scan_seconds_int(str: String) -> Int {
  case scan(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) ->
      case valid_date(y, mo, d) && is_valid_time(h, mi, s) {
        False -> 0
        True -> seconds_since_epoch(y, mo, d, h, mi, s, off) + ns
      }
  }
}

// L3b: L3 with the month length compared inline per arm instead of via a
// `days_in_month` helper (and `is_leap_year` reached only for Feb 29).
@target(erlang)
fn l3b_scan_validate_inline(str: String) -> Int {
  case scan(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) ->
      case valid_date_inline(y, mo, d) && is_valid_time(h, mi, s) {
        False -> 0
        True -> y + mo + d + h + mi + s + ns + off
      }
  }
}

// L4b: L4 with the three integer divisions in the Julian formula replaced by
// a multiply-shift (`/100`) and two arithmetic shifts (`/4`), both verified
// exact over the whole `adjusted_year` domain 4799..14799.
@target(erlang)
fn l4b_scan_seconds_shift(str: String) -> Int {
  case scan(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) ->
      case valid_date(y, mo, d) && is_valid_time(h, mi, s) {
        False -> 0
        True -> seconds_since_epoch_shift(y, mo, d, h, mi, s, off) + ns
      }
  }
}

// L5: L4 plus building the real `Timestamp`. Delta over L4 = `Timestamp`
// construction (incl. `normalise`).
@target(erlang)
fn l5_scan_timestamp(str: String) -> Int {
  case scan(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(#(y, mo, d, h, mi, s, ns, off)) ->
      case valid_date(y, mo, d) && is_valid_time(h, mi, s) {
        False -> 0
        True ->
          discard_ts(timestamp.from_unix_seconds_and_nanoseconds(
            seconds_since_epoch(y, mo, d, h, mi, s, off),
            ns,
          ))
      }
  }
}

// L6: the shipped bare scanner. Same scan as L2, but returning the real
// `Ok(#(.., Option, List))` 10-tuple. Delta over L2 = construction cost of
// the raw result, i.e. the "is BEAM allocation-bound?" measurement.
@target(erlang)
fn l6_parse_ixdtf_fast(str: String) -> Int {
  case internal.parse_ixdtf_fast(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

// L7: `parser.parse_ixdtf` -- L6 plus the `Ixdtf` record wrap.
@target(erlang)
fn l7_parser_parse_ixdtf(str: String) -> Int {
  case parser.parse_ixdtf(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

// L8: the public `osler.parse_timestamp`.
@target(erlang)
fn l8_parse_timestamp(str: String) -> Int {
  case osler.parse_timestamp(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

// L9: the public `osler.parse_ixdtf`.
@target(erlang)
fn l9_parse_ixdtf(str: String) -> Int {
  case osler.parse_ixdtf(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

// OTP's own RFC 3339 parser. It returns a bare `Int` rather than a
// `Timestamp`, and rejects every non-RFC-3339 shape osler accepts -- see
// `bench_native` before reading anything into the comparison.
@target(erlang)
fn ln_native(str: String) -> Int {
  case bench_native.rfc3339_to_system_time(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

// Isolated: the offset `Duration` that `parse_ixdtf` allocates and
// `parse_timestamp` does not.
@target(erlang)
fn l10_duration_minutes(_str: String) -> Int {
  discard_dur(duration.minutes(600))
}

@target(erlang)
fn discard_ts(_t: Timestamp) -> Int {
  1
}

@target(erlang)
fn discard_dur(_d: duration.Duration) -> Int {
  1
}

// --- The scan, returning bare ints -----------------------------------------

// A byte-for-byte copy of `internal.parse_ixdtf_fast`'s canonical fast path,
// returning a flat 8-int tuple instead of the real 10-tuple with its `Option`
// and `List`. Non-canonical input returns `Error(Nil)` rather than falling
// through to the general parser, so this measures only the fast path.
//
// `local` selects whether the fraction/offset continuations are the *local*
// copies below or the cross-module `internal.*` ones: the BEAM compiler can
// only pass a live match context into a function in the same module, so a
// cross-module call forces a real heap sub-binary for `rest`. The two
// variants are separate top-level functions, never one parameterized by a
// flag (playbook rule 3).
@target(erlang)
fn scan(
  bytes: BitArray,
) -> Result(#(Int, Int, Int, Int, Int, Int, Int, Int), Nil) {
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
      case internal.parse_optional_fraction_ns(rest) {
        Error(Nil) -> Error(Nil)
        Ok(#(nanosecond, rest)) ->
          case internal.parse_offset_fast(rest) {
            Error(Nil) -> Error(Nil)
            Ok(#(offset_minutes, rest)) ->
              case rest {
                <<>> ->
                  Ok(#(
                    { y1 - 0x30 }
                      * 1000
                      + { y2 - 0x30 }
                      * 100
                      + { y3 - 0x30 }
                      * 10
                      + { y4 - 0x30 },
                    { mo1 - 0x30 } * 10 + { mo2 - 0x30 },
                    { d1 - 0x30 } * 10 + { d2 - 0x30 },
                    { h1 - 0x30 } * 10 + { h2 - 0x30 },
                    { mi1 - 0x30 } * 10 + { mi2 - 0x30 },
                    { s1 - 0x30 } * 10 + { s2 - 0x30 },
                    nanosecond,
                    offset_minutes,
                  ))
                _ -> Error(Nil)
              }
          }
      }

    _ -> Error(Nil)
  }
}

// The same scan, but continuing into same-module copies of the fraction and
// offset parsers.
@target(erlang)
fn scan_local(
  bytes: BitArray,
) -> Result(#(Int, Int, Int, Int, Int, Int, Int, Int), Nil) {
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
      case local_fraction_ns(rest) {
        Error(Nil) -> Error(Nil)
        Ok(#(nanosecond, rest)) ->
          case local_offset(rest) {
            Error(Nil) -> Error(Nil)
            Ok(#(offset_minutes, rest)) ->
              case rest {
                <<>> ->
                  Ok(#(
                    { y1 - 0x30 }
                      * 1000
                      + { y2 - 0x30 }
                      * 100
                      + { y3 - 0x30 }
                      * 10
                      + { y4 - 0x30 },
                    { mo1 - 0x30 } * 10 + { mo2 - 0x30 },
                    { d1 - 0x30 } * 10 + { d2 - 0x30 },
                    { h1 - 0x30 } * 10 + { h2 - 0x30 },
                    { mi1 - 0x30 } * 10 + { mi2 - 0x30 },
                    { s1 - 0x30 } * 10 + { s2 - 0x30 },
                    nanosecond,
                    offset_minutes,
                  ))
                _ -> Error(Nil)
              }
          }
      }

    _ -> Error(Nil)
  }
}

// A single monolithic pattern that swallows fraction and offset too, for the
// exact shape `YYYY-MM-DD?HH:MM:SS.mmm+HH:MM` -- playbook step 4, first item.
// Everything else returns `Error`; this is an upper bound on what extending
// the monolithic match could buy, not a shippable parser.
@target(erlang)
fn scan_mono(
  bytes: BitArray,
) -> Result(#(Int, Int, Int, Int, Int, Int, Int, Int), Nil) {
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
      0x2E,
      f1,
      f2,
      f3,
      osign,
      oh1,
      oh2,
      0x3A,
      om1,
      om2,
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
      && f1 >= byte_zero
      && f1 <= byte_nine
      && f2 >= byte_zero
      && f2 <= byte_nine
      && f3 >= byte_zero
      && f3 <= byte_nine
      && oh1 >= byte_zero
      && oh1 <= byte_nine
      && oh2 >= byte_zero
      && oh2 <= byte_nine
      && om1 >= byte_zero
      && om1 <= byte_nine
      && om2 >= byte_zero
      && om2 <= byte_nine
      && { osign == 0x2B || osign == 0x2D }
      && {
        sep == byte_t_upper
        || sep == byte_t_lower
        || sep == byte_underscore
        || sep == byte_space
      }
    -> {
      let offset =
        { { oh1 - 0x30 } * 10 + { oh2 - 0x30 } }
        * 60
        + { om1 - 0x30 }
        * 10
        + { om2 - 0x30 }
      Ok(
        #(
          { y1 - 0x30 }
            * 1000
            + { y2 - 0x30 }
            * 100
            + { y3 - 0x30 }
            * 10
            + { y4 - 0x30 },
          { mo1 - 0x30 } * 10 + { mo2 - 0x30 },
          { d1 - 0x30 } * 10 + { d2 - 0x30 },
          { h1 - 0x30 } * 10 + { h2 - 0x30 },
          { mi1 - 0x30 } * 10 + { mi2 - 0x30 },
          { s1 - 0x30 } * 10 + { s2 - 0x30 },
          { { f1 - 0x30 } * 100 + { f2 - 0x30 } * 10 + { f3 - 0x30 } }
            * 1_000_000,
          case osign == 0x2D {
            True -> -offset
            False -> offset
          },
        ),
      )
    }

    _ -> Error(Nil)
  }
}

// Identical to `scan_mono` except every `b - 0x30` goes through a tiny
// same-module function, as `internal`'s fast path does via `digit_value`.
// The L2c/L2d delta is the cost of 14 un-inlined local calls.
@target(erlang)
fn dv(b: Int) -> Int {
  b - 0x30
}

@target(erlang)
fn scan_mono_dv(
  bytes: BitArray,
) -> Result(#(Int, Int, Int, Int, Int, Int, Int, Int), Nil) {
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
      0x2E,
      f1,
      f2,
      f3,
      osign,
      oh1,
      oh2,
      0x3A,
      om1,
      om2,
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
      && f1 >= byte_zero
      && f1 <= byte_nine
      && f2 >= byte_zero
      && f2 <= byte_nine
      && f3 >= byte_zero
      && f3 <= byte_nine
      && oh1 >= byte_zero
      && oh1 <= byte_nine
      && oh2 >= byte_zero
      && oh2 <= byte_nine
      && om1 >= byte_zero
      && om1 <= byte_nine
      && om2 >= byte_zero
      && om2 <= byte_nine
      && { osign == 0x2B || osign == 0x2D }
      && {
        sep == byte_t_upper
        || sep == byte_t_lower
        || sep == byte_underscore
        || sep == byte_space
      }
    -> {
      let offset = { dv(oh1) * 10 + dv(oh2) } * 60 + dv(om1) * 10 + dv(om2)
      Ok(
        #(
          dv(y1) * 1000 + dv(y2) * 100 + dv(y3) * 10 + dv(y4),
          dv(mo1) * 10 + dv(mo2),
          dv(d1) * 10 + dv(d2),
          dv(h1) * 10 + dv(h2),
          dv(mi1) * 10 + dv(mi2),
          dv(s1) * 10 + dv(s2),
          { dv(f1) * 100 + dv(f2) * 10 + dv(f3) } * 1_000_000,
          case osign == 0x2D {
            True -> -offset
            False -> offset
          },
        ),
      )
    }

    _ -> Error(Nil)
  }
}

// --- Same-module copies of internal's fraction/offset continuations ---------

@target(erlang)
fn local_fraction_ns(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<0x2E, rest:bytes>> -> local_fraction_digits(rest, 0, 0)
    _ -> Ok(#(0, bytes))
  }
}

@target(erlang)
fn local_fraction_digits(
  bytes: BitArray,
  acc: Int,
  count: Int,
) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b >= byte_zero && b <= byte_nine && count < 9 ->
      local_fraction_digits(rest, acc * 10 + { b - 0x30 }, count + 1)
    <<b, rest:bytes>> if b >= byte_zero && b <= byte_nine ->
      Ok(#(acc, local_skip_digits(rest)))
    _ ->
      case count {
        0 -> Error(Nil)
        _ -> Ok(#(acc * local_pow10(9 - count), bytes))
      }
  }
}

@target(erlang)
fn local_skip_digits(bytes: BitArray) -> BitArray {
  case bytes {
    <<b, rest:bytes>> if b >= byte_zero && b <= byte_nine ->
      local_skip_digits(rest)
    _ -> bytes
  }
}

@target(erlang)
fn local_pow10(n: Int) -> Int {
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

@target(erlang)
fn local_offset(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == 0x5A || b == 0x7A -> Ok(#(0, rest))

    <<b, rest:bytes>> if b == 0x2B || b == 0x2D -> {
      let sign = case b == 0x2D {
        True -> -1
        False -> 1
      }
      case local_offset_digits(rest) {
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

@target(erlang)
fn local_offset_digits(bytes: BitArray) -> Result(#(Int, Int, BitArray), Nil) {
  case bytes {
    <<b1, rest:bytes>> if b1 >= byte_zero && b1 <= byte_nine ->
      case rest {
        <<b2, rest2:bytes>> if b2 >= byte_zero && b2 <= byte_nine -> {
          let hour = { b1 - 0x30 } * 10 + { b2 - 0x30 }
          case rest2 {
            <<0x3A, rest3:bytes>> ->
              case rest3 {
                <<m1, m2, rest4:bytes>>
                  if m1 >= byte_zero
                  && m1 <= byte_nine
                  && m2 >= byte_zero
                  && m2 <= byte_nine
                -> Ok(#(hour, { m1 - 0x30 } * 10 + { m2 - 0x30 }, rest4))
                _ -> Error(Nil)
              }

            <<b3, rest3:bytes>> if b3 >= byte_zero && b3 <= byte_nine ->
              case rest3 {
                <<b4, rest4:bytes>> if b4 >= byte_zero && b4 <= byte_nine ->
                  Ok(#(hour, { b3 - 0x30 } * 10 + { b4 - 0x30 }, rest4))
                _ -> Error(Nil)
              }

            _ -> Ok(#(hour, 0, rest2))
          }
        }

        _ -> Ok(#({ b1 - 0x30 }, 0, rest))
      }

    _ -> Error(Nil)
  }
}

// --- Zone-suffix micro-ladder ----------------------------------------------
//
// `[Australia/Sydney]` is the single most expensive thing in the whole parser.
// These variants take the bracket contents (`internal`'s private helpers are
// copied verbatim) and add one stage at a time, so the cost splits into: the
// terminator scan, the slice, the grammar validation, and the UTF-8 checked
// `to_string`. `_guarded` variants replace the body-position char-class
// function calls with the same tests written inline in `case` guards.

@target(erlang)
const zone_body = "Australia/Sydney]"

@target(erlang)
fn z1_token_len(str: String) -> Int {
  case c_token_len(bit_array.from_string(str), 0) {
    Error(Nil) -> 0
    Ok(#(len, _term, _rest)) -> len
  }
}

@target(erlang)
fn z2_token_slice(str: String) -> Int {
  let bytes = bit_array.from_string(str)
  case c_token_len(bytes, 0) {
    Error(Nil) -> 0
    Ok(#(len, _term, _rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> 0
        Ok(tok) -> bit_array.byte_size(tok)
      }
  }
}

@target(erlang)
fn z3_validate(str: String) -> Int {
  let bytes = bit_array.from_string(str)
  case c_token_len(bytes, 0) {
    Error(Nil) -> 0
    Ok(#(len, _term, _rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> 0
        Ok(tok) ->
          case c_valid_zone_name(tok) {
            True -> 1
            False -> 0
          }
      }
  }
}

@target(erlang)
fn z3b_validate_guarded(str: String) -> Int {
  let bytes = bit_array.from_string(str)
  case c_token_len(bytes, 0) {
    Error(Nil) -> 0
    Ok(#(len, _term, _rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> 0
        Ok(tok) ->
          case g_valid_zone_name(tok) {
            True -> 1
            False -> 0
          }
      }
  }
}

// The full shipped shape: scan, slice, validate, then UTF-8 `to_string`.
@target(erlang)
fn z4_full(str: String) -> Int {
  let bytes = bit_array.from_string(str)
  case c_token_len(bytes, 0) {
    Error(Nil) -> 0
    Ok(#(len, _term, _rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> 0
        Ok(tok) ->
          case c_valid_zone_name(tok) {
            False -> 0
            True ->
              case bit_array.to_string(tok) {
                Error(Nil) -> 0
                Ok(s) -> string.byte_size(s)
              }
          }
      }
  }
}

@target(erlang)
fn z4b_full_guarded(str: String) -> Int {
  let bytes = bit_array.from_string(str)
  case c_token_len(bytes, 0) {
    Error(Nil) -> 0
    Ok(#(len, _term, _rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> 0
        Ok(tok) ->
          case g_valid_zone_name(tok) {
            False -> 0
            True ->
              case bit_array.to_string(tok) {
                Error(Nil) -> 0
                Ok(s) -> string.byte_size(s)
              }
          }
      }
  }
}

// Fused: one guarded pass that validates *and* finds the terminator, so the
// bytes are walked once instead of twice, then a single slice + to_string.
@target(erlang)
fn z5_fused(str: String) -> Int {
  let bytes = bit_array.from_string(str)
  case g_zone_scan(bytes, 0, 0, 0, True) {
    Error(Nil) -> 0
    Ok(#(len, _rest)) ->
      case bit_array.slice(bytes, 0, len) {
        Error(Nil) -> 0
        Ok(tok) ->
          case bit_array.to_string(tok) {
            Error(Nil) -> 0
            Ok(s) -> string.byte_size(s)
          }
      }
  }
}

// --- copies of internal's private zone helpers (body-position char classes) --

@target(erlang)
fn c_token_len(bytes: BitArray, n: Int) -> Result(#(Int, Int, BitArray), Nil) {
  case bytes {
    <<b, rest:bytes>> if b == 0x3D || b == 0x5D -> Ok(#(n, b, rest))
    <<_b, rest:bytes>> -> c_token_len(rest, n + 1)
    _ -> Error(Nil)
  }
}

@target(erlang)
fn c_is_alpha(b: Int) -> Bool {
  { b >= 0x41 && b <= 0x5A } || { b >= 0x61 && b <= 0x7A }
}

@target(erlang)
fn c_is_digit(b: Int) -> Bool {
  b >= byte_zero && b <= byte_nine
}

@target(erlang)
fn c_is_zone_initial(b: Int) -> Bool {
  c_is_alpha(b) || b == 0x2E || b == 0x5F
}

@target(erlang)
fn c_is_zone_char(b: Int) -> Bool {
  c_is_zone_initial(b) || c_is_digit(b) || b == 0x2D || b == 0x2B
}

@target(erlang)
fn c_valid_zone_name(tok: BitArray) -> Bool {
  case c_parse_zone_part(tok) {
    Error(Nil) -> False
    Ok(rest) ->
      case rest {
        <<>> -> True
        <<b, rest:bytes>> ->
          case b == 0x2F {
            True -> c_valid_zone_name(rest)
            False -> False
          }
        _ -> False
      }
  }
}

@target(erlang)
fn c_parse_zone_part(tok: BitArray) -> Result(BitArray, Nil) {
  case tok {
    <<b, rest:bytes>> ->
      case c_is_zone_initial(b) {
        True ->
          case b == 0x2E {
            True -> c_zone_part_chars(rest, 1, 1)
            False -> c_zone_part_chars(rest, 1, 0)
          }
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

@target(erlang)
fn c_zone_part_chars(
  tok: BitArray,
  len: Int,
  dots: Int,
) -> Result(BitArray, Nil) {
  case tok {
    <<b, rest:bytes>> ->
      case c_is_zone_char(b) {
        True ->
          case b == 0x2E {
            True -> c_zone_part_chars(rest, len + 1, dots + 1)
            False -> c_zone_part_chars(rest, len + 1, dots)
          }
        False -> c_end_zone_part(tok, len, dots)
      }
    _ -> c_end_zone_part(tok, len, dots)
  }
}

@target(erlang)
fn c_end_zone_part(
  rest: BitArray,
  len: Int,
  dots: Int,
) -> Result(BitArray, Nil) {
  case len == dots && len <= 2 {
    True -> Error(Nil)
    False -> Ok(rest)
  }
}

// --- the same grammar, with char classes written inline in guards -----------

@target(erlang)
fn g_valid_zone_name(tok: BitArray) -> Bool {
  case g_parse_zone_part(tok) {
    Error(Nil) -> False
    Ok(rest) ->
      case rest {
        <<>> -> True
        <<0x2F, rest:bytes>> -> g_valid_zone_name(rest)
        _ -> False
      }
  }
}

@target(erlang)
fn g_parse_zone_part(tok: BitArray) -> Result(BitArray, Nil) {
  case tok {
    <<0x2E, rest:bytes>> -> g_zone_part_chars(rest, 1, 1)
    <<b, rest:bytes>>
      if { b >= 0x41 && b <= 0x5A } || { b >= 0x61 && b <= 0x7A } || b == 0x5F
    -> g_zone_part_chars(rest, 1, 0)
    _ -> Error(Nil)
  }
}

@target(erlang)
fn g_zone_part_chars(
  tok: BitArray,
  len: Int,
  dots: Int,
) -> Result(BitArray, Nil) {
  case tok {
    <<0x2E, rest:bytes>> -> g_zone_part_chars(rest, len + 1, dots + 1)
    <<b, rest:bytes>>
      if { b >= 0x41 && b <= 0x5A }
      || { b >= 0x61 && b <= 0x7A }
      || { b >= byte_zero && b <= byte_nine }
      || b == 0x5F
      || b == 0x2D
      || b == 0x2B
    -> g_zone_part_chars(rest, len + 1, dots)
    _ -> c_end_zone_part(tok, len, dots)
  }
}

// One pass: validate the time-zone-name grammar *and* locate the closing `]`,
// returning the token length. `len`/`dots` track the current part; `initial`
// marks that the next byte starts a part.
@target(erlang)
fn g_zone_scan(
  bytes: BitArray,
  n: Int,
  len: Int,
  dots: Int,
  initial: Bool,
) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<0x5D, rest:bytes>> ->
      case initial || { len == dots && len <= 2 } {
        True -> Error(Nil)
        False -> Ok(#(n, rest))
      }
    <<0x2F, rest:bytes>> ->
      case initial || { len == dots && len <= 2 } {
        True -> Error(Nil)
        False -> g_zone_scan(rest, n + 1, 0, 0, True)
      }
    <<0x2E, rest:bytes>> -> g_zone_scan(rest, n + 1, len + 1, dots + 1, False)
    <<b, rest:bytes>>
      if { b >= 0x41 && b <= 0x5A } || { b >= 0x61 && b <= 0x7A } || b == 0x5F
    -> g_zone_scan(rest, n + 1, len + 1, dots, False)
    // Digits, `-` and `+` are time-zone-chars but not time-zone-initials.
    <<b, rest:bytes>>
      if !initial
      && { { b >= byte_zero && b <= byte_nine } || b == 0x2D || b == 0x2B }
    -> g_zone_scan(rest, n + 1, len + 1, dots, False)
    _ -> Error(Nil)
  }
}

// --- Copies of osler.gleam's private validation/construction ----------------

@target(erlang)
fn valid_date(year: Int, month: Int, day: Int) -> Bool {
  day >= 1 && day <= days_in_month(month, year)
}

@target(erlang)
fn days_in_month(month: Int, year: Int) -> Int {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    4 | 6 | 9 | 11 -> 30
    2 ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
    _ -> 0
  }
}

@target(erlang)
fn valid_date_inline(year: Int, month: Int, day: Int) -> Bool {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> day >= 1 && day <= 31
    4 | 6 | 9 | 11 -> day >= 1 && day <= 30
    2 -> { day >= 1 && day <= 28 } || { day == 29 && is_leap_year(year) }
    _ -> False
  }
}

@target(erlang)
fn seconds_since_epoch_shift(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
  offset_minutes: Int,
) -> Int {
  let adjustment = case month <= 2 {
    True -> 1
    False -> 0
  }
  let adjusted_year = year + 4800 - adjustment
  let adjusted_month = month + { 12 * adjustment } - 3
  let ay_div_100 = int.bitwise_shift_right(adjusted_year * 5243, 19)
  let julian_day =
    day
    + days_before_month(adjusted_month)
    + { 365 * adjusted_year }
    + int.bitwise_shift_right(adjusted_year, 2)
    - ay_div_100
    + int.bitwise_shift_right(ay_div_100, 2)
    - 32_045
  { julian_day * 86_400 }
  + { hour * 3600 }
  + { minute * 60 }
  + second
  - 210_866_803_200
  - { offset_minutes * 60 }
}

@target(erlang)
fn is_leap_year(year: Int) -> Bool {
  { year % 4 == 0 && year % 100 != 0 } || year % 400 == 0
}

@target(erlang)
fn is_valid_time(hour: Int, minute: Int, second: Int) -> Bool {
  {
    hour >= 0
    && hour <= 23
    && minute >= 0
    && minute <= 59
    && second >= 0
    && second <= 59
  }
  || { hour == 24 && minute == 0 && second == 0 }
  || { hour == 23 && minute == 59 && second == 60 }
}

@target(erlang)
fn seconds_since_epoch(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
  offset_minutes: Int,
) -> Int {
  let adjustment = case month <= 2 {
    True -> 1
    False -> 0
  }
  let adjusted_year = year + 4800 - adjustment
  let adjusted_month = month + { 12 * adjustment } - 3
  let ay_div_100 = adjusted_year / 100
  let julian_day =
    day
    + days_before_month(adjusted_month)
    + { 365 * adjusted_year }
    + { adjusted_year / 4 }
    - ay_div_100
    + { ay_div_100 / 4 }
    - 32_045
  { julian_day * 86_400 }
  + { hour * 3600 }
  + { minute * 60 }
  + second
  - 210_866_803_200
  - { offset_minutes * 60 }
}

@target(erlang)
fn days_before_month(am: Int) -> Int {
  case am {
    0 -> 0
    1 -> 31
    2 -> 61
    3 -> 92
    4 -> 122
    5 -> 153
    6 -> 184
    7 -> 214
    8 -> 245
    9 -> 275
    10 -> 306
    _ -> 337
  }
}

// --- Harness ----------------------------------------------------------------

@target(erlang)
const iterations = 200_000

@target(erlang)
const rounds = 25

@target(erlang)
fn loop(f: fn(String) -> Int, str: String, n: Int, acc: Int) -> Int {
  case n {
    0 -> acc
    _ -> loop(f, str, n - 1, acc + f(str))
  }
}

@target(erlang)
/// Nanoseconds per op, minimum over `rounds` timed runs of `iterations` calls.
fn measure(f: fn(String) -> Int, str: String) -> Float {
  measure_loop(f, str, rounds, 1.0e18)
}

@target(erlang)
fn measure_loop(
  f: fn(String) -> Int,
  str: String,
  remaining: Int,
  best: Float,
) -> Float {
  case remaining {
    0 -> best
    _ -> {
      let start = timestamp.system_time()
      let _ = loop(f, str, iterations, 0)
      let elapsed = timestamp.difference(start, timestamp.system_time())
      let ns = duration.to_seconds(elapsed) *. 1.0e9 /. int.to_float(iterations)
      measure_loop(f, str, remaining - 1, float.min(best, ns))
    }
  }
}

@target(erlang)
fn row(label: String, ns: Float, baseline: Float) -> Nil {
  let net = ns -. baseline
  io.println(
    string.pad_end(label, 46, " ")
    <> string.pad_start(float.to_string(float.to_precision(net, 1)), 9, " ")
    <> " ns",
  )
}

@target(erlang)
pub fn main() {
  // Sanity: a variant that fast-fails would look wonderfully quick and mean
  // nothing, so print every variant's result before timing anything. Every
  // number below must be non-zero.
  io.println(
    "sanity (all must be non-zero): "
    <> string.join(
      list.map(
        [
          l1_from_string(input),
          l2_scan_int(input),
          l2b_scan_int_local(input),
          l2c_scan_int_mono(input),
          l2d_scan_int_mono_dv(input),
          l3_scan_validate_int(input),
          l3b_scan_validate_inline(input),
          l4_scan_seconds_int(input),
          l4b_scan_seconds_shift(input),
          l5_scan_timestamp(input),
          l6_parse_ixdtf_fast(input),
          l7_parser_parse_ixdtf(input),
          l8_parse_timestamp(input),
          l9_parse_ixdtf(input),
          ln_native(input),
          l6_parse_ixdtf_fast(input_suffix),
          l6_parse_ixdtf_fast(general_no_suffix),
          l6_parse_ixdtf_fast(general_zone),
          l6_parse_ixdtf_fast(general_tag),
          l6_parse_ixdtf_fast(canonical_zone),
          l6_parse_ixdtf_fast(canonical_2tags),
          z1_token_len(zone_body),
          z2_token_slice(zone_body),
          z3_validate(zone_body),
          z3b_validate_guarded(zone_body),
          z4_full(zone_body),
          z4b_full_guarded(zone_body),
          z5_fused(zone_body),
        ],
        int.to_string,
      ),
      " ",
    ),
  )

  // Warm the code paths before the first timed round.
  let _ = loop(l9_parse_ixdtf, input, 20_000, 0)

  let base = measure(l0_noop, input)
  io.println(
    "loop+closure baseline: "
    <> float.to_string(float.to_precision(base, 1))
    <> " ns/op (subtracted from every row below)",
  )
  io.println("")
  io.println("canonical, suffix-free: " <> input)
  io.println(string.repeat("-", 58))

  let rows = [
    #("L1  bit_array.from_string", measure(l1_from_string, input)),
    #("L2  + scan -> Int (cross-module conts)", measure(l2_scan_int, input)),
    #(
      "L2b + scan -> Int (same-module conts)",
      measure(l2b_scan_int_local, input),
    ),
    #(
      "L2c + scan -> Int (one monolithic match)",
      measure(l2c_scan_int_mono, input),
    ),
    #(
      "L2d + scan -> Int (mono, digit_value calls)",
      measure(l2d_scan_int_mono_dv, input),
    ),
    #("L3  + validate -> Int", measure(l3_scan_validate_int, input)),
    #(
      "L3b + validate, inline month length",
      measure(l3b_scan_validate_inline, input),
    ),
    #("L4  + seconds_since_epoch -> Int", measure(l4_scan_seconds_int, input)),
    #(
      "L4b + seconds, shifts not divisions",
      measure(l4b_scan_seconds_shift, input),
    ),
    #("L5  + build Timestamp", measure(l5_scan_timestamp, input)),
    #(
      "L6  internal.parse_ixdtf_fast (10-tuple)",
      measure(l6_parse_ixdtf_fast, input),
    ),
    #(
      "L7  parser.parse_ixdtf (Ixdtf record)",
      measure(l7_parser_parse_ixdtf, input),
    ),
    #("L8  osler.parse_timestamp", measure(l8_parse_timestamp, input)),
    #("L9  osler.parse_ixdtf", measure(l9_parse_ixdtf, input)),
    #(
      "L8' osler.parse_timestamp (re-measured)",
      measure(l8_parse_timestamp, input),
    ),
    #("L9' osler.parse_ixdtf (re-measured)", measure(l9_parse_ixdtf, input)),
    #("N   calendar:rfc3339_to_system_time (OTP)", measure(ln_native, input)),
    #("--  duration.minutes alone", measure(l10_duration_minutes, input)),
  ]
  list.each(rows, fn(r) { row(r.0, r.1, base) })

  io.println("")
  io.println("the general (non-canonical / suffixed) path")
  io.println(string.repeat("-", 58))

  // Each input below adds one more piece of general-path work than the one
  // above it, so the deltas isolate field-by-field date/time/offset parsing,
  // the empty-suffix check, the zone group, and each tag group.
  let grows = [
    #("G0  canonical, fast path", measure(l6_parse_ixdtf_fast, input)),
    #(
      "G1  '/' delims -> general, no suffix",
      measure(l6_parse_ixdtf_fast, general_no_suffix),
    ),
    #("G2  general + [zone]", measure(l6_parse_ixdtf_fast, general_zone)),
    #("G3  general + [zone][tag]", measure(l6_parse_ixdtf_fast, general_tag)),
    #("G4  canonical + [zone]", measure(l6_parse_ixdtf_fast, canonical_zone)),
    #(
      "G5  canonical + [zone][tag]  (= L6 suffix)",
      measure(l6_parse_ixdtf_fast, input_suffix),
    ),
    #(
      "G6  canonical + [zone][tag][tag]",
      measure(l6_parse_ixdtf_fast, canonical_2tags),
    ),
    // OTP's parser accepts neither of these, so these two rows are how fast
    // it *rejects*, not a comparable parse. They are here to make that
    // explicit rather than to be read as a win.
    #(
      "N   OTP native on G1 (REJECTS, fail time)",
      measure(ln_native, general_no_suffix),
    ),
    #(
      "N   OTP native on G5 (REJECTS, fail time)",
      measure(ln_native, input_suffix),
    ),
    #(
      "--  parser.parse_ixdtf on G5",
      measure(l7_parser_parse_ixdtf, input_suffix),
    ),
    #(
      "--  osler.parse_timestamp on G5",
      measure(l8_parse_timestamp, input_suffix),
    ),
    #("--  osler.parse_ixdtf on G5", measure(l9_parse_ixdtf, input_suffix)),
  ]
  list.each(grows, fn(r) { row(r.0, r.1, base) })

  io.println("")
  io.println("inside the zone group: " <> zone_body)
  io.println(string.repeat("-", 58))

  let zrows = [
    #("Z1  token_len (scan to ']')", measure(z1_token_len, zone_body)),
    #("Z2  + bit_array.slice", measure(z2_token_slice, zone_body)),
    #("Z3  + valid_zone_name (body calls)", measure(z3_validate, zone_body)),
    #(
      "Z3b + valid_zone_name (guards)",
      measure(z3b_validate_guarded, zone_body),
    ),
    #("Z4  + to_string  == shipped shape", measure(z4_full, zone_body)),
    #("Z4b + to_string, guarded", measure(z4b_full_guarded, zone_body)),
    #("Z5  fused one-pass guarded scan", measure(z5_fused, zone_body)),
  ]
  list.each(zrows, fn(r) { row(r.0, r.1, base) })
}

@target(erlang)
const general_no_suffix = "2024/06/13T23:04:00.009+10:00"

@target(erlang)
const general_zone = "2024/06/13T23:04:00.009+10:00[Australia/Sydney]"

@target(erlang)
const general_tag = "2024/06/13T23:04:00.009+10:00[Australia/Sydney][u-ca=hebrew]"

@target(erlang)
const canonical_zone = "2024-06-13T23:04:00.009+10:00[Australia/Sydney]"

@target(erlang)
const canonical_2tags = "2024-06-13T23:04:00.009+10:00[Australia/Sydney][u-ca=hebrew][x-foo=bar]"
