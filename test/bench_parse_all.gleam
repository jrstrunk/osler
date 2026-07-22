@target(erlang)
import glychee/benchmark
@target(erlang)
import glychee/configuration
@target(erlang)
import osler
@target(erlang)
import osler/parser.{
  Day2, IsoDate, IsoNaiveDateTime, IsoOffset, IsoTime, Literal, Month2, Year4,
}

@target(erlang)
/// Compares parsing the same date through the compound `IsoDate` directive
/// (which dispatches to the fast, delimiter-flexible byte scanner) against a
/// fine-grained fixed directive list, and exercises each of the compound ISO
/// directives plus `parse_ixdtf`.
///
/// Run with:
///   gleam run -m bench_parse_all
fn discard(_result: a) -> Nil {
  Nil
}

@target(erlang)
pub fn main() {
  configuration.initialize()
  configuration.set_pair(configuration.Warmup, 1)
  configuration.set_pair(configuration.Time, 2)
  configuration.set_pair(configuration.Parallel, 1)

  let fine = [Year4, Literal("-"), Month2, Literal("-"), Day2]

  benchmark.run(
    [
      benchmark.Function(label: "parse [IsoDate]", callable: fn(_) {
        fn() { parser.parse("2024-06-13", [IsoDate]) |> discard }
      }),
      benchmark.Function(label: "parse fine-grained", callable: fn(_) {
        fn() { parser.parse("2024-06-13", fine) |> discard }
      }),
    ],
    [benchmark.Data(label: "date", data: Nil)],
  )

  benchmark.run(
    [
      benchmark.Function(label: "parse [IsoTime]", callable: fn(_) {
        fn() { parser.parse("13:42:11.354053", [IsoTime]) |> discard }
      }),
      benchmark.Function(label: "parse [IsoOffset]", callable: fn(_) {
        fn() { parser.parse("-04:00", [IsoOffset]) |> discard }
      }),
      benchmark.Function(label: "parse [IsoNaiveDateTime]", callable: fn(_) {
        fn() {
          parser.parse("2024-06-13T13:42:11.354053", [IsoNaiveDateTime])
          |> discard
        }
      }),
      benchmark.Function(label: "osler.parse_ixdtf", callable: fn(_) {
        fn() {
          osler.parse_ixdtf("2024-06-13T13:42:11.354053-04:00") |> discard
        }
      }),
    ],
    [benchmark.Data(label: "time/offset/naive/ixdtf", data: Nil)],
  )
}
