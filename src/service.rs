//! `squircle service install|start|restart|stop|uninstall`: controls the
//! `squircle serve` running for a data directory, found through its lock
//! (`service.lock` holds its PID).
//!
//! Installed, the service is a launchd user agent (`dev.squircle.service`,
//! RunAtLoad, kept alive unless it stopped cleanly), so it comes back after a
//! reboot or a crash. Install copies the running service's serve arguments
//! and environment (or builds them for this binary) into the plist, hands the
//! running service's sessions over to launchd's, and from then on restart is
//! launchd's `kickstart -k` (still SIGTERM, still a handover).
//!
//! macOS's privacy protection (TCC) keeps background jobs out of ~/Documents,
//! ~/Desktop and the like unless their program has Full Disk Access; launchd
//! itself can't even open a log there for the job (it fails the spawn with
//! EX_CONFIG). So launchd runs a copy of the binary from the service's own
//! folder (`~/Library/Application Support/dev.squircle.service`), signed with
//! the Mac's Apple Development identity under the fixed identifier
//! `dev.squircle.service`: TCC keys a grant on that signature, so one grant
//! survives rebuilds. launchd opens nothing in the data directory (the
//! service opens its own log, `serve --log`), and every install, restart and
//! start first runs the copy once as a launchd job (`service check`): if it
//! can't read the data directory the command says what to grant and leaves
//! the running service alone.
//!
//! A restart sends SIGTERM, on which the service hands its simulator sessions
//! over instead of ending them, then re-runs the service's own command line,
//! environment and working directory (read from the kernel), so a binary
//! rebuilt at the same path takes over and adopts them. It builds nothing.
//! A stop sends SIGINT, on which the service ends them.

use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, OsString},
    fs::{File, OpenOptions},
    os::unix::ffi::OsStringExt,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

/// How a process was started: enough to start it again the same way.
#[derive(Debug, PartialEq)]
pub struct Invocation {
    pub argv: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub cwd: PathBuf,
}

/// The PID of the service holding `root`'s lock, if one runs.
pub fn holder(root: &Path) -> Result<Option<u32>> {
    let path = root.join("service.lock");
    let file = match File::open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).context("Cannot read the service lock"),
    };
    // The kernel holds the lock exactly while its owner runs.
    if file.try_lock().is_ok() {
        return Ok(None);
    }
    let pid = std::fs::read_to_string(&path)?;
    Ok(Some(pid.trim().parse().with_context(|| {
        format!("The service lock names no process ({pid:?}); it may be starting")
    })?))
}

