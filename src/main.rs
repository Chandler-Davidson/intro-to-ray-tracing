mod camera;
mod color;
mod common;
mod hittable;
mod hittable_list;
mod material;
mod ray;
mod sphere;
mod vec3;

use std::io;
use std::sync::Arc;
use std::thread;

use camera::Camera;
use color::Color;
use hittable::{HitRecord, Hittable};
use hittable_list::HittableList;
use material::{Dielectric, Lambertian, Metal};
use ray::Ray;
use sphere::Sphere;
use vec3::{Point3, Vec3};

fn ray_color(r: &Ray, world: &dyn Hittable, depth: i32) -> Color {
    // If we've exceeded the ray bounce limit, no more light is gathered
    if depth <= 0 {
        return color::black();
    }

    let mut rec = HitRecord::default();
    if world.hit(r, 0.001, common::INFINITY, &mut rec) {
        let mut attenuation = Color::default();
        let mut scattered = Ray::default();
        if rec
            .material
            .as_ref()
            .unwrap()
            .scatter(r, &rec, &mut attenuation, &mut scattered)
        {
            return attenuation * ray_color(&scattered, world, depth - 1);
        }
        return Color::new(0.0, 0.0, 0.0);
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
    let r = f64::cos(common::PI / 4.0);
    let mut world = HittableList::new();
    let material_ground = Arc::new(Lambertian::new(Color::new(0.8, 0.8, 0.0)));
    let material_matte = Arc::new(Lambertian::new(Color::new(0.1, 0.2, 0.5)));
    let material_glass = Arc::new(Dielectric::new(1.5));
    let material_metal = Arc::new(Metal::new(Color::new(0.8, 0.6, 0.2), 0.0));

    world.add(Box::new(Sphere::new(
        Point3::new(0.0, -100.5, -1.0),
        100.0,
        material_ground,
    )));
    world.add(Box::new(Sphere::new(
        Point3::new(0.0, 0.0, -1.0),
        0.5,
        material_matte,
    )));
    world.add(Box::new(Sphere::new(
        Point3::new(-1.0, 0.0, -1.0),
        0.5,
        material_glass.clone(),
    )));
    world.add(Box::new(Sphere::new(
        Point3::new(-1.0, 0.0, -1.0),
        -0.4,
        material_glass,
    )));
    world.add(Box::new(Sphere::new(
        Point3::new(1.0, 0.0, -1.0),
        0.5,
        material_metal,
    )));

    // Camera
    let cam = Arc::new(Camera::new(
        Point3::new(-2.0, 2.0, 1.0),
        Point3::new(0.0, 0.0, -1.0),
        Vec3::new(0.0, 1.0, 0.0),
        20.0,
        ASPECT_RATIO,
    ));
    let world = Arc::new(world);

    // Render
    print!("P3\n{} {}\n255\n", IMAGE_WIDTH, IMAGE_HEIGHT);

    let handles: Vec<thread::JoinHandle<(i32, Vec<Color>)>> = (0..IMAGE_HEIGHT)
        .rev()
        .map(|j| {
            let world = Arc::clone(&world);
            let cam = Arc::clone(&cam);
            thread::spawn(move || {
                let mut row = Vec::with_capacity(IMAGE_WIDTH as usize);
                for i in 0..IMAGE_WIDTH {
                    let mut pixel_color = color::black();
                    for _ in 0..SAMPLES_PER_PIXEL {
                        let u = (i as f64 + common::random_double()) / (IMAGE_WIDTH - 1) as f64;
                        let v = (j as f64 + common::random_double()) / (IMAGE_HEIGHT - 1) as f64;
                        let r = cam.get_ray(u, v);
                        pixel_color += ray_color(&r, world.as_ref(), MAX_DEPTH);
                    }
                    row.push(pixel_color);
                }
                (j, row)
            })
        })
        .collect();

    let mut rows: Vec<Vec<Color>> = (0..IMAGE_HEIGHT as usize).map(|_| Vec::new()).collect();
    let total = handles.len();
    for (completed, handle) in handles.into_iter().enumerate() {
        let (j, row) = handle.join().unwrap();
        eprint!("\rScanlines remaining: {} ", total - completed - 1);
        rows[j as usize] = row;
    }

    for j in (0..IMAGE_HEIGHT).rev() {
        for &pixel_color in &rows[j as usize] {
            color::write_color(&mut io::stdout(), pixel_color, SAMPLES_PER_PIXEL);
        }
    }

    eprint!("\nDone.\n");
}
