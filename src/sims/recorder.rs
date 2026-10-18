use super::*;

/// Who may signal a session's recorder. Only a process this run started is
/// owned; one a previous run started is taken over only once its start
/// time and command line proved it is the session's (PIDs are reused).
pub(super) enum Recorder {
    Owned(Child),
    Recovered(RecorderID),
}

/// T3's 24-hex-digit key (sha256 prefix) for agent-device files.
pub(super) fn key(value: &str) -> String {
    Sha256::digest(value.as_bytes())
        .iter()
        .take(12)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// simctl records at about 6 Mbit/s; the phone downloads recordings over
/// cellular. macOS's own `avconvert` re-encodes them far smaller (mostly
/// still screens). Returns the smaller file, having removed the original.
pub(super) async fn compact(raw: &Path) -> Option<PathBuf> {
    let small = compacted(raw);
    let converted = tokio::time::timeout(
        Duration::from_secs(180),
        Command::new("/usr/bin/avconvert")
            .args(["--preset", "Preset1280x720", "--replace", "--source"])
            .arg(raw)
            .arg("--output")
            .arg(&small)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .status(),
    )
    .await;
    if matches!(converted, Ok(Ok(status)) if status.success())
        && small.metadata().is_ok_and(|m| m.len() > 0)
    {
        let _ = std::fs::remove_file(raw);
        Some(small)
    } else {
        let _ = std::fs::remove_file(&small);
        None
    }
}

pub(super) fn compacted(raw: &Path) -> PathBuf {
    raw.with_extension("compact.mp4")
}

pub(super) fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

/// When the process started (seconds, microseconds since 1970), if it runs.
pub(super) fn process_start(pid: u32) -> Option<(u64, u64)> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let read = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    (read == size).then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

/// The process's command line, if it is running.
pub(super) fn command_line(pid: u32) -> Option<String> {
    let output = std::process::Command::new("/bin/ps")
        .args(["-ww", "-o", "command=", "-p", &pid.to_string()])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let line = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (output.status.success() && !line.is_empty()).then_some(line)
}

/// Whether `recorder` is still this session's: its command line names the
/// session's own recording file, and (once recorded) it started when the
/// recorder did, which no reused PID can.
pub(super) fn is_recorder(recorder: RecorderID, session: &str) -> bool {
    let named = command_line(recorder.pid)
        .is_some_and(|line| line.contains(&format!(".{session}.recording.mp4")));
    named
        && recorder
            .start
            .is_none_or(|start| process_start(recorder.pid) == Some(start))
}