/// Restarts the running service; returns once the new one answers.
pub async fn restart(root: &Path, server: &str) -> Result<Value> {
    let loaded = job().await;
    let launchd_runs =
        |old: Option<u32>| old.is_none() || loaded.as_ref().is_some_and(|job| job.pid == old);
    // A service started by hand beside a loaded job restarts by hand.
    if loaded.is_some() && launchd_runs(holder(root)?) {
        let root = std::path::absolute(root)?;
        let old = holder(&root)?;
        // A binary rebuilt at the source path takes over, as without launchd.
        let record = Record::load()?.context(
            "launchd's service was installed by an older squircle; run squircle service install",
        )?;
        let record = refresh(&record.source, record.identity.as_deref()).await?;
        check(&root, &record).await?;
        launchctl(&["kickstart", "-k", &target()]).await?;
        let pid = launched(&root, server, old).await?;
        return Ok(
            json!({"previous_pid": old, "pid": pid, "launchd": label(), "program": program(), "source": record.source, "log": root.join("serve.log"),
                         "next": "Simulator sessions were handed over; squircle sim status shows them."}),
        );
    }
    let old = holder(root)?.context(
        "No Squircle service is running for this data directory; start one with squircle serve",
    )?;
    let invocation = invocation(old)?;
    ensure!(
        invocation.argv.iter().any(|a| a == "serve"),
        "Process {old} holds the lock but is not squircle serve"
    );
    let program = invocation.cwd.join(
        invocation
            .argv
            .first()
            .context("The service has no command line")?,
    );
    let log_path = std::path::absolute(root.join("serve.log"))?;
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .context("Cannot open the service log")?;

    signal(old, libc::SIGTERM)?;
    exited(old).await;
    let from = std::fs::metadata(&log_path).map(|m| m.len()).unwrap_or(0);
    let mut child = tokio::process::Command::new(&program)
        .args(&invocation.argv[1..])
        .env_clear()
        .envs(invocation.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&invocation.cwd)
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        // Not in this command's process group: it outlives it.
        .process_group(0)
        .spawn()
        .with_context(|| format!("Cannot start {}", program.display()))?;
    let new = child.id().context("The new service exited at once")?;
    // It announces itself once it holds the lock and listens, or exits.
    tokio::select! {
        status = child.wait() => {
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            let tail: Vec<&str> = log.lines().rev().take(15).collect();
            bail!(
                "The new service exited ({}); simulator sessions stay in the ledger for the next start. Log:\n{}",
                status?,
                tail.into_iter().rev().collect::<Vec<_>>().join("\n")
            );
        }
        listening = announced(&log_path, from) => listening?,
    }
    ensure!(
        holder(root)? == Some(new),
        "Another process took the service lock from the new service ({new})"
    );
    Ok(
        json!({"previous_pid": old, "pid": new, "program": program, "log": log_path,
              "next": "Simulator sessions were handed over; squircle sim status shows them."}),
    )
}

/// Stops the running service, ending its simulator sessions. Installed, it
/// stays stopped (a clean exit) until `service start` or the next login.
pub async fn stop(root: &Path) -> Result<Value> {
    let pid = holder(root)?.context("No Squircle service is running for this data directory")?;
    signal(pid, libc::SIGINT)?;
    exited(pid).await;
    Ok(json!({"stopped_pid": pid, "launchd": job().await.map(|_| label())}))
}

// MARK: launchd

pub const LABEL: &str = "dev.squircle.service";

/// launchd's label: `SQUIRCLE_SERVICE_LABEL` installs a second service (for
/// another data directory) beside the usual one.
pub fn label() -> String {
    std::env::var("SQUIRCLE_SERVICE_LABEL")
        .ok()
        .filter(|l| !l.is_empty())
        .unwrap_or_else(|| LABEL.into())
}

/// Environment the service needs, copied into the plist; launchd gives a
/// bare one otherwise (no Homebrew or user tools on PATH).
fn wanted(key: &std::ffi::OsStr) -> bool {
    let key = key.to_string_lossy();
    [
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "LANG",
        "DEVELOPER_DIR",
        "RUST_LOG",
        "RUST_BACKTRACE",
    ]
    .contains(&key.as_ref())
        || key.starts_with("LC_")
        || (key.starts_with("SQUIRCLE_") && key != "SQUIRCLE_DATA_DIR")
}

fn plist_path() -> Result<PathBuf> {
    Ok(dirs::home_dir()
        .context("No home directory")?
        .join("Library/LaunchAgents")
        .join(format!("{}.plist", label())))
}

/// The service's own folder, outside anything TCC protects: the signed
/// binary launchd runs, its working directory and launchd's own log.
fn folder() -> Result<PathBuf> {
    Ok(dirs::data_dir()
        .context("No Application Support folder")?
        .join(label()))
}

/// The binary launchd runs.
fn program() -> PathBuf {
    folder().unwrap_or_default().join("squircle")
}

fn domain() -> String {
    format!("gui/{}", unsafe { libc::getuid() })
}

fn target() -> String {
    format!("{}/{}", domain(), label())
}

