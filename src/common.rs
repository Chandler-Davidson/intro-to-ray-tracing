// Constants

pub use std::f64::INFINITY;
pub use std::f64::consts::PI;

// Utility functions

pub fn degrees_to_radians(degrees: f64) -> f64 {
    degrees * PI / 180.0
}
