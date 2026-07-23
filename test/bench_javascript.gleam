//// JavaScript-target microbenchmark for the directive engine, mirroring
//// `bench_memory` (glychee only runs on Erlang). It times each parser
//// over many iterations on the JS target -- where `osler_ffi.mjs`'s charCode
//// scanning is what runs -- and reports min / median / max ns/op across
//// several rounds (each round is one full pass of `iterations` calls).
////
//// Compares, on one RFC 3339 input:
////
//// - `parser.parse` with a compound-ISO directive list and a fine-grained one;
//// - `parser.parse_ixdtf` / `osler.parse_ixdtf` (dedicated fixed grammar);
//// - `timestamp.parse_rfc3339` (gleam_time);
//// - `Date.parse` (the JS engine builtin).
////
//// Run with:
////   gleam run -m bench_javascript --target javascript

@target(javascript)
import gleam/float
@target(javascript)
import gleam/int
@target(javascript)
import gleam/io
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string
@target(javascript)
import gleam/time/timestamp
@target(javascript)
import osler
@target(javascript)
import osler/parser.{
  DateTimeSeparator, Day2, Hour24Padded, IsoDate, IsoNaiveDateTime, IsoOffset,
  IsoTime, Literal, Milli, Minute2, Month2, OffsetColon, Second2, Year4,
}

@target(javascript)
@external(javascript, "./bench_js_ffi.mjs", "now")
fn now() -> Float

@target(javascript)
@external(javascript, "./bench_js_ffi.mjs", "dateParse")
fn date_parse(str: String) -> Result(Float, Nil)

@target(javascript)
const iterations = 500_000

@target(javascript)
const warmup = 200_000

@target(javascript)
const rounds = 9

@target(javascript)
const input = "2024-06-13T23:04:00.009+10:00"

@target(javascript)
const compound = [IsoDate, DateTimeSeparator, IsoTime, IsoOffset]

@target(javascript)
const naive_compound = [IsoNaiveDateTime, IsoOffset]

@target(javascript)
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

@target(javascript)
pub fn main() {
  io.println(
    "JS directive-parse benchmark -- input \""
    <> input
    <> "\"\n("
    <> int.to_string(iterations)
    <> " iterations x "
    <> int.to_string(rounds)
    <> " rounds -- ns/op)\n",
  )
  io.println(
    string.pad_end("", 52, " ")
    <> string.pad_start("min", 8, " ")
    <> string.pad_start("median", 10, " ")
    <> string.pad_start("max", 10, " "),
  )
  report("parser.parse (compound IsoDate/T/IsoTime/IsoOffset)", fn(s) {
    parser.parse(s, compound)
  })
  report("parser.parse (compound IsoNaiveDateTime/IsoOffset)", fn(s) {
    parser.parse(s, naive_compound)
  })
  report("parser.parse (fine-grained, 14 directives)", fn(s) {
    parser.parse(s, fine)
  })
  report("parser.parse_ixdtf (bare RFC 9557)", parser.parse_ixdtf)
  report("osler.parse_ixdtf (validated Timestamp)", osler.parse_ixdtf)
  report("osler.parse_timestamp (Timestamp only)", osler.parse_timestamp)
  report("timestamp.parse_rfc3339 (gleam_time)", timestamp.parse_rfc3339)
  report("Date.parse (JS builtin)", date_parse)
  io.println("")
  report_slow("parse_any: prose w/ date+time+offset", fn(_) {
    Ok(osler.parse_any("Meeting on 2024/06/22 at 1:42 PM in -04:00"))
  })
  report_slow("parse_any: ISO timestamp", fn(_) {
    Ok(osler.parse_any("2024-06-13T13:42:11.314+10:00"))
  })
  report_slow("parse_any: bare date", fn(_) {
    Ok(osler.parse_any("2024/06/22"))
  })
  report_slow("parse_any: no match (worst case)", fn(_) {
    Ok(osler.parse_any("just some words with nothing in them at all"))
  })
}

