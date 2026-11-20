//! The visual gates kit (docs/task-tracking.md#gates): `draw`, `plan`,
//! `film`, `review`, `merge`, `gates`. Everything but `draw` asks the
//! service, which keeps each round and decides; `draw` renders pictures
//! here, from a short JSON spec, with headless Chrome.
use super::*;

#[derive(Subcommand)]
pub(super) enum ReviewCommand {
    /// Start the independent reviewer (a T3 worker, Codex GPT-6 Astra unless the app's .squircle/gates.toml names another) at the branch's head.
    Start {
        /// The code work item.
        item: String,
        #[arg(
            long,
            help = "Your (the app agent's) thread ID: the reviewer is your worker"
        )]
        thread: String,
        #[arg(
            long,
            help = "The branch to review (default: the one last reviewed, or the newest linked worker's)"
        )]
        branch: Option<String>,
    },
    /// The reviewer hands in review-N.md (squircle help gates has the format). Refused without a line per planned change, a picture per finding, or a film per change.
    Submit {
        item: String,
        #[arg(long, help = "The commit you reviewed, as your brief gave it")]
        head: String,
        #[arg(long, help = "Absolute path of your review-N.md")]
        file: PathBuf,
    },
}

#[derive(Subcommand)]
pub(super) enum GatesCommand {
    /// Write the app's .squircle/gates.toml: base branch, reviewer, the rule documents it enforces, and the checks a merge runs first.
    Enable {
        #[arg(long, help = "Your thread ID (the app is taken from it)")]
        thread: Option<String>,
        #[arg(long, help = "T3 project ID instead of a thread")]
        project: Option<String>,
        #[arg(
            long,
            help = "Base branch (default: the one checked out in the app's folder)"
        )]
        base: Option<String>,
        #[arg(
            long = "rule",
            value_name = "PATH",
            help = "A document the reviewer enforces (repeat)"
        )]
        rules: Vec<String>,
        #[arg(
            long = "check",
            value_name = "COMMAND",
            help = "A command a merge runs on the merged tree first (repeat)"
        )]
        checks: Vec<String>,
        #[arg(long)]
        provider: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        effort: Option<String>,
    },
}

pub(super) async fn plan(cli: &Cli, item: &str, dir: &std::path::Path) -> Result<Option<Value>> {
    let dir = std::path::absolute(dir)?;
    Ok(Some(
        post(
            cli,
            &format!("/v1/tasks/{}/plan", task_id(item)?),
            json!({"dir": dir}),
        )
        .await?,
    ))
}

pub(super) async fn film(
    cli: &Cli,
    item: &str,
    change: u32,
    side: squircle::tasks::Side,
    file: Option<&PathBuf>,
    thread: Option<&str>,
    caption: Option<&str>,
) -> Result<Option<Value>> {
    let file = file.map(std::path::absolute).transpose()?;
    Ok(Some(
        post(
            cli,
            &format!("/v1/tasks/{}/film", task_id(item)?),
            json!({"change": change, "side": side, "file": file, "thread": thread, "caption": caption}),
        )
        .await?,
    ))
}

pub(super) async fn review(cli: &Cli, command: &ReviewCommand) -> Result<Option<Value>> {
    Ok(Some(match command {
        ReviewCommand::Start {
            item,
            thread,
            branch,
        } => {
            post(
                cli,
                &format!("/v1/tasks/{}/review", task_id(item)?),
                json!({"thread": thread_id(thread)?, "branch": branch}),
            )
            .await?
        }
        ReviewCommand::Submit { item, head, file } => {
            post(
                cli,
                &format!("/v1/tasks/{}/review/submit", task_id(item)?),
                json!({"head": head, "file": std::path::absolute(file)?}),
            )
            .await?
        }
    }))
}

pub(super) async fn merge(cli: &Cli, item: &str) -> Result<Option<Value>> {
    Ok(Some(
        post(
            cli,
            &format!("/v1/tasks/{}/merge", task_id(item)?),
            json!({}),
        )
        .await?,
    ))
}

