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

/// Measures the RFC 9557 (IXDTF) parsers:
///
/// - `parser.parse_ixdtf` on a plain RFC 3339 string (no suffix) shows the
///   overhead of the richer `Ixdtf` return value over the bare-tuple
///   `parser.parse_datetime`.
/// - `parser.parse_ixdtf` on a string with a time zone + tag shows the cost
///   of scanning and validating the suffix.
/// - `osler.parse_ixdtf` adds calendar-type construction/validation on top.
///
/// Run with:
///   gleam run -m bench_ixdtf_parse
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
        label: "timestamp.parse_rfc3339 (gleam_time, no-suffix input)",
        callable: fn(test_data: #(String, String)) {
          fn() { timestamp.parse_rfc3339(test_data.0) |> discard }
        },
      ),
      benchmark.Function(
        label: "parser.parse_ixdtf (no suffix present)",
        callable: fn(test_data: #(String, String)) {
          fn() { parser.parse_ixdtf(test_data.0) |> discard }
        },
      ),
      benchmark.Function(
        label: "parser.parse_ixdtf (zone + tag suffix)",
        callable: fn(test_data: #(String, String)) {
          fn() { parser.parse_ixdtf(test_data.1) |> discard }
        },
      ),
      benchmark.Function(
        label: "osler.parse_ixdtf (calendar-validated, zone + tag)",
        callable: fn(test_data: #(String, String)) {
          fn() { osler.parse_ixdtf(test_data.1) |> discard }
        },
      ),
    ],
    [
      benchmark.Data(label: "ixdtf", data: #(
        "2024-06-13T23:04:00.009+10:00",
        "2024-06-13T23:04:00.009+10:00[Australia/Sydney][u-ca=hebrew]",
      )),
    ],
  )
}