async fn launchctl(args: &[&str]) -> Result<String> {
    let output = tokio::process::Command::new("/bin/launchctl")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .await
        .context("Cannot run launchctl")?;
    ensure!(
        output.status.success(),
        "launchctl {} failed: {}{}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr).trim(),
        String::from_utf8_lossy(&output.stdout).trim()
    );
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// launchd's job, if loaded: its PID while running, and its last exit status.
#[derive(Debug, PartialEq)]
struct Job {
    pid: Option<u32>,
    last_exit: Option<i64>,
}

async fn job() -> Option<Job> {
    job_named(&target()).await
}

async fn job_named(target: &str) -> Option<Job> {
    Some(parse_job(&launchctl(&["print", target]).await.ok()?))
}

/// `launchctl print`'s fields: `pid = 123`, `last exit code = 78: EX_CONFIG`
/// (or `(never exited)`).
fn parse_job(printed: &str) -> Job {
    let field = |name: &str| {
        printed.lines().find_map(|l| {
            let value = l.trim().strip_prefix(name)?.trim();
            let digits = value
                .char_indices()
                .take_while(|(i, c)| c.is_ascii_digit() || (*i == 0 && *c == '-'))
                .count();
            value[..digits].parse::<i64>().ok()
        })
    };
    Job {
        pid: field("pid = ").map(|p| p as u32),
        last_exit: field("last exit code = "),
    }
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// A user agent's plist running `invocation`, with launchd's own output
/// (anything before the program opens its log) going to `log`. `keep_alive`:
/// started at load and brought back unless it exited cleanly; otherwise it
/// runs once.
pub fn plist(label: &str, invocation: &Invocation, log: &Path, keep_alive: bool) -> String {
    let string = |s: &std::ffi::OsStr| format!("<string>{}</string>", escape(&s.to_string_lossy()));
    let args: Vec<String> = invocation.argv.iter().map(|a| string(a)).collect();
    let env: Vec<String> = invocation
        .env
        .iter()
        .map(|(k, v)| format!("<key>{}</key>{}", escape(&k.to_string_lossy()), string(v)))
        .collect();
    let keep = if keep_alive {
        "<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>\n<key>ThrottleInterval</key><integer>10</integer>\n"
    } else {
        ""
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>Label</key>{}
<key>ProgramArguments</key><array>{}</array>
<key>EnvironmentVariables</key><dict>{}</dict>
<key>WorkingDirectory</key>{}
<key>StandardOutPath</key>{}
<key>StandardErrorPath</key>{}
<key>RunAtLoad</key><true/>
{keep}</dict>
</plist>
"#,
        string(label.as_ref()),
        args.join(""),
        env.join(""),
        string(invocation.cwd.as_os_str()),
        string(log.as_os_str()),
        string(log.as_os_str()),
    )
}

/// What install chose, kept beside the binary so restart can refresh it:
/// the binary it copies and the identity it signs with.
#[derive(serde::Serialize, serde::Deserialize)]
struct Record {
    source: PathBuf,
    /// The signing identity's SHA-1; none when the Mac has none (ad hoc).
    identity: Option<String>,
    identity_name: Option<String>,
}

impl Record {
    fn path() -> Result<PathBuf> {
        Ok(folder()?.join("service.json"))
    }

    fn load() -> Result<Option<Self>> {
        match std::fs::read(Self::path()?) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e).context("Cannot read the service record"),
        }
    }
}

/// Valid code-signing identities, in `security`'s order: (SHA-1, name).
async fn identities() -> Vec<(String, String)> {
    let Ok(output) = tokio::process::Command::new("/usr/bin/security")
        .args(["find-identity", "-v", "-p", "codesigning"])
        .stdin(Stdio::null())
        .output()
        .await
    else {
        return Vec::new();
    };
    parse_identities(&String::from_utf8_lossy(&output.stdout))
}

fn parse_identities(listed: &str) -> Vec<(String, String)> {
    listed
        .lines()
        .filter_map(|l| {
            let (_, rest) = l.trim().split_once(") ")?;
            let (hash, name) = rest.split_once(' ')?;
            let name = name.trim().strip_prefix('"')?.strip_suffix('"')?;
            (hash.len() == 40).then(|| (hash.to_string(), name.to_string()))
        })
        .collect()
}

