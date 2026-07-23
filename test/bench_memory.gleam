//// Allocation and reduction counts for osler's Erlang parsers, via glychee.
////
//// The timing benchmarks (`bench_erlang`, `bench_javascript`) use a tighter
//// harness and are the ones to trust for ns/op. This module exists for the two
//// things only glychee reports: bytes allocated and reductions consumed per
//// call, which is how the parsers are compared against OTP's own and
//// `gleam_time`'s on cost rather than wall clock.
////
//// Run with:
////   gleam run --target erlang -m bench_memory

@target(erlang)
import bench_native
@target(erlang)
import gleam/time/timestamp
@target(erlang)
import glychee/benchmark
@target(erlang)
import glychee/configuration
@target(erlang)
import osler
@target(erlang)
import osler/parser.{DateTimeSeparator, IsoDate, IsoOffset, IsoTime}

@target(erlang)
fn discard(_result: a) -> Nil {
  Nil
}

@target(erlang)
const compound = [IsoDate, DateTimeSeparator, IsoTime, IsoOffset]

@target(erlang)
pub fn main() {
  configuration.initialize()
  configuration.set_pair(configuration.Warmup, 2)
  configuration.set_pair(configuration.Time, 5)
  configuration.set_pair(configuration.Parallel, 1)

  benchmark.run(
    [
      benchmark.Function(
        label: "parser.parse_ixdtf (raw ints)",
        callable: fn(input) { fn() { parser.parse_ixdtf(input) |> discard } },
      ),
      benchmark.Function(label: "osler.parse_timestamp", callable: fn(input) {
        fn() { osler.parse_timestamp(input) |> discard }
      }),
      benchmark.Function(label: "osler.parse_ixdtf", callable: fn(input) {
        fn() { osler.parse_ixdtf(input) |> discard }
      }),
      benchmark.Function(
        label: "parser.parse (compound directives)",
        callable: fn(input) {
          fn() { parser.parse(input, compound) |> discard }
        },
      ),
      benchmark.Function(
        label: "calendar:rfc3339_to_system_time (OTP)",
        callable: fn(input) {
          fn() { bench_native.rfc3339_to_system_time(input) |> discard }
        },
      ),
      benchmark.Function(
        label: "timestamp.parse_rfc3339 (gleam_time)",
        callable: fn(input) {
          fn() { timestamp.parse_rfc3339(input) |> discard }
        },
      ),
    ],
    [benchmark.Data(label: "rfc3339", data: "2024-06-13T23:04:00.009+10:00")],
  )
}
