//// OTP's own RFC 3339 parser, exposed for benchmark comparison against
//// osler's Erlang-target parsers.
////
//// Reading the comparison fairly:
////
//// - It returns a bare `Int` (nanoseconds since the Unix epoch), so it
////   allocates no `Timestamp`. The closest osler analogue is
////   `osler.parse_timestamp`, which does build one -- worth ~45ns.
//// - It parses RFC 3339 only. It **raises** on an RFC 9557 suffix
////   (`[Australia/Sydney]`), on the compact forms, and on any delimiter other
////   than `-`/`:`, all of which osler accepts. Benchmarks that feed it those
////   are measuring how fast it fails, not a like-for-like parse.
//// - `calendar:rfc3339_to_system_time/2` signals failure by raising, which
////   Gleam cannot catch, so `osler_bench_ffi` wraps it in a `try`. That cost
////   lands on both the success and failure paths and does not flatter it.

@target(erlang)
/// Nanoseconds since the Unix epoch, via `calendar:rfc3339_to_system_time/2`.
@external(erlang, "osler_bench_ffi", "rfc3339_to_system_time")
pub fn rfc3339_to_system_time(str: String) -> Result(Int, Nil)