/// Copies `source` into the service's folder and signs it, keeping the
/// identity used before (a grant names it) unless it's gone.
async fn refresh(source: &Path, identity: Option<&str>) -> Result<Record> {
    let folder = folder()?;
    std::fs::create_dir_all(&folder)?;
    let available = identities().await;
    let chosen = identity
        .and_then(|id| available.iter().find(|(hash, _)| hash == id))
        .or_else(|| {
            ["Apple Development:", "Developer ID Application:"]
                .iter()
                .find_map(|kind| available.iter().find(|(_, name)| name.starts_with(kind)))
        })
        .cloned();
    let draft = folder.join("squircle.new");
    let _ = std::fs::remove_file(&draft);
    std::fs::copy(source, &draft)
        .with_context(|| format!("Cannot copy {} into the service's folder", source.display()))?;
    let output = tokio::process::Command::new("/usr/bin/codesign")
        .args([
            "--force",
            "--timestamp=none",
            "--identifier",
            LABEL,
            "--sign",
        ])
        .arg(chosen.as_ref().map_or("-", |(hash, _)| hash.as_str()))
        .arg(&draft)
        .stdin(Stdio::null())
        .output()
        .await
        .context("Cannot run codesign")?;
    ensure!(
        output.status.success(),
        "codesign failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    std::fs::rename(&draft, program())?;
    let record = Record {
        source: source.to_path_buf(),
        identity: chosen.as_ref().map(|(hash, _)| hash.clone()),
        identity_name: chosen.map(|(_, name)| name),
    };
    std::fs::write(Record::path()?, serde_json::to_vec_pretty(&record)?)?;
    Ok(record)
}

/// `service check`: what a launchd job of this binary must be able to do in
/// the data directory. Run as one (see `check`), it fails where TCC keeps
/// background jobs out.
pub fn check_access(root: &Path) -> Result<Value> {
    std::fs::read_dir(root)
        .with_context(|| format!("Cannot list {}", root.display()))?
        .next();
    File::open(root.join("config.json"))
        .with_context(|| format!("Cannot read {}", root.join("config.json").display()))?;
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("serve.log"))
        .with_context(|| format!("Cannot open {}", root.join("serve.log").display()))?;
    Ok(json!({"data_dir": root, "readable": true}))
}

