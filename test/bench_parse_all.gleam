@target(erlang)
import glychee/benchmark
@target(erlang)
import glychee/configuration
@target(erlang)
import osler
@target(erlang)
import osler/parser

/// Compares osler's calendar-type-returning public API against
/// `osler/parser`'s bare, unvalidated int tuples for each of the smaller
/// parsers, to see what the calendar-type construction/validation costs
/// on top of the raw scan.
///
/// Run with:
///   gleam run -m bench_parse_all
@target(erlang)
fn discard(_result: a) -> Nil {
  Nil
}

@target(erlang)
pub fn main() {
  configuration.initialize()
  configuration.set_pair(configuration.Warmup, 1)
  configuration.set_pair(configuration.Time, 2)
  configuration.set_pair(configuration.Parallel, 1)

  benchmark.run(
    [
      benchmark.Function(label: "osler.parse_date", callable: fn(_) {
        fn() { osler.parse_date("2024-06-13") |> discard }
      }),
      benchmark.Function(label: "osler/parser.parse_date", callable: fn(_) {
        fn() { parser.parse_date("2024-06-13") |> discard }
      }),
    ],
    [benchmark.Data(label: "date", data: Nil)],
  )

  benchmark.run(
    [
      benchmark.Function(label: "osler.parse_time", callable: fn(_) {
        fn() { osler.parse_time("13:42:11.354053") |> discard }
      }),
      benchmark.Function(label: "osler/parser.parse_time", callable: fn(_) {
        fn() { parser.parse_time("13:42:11.354053") |> discard }
      }),
    ],
    [benchmark.Data(label: "time", data: Nil)],
  )

  benchmark.run(
    [
      benchmark.Function(label: "osler.parse_offset", callable: fn(_) {
        fn() { osler.parse_offset("-04:00") |> discard }
      }),
      benchmark.Function(label: "osler/parser.parse_offset", callable: fn(_) {
        fn() { parser.parse_offset("-04:00") |> discard }
      }),
    ],
    [benchmark.Data(label: "offset", data: Nil)],
  )

  benchmark.run(
    [
      benchmark.Function(label: "osler.parse_naive_datetime", callable: fn(_) {
        fn() {
          osler.parse_naive_datetime("2024-06-13T13:42:11.354053")
          |> discard
        }
      }),
      benchmark.Function(
        label: "osler/parser.parse_naive_datetime",
        callable: fn(_) {
          fn() {
            parser.parse_naive_datetime("2024-06-13T13:42:11.354053")
            |> discard
          }
        },
      ),
    ],
    [benchmark.Data(label: "naive_datetime", data: Nil)],
  )
}
