//! `squircle service restart|stop`: controls the `squircle serve` running for
//! a data directory, found through its lock (`service.lock` holds its PID).
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

/// Stops the running service, ending its simulator sessions.
pub async fn stop(root: &Path) -> Result<Value> {
    let pid = holder(root)?.context("No Squircle service is running for this data directory")?;
    signal(pid, libc::SIGINT)?;
    exited(pid).await;
    Ok(json!({"stopped_pid": pid}))
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
fn parse_procargs(raw: &[u8]) -> Result<(Vec<OsString>, Vec<(OsString, OsString)>)> {
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
