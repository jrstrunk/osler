// Timing primitive for the JavaScript-target microbenchmark
// (`bench_ixdtf_js`). `performance.now()` is a Node/browser global returning
// a high-resolution timestamp in milliseconds.
export function now() {
  return performance.now();
}
