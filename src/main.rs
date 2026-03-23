mod camera;
mod color;
mod common;
mod hittable;
mod hittable_list;
mod ray;
mod sphere;
mod vec3;

use std::io;

use camera::Camera;
use color::Color;
use ray::Ray;
use sphere::Sphere;
use vec3::Point3;

use crate::hittable::{HitRecord, Hittable};
use hittable_list::HittableList;

fn ray_color(r: &Ray, world: &dyn Hittable, depth: i32) -> Color {
    // If we've exceeded the ray bounce limit, no more light is gathered
    if depth <= 0 {
        return color::black();
    }

    let mut rec = HitRecord::default();
    if world.hit(r, 0.001, common::INFINITY, &mut rec) {
        // Choose a random direction to simulate matte diffusion
        let direction = rec.normal + vec3::random_unit_vector();
        return 0.5 * ray_color(&Ray::new(rec.p, direction), world, depth - 1);
    }

    // t represents the hit point
    let unit_direction = vec3::unit_vector(r.direction());
    let t = 0.5 * (unit_direction.y() + 1.0);
    // Linear blend: blended_value = (1 - t) * start_value + t * end_value
    (1.0 - t) * color::white() + t * Color::new(0.5, 0.7, 1.0)
}

fn main() {
    // Image

    const ASPECT_RATIO: f64 = 16.0 / 9.0;
    const IMAGE_WIDTH: i32 = 400;
    const IMAGE_HEIGHT: i32 = (IMAGE_WIDTH as f64 / ASPECT_RATIO) as i32;
    const SAMPLES_PER_PIXEL: i32 = 100;
    const MAX_DEPTH: i32 = 50;

    // World
    let mut world = HittableList::new();
    // Centered sphere
    world.add(Box::new(Sphere::new(Point3::new(0.0, 0.0, -1.0), 0.5)));

    // Floor
    world.add(Box::new(Sphere::new(Point3::new(0.0, -100.5, -1.0), 100.0)));

    // Camera
    let cam = Camera::new();

    // Render

    print!("P3\n{} {}\n255\n", IMAGE_WIDTH, IMAGE_HEIGHT);

    for j in (0..IMAGE_HEIGHT).rev() {
        eprint!("\rScanlines remaining: {} ", j);
        for i in 0..IMAGE_WIDTH {
            let mut pixel_color = color::black();
            for _ in 0..SAMPLES_PER_PIXEL {
                let u = (i as f64 + common::random_double()) / (IMAGE_WIDTH - 1) as f64;
                let v = (j as f64 + common::random_double()) / (IMAGE_HEIGHT - 1) as f64;
                let r = cam.get_ray(u, v);
                pixel_color += ray_color(&r, &world, MAX_DEPTH);
            }
            color::write_color(&mut io::stdout(), pixel_color, SAMPLES_PER_PIXEL);
        }
    }

    eprint!("\nDone.\n");
}
