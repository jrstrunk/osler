@target(erlang)
import gleam/time/timestamp
@target(erlang)
import glychee/benchmark
@target(erlang)
import glychee/configuration
@target(erlang)
import osler
@target(erlang)
import osler/parser.{
  DateTimeSeparator, Day2, Hour24Padded, IsoDate, IsoNaiveDateTime, IsoOffset,
  IsoTime, Literal, Milli, Minute2, Month2, OffsetColon, Second2, Year4,
}

@target(erlang)
/// Compares parsing one RFC 3339 string three ways on the Erlang target:
///
/// - osler's directive engine, `parser.parse`, with a compound-ISO directive
///   list and with a fine-grained fixed directive list (the two are the same
///   scan, so the gap is the per-directive walk cost);
/// - `parser.parse_ixdtf` / `osler.parse_ixdtf`, the dedicated fixed-grammar
///   RFC 9557 parsers (bare ints, and calendar-validated `Timestamp`);
/// - `timestamp.parse_rfc3339`, gleam_time's own parser.
///
/// Run with:
///   gleam run -m bench_directive_parse
fn discard(_result: a) -> Nil {
  Nil
}

// OTP's builtin RFC 3339 parser (returns the epoch-seconds system time, or
// throws on an unparseable string -- fine for a valid benchmark input).
@target(erlang)
@external(erlang, "calendar", "rfc3339_to_system_time")
fn rfc3339_to_system_time(str: String) -> Int

// Directive lists are built once and reused, as they would be in real use.
@target(erlang)
const compound = [IsoDate, DateTimeSeparator, IsoTime, IsoOffset]

@target(erlang)
const naive_compound = [IsoNaiveDateTime, IsoOffset]

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

@target(erlang)
pub fn main() {
  configuration.initialize()
  configuration.set_pair(configuration.Warmup, 2)
  configuration.set_pair(configuration.Time, 5)
  configuration.set_pair(configuration.Parallel, 1)

  benchmark.run(
    [
      benchmark.Function(
        label: "parser.parse (compound [IsoDate, T, IsoTime, IsoOffset])",
        callable: fn(input: String) {
          fn() { parser.parse(input, compound) |> discard }
        },
      ),
      benchmark.Function(
        label: "parser.parse (compound [IsoNaiveDateTime, IsoOffset])",
        callable: fn(input: String) {
          fn() { parser.parse(input, naive_compound) |> discard }
        },
      ),
      benchmark.Function(
        label: "parser.parse (fine-grained, 14 directives)",
        callable: fn(input: String) {
          fn() { parser.parse(input, fine) |> discard }
        },
      ),
      benchmark.Function(
        label: "parser.parse_ixdtf (bare RFC 9557)",
        callable: fn(input: String) {
          fn() { parser.parse_ixdtf(input) |> discard }
        },
      ),
      benchmark.Function(
        label: "osler.parse_ixdtf (validated Timestamp)",
        callable: fn(input: String) {
          fn() { osler.parse_ixdtf(input) |> discard }
        },
      ),
      benchmark.Function(
        label: "osler.parse_timestamp (Timestamp only)",
        callable: fn(input: String) {
          fn() { osler.parse_timestamp(input) |> discard }
        },
      ),
      benchmark.Function(
        label: "timestamp.parse_rfc3339 (gleam_time)",
        callable: fn(input: String) {
          fn() { timestamp.parse_rfc3339(input) |> discard }
        },
      ),
      benchmark.Function(
        label: "calendar:rfc3339_to_system_time (OTP builtin)",
        callable: fn(input: String) {
          fn() { rfc3339_to_system_time(input) |> discard }
        },
      ),
    ],
    [benchmark.Data(label: "rfc3339", data: "2024-06-13T23:04:00.009+10:00")],
  )
}
