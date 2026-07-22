//// A JavaScript-target microbenchmark mirroring `bench_datetime_parse`, since
//// glychee/benchee only runs on Erlang. It times each parser over many
//// iterations on the JS target (where osler's `osler_ffi.mjs` charCode
//// scanning is what runs) and reports the best (minimum) ns/op across several
//// rounds -- the min being the least noise-affected estimate of steady-state
//// speed.
////
//// The same plain RFC 3339 input is fed to all three, since gleam_time can
//// only parse the suffix-free form:
////
//// - `osler/parser.parse_ixdtf` -- bare, unvalidated ints (+ empty suffix).
//// - `osler.parse_ixdtf` -- calendar-validated, returns a `Timestamp`.
//// - `timestamp.parse_rfc3339` -- gleam_time's own parser.
////
//// Run with:
////   gleam run -m bench_ixdtf_js --target javascript

@target(javascript)
import gleam/float
@target(javascript)
import gleam/int
@target(javascript)
import gleam/io
@target(javascript)
import gleam/string
@target(javascript)
import gleam/time/timestamp
@target(javascript)
import osler
@target(javascript)
import osler/parser

@target(javascript)
@external(javascript, "./bench_js_ffi.mjs", "now")
fn now() -> Float

@target(javascript)
const iterations = 1_000_000

@target(javascript)
const warmup = 200_000

@target(javascript)
const rounds = 6

@target(javascript)
const input = "2024-06-13T23:04:00.009+10:00"

@target(javascript)
pub fn main() {
  io.println(
    "JS parse benchmark -- input \""
    <> input
    <> "\"\n("
    <> int.to_string(iterations)
    <> " iterations x "
    <> int.to_string(rounds)
    <> " rounds, best ns/op)\n",
  )
  report("osler/parser.parse_ixdtf (bare RFC 9557)", parser.parse_ixdtf)
  report("osler.parse_ixdtf (validated, Timestamp + suffix)", osler.parse_ixdtf)
  report("timestamp.parse_rfc3339 (gleam_time)", timestamp.parse_rfc3339)
}

@target(javascript)
fn report(label: String, parse: fn(String) -> Result(a, Nil)) -> Nil {
  // Warm the JIT before measuring.
  let _ = run(warmup, parse, 0)
  let ns = best_ns_per_op(rounds, parse, 1.0e18)
  io.println(
    string.pad_end(label, 52, " ") <> int.to_string(float.round(ns)) <> " ns/op",
  )
}

@target(javascript)
fn best_ns_per_op(
  round: Int,
  parse: fn(String) -> Result(a, Nil),
  best: Float,
) -> Float {
  case round {
    0 -> best
    _ -> {
      let start = now()
      let oks = run(iterations, parse, 0)
      let elapsed_ms = now() -. start
      let ns = elapsed_ms *. 1_000_000.0 /. int.to_float(iterations)
      // `oks` is threaded into the comparison so V8 cannot treat the loop as
      // dead and optimize the parse calls away.
      let best = case oks > -1 && ns <. best {
        True -> ns
        False -> best
      }
      best_ns_per_op(round - 1, parse, best)
    }
  }
}

@target(javascript)
fn run(n: Int, parse: fn(String) -> Result(a, Nil), oks: Int) -> Int {
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