/// Runs the installed binary once as a launchd job, `service check` against
/// `root`, before anything stops the running service.
async fn check(root: &Path, record: &Record) -> Result<()> {
    let folder = folder()?;
    let label = format!("{}.check", label());
    let target = format!("{}/{label}", domain());
    let log = folder.join("check.log");
    let _ = std::fs::remove_file(&log);
    let invocation = Invocation {
        argv: vec![
            program().into(),
            "--data-dir".into(),
            root.into(),
            "service".into(),
            "check".into(),
        ],
        env: std::env::vars_os().filter(|(k, _)| wanted(k)).collect(),
        cwd: folder.clone(),
    };
    let path = folder.join(format!("{label}.plist"));
    std::fs::write(&path, plist(&label, &invocation, &log, false))?;
    if job_named(&target).await.is_some() {
        launchctl(&["bootout", &target]).await?;
    }
    launchctl(&["bootstrap", &domain(), &path.to_string_lossy()]).await?;
    // It runs once, at load; launchd reports its exit (78 if it couldn't
    // spawn). It blocks while macOS asks the user about the folder.
    let began = std::time::Instant::now();
    let mut told = false;
    let code = loop {
        match job_named(&target).await {
            Some(Job {
                pid: None,
                last_exit: Some(code),
            }) => break code,
            None => bail!("launchd dropped the check job"),
            _ => {}
        }
        if !told && began.elapsed() > Duration::from_secs(2) {
            told = true;
            eprintln!(
                "Waiting for macOS: if the Mac asks whether \"squircle\" may access a folder, click Allow (it lasts across rebuilds). Or grant Full Disk Access to {} in System Settings → Privacy & Security.",
                program().display()
            );
        }
        // launchd tells a job's state only to `launchctl print`.
        crate::clock::after(Duration::from_millis(100)).await;
    };
    launchctl(&["bootout", &target]).await?;
    let _ = std::fs::remove_file(&path);
    if code == 0 {
        return Ok(());
    }
    let said = std::fs::read_to_string(&log).unwrap_or_default();
    // EPERM: declined, or Full Disk Access only; EINTR: macOS's prompt went
    // unanswered until it timed out (about half an hour); 78: launchd itself
    // was kept out.
    let denied = said.contains("(os error 1)") || said.contains("(os error 4)") || code == 78;
    let signed = match &record.identity_name {
        Some(name) => format!(
            "It is signed as {LABEL} by \"{name}\", so the grant lasts across rebuilds and reinstalls."
        ),
        None => "No signing identity was found, so it is signed ad hoc and every rebuild needs the grant again; with an Apple Development certificate in the login keychain it wouldn't.".into(),
    };
    if denied {
        bail!(
            "launchd's service can't open the data directory {}: macOS keeps background services out of Documents, Desktop, Downloads and iCloud Drive unless they're allowed (its prompt was declined or never answered).\nGrant it once: System Settings → Privacy & Security → Full Disk Access → + → press ⌘⇧G, paste {} → Open, and leave it switched on. {signed}\nThen run this command again. The running service was left as it was.\n{}",
            root.display(),
            program().display(),
            said.trim()
        );
    }
    let said = match said.trim() {
        "" => format!(
            "It wrote nothing to {}{}; launchd's side: log show --last 10m --predicate 'eventMessage CONTAINS \"{label}\"'",
            log.display(),
            if code == 101 {
                " (101 is a Rust panic)"
            } else {
                ""
            }
        ),
        said => said.to_string(),
    };
    bail!(
        "The installed binary failed its launchd check (exit {code}); the running service was left as it was.\n{said}"
    )
}

/// Waits until a service other than `old` holds the lock and answers;
/// fails with the log's tail if launchd's job exits instead.
async fn launched(root: &Path, server: &str, old: Option<u32>) -> Result<u32> {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let health = format!("{}/health", server.trim_end_matches('/'));
    loop {
        if let Some(pid) = holder(root).ok().flatten().filter(|p| Some(*p) != old)
            && client
                .get(&health)
                .send()
                .await
                .is_ok_and(|r| r.status().is_success())
        {
            return Ok(pid);
        }
        if let Some(job) = job().await
            && job.pid.is_none()
            && job.last_exit.is_some_and(|code| code != 0)
            && holder(root).ok().flatten().is_none_or(|p| Some(p) == old)
        {
            let mut log = std::fs::read_to_string(root.join("serve.log")).unwrap_or_default();
            log += &std::fs::read_to_string(folder()?.join("launchd.log")).unwrap_or_default();
            let tail: Vec<&str> = log.lines().rev().take(15).collect();
            bail!(
                "launchd's service exited (status {}); simulator sessions stay in the ledger. Log:\n{}",
                job.last_exit.unwrap_or_default(),
                tail.into_iter().rev().collect::<Vec<_>>().join("\n")
            );
        }
        // launchd tells a job's state only to `launchctl print`.
        crate::clock::after(Duration::from_millis(200)).await;
    }
}

/// serve's own arguments from a command line (what follows `serve`), minus
/// the data directory and log the plist sets itself.
fn serve_args(argv: &[OsString]) -> Vec<OsString> {
    let mut rest = argv
        .iter()
        .skip_while(|a| *a != "serve")
        .skip(1)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter();
    let mut kept = Vec::new();
    while let Some(arg) = rest.next() {
        let text = arg.to_string_lossy();
        if text == "--data-dir" || text == "--log" {
            rest.next();
        } else if !(text.starts_with("--data-dir=") || text.starts_with("--log=")) {
            kept.push(arg);
        }
    }
    kept
}

