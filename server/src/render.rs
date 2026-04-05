use crate::StrokePoint;
use image::{ImageBuffer, Rgb};

const PADDING: f64 = 60.0;
const STROKE_WIDTH: f64 = 3.0;
const MIN_SIZE: u32 = 128;
const MAX_SIZE: u32 = 4096;

pub struct RenderResult {
    pub image: ImageBuffer<Rgb<u8>, Vec<u8>>,
    pub min_x: f64,
    pub min_y: f64,
    pub margin: f64,
    pub scale_x: f64,
    pub scale_y: f64,
}

impl RenderResult {
    /// Convert pixel-space bbox [x1, y1, x2, y2] to world coordinates.
    pub fn pixel_to_world(&self, bbox: &[u32; 4]) -> [f64; 4] {
        [
            bbox[0] as f64 * self.scale_x + self.min_x - self.margin,
            bbox[1] as f64 * self.scale_y + self.min_y - self.margin,
            bbox[2] as f64 * self.scale_x + self.min_x - self.margin,
            bbox[3] as f64 * self.scale_y + self.min_y - self.margin,
        ]
    }

    /// Convert world-space bbox back to pixel coordinates.
    pub fn world_to_pixel(&self, world_bbox: &[f64; 4]) -> [u32; 4] {
        [
            ((world_bbox[0] - self.min_x + self.margin) / self.scale_x).round() as u32,
            ((world_bbox[1] - self.min_y + self.margin) / self.scale_y).round() as u32,
            ((world_bbox[2] - self.min_x + self.margin) / self.scale_x).round() as u32,
            ((world_bbox[3] - self.min_y + self.margin) / self.scale_y).round() as u32,
        ]
    }
}

/// Render strokes to a white-background RGB image.
/// Also saves a debug copy to quire_render_debug.png.
pub fn strokes_to_image(strokes: &[Vec<StrokePoint>]) -> RenderResult {
    let mut min_x = f64::MAX;
    let mut min_y = f64::MAX;
    let mut max_x = f64::MIN;
    let mut max_y = f64::MIN;

    for stroke in strokes {
        for p in stroke {
            min_x = min_x.min(p.x);
            min_y = min_y.min(p.y);
            max_x = max_x.max(p.x);
            max_y = max_y.max(p.y);
        }
    }

    let margin = PADDING + STROKE_WIDTH;
    let raw_w = max_x - min_x + 2.0 * margin;
    let raw_h = max_y - min_y + 2.0 * margin;

    let width = (raw_w as u32).clamp(MIN_SIZE, MAX_SIZE);
    let height = (raw_h as u32).clamp(MIN_SIZE, MAX_SIZE);

    let scale_x = raw_w / width as f64;
    let scale_y = raw_h / height as f64;

    eprintln!(
        "[render] {} strokes, bbox ({:.0},{:.0})–({:.0},{:.0}), img {}x{}",
        strokes.len(), min_x, min_y, max_x, max_y, width, height
    );

    let mut img = ImageBuffer::from_pixel(width, height, Rgb([255u8, 255, 255]));
    let black = Rgb([0u8, 0, 0]);

    for stroke in strokes {
        for i in 0..stroke.len().saturating_sub(1) {
            let x0 = stroke[i].x - min_x + margin;
            let y0 = stroke[i].y - min_y + margin;
            let x1 = stroke[i + 1].x - min_x + margin;
            let y1 = stroke[i + 1].y - min_y + margin;
            draw_thick_line(&mut img, x0, y0, x1, y1, STROKE_WIDTH, black);
        }
        if stroke.len() == 1 {
            let x = stroke[0].x - min_x + margin;
            let y = stroke[0].y - min_y + margin;
            draw_filled_circle(&mut img, x, y, STROKE_WIDTH / 2.0, black);
        }
    }

    let _ = img.save("quire_render_debug.png");
    RenderResult { image: img, min_x, min_y, margin, scale_x, scale_y }
}

/// Crop a region from an image by pixel coordinates.
pub fn crop_image(
    img: &ImageBuffer<Rgb<u8>, Vec<u8>>,
    x1: u32, y1: u32, x2: u32, y2: u32,
) -> ImageBuffer<Rgb<u8>, Vec<u8>> {
    let x1 = x1.min(img.width());
    let y1 = y1.min(img.height());
    let x2 = x2.min(img.width()).max(x1 + 1);
    let y2 = y2.min(img.height()).max(y1 + 1);
    let w = x2 - x1;
    let h = y2 - y1;
    ImageBuffer::from_fn(w, h, |x, y| *img.get_pixel(x1 + x, y1 + y))
}

fn draw_thick_line(
    img: &mut ImageBuffer<Rgb<u8>, Vec<u8>>,
    x0: f64, y0: f64, x1: f64, y1: f64,
    width: f64, color: Rgb<u8>,
) {
    let dx = x1 - x0;
    let dy = y1 - y0;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 0.5 {
        draw_filled_circle(img, x0, y0, width / 2.0, color);
        return;
    }
    let steps = (len * 2.0) as usize;
    for s in 0..=steps {
        let t = s as f64 / steps as f64;
        draw_filled_circle(img, x0 + dx * t, y0 + dy * t, width / 2.0, color);
    }
}

fn draw_filled_circle(
    img: &mut ImageBuffer<Rgb<u8>, Vec<u8>>,
    cx: f64, cy: f64, radius: f64, color: Rgb<u8>,
) {
    let r = radius.ceil() as i32;
    let (w, h) = (img.width() as i32, img.height() as i32);
    let icx = cx as i32;
    let icy = cy as i32;
    let r_sq = radius * radius;
    for dy in -r..=r {
        for dx in -r..=r {
            if (dx * dx + dy * dy) as f64 <= r_sq {
                let px = icx + dx;
                let py = icy + dy;
                if px >= 0 && px < w && py >= 0 && py < h {
                    img.put_pixel(px as u32, py as u32, color);
                }
            }
        }
    }
}
