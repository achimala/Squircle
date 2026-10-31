//! What reached the screen and why a frame was late, from a capture's Metal
//! records, thread samples and main-thread samples. Pure: `perf show`
//! renders it.

use serde::Deserialize;
use serde_json::Value;

/// The probe's Metal records (format version 2).
#[derive(Deserialize, Default)]
pub struct Metal {
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub counters: String,
    #[serde(default)]
    pub layers: Vec<Layer>,
    /// [layer, requested, wait, presented (0 never, -1 unknown), thread, present called (0 never)]
    #[serde(default)]
    pub drawables: Vec<Vec<f64>>,
    /// [committed, gpu start, gpu end, thread, status]
    #[serde(default)]
    pub command_buffers: Vec<Vec<f64>>,
    #[serde(default)]
    pub passes: Vec<Pass>,
    /// [kind, start, end, thread]
    #[serde(default)]
    pub waits: Vec<Value>,
}

#[derive(Deserialize, Clone)]
pub struct Layer {
    pub name: String,
    #[serde(default)]
    pub pixels: Vec<f64>,
    #[serde(default)]
    pub screen_share: f64,
    #[serde(default)]
    pub max_drawables: u32,
    #[serde(default)]
    pub presents_with_transaction: bool,
    #[serde(default)]
    pub format: String,
}

#[derive(Deserialize, Clone)]
pub struct Pass {
    pub kind: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub target: String,
    pub start: f64,
    pub end: f64,
    #[serde(default)]
    pub vertex: Option<(f64, f64)>,
    #[serde(default)]
    pub fragment: Option<(f64, f64)>,
}

/// Where the frame times come from, most truthful first.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Source {
    /// Metal's presented handler: when each drawable reached the glass.
    OnGlass,
    /// When the app presented each drawable (the simulator reports no
    /// on-glass time): frames the compositor dropped are not seen.
    PresentCalls,
    /// No Metal drawables: display refreshes on which the main thread was
    /// free; animations the render server runs itself are not seen.
    Refreshes,
}

/// One drawable, as `perf show` uses it.
#[derive(Clone, Copy)]
pub struct Drawable {
    pub layer: usize,
    pub requested: f64,
    pub wait: f64,
    pub presented: Option<f64>,
    pub thread: u64,
    pub present_called: Option<f64>,
}

impl Metal {
    pub fn drawables(&self) -> Vec<Drawable> {
        self.drawables
            .iter()
            .filter(|d| d.len() >= 5)
            .map(|d| Drawable {
                layer: d[0] as usize,
                requested: d[1],
                wait: d[2],
                presented: (d[3] >= 0.0).then_some(d[3]),
                thread: d[4] as u64,
                present_called: d.get(5).copied().filter(|t| *t > 0.0),
            })
            .collect()
    }

    /// (committed, gpu start, gpu end, thread) of buffers the GPU timed.
    pub fn buffers(&self) -> Vec<(f64, f64, f64, u64)> {
        self.command_buffers
            .iter()
            .filter(|b| b.len() >= 4 && b[2] > b[1] && b[1] > 0.0)
            .map(|b| (b[0], b[1], b[2], b[3] as u64))
            .collect()
    }

    /// (kind, start, end, thread)
    pub fn waits(&self) -> Vec<(String, f64, f64, u64)> {
        self.waits
            .iter()
            .filter_map(|w| {
                Some((
                    w[0].as_str()?.to_owned(),
                    w[1].as_f64()?,
                    w[2].as_f64()?,
                    w[3].as_f64()? as u64,
                ))
            })
            .collect()
    }
}

/// Times closer than `within` are one screen frame (several layers shown
/// in one transaction).
pub fn cluster(mut times: Vec<f64>, within: f64) -> Vec<f64> {
    times.sort_by(f64::total_cmp);
    let mut out: Vec<f64> = Vec::new();
    for t in times {
        if out.last().is_none_or(|last| t - last > within) {
            out.push(t);
        }
    }
    out
}

