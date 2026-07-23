//// Erlang-target regression benchmark for osler's parsers.
////
//// glychee's per-call overhead swamps the deltas that matter here, so this is
//// a tight min-of-N loop: each row runs `iterations` times in a recursive
//// loop, the whole loop is timed, and the minimum over `rounds` repetitions is
//// reported with the loop's own overhead subtracted. `parse_any` is
//// microseconds rather than nanoseconds per call, so it gets its own smaller
//// iteration count.
////
//// Every row's result is printed before anything is timed. A variant that
//// fast-fails looks wonderfully quick and means nothing, so the sanity line is
//// load-bearing: all of its numbers must be non-zero.
////
//// Sub-20ns deltas are at this harness's floor and a few rows are sensitive to
//// where in the run they are measured. Trust a delta only if it reproduces
//// across runs.
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
import gleam/option.{None}
@target(erlang)
import gleam/string
@target(erlang)
import gleam/time/duration
@target(erlang)
import gleam/time/timestamp
@target(erlang)
import osler
@target(erlang)
import osler/parser.{
  DateTimeSeparator, Day2, Hour24Padded, IsoDate, IsoNaiveDateTime, IsoOffset,
  IsoTime, Literal, Milli, Minute2, Month2, OffsetColon, Second2, Year4,
}

// --- inputs -----------------------------------------------------------------

@target(erlang)
const canonical = "2024-06-13T23:04:00.009+10:00"

@target(erlang)
const general_no_suffix = "2024/06/13T23:04:00.009+10:00"

@target(erlang)
const canonical_zone = "2024-06-13T23:04:00.009+10:00[Australia/Sydney]"

@target(erlang)
const canonical_zone_tag = "2024-06-13T23:04:00.009+10:00[Australia/Sydney][u-ca=hebrew]"

@target(erlang)
const any_prose = "Meeting on 2024/06/22 at 1:42 PM in -04:00"

@target(erlang)
const any_iso = "2024-06-13T13:42:11.314+10:00"

@target(erlang)
const any_none = "just some words with nothing in them at all"

// --- directive lists, built once as they would be in real use ---------------

@target(erlang)
const compound = [IsoDate, DateTimeSeparator, IsoTime, IsoOffset]

@target(erlang)
const naive = [IsoNaiveDateTime, IsoOffset]

@target(erlang)
const fine = [
  Year4,
  Literal("-"),
  Month2,
  Literal("-"),
  Day2,
  Literal("T"),
  Hour24Padded,
  Literal(":"),
  Minute2,
  Literal(":"),
  Second2,
  Literal("."),
  Milli,
  OffsetColon,
]

// --- the rows ---------------------------------------------------------------

