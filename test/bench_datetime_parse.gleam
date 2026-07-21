@target(erlang)
import gleam/time/timestamp
@target(erlang)
import glychee/benchmark
@target(erlang)
import glychee/configuration
@target(erlang)
import osler
@target(erlang)
import osler/parser

/// Compares osler's RFC 9557 (IXDTF) parser against `gleam_time`'s RFC 3339
/// parser on the same plain RFC 3339 input (no suffix -- the only kind
/// `gleam_time` can parse, so it is the apples-to-apples comparison):
///
/// - `osler/parser.parse_ixdtf` returns the raw, unvalidated ints (plus an
///   empty suffix) straight off the byte/charcode scan -- no `gleam_time`
///   types constructed at all.
/// - `osler.parse_ixdtf` builds `calendar.Date`/`calendar.TimeOfDay` values
///   and validates them via `gleam_time`'s calendar module.
/// - `timestamp.parse_rfc3339` is `gleam_time`'s own parser, the baseline.
///
/// Run with:
///   gleam run -m bench_datetime_parse
@target(erlang)
fn discard(_result: a) -> Nil {
  Nil
}

@target(erlang)
pub fn main() {
  configuration.initialize()
  configuration.set_pair(configuration.Warmup, 2)
  configuration.set_pair(configuration.Time, 5)
  configuration.set_pair(configuration.Parallel, 1)

  benchmark.run(
    [
      benchmark.Function(
        label: "osler/parser.parse_ixdtf (bare RFC 9557, no validation)",
        callable: fn(test_data) {
          fn() { parser.parse_ixdtf(test_data) |> discard }
        },
      ),
      benchmark.Function(
        label: "osler.parse_ixdtf (calendar-validated, RFC 9557 parts)",
        callable: fn(test_data) {
          fn() { osler.parse_ixdtf(test_data) |> discard }
        },
      ),
      benchmark.Function(
        label: "timestamp.parse_rfc3339 (gleam_time)",
        callable: fn(test_data) {
          fn() { timestamp.parse_rfc3339(test_data) |> discard }
        },
      ),
    ],
    [
      benchmark.Data(
        label: "ISO datetime with millisecond offset",
        data: "2024-06-13T23:04:00.009+10:00",
      ),
    ],
  )
}
