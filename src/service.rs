//! `squircle service install|start|restart|stop|uninstall`: controls the
//! `squircle serve` running for a data directory, found through its lock
//! (`service.lock` holds its PID).
//!
//! Installed, the service is a launchd user agent (`dev.squircle.service`,
//! RunAtLoad, kept alive unless it stopped cleanly), so it comes back after a
//! reboot or a crash. Install copies the running service's command line and
//! environment (or builds one for this binary) into the plist, hands the
//! running service's sessions over to launchd's, and from then on restart is
//! launchd's `kickstart -k` (still SIGTERM, still a handover).
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
    os::unix::{ffi::OsStringExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
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
    if job().await.is_some() {
        let old = holder(root)?;
        launchctl(&["kickstart", "-k", &target()]).await?;
        let pid = launched(root, server, old).await?;
        return Ok(
            json!({"previous_pid": old, "pid": pid, "launchd": LABEL, "log": root.join("serve.log"),
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
    let mut child = Command::new(&program)
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
    let new = child.id();
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let health = format!("{}/health", server.trim_end_matches('/'));
    loop {
        if let Some(status) = child.try_wait()? {
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            let tail: Vec<&str> = log.lines().rev().take(15).collect();
            bail!(
                "The new service exited ({status}); simulator sessions stay in the ledger for the next start. Log:\n{}",
                tail.into_iter().rev().collect::<Vec<_>>().join("\n")
            );
        }
        if holder(root).ok().flatten() == Some(new)
            && client
                .get(&health)
                .send()
                .await
                .is_ok_and(|r| r.status().is_success())
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
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
    Ok(json!({"stopped_pid": pid, "launchd": job().await.is_some().then_some(LABEL)}))
}

// MARK: launchd

pub const LABEL: &str = "dev.squircle.service";

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
        || key.starts_with("SQUIRCLE_")
}

fn plist_path() -> Result<PathBuf> {
    Ok(dirs::home_dir()
        .context("No home directory")?
        .join("Library/LaunchAgents")
        .join(format!("{LABEL}.plist")))
}

fn target() -> String {
    format!("gui/{}/{LABEL}", unsafe { libc::getuid() })
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
struct Job {
    pid: Option<u32>,
    last_exit: Option<i64>,
}

async fn job() -> Option<Job> {
    let printed = launchctl(&["print", &target()]).await.ok()?;
    let field = |name: &str| {
        printed
            .lines()
            .find_map(|l| l.trim().strip_prefix(name)?.trim().parse::<i64>().ok())
    };
    Some(Job {
        pid: field("pid = ").map(|p| p as u32),
        last_exit: field("last exit code = "),
    })
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The user agent's plist for `invocation`, logging to `log`.
pub fn plist(invocation: &Invocation, log: &Path) -> String {
    let string = |s: &std::ffi::OsStr| format!("<string>{}</string>", escape(&s.to_string_lossy()));
    let args: Vec<String> = invocation.argv.iter().map(|a| string(a)).collect();
    let env: Vec<String> = invocation
        .env
        .iter()
        .map(|(k, v)| format!("<key>{}</key>{}", escape(&k.to_string_lossy()), string(v)))
        .collect();
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>Label</key><string>{LABEL}</string>
<key>ProgramArguments</key><array>{}</array>
<key>EnvironmentVariables</key><dict>{}</dict>
<key>WorkingDirectory</key>{}
<key>StandardOutPath</key>{}
<key>StandardErrorPath</key>{}
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
"#,
        args.join(""),
        env.join(""),
        string(invocation.cwd.as_os_str()),
        string(log.as_os_str()),
        string(log.as_os_str()),
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
            let log = std::fs::read_to_string(root.join("serve.log")).unwrap_or_default();
            let tail: Vec<&str> = log.lines().rev().take(15).collect();
            bail!(
                "launchd's service exited (status {}); simulator sessions stay in the ledger. Log:\n{}",
                job.last_exit.unwrap_or_default(),
                tail.into_iter().rev().collect::<Vec<_>>().join("\n")
            );
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

/// Installs the service as a launchd user agent and starts it there,
/// handing the running service's simulator sessions over. `serve_args`
/// replace the running service's own (`--listen`, `--public-url`).
pub async fn install(root: &Path, server: &str, serve_args: Vec<String>) -> Result<Value> {
    let root = std::path::absolute(root)?;
    let running = holder(&root)?;
    let mut invocation = match running {
        Some(pid) if serve_args.is_empty() => {
            let mut invocation = invocation(pid)?;
            ensure!(
                invocation.argv.iter().any(|a| a == "serve"),
                "Process {pid} holds the lock but is not squircle serve"
            );
            let program = invocation.cwd.join(&invocation.argv[0]);
            invocation.argv[0] = program.canonicalize().unwrap_or(program).into();
            invocation
        }
        _ => {
            let exe = std::env::current_exe()?.canonicalize()?;
            let mut argv: Vec<OsString> = vec![
                exe.into(),
                "--data-dir".into(),
                root.clone().into(),
                "serve".into(),
            ];
            argv.extend(serve_args.into_iter().map(OsString::from));
            Invocation {
                argv,
                env: std::env::vars_os().collect(),
                cwd: std::env::current_dir()?,
            }
        }
    };
    invocation.env.retain(|(k, _)| wanted(k));
    let log = root.join("serve.log");
    let path = plist_path()?;
    std::fs::create_dir_all(path.parent().context("No LaunchAgents folder")?)?;
    let draft = path.with_extension("plist.new");
    std::fs::write(&draft, plist(&invocation, &log))?;
    std::fs::rename(&draft, &path)?;

    // One service at a time: the old one hands its sessions over first.
    if job().await.is_some() {
        launchctl(&["bootout", &target()]).await?;
    } else if let Some(pid) = running {
        signal(pid, libc::SIGTERM)?;
    }
    if let Some(pid) = running {
        exited(pid).await;
    }
    let domain = format!("gui/{}", unsafe { libc::getuid() });
    launchctl(&["bootstrap", &domain, &path.to_string_lossy()]).await?;
    let pid = launched(&root, server, running).await?;
    Ok(
        json!({"label": LABEL, "plist": path, "pid": pid, "previous_pid": running, "log": log,
              "command": invocation.argv, "next": "launchd now starts the service at login and after a crash; squircle service restart|stop|start control it."}),
    )
}

/// Starts the installed service (after `service stop`).
pub async fn start(root: &Path, server: &str) -> Result<Value> {
    ensure!(
        job().await.is_some(),
        "The service isn't installed with launchd; run squircle service install (or squircle serve)"
    );
    if let Some(pid) = holder(root)? {
        return Ok(json!({"pid": pid, "already_running": true}));
    }
    launchctl(&["kickstart", &target()]).await?;
    Ok(json!({"pid": launched(root, server, None).await?, "launchd": LABEL}))
}

/// Removes the launchd user agent, stopping the service it runs (ending its sessions).
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
    Ok(
        json!({"label": LABEL, "plist_removed": removed, "stopped_pid": running,
              "next": "Start the service yourself with squircle serve."}),
    )
}

fn signal(pid: u32, signal: libc::c_int) -> Result<()> {
    ensure!(
        unsafe { libc::kill(pid as i32, signal) } == 0,
        "Cannot signal process {pid}: {}",
        std::io::Error::last_os_error()
    );
    Ok(())
}

/// Waits for `pid` to exit; the service bounds its own wind-down.
async fn exited(pid: u32) {
    while unsafe { libc::kill(pid as i32, 0) } == 0 {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// `pid`'s command line, environment and working directory.
fn invocation(pid: u32) -> Result<Invocation> {
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
    let (argv, env) = parse_procargs(&raw)?;

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

    /// This test process reads back as itself.
    #[test]
    fn reads_a_running_process() {
        let own = invocation(std::process::id()).unwrap();
        assert_eq!(own.cwd, std::env::current_dir().unwrap());
        assert_eq!(own.argv, std::env::args_os().collect::<Vec<_>>());
        assert!(own.env.iter().any(|(k, _)| k == "HOME"));
    }
}