@target(erlang)
fn bare(str: String) -> Int {
  case parser.parse_ixdtf_raw(bit_array.from_string(str)) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

@target(erlang)
fn parts(str: String) -> Int {
  case parser.parse_ixdtf(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

@target(erlang)
fn instant(str: String) -> Int {
  case osler.parse_timestamp(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

@target(erlang)
fn full(str: String) -> Int {
  case osler.parse_ixdtf(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

// OTP's built-in. It returns a bare `Int` and rejects every shape osler
// accepts beyond RFC 3339 -- see `bench_native` before reading anything into
// the comparison.
@target(erlang)
fn native(str: String) -> Int {
  case bench_native.rfc3339_to_system_time(str) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

@target(erlang)
fn directives(str: String, ds: List(parser.Directive)) -> Int {
  case parser.parse(str, ds) {
    Error(Nil) -> 0
    Ok(_) -> 1
  }
}

@target(erlang)
fn any(str: String) -> Int {
  case osler.parse_any(str) {
    #(None, None, None) -> 1
    _ -> 2
  }
}

@target(erlang)
pub fn main() {
  io.println(
    "sanity (all must be non-zero): "
    <> string.join(
      list.map(
        [
          bare(canonical),
          parts(canonical),
          instant(canonical),
          full(canonical),
          native(canonical),
          bare(general_no_suffix),
          bare(canonical_zone),
          bare(canonical_zone_tag),
          directives(canonical, compound),
          directives(canonical, naive),
          directives(canonical, fine),
          any(any_prose),
          any(any_none),
        ],
        int.to_string,
      ),
      " ",
    ),
  )

  let base = measure(fn(_) { 1 }, canonical)
  io.println(
    "loop baseline: "
    <> float.to_string(float.to_precision(base, 1))
    <> " ns/op (subtracted from every row)\n",
  )

  section("RFC 9557, canonical: " <> canonical)
  row("parser.parse_ixdtf_raw (raw ints)", measure(bare, canonical), base)
  row("parser.parse_ixdtf (Ixdtf)", measure(parts, canonical), base)
  row("osler.parse_timestamp", measure(instant, canonical), base)
  row("osler.parse_ixdtf", measure(full, canonical), base)
  row("calendar:rfc3339_to_system_time (OTP)", measure(native, canonical), base)

  // Re-measured at a different point in the run. Some rows are sensitive to
  // where they are measured -- `osler.parse_ixdtf` has been seen to differ by
  // ~30ns between positions with identical code -- so this pair is here to
  // make that visible rather than let it read as a regression.
  row("osler.parse_ixdtf (re-measured)", measure(full, canonical), base)
  row("osler.parse_timestamp (re-measured)", measure(instant, canonical), base)

  section("other shapes, via parser.parse_ixdtf")
  row("'/' delimiters, no suffix", measure(parts, general_no_suffix), base)
  row("canonical + [zone]", measure(parts, canonical_zone), base)
  row("canonical + [zone][tag]", measure(parts, canonical_zone_tag), base)

  section("directive engine, canonical input")
  row(
    "[IsoDate, T, IsoTime, IsoOffset]",
    measure(fn(s) { directives(s, compound) }, canonical),
    base,
  )
  row(
    "[IsoNaiveDateTime, IsoOffset]",
    measure(fn(s) { directives(s, naive) }, canonical),
    base,
  )
  row(
    "fine-grained, 14 directives",
    measure(fn(s) { directives(s, fine) }, canonical),
    base,
  )

  section("parse_any (microseconds -- note the scale)")
  row("date + time + offset in prose", measure_slow(any, any_prose), base)
  row("ISO timestamp", measure_slow(any, any_iso), base)
  row("no match (worst case)", measure_slow(any, any_none), base)
}

// --- harness ----------------------------------------------------------------

@target(erlang)
const iterations = 200_000

@target(erlang)
const rounds = 25

@target(erlang)
const slow_iterations = 20_000

@target(erlang)
const slow_rounds = 9

@target(erlang)
fn section(title: String) -> Nil {
  io.println(title)
  io.println(string.repeat("-", 58))
}

@target(erlang)
fn row(label: String, ns: Float, baseline: Float) -> Nil {
  io.println(
    string.pad_end(label, 42, " ")
    <> string.pad_start(
      float.to_string(float.to_precision(ns -. baseline, 1)),
      10,
      " ",
    )
    <> " ns",
  )
}

@target(erlang)
fn measure(f: fn(String) -> Int, str: String) -> Float {
  best(f, str, iterations, rounds, 1.0e18)
}

@target(erlang)
fn measure_slow(f: fn(String) -> Int, str: String) -> Float {
  best(f, str, slow_iterations, slow_rounds, 1.0e18)
}

@target(erlang)
fn best(
  f: fn(String) -> Int,
  str: String,
  iters: Int,
  remaining: Int,
  acc: Float,
) -> Float {
  case remaining {
    0 -> acc
    _ -> {
      let start = timestamp.system_time()
      let _ = loop(f, str, iters, 0)
      let elapsed = timestamp.difference(start, timestamp.system_time())
      let ns = duration.to_seconds(elapsed) *. 1.0e9 /. int.to_float(iters)
      best(f, str, iters, remaining - 1, float.min(acc, ns))
    }
  }
}

// `acc` is threaded out so the calls cannot be optimised away.
@target(erlang)
fn loop(f: fn(String) -> Int, str: String, n: Int, acc: Int) -> Int {
  case n {
    0 -> acc
    _ -> loop(f, str, n - 1, acc + f(str))
  }
}
