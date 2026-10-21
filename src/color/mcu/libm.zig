//! System libm transcendentals, called directly.
//!
//! These call libm directly; Zig's `std.math` equivalents can
//! differ by 1 ulp, and this pipeline makes exact decisions (rounding to
//! bytes, `<` comparisons, argmins) where 1 ulp flips the outcome — observed
//! as an off-by-one quantize count and a neighboring-hue complement pick.
//! Exact ops (`@sqrt`, `@round`, `@floor`, `@ceil`, `@abs`, `@min/@max`)
//! stay builtins. All port logic remains Zig; only the transcendental kernels
//! come from the system libm.
pub extern fn sin(x: f64) f64;
pub extern fn cos(x: f64) f64;
pub extern fn atan2(y: f64, x: f64) f64;
pub extern fn exp(x: f64) f64;
/// C `log()`: natural logarithm.
pub extern fn log(x: f64) f64;
pub extern fn pow(x: f64, y: f64) f64;
pub extern fn hypot(x: f64, y: f64) f64;