pub(super) async fn gates(cli: &Cli, command: &GatesCommand) -> Result<Option<Value>> {
    Ok(Some(match command {
        GatesCommand::Enable {
            thread,
            project,
            base,
            rules,
            checks,
            provider,
            model,
            effort,
        } => {
            post(
                cli,
                "/v1/gates/enable",
                json!({"thread": thread, "project": project, "base": base, "rules": rules, "checks": checks,
                       "provider": provider, "model": model, "effort": effort}),
            )
            .await?
        }
    }))
}

// MARK: draw

/// Pearl, light (docs/design/README.md#pearl-and-the-soap-film-agent).
const PAPER: &str = "#F5F5F2";
const INK: &str = "#1C1D22";
const IDLE: &str = "#8E8E95";
const WORKING: &str = "#6E56F0";
const SUCCESS: &str = "#2F9461";
const FAILURE: &str = "#D33A3A";
const FILL: &str = "#FFFFFF";

/// Phone width in points; rendered at 3×.
const W: f64 = 390.0;
const PAD: f64 = 20.0;

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Lines of `text` that fit `width` at `size` (an estimate of the system
/// font's advance, generous so nothing overflows).
fn wrap(text: &str, width: f64, size: f64) -> Vec<String> {
    let per_line = ((width / (size * 0.56)).floor() as usize).max(8);
    let mut lines = vec![];
    let mut line = String::new();
    for word in text.split_whitespace() {
        if !line.is_empty() && line.chars().count() + 1 + word.chars().count() > per_line {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

struct Svg {
    body: String,
    y: f64,
}

impl Svg {
    fn text(&mut self, x: f64, text: &str, size: f64, weight: u32, color: &str, width: f64) {
        for line in wrap(text, width, size) {
            self.y += size * 1.3;
            self.body.push_str(&format!(
                r#"<text x="{x}" y="{:.1}" font-size="{size}" font-weight="{weight}" fill="{color}">{}</text>"#,
                self.y - size * 0.3,
                escape(&line)
            ));
        }
    }
}

fn mark_style(mark: &str) -> (&'static str, &'static str, Option<&'static str>, bool) {
    // (stroke, fill, badge, dashed)
    match mark {
        "added" | "new" => (SUCCESS, "#EAF5EF", Some("NEW"), false),
        "moved" | "changed" => (WORKING, "#EFECFD", Some("MOVED"), false),
        "removed" => (IDLE, "#EFEFEC", Some("REMOVED"), true),
        "odd" => (FAILURE, "#FBEAEA", Some("ODD"), false),
        _ => (INK, FILL, None, false),
    }
}

/// The SVG for a draw spec, and its height in points.
pub(super) fn draw_svg(spec: &Value) -> Result<(String, f64)> {
    let kind = spec["kind"].as_str().unwrap_or("now");
    ensure!(
        matches!(kind, "now" | "proposed" | "problem"),
        "kind is now, proposed or problem"
    );
    let title = spec["title"].as_str().context("A picture needs a title")?;
    let mut svg = Svg {
        body: String::new(),
        y: PAD,
    };
    let inner = W - 2.0 * PAD;
    svg.text(PAD, title, 19.0, 700, INK, inner);
    if let Some(text) = spec["text"].as_str() {
        svg.y += 4.0;
        svg.text(PAD, text, 14.0, 400, "#5A5B62", inner);
    }
    svg.y += 14.0;
    if kind == "problem" {
        for (key, label, color) in [
            ("did", "YOU DID", INK),
            ("does", "THE APP DOES", FAILURE),
            ("should", "IT SHOULD", SUCCESS),
        ] {
            let Some(text) = spec[key].as_str() else {
                bail!("A problem picture needs did, does and should");
            };
            let top = svg.y;
            let lines = wrap(text, inner - 28.0, 15.0).len() as f64;
            let height = 8.0 + 14.3 + lines * 19.5 + 14.0;
            svg.body.push_str(&format!(
                r#"<rect x="{PAD}" y="{top}" width="{inner}" height="{height:.1}" rx="12" fill="{FILL}" stroke="{color}" stroke-width="1.5"/>"#
            ));
            svg.y = top + 8.0;
            svg.text(PAD + 14.0, label, 11.0, 700, color, inner - 28.0);
            svg.text(PAD + 14.0, text, 15.0, 400, INK, inner - 28.0);
            svg.y = top + height + 10.0;
        }
        return Ok((svg.body, svg.y + PAD));
    }
    let boxes = spec["boxes"]
        .as_array()
        .context("A now or proposed picture needs boxes")?;
    ensure!(!boxes.is_empty(), "boxes is empty");
    let arrows = spec["arrows"].as_array().cloned().unwrap_or_default();
    let id = |b: &Value| {
        b["id"]
            .as_str()
            .or(b["name"].as_str())
            .unwrap_or("")
            .to_string()
    };
    let ids: Vec<String> = boxes.iter().map(id).collect();
    for a in &arrows {
        for end in ["from", "to"] {
            let name = a[end].as_str().unwrap_or("");
            ensure!(
                ids.iter().any(|i| i == name),
                "An arrow's {end} names no box: {name}"
            );
        }
    }
    // Boxes in a column, the gaps wide enough for the arrows' labels; arrows
    // between neighbours run straight down, others along the right edge.
    let box_w = inner - 36.0;
    let mut tops = vec![];
    let mut bottoms = vec![];
    for (i, b) in boxes.iter().enumerate() {
        let name = b["name"].as_str().unwrap_or(&ids[i]);
        let note = b["note"].as_str().unwrap_or("");
        let (stroke, fill, badge, dashed) = mark_style(b["mark"].as_str().unwrap_or(""));
        let lines = wrap(note, box_w - 24.0, 12.5).len() as f64;
        let height = 34.0 + lines * 16.0 + if note.is_empty() { -4.0 } else { 6.0 };
        let top = svg.y;
        let dash = if dashed {
            r#" stroke-dasharray="6 4""#
        } else {
            ""
        };
        svg.body.push_str(&format!(
            r#"<rect x="{PAD}" y="{top}" width="{box_w}" height="{height:.1}" rx="10" fill="{fill}" stroke="{stroke}" stroke-width="1.8"{dash}/>"#
        ));
        if let Some(badge) = badge {
            let bw = badge.len() as f64 * 8.0 + 14.0;
            svg.body.push_str(&format!(
                r#"<rect x="{:.1}" y="{:.1}" width="{bw}" height="18" rx="5" fill="{stroke}"/><text x="{:.1}" y="{:.1}" font-size="10.5" font-weight="700" fill="white" text-anchor="middle">{badge}</text>"#,
                PAD + box_w - bw - 8.0,
                top - 9.0,
                PAD + box_w - 8.0 - bw / 2.0,
                top + 4.0
            ));
        }
        svg.y = top + 6.0;
        let name_color = if dashed { IDLE } else { INK };
        svg.text(PAD + 12.0, name, 15.0, 700, name_color, box_w - 24.0);
        if !note.is_empty() {
            svg.text(PAD + 12.0, note, 12.5, 400, "#5A5B62", box_w - 24.0);
        }
        if dashed {
            svg.body.push_str(&format!(
                r#"<line x1="{:.1}" y1="{:.1}" x2="{:.1}" y2="{:.1}" stroke="{IDLE}" stroke-width="1.5"/>"#,
                PAD + 10.0,
                top + 18.0,
                PAD + box_w - 10.0,
                top + 18.0
            ));
        }
        tops.push(top);
        bottoms.push(top + height);
        // Room for a label on the arrow down from this box.
        let label = arrows
            .iter()
            .find(|a| {
                a["from"].as_str() == Some(&ids[i])
                    && ids.get(i + 1).is_some_and(|n| a["to"].as_str() == Some(n))
            })
            .and_then(|a| a["label"].as_str());
        svg.y = top + height + if label.is_some() { 40.0 } else { 26.0 };
    }
    let mut lane = 0.0;
    for a in &arrows {
        let from = ids
            .iter()
            .position(|i| a["from"].as_str() == Some(i))
            .expect("checked");
        let to = ids
            .iter()
            .position(|i| a["to"].as_str() == Some(i))
            .expect("checked");
        let odd = a["mark"].as_str() == Some("odd");
        let color = if odd { FAILURE } else { INK };
        let label = a["label"].as_str().unwrap_or("");
        if to == from + 1 {
            let x = PAD + 40.0;
            let (y1, y2) = (bottoms[from], tops[to]);
            svg.body.push_str(&format!(
                r#"<line x1="{x}" y1="{y1:.1}" x2="{x}" y2="{:.1}" stroke="{color}" stroke-width="1.6" marker-end="url(#{})"/>"#,
                y2 - 2.0,
                if odd { "headr" } else { "head" }
            ));
            if !label.is_empty() {
                svg.body.push_str(&format!(
                    r#"<text x="{:.1}" y="{:.1}" font-size="12" fill="{color}">{}</text>"#,
                    x + 10.0,
                    (y1 + y2) / 2.0 + 4.0,
                    escape(label)
                ));
            }
        } else {
            lane += 1.0;
            let x = PAD + box_w + 6.0 + lane * 5.0;
            let (y1, y2) = (
                (tops[from] + bottoms[from]) / 2.0,
                (tops[to] + bottoms[to]) / 2.0,
            );
            svg.body.push_str(&format!(
                r#"<path d="M{:.1} {y1:.1} H{x:.1} V{y2:.1} H{:.1}" fill="none" stroke="{color}" stroke-width="1.6" marker-end="url(#{})"/>"#,
                PAD + box_w,
                PAD + box_w + 2.0,
                if odd { "headr" } else { "head" }
            ));
            if !label.is_empty() {
                svg.body.push_str(&format!(
                    r#"<text x="{:.1}" y="{:.1}" font-size="11" fill="{color}" text-anchor="end">{}</text>"#,
                    PAD + box_w - 6.0,
                    tops[to] - 14.0,
                    escape(label)
                ));
            }
        }
    }
    Ok((svg.body, svg.y + PAD - 10.0))
}

fn chrome() -> Result<PathBuf> {
    [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|p| p.is_file())
    .context("squircle draw renders with headless Chrome; install Google Chrome")
}

pub(super) async fn draw(spec: &std::path::Path, out: Option<&PathBuf>) -> Result<Option<Value>> {
    let text =
        std::fs::read_to_string(spec).with_context(|| format!("Reading {}", spec.display()))?;
    let spec_value: Value = serde_json::from_str(&text).context("The spec is JSON")?;
    let (body, height) = draw_svg(&spec_value)?;
    let height = height.ceil();
    let svg = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" viewBox="0 0 {W} {height}" font-family="-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"><defs><marker id="head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="{INK}"/></marker><marker id="headr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="{FAILURE}"/></marker></defs><rect width="100%" height="100%" fill="{PAPER}"/>{body}</svg>"#
    );
    let out = match out {
        Some(out) => std::path::absolute(out)?,
        None => std::path::absolute(spec.with_extension("png"))?,
    };
    let page = out.with_extension("svg");
    std::fs::write(&page, &svg)?;
    let status = tokio::process::Command::new(chrome()?)
        .args([
            "--headless",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=3",
            &format!("--window-size={},{}", W as u32, height as u32),
            &format!("--screenshot={}", out.display()),
        ])
        .arg(
            url::Url::from_file_path(&page)
                .map_err(|_| anyhow::anyhow!("bad path"))?
                .as_str(),
        )
        .output()
        .await?;
    let _ = std::fs::remove_file(&page);
    ensure!(
        status.status.success() && out.is_file(),
        "Chrome didn't render the picture: {}",
        String::from_utf8_lossy(&status.stderr)
            .lines()
            .last()
            .unwrap_or("")
    );
    Ok(Some(success(json!({
        "picture": out,
        "next": "Look at it before handing it in. Reference it from plan.md as ![what it shows](pictures/NAME.png), relative to plan.md.",
    }))))
}