/// Installs the service as a launchd user agent and starts it there,
/// handing the running service's simulator sessions over. `serve_args`
/// replace the running service's own (`--listen`, `--public-url`).
pub async fn install(root: &Path, server: &str, args: Vec<String>) -> Result<Value> {
    let root = std::path::absolute(root)?;
    let running = holder(&root)?;
    let previous = Record::load()?;
    let (source, env, mut serve) = match running {
        Some(pid) => {
            let invocation = invocation(pid)?;
            ensure!(
                invocation.argv.iter().any(|a| a == "serve"),
                "Process {pid} holds the lock but is not squircle serve"
            );
            let program = invocation.cwd.join(&invocation.argv[0]);
            let program = program.canonicalize().unwrap_or(program);
            // launchd's copy came from the binary it was installed from.
            let source = match &previous {
                Some(record) if program == self::program() => record.source.clone(),
                _ => program,
            };
            (source, invocation.env, serve_args(&invocation.argv))
        }
        None => (
            std::env::current_exe()?.canonicalize()?,
            std::env::vars_os().collect(),
            Vec::new(),
        ),
    };
    if !args.is_empty() {
        serve = args.into_iter().map(OsString::from).collect();
    }
    let record = refresh(
        &source,
        previous.as_ref().and_then(|r| r.identity.as_deref()),
    )
    .await?;
    check(&root, &record).await?;

    let log = root.join("serve.log");
    let mut argv: Vec<OsString> = vec![
        program().into(),
        "--data-dir".into(),
        root.clone().into(),
        "serve".into(),
        "--log".into(),
        log.clone().into(),
    ];
    argv.extend(serve);
    let invocation = Invocation {
        argv,
        env: env.into_iter().filter(|(k, _)| wanted(k)).collect(),
        cwd: folder()?,
    };
    let path = plist_path()?;
    std::fs::create_dir_all(path.parent().context("No LaunchAgents folder")?)?;
    let draft = path.with_extension("plist.new");
    std::fs::write(
        &draft,
        plist(&label(), &invocation, &folder()?.join("launchd.log"), true),
    )?;
    std::fs::rename(&draft, &path)?;

    // One service at a time: the old one hands its sessions over first.
    // A loaded job needn't be the one running: after a reboot an older
    // install's job can sit failing to spawn while a hand-started service
    // holds the lock, and bootout only stops launchd's own process.
    let loaded = job().await;
    if loaded.is_some() {
        launchctl(&["bootout", &target()]).await?;
    }
    if let Some(pid) = running {
        if loaded.and_then(|job| job.pid) != Some(pid) {
            signal(pid, libc::SIGTERM)?;
        }
        exited(pid).await;
    }
    launchctl(&["bootstrap", &domain(), &path.to_string_lossy()]).await?;
    let pid = launched(&root, server, running).await?;
    Ok(
        json!({"label": label(), "plist": path, "pid": pid, "previous_pid": running, "log": log,
              "program": program(), "source": record.source, "signed_by": record.identity_name,
              "command": invocation.argv.iter().map(|a| a.to_string_lossy()).collect::<Vec<_>>(), "next": "launchd now starts the service at login and after a crash; squircle service restart copies a rebuilt binary from the source path and hands over; restart|stop|start control it."}),
    )
}

/// Starts the installed service (after `service stop`).
pub async fn start(root: &Path, server: &str) -> Result<Value> {
    ensure!(
        job().await.is_some(),
        "The service isn't installed with launchd; run squircle service install (or squircle serve)"
    );
    let root = std::path::absolute(root)?;
    if let Some(pid) = holder(&root)? {
        return Ok(json!({"pid": pid, "already_running": true}));
    }
    if let Some(record) = Record::load()? {
        check(&root, &record).await?;
    }
    launchctl(&["kickstart", &target()]).await?;
    Ok(json!({"pid": launched(&root, server, None).await?, "launchd": label()}))
}