/// Screen frames with new content and where they come from; `dropped`
/// counts drawables the app presented that never reached the screen.
pub fn screen_frames(metal: &Metal, refreshes: &[f64]) -> (Vec<f64>, Source, usize) {
    // A small Metal layer (an animated glyph in a Core Animation screen) is
    // not the screen: its own pacing says nothing about the rest, which
    // moves on the main thread's refreshes. Older captures carry no share.
    // Some captures report no share; then pixels: a phone screen is ~3 M.
    let small = |l: &Layer| match l.screen_share {
        s if s > 0.0 => s < 0.25,
        _ => l.pixels.len() == 2 && l.pixels[0] * l.pixels[1] < 300_000.0,
    };
    let share: f64 = metal.layers.iter().map(|l| l.screen_share).sum();
    if !metal.layers.is_empty()
        && metal.layers.iter().all(small)
        && share < 0.25
        && !refreshes.is_empty()
    {
        return (refreshes.to_vec(), Source::Refreshes, 0);
    }
    let drawables = metal.drawables();
    let on_glass: Vec<f64> = drawables
        .iter()
        .filter_map(|d| d.presented.filter(|t| *t > 0.0))
        .collect();
    let dropped = drawables
        .iter()
        .filter(|d| d.presented == Some(0.0) && d.present_called.is_some())
        .count();
    if !on_glass.is_empty() {
        return (cluster(on_glass, 0.001), Source::OnGlass, dropped);
    }
    let called: Vec<f64> = drawables.iter().filter_map(|d| d.present_called).collect();
    if !called.is_empty() {
        return (cluster(called, 0.002), Source::PresentCalls, 0);
    }
    (refreshes.to_vec(), Source::Refreshes, 0)
}

/// The time between two screen frames.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Gap {
    pub start: f64,
    pub end: f64,
    /// Inside a run of frames (something was moving), not a still screen.
    pub moving: bool,
    /// Moving and more than half a refresh past due.
    pub late: bool,
}

impl Gap {
    pub fn length(&self) -> f64 {
        self.end - self.start
    }
}

/// Gaps between screen frames. A gap is part of motion when it is under
/// half a second and a neighbour is under 100 ms: a still screen between
/// animations is not a late frame.
pub fn gaps(frames: &[f64], period: f64) -> Vec<Gap> {
    let lengths: Vec<f64> = frames.windows(2).map(|w| w[1] - w[0]).collect();
    (0..lengths.len())
        .map(|i| {
            let length = lengths[i];
            let near = |j: Option<usize>| j.and_then(|j| lengths.get(j)).is_some_and(|l| *l < 0.1);
            let moving =
                length < 0.1 || (length < 0.5 && (near(i.checked_sub(1)) || near(Some(i + 1))));
            Gap {
                start: frames[i],
                end: frames[i + 1],
                moving,
                late: moving && length > period * 1.5,
            }
        })
        .collect()
}

/// How much of [a, b] the intervals cover, overlaps counted once.
pub fn covered(intervals: &[(f64, f64)], a: f64, b: f64) -> f64 {
    let mut clipped: Vec<(f64, f64)> = intervals
        .iter()
        .filter(|(s, e)| *e > a && *s < b)
        .map(|(s, e)| (s.max(a), e.min(b)))
        .collect();
    clipped.sort_by(|x, y| x.0.total_cmp(&y.0));
    let (mut total, mut reach) = (0.0, a);
    for (s, e) in clipped {
        let s = s.max(reach);
        if e > s {
            total += e - s;
            reach = e;
        }
    }
    total
}

/// What one late frame's time went to, in seconds.
#[derive(Clone, Debug, Default)]
pub struct Breakdown {
    /// The main thread running (not idle, not blocked).
    pub main_work: f64,
    /// The main thread blocked: waiting for the GPU to schedule or finish,
    /// for a drawable, or on a lock.
    pub main_blocked: f64,
    /// Any thread waiting in nextDrawable.
    pub drawable_wait: f64,
    /// The GPU running the app's command buffers.
    pub gpu: f64,
    /// The longest single command buffer in the gap.
    pub longest_buffer: f64,
    /// CPU time of threads that encode or present Metal work, other than main.
    pub render_cpu: f64,
    /// From the gap's start to the app's first drawable request in it (the
    /// whole gap when it asked for none).
    pub request_delay: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Cause {
    MainThread,
    RenderThread,
    Gpu,
    DrawableWait,
    /// The app asked for no frame: its own pacing or frame-rate setting.
    AppPaced,
    /// Nothing in the app was busy: the compositor or display.
    Outside,
}

impl Cause {
    pub fn label(self) -> &'static str {
        match self {
            Cause::MainThread => "CPU-bound: main thread",
            Cause::RenderThread => "CPU-bound: render thread",
            Cause::Gpu => "GPU-bound",
            Cause::DrawableWait => "waiting for a drawable (GPU or compositor holding them)",
            Cause::AppPaced => "app asked for no frame (its own pacing)",
            Cause::Outside => "nothing in the app was busy (compositor/display)",
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Cause::MainThread => "main_thread",
            Cause::RenderThread => "render_thread",
            Cause::Gpu => "gpu",
            Cause::DrawableWait => "drawable_wait",
            Cause::AppPaced => "app_paced",
            Cause::Outside => "outside_app",
        }
    }
}

