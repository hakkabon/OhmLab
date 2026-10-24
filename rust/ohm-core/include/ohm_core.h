// ohm_core.h — C ABI for OhmLab's optional Rust simulation core (ohm-core).
//
// This is the only surface the Swift side sees. It is intentionally tiny: a
// version string and a JSON-returning solve call, so no generated bindings are
// required. Link against the static library produced by
// `scripts/build-rust-core.sh` (libohm_core.a).

#ifndef OHM_CORE_H
#define OHM_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns a NUL-terminated static version string, e.g. "ohm-core 0.3.0".
/// The pointer is owned by the library; do not free it.
const char *ohm_engine_version(void);

/// Parses and solves `netlist` (NUL-terminated UTF-8), writing a heap-allocated
/// JSON result to `*out_json`.
///
/// Returns 0 on success or a negative code on invalid arguments:
///   -1  a null pointer was passed
///   -2  `netlist` was not valid UTF-8
///   -3  the result could not be encoded as a C string
///
/// Solver-level failures (singular matrix, missing ground, unsupported device)
/// are reported inside the JSON `warnings` array with the affected analysis set
/// to `null`; a 0 return can therefore still carry diagnostics. The caller owns
/// `*out_json` and must release it with `ohm_free_string`.
int32_t ohm_solve(const char *netlist, char **out_json);

/// Decodes and solves a versioned JSON Circuit IR transport request. This is
/// the preferred ABI for typed frontends: no SPICE text is reparsed and an
/// unsupported schema, device, or analysis is reported in the JSON `errors`
/// array without partially solving the circuit.
int32_t ohm_solve_circuit_ir(const char *request_json, char **out_json);

/// Frees a string returned through either solve entry point. Passing NULL is safe.
void ohm_free_string(char *s);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // OHM_CORE_H