/// Removes the launchd user agent, stopping the service it runs (ending its
/// sessions), and the service's folder.
pub async fn uninstall(root: &Path) -> Result<Value> {
    let path = plist_path()?;
    let running = holder(root)?;
    if job().await.is_some() {
        // launchd's SIGTERM would hand over to a next run that won't come.
        if let Some(pid) = running {
            signal(pid, libc::SIGINT)?;
            exited(pid).await;
        }
        launchctl(&["bootout", &target()]).await?;
    }
    let removed = match std::fs::remove_file(&path) {
        Ok(()) => true,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(e) => return Err(e).context("Cannot remove the launchd plist"),
    };
    let folder = folder()?;
    if folder.is_dir() {
        std::fs::remove_dir_all(&folder)?;
    }
    Ok(
        json!({"label": label(), "plist_removed": removed, "stopped_pid": running,
              "next": format!("Start the service yourself with squircle serve. Its Full Disk Access entry ({}) can be removed in System Settings.", program().display())}),
    )
}

/// Sends this process's stdout and stderr to the end of `path`.
pub fn log_to(path: &Path) -> Result<()> {
    use std::os::fd::AsRawFd;
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("Cannot open the service log {}", path.display()))?;
    for fd in [libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        ensure!(
            unsafe { libc::dup2(file.as_raw_fd(), fd) } == fd,
            "Cannot redirect output to {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        );
    }
    Ok(())
}

fn signal(pid: u32, signal: libc::c_int) -> Result<()> {
    ensure!(
        unsafe { libc::kill(pid as i32, signal) } == 0,
        "Cannot signal process {pid}: {}",
        std::io::Error::last_os_error()
    );
    Ok(())
}

/// Waits for `pid` to exit, as the kernel reports it; the service bounds
/// its own wind-down.
async fn exited(pid: u32) {
    if let Err(error) = crate::kq::exited(pid).await {
        eprintln!("Cannot watch process {pid}: {error}");
    }
}

/// Resolves once `log` has, past its first `from` bytes, the line the
/// service prints when it listens. The log's own writes wake this.
async fn announced(log: &Path, from: u64) -> Result<()> {
    use std::io::{Read, Seek};
    let changes = crate::kq::Changes::watch(log)?;
    let mut file = File::open(log)?;
    file.seek(std::io::SeekFrom::Start(from))?;
    let mut said = Vec::new();
    loop {
        file.read_to_end(&mut said)?;
        if String::from_utf8_lossy(&said)
            .lines()
            .any(|line| line.starts_with(crate::server::LISTENING))
        {
            return Ok(());
        }
        changes.next().await?;
    }
}

/// `pid`'s command line, environment and working directory.
fn invocation(pid: u32) -> Result<Invocation> {
    let (argv, env) = process_args(pid)?;
    invocation_with(pid, argv, env)
}

/// `pid`'s arguments, read from the kernel (no `ps`, nothing waited for).
pub(crate) fn arguments(pid: u32) -> Result<Vec<OsString>> {
    Ok(process_args(pid)?.0)
}

fn process_args(pid: u32) -> Result<ProcessArgs> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid as libc::c_int];
    let mut size: libc::size_t = 0;
    let sized = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    ensure!(
        sized == 0,
        "Cannot read process {pid}'s arguments: {}",
        std::io::Error::last_os_error()
    );
    let mut raw = vec![0u8; size];
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            raw.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    ensure!(
        read == 0,
        "Cannot read process {pid}'s arguments: {}",
        std::io::Error::last_os_error()
    );
    raw.truncate(size);
    parse_procargs(&raw)
}