// `parse_any` is orders of magnitude slower than the fixed parsers, so it gets
// its own far smaller iteration count -- at the shared 500k it would run for
// tens of minutes.
@target(javascript)
const slow_iterations = 20_000

@target(javascript)
fn report_slow(label: String, parse: fn(String) -> Result(a, b)) -> Nil {
  let _ = run(slow_iterations, parse, 0)
  let samples = sample_n(slow_iterations, rounds, parse, [])
  let sorted = list.sort(samples, float.compare)
  io.println(
    string.pad_end(label, 52, " ")
    <> col(min(sorted))
    <> col(median(sorted))
    <> col(max(sorted)),
  )
}

@target(javascript)
fn sample_n(
  iters: Int,
  round: Int,
  parse: fn(String) -> Result(a, b),
  acc: List(Float),
) -> List(Float) {
  case round {
    0 -> acc
    _ -> {
      let start = now()
      let oks = run(iters, parse, 0)
      let elapsed = now() -. start
      case oks < 0 {
        True -> io.println("unreachable")
        False -> Nil
      }
      sample_n(iters, round - 1, parse, [
        elapsed *. 1_000_000.0 /. int.to_float(iters),
        ..acc
      ])
    }
  }
}

@target(javascript)
fn report(label: String, parse: fn(String) -> Result(a, b)) -> Nil {
  // Warm the JIT before measuring.
  let _ = run(warmup, parse, 0)
  let samples = sample(rounds, parse, []) |> list.sort(float.compare)
  io.println(
    string.pad_end(label, 52, " ")
    <> col(min(samples))
    <> col(median(samples))
    <> col(max(samples)),
  )
}

@target(javascript)
fn col(ns: Float) -> String {
  string.pad_start(int.to_string(float.round(ns)), 10, " ")
}

// Runs `rounds` timed passes of `iterations` parses each, returning the per-op
// ns of each pass. `oks` is threaded out so V8 cannot treat the loop as dead
// and optimize the parse calls away.
@target(javascript)
fn sample(
  round: Int,
  parse: fn(String) -> Result(a, b),
  acc: List(Float),
) -> List(Float) {
  case round {
    0 -> acc
    _ -> {
      let start = now()
      let oks = run(iterations, parse, 0)
      let elapsed_ms = now() -. start
      let ns = elapsed_ms *. 1_000_000.0 /. int.to_float(iterations)
      let acc = case oks > -1 {
        True -> [ns, ..acc]
        False -> acc
      }
      sample(round - 1, parse, acc)
    }
  }
}

// `samples` is assumed already sorted ascending.
@target(javascript)
fn min(samples: List(Float)) -> Float {
  case samples {
    [first, ..] -> first
    [] -> 0.0
  }
}

@target(javascript)
fn max(samples: List(Float)) -> Float {
  case list.last(samples) {
    Ok(last) -> last
    Error(Nil) -> 0.0
  }
}

@target(javascript)
fn median(samples: List(Float)) -> Float {
  let n = list.length(samples)
  case n {
    0 -> 0.0
    _ -> {
      let mid = n / 2
      case n % 2 {
        // odd count: the middle element
        1 -> at(samples, mid)
        // even count: mean of the two middle elements
        _ -> { at(samples, mid - 1) +. at(samples, mid) } /. 2.0
      }
    }
  }
}

@target(javascript)
fn at(samples: List(Float), index: Int) -> Float {
  case list.drop(samples, index) {
    [value, ..] -> value
    [] -> 0.0
  }
}

@target(javascript)
fn run(n: Int, parse: fn(String) -> Result(a, b), oks: Int) -> Int {
  case n {
    0 -> oks
    _ -> {
      let oks = case parse(input) {
        Ok(_) -> oks + 1
        Error(_) -> oks
      }
      run(n - 1, parse, oks)
    }
  }
}
