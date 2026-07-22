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
  const ms = Date.parse(str);
  return Number.isNaN(ms) ? new Error(undefined) : new Ok(ms);
}
