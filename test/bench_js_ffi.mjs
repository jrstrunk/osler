// Timing + builtin-parser primitives for the JavaScript-target
// microbenchmarks (`bench_ixdtf_js`, `bench_directive_js`).
import { Ok, Error } from "./gleam.mjs";

// `performance.now()` is a Node/browser global returning a high-resolution
// timestamp in milliseconds.
export function now() {
  return performance.now();
}

// The JS engine's builtin date-string parser, wrapped as a Gleam Result so it
// slots into the same benchmark harness as the other parsers. Returns the
// epoch-milliseconds number, or Error on an unparseable string (Date.parse
// yields NaN).
export function dateParse(str) {
  return Date.parse(str);
}

// `Temporal` is not yet unflagged on Node 20 -- the benchmark skips the
// Temporal row rather than timing 500k thrown ReferenceErrors.
export function hasTemporal() {
  return typeof Temporal !== "undefined";
}

// `Temporal.Instant.from`, the native parser that does the same job as
// `osler.parse_ixdtf`: a validated, nanosecond-precision instant. Throws on
// an unparseable string, so wrap in a Result.
export function temporalParse(str) {
  return Temporal.Instant.from(str);
}