fn invocation_with(
    pid: u32,
    argv: Vec<OsString>,
    env: Vec<(OsString, OsString)>,
) -> Result<Invocation> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let length = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let got = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            (&raw mut info).cast(),
            length,
        )
    };
    ensure!(
        got == length,
        "Cannot read process {pid}'s working directory: {}",
        std::io::Error::last_os_error()
    );
    let cwd = unsafe { CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr().cast()) };
    Ok(Invocation {
        argv,
        env,
        cwd: PathBuf::from(OsString::from_vec(cwd.to_bytes().to_vec())),
    })
}

/// `KERN_PROCARGS2`: argc, the executable path and NUL padding, then argc
/// arguments and the environment, each NUL-terminated; an empty string ends
/// the environment (the kernel's own strings follow).
type ProcessArgs = (Vec<OsString>, Vec<(OsString, OsString)>);

fn parse_procargs(raw: &[u8]) -> Result<ProcessArgs> {
    ensure!(raw.len() >= 4, "Truncated process arguments");
    let argc = i32::from_ne_bytes(raw[..4].try_into()?) as usize;
    let mut strings = raw[4..].split(|b| *b == 0);
    strings.next().context("No executable path")?;
    let mut strings = strings.skip_while(|s| s.is_empty());
    let argv: Vec<OsString> = strings
        .by_ref()
        .take(argc)
        .map(|s| OsString::from_vec(s.to_vec()))
        .collect();
    ensure!(argv.len() == argc, "Truncated process arguments");
    let env = strings
        .take_while(|s| !s.is_empty())
        .filter_map(|s| {
            let at = s.iter().position(|b| *b == b'=')?;
            Some((
                OsString::from_vec(s[..at].to_vec()),
                OsString::from_vec(s[at + 1..].to_vec()),
            ))
        })
        .collect();
    Ok((argv, env))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The kernel's layout, including an empty argument, padding and the
    /// strings after the environment that must not become variables.
    #[test]
    fn procargs_split_arguments_from_environment() {
        let mut raw = 3i32.to_ne_bytes().to_vec();
        raw.extend_from_slice(
            b"./squircle\0\0\0\0./squircle\0serve\0\0A=1=2\0B=\0\0executable_path=x\0\0",
        );
        let (argv, env) = parse_procargs(&raw).unwrap();
        assert_eq!(argv, ["./squircle", "serve", ""]);
        assert_eq!(env, [("A".into(), "1=2".into()), ("B".into(), "".into())]);
    }

    /// launchd prints the exit with its name, or `(never exited)`.
    #[test]
    fn reads_launchd_exit_codes() {
        let failed = "\tstate = not running\n\tlast exit code = 78: EX_CONFIG\n";
        assert_eq!(
            parse_job(failed),
            Job {
                pid: None,
                last_exit: Some(78)
            }
        );
        let running = "\tpid = 396\n\tlast exit code = (never exited)\n";
        assert_eq!(
            parse_job(running),
            Job {
                pid: Some(396),
                last_exit: None
            }
        );
    }

    /// The running service's serve arguments carry over; the data directory
    /// and log are the plist's own.
    #[test]
    fn keeps_only_serve_arguments() {
        let argv: Vec<OsString> = [
            "./squircle",
            "--data-dir",
            ".squircle",
            "serve",
            "--log",
            "x.log",
            "--public-url",
            "https://mac.test",
            "--data-dir=y",
            "--listen",
            "127.0.0.1:1",
        ]
        .map(OsString::from)
        .into();
        assert_eq!(
            serve_args(&argv),
            [
                "--public-url",
                "https://mac.test",
                "--listen",
                "127.0.0.1:1"
            ]
        );
    }

    /// This test process reads back as itself.
    #[test]
    fn reads_a_running_process() {
        let own = invocation(std::process::id()).unwrap();
        assert_eq!(own.cwd, std::env::current_dir().unwrap());
        assert_eq!(own.argv, std::env::args_os().collect::<Vec<_>>());
        assert!(own.env.iter().any(|(k, _)| k == "HOME"));
    }
}
