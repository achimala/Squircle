use super::*;

/// Who may signal a session's recorder. Only a process this run started is
/// owned; one a previous run started is taken over only once its start
/// time and command line proved it is the session's (PIDs are reused).
pub(super) enum Recorder {
    Owned(Child),
    Recovered(RecorderID),
}

/// Makes a filed recording light in place (`crate::recordings`). A failure
/// leaves it as simctl wrote it; `squircle media shrink` retries those.
pub(super) async fn shrink(file: &Path) {
    let outcome = match crate::recordings::Tools::find() {
        Ok(tools) => crate::recordings::shrink(&tools, file).await,
        Err(error) => Err(error),
    };
    match outcome {
        Ok(crate::recordings::Outcome::Replaced { before, after, .. }) => eprintln!(
            "Recording {} made light: {} MB to {} MB",
            file.display(),
            before / 1_000_000,
            after / 1_000_000
        ),
        Ok(_) => {}
        Err(error) => eprintln!("Recording {} left as recorded: {error:#}", file.display()),
    }
}

/// Where an earlier version left avconvert's smaller copy.
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

/// Asks a recorder to finish: simctl writes the movie's index on SIGINT.
pub(super) fn interrupt(pid: u32) {
    unsafe { libc::kill(pid as i32, libc::SIGINT) };
}

/// Waits for an interrupted recorder to finish writing, however long that
/// takes. One cut off mid-write leaves SimRenderServer finishing a movie
/// whose simulator, or file, is gone, which crashed it.
pub(super) async fn finished(recorder: Recorder, session: &str) {
    match recorder {
        Recorder::Owned(mut child) => {
            let _ = child.wait().await;
        }
        Recorder::Recovered(recorder) => {
            while is_recorder(recorder, session) {
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
    }
}
