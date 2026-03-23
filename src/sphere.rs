use crate::ray::Ray;
use crate::vec3;
use crate::vec3::Point3;

#[derive(Default)]
pub struct Sphere {
    orig: Point3,
    radius: f64,
}

impl Sphere {
    pub fn new(origin: Point3, radius: f64) -> Sphere {
        Sphere {
            orig: origin,
            radius,
        }
    }

    pub fn intersects(&self, r: &Ray) -> f64 {
        let oc = r.origin() - self.orig;
        let a = r.direction().length_squared();
        let half_b = vec3::dot(oc, r.direction());
        let c = oc.length_squared() - self.radius * self.radius;

        let discriminant = half_b * half_b - a * c;
        if discriminant < 0.0 {
            -1.0
        } else {
            (-half_b - f64::sqrt(discriminant)) / a
        }
    }
}