/// The cause that took most of the gap. The GPU wins when it ran longer
/// than a refresh in one buffer or was busy most of the gap; time the main
/// thread spent blocked on the GPU counts for the GPU.
pub fn cause(b: &Breakdown, length: f64, period: f64, metal: bool) -> Cause {
    // Nothing asked for the next frame until well after it was due, and
    // the app wasn't busy meanwhile.
    if metal && b.request_delay > period * 1.2 && b.main_work + b.render_cpu < b.request_delay * 0.5
    {
        return Cause::AppPaced;
    }
    if b.longest_buffer > period || b.gpu > length * 0.8 {
        return Cause::Gpu;
    }
    let candidates = [
        (Cause::MainThread, b.main_work),
        (Cause::RenderThread, b.render_cpu),
        (Cause::DrawableWait, b.drawable_wait),
        (
            Cause::Gpu,
            b.gpu + (b.main_blocked - b.drawable_wait).max(0.0),
        ),
    ];
    let (cause, time) = candidates
        .iter()
        .copied()
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .unwrap_or((Cause::Outside, 0.0));
    if time < (length - period).max(period) * 0.3 {
        Cause::Outside
    } else {
        cause
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layers_presented_together_are_one_frame_and_on_glass_wins() {
        let metal: Metal = serde_json::from_value(serde_json::json!({
            "drawables": [
                [0, 0.0, 0.0, 0.0331, 1, 0.010],
                [1, 0.0, 0.0, 0.0333, 1, 0.011],
                [0, 0.02, 0.0, 0.0, 1, 0.030],
                [0, 0.04, 0.0, 0.0665, 1, 0.045]
            ]
        }))
        .unwrap();
        let (frames, source, dropped) = screen_frames(&metal, &[0.0, 0.0083, 0.0166]);
        assert_eq!(source, Source::OnGlass);
        assert_eq!(frames, vec![0.0331, 0.0665]);
        assert_eq!(dropped, 1, "presented but never on glass");

        let sim: Metal = serde_json::from_value(serde_json::json!({
            "drawables": [[0, 0.0, 0.0, -1, 1, 0.010], [1, 0.0, 0.0, -1, 1, 0.0105], [0, 0.0, 0.0, -1, 1, 0.050]]
        }))
        .unwrap();
        let (frames, source, _) = screen_frames(&sim, &[]);
        assert_eq!((frames.len(), source), (2, Source::PresentCalls));

        // A glyph-sized Metal layer: the screen is the refreshes.
        let glyph: Metal = serde_json::from_value(serde_json::json!({
            "layers": [{"name": "CAMetalLayer", "screen_share": 0.01}],
            "drawables": [[0, 0.0, 0.0, 0.0331, 1, 0.010]]
        }))
        .unwrap();
        let (frames, source, _) = screen_frames(&glyph, &[0.0, 0.0083]);
        assert_eq!((frames.len(), source), (2, Source::Refreshes));
    }

    #[test]
    fn a_still_screen_is_not_a_late_frame() {
        let period = 1.0 / 60.0;
        // Smooth, one stall in motion, then still for 2 s, then smooth again.
        let frames = [0.0, 0.0167, 0.0333, 0.1333, 0.15, 2.15, 2.1667, 2.1833];
        let late: Vec<(f64, bool)> = gaps(&frames, period)
            .iter()
            .map(|g| (g.start, g.late))
            .filter(|(_, late)| *late)
            .collect();
        assert_eq!(late, vec![(0.0333, true)]);
        assert!(!gaps(&frames, period)[4].moving);
    }

    #[test]
    fn causes() {
        let period = 1.0 / 60.0;
        let gpu = Breakdown {
            gpu: 0.03,
            longest_buffer: 0.03,
            ..Default::default()
        };
        assert_eq!(cause(&gpu, 0.05, period, true), Cause::Gpu);
        let main = Breakdown {
            main_work: 0.04,
            gpu: 0.002,
            longest_buffer: 0.002,
            request_delay: 0.04,
            ..Default::default()
        };
        assert_eq!(cause(&main, 0.05, period, true), Cause::MainThread);
        // Blocked in waitUntilScheduled behind a busy GPU: the GPU's.
        let blocked = Breakdown {
            main_blocked: 0.03,
            gpu: 0.012,
            longest_buffer: 0.012,
            ..Default::default()
        };
        assert_eq!(cause(&blocked, 0.05, period, true), Cause::Gpu);
        let paced = Breakdown {
            main_work: 0.002,
            request_delay: 0.03,
            ..Default::default()
        };
        assert_eq!(cause(&paced, 0.033, period, true), Cause::AppPaced);
        assert_eq!(
            covered(&[(0.0, 2.0), (1.0, 3.0), (5.0, 6.0)], 0.5, 5.5),
            3.0
        );
    }
}
