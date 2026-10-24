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

/// The process's command line, if it is running, from the kernel: read in
/// owner letters, it must not wait on a `ps`.
pub(super) fn command_line(pid: u32) -> Option<String> {
    let arguments = crate::service::arguments(pid).ok()?;
    let line = arguments
        .iter()
        .map(|a| a.to_string_lossy())
        .collect::<Vec<_>>()
        .join(" ");
    (!line.is_empty()).then_some(line)
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

/// Pokes the watchdog once `pid` has exited, so a recorder that dies is
/// noticed when it does. The pid must still be the recorder's (an unreaped
/// child, or one whose identity was just checked).
pub(super) fn watch_exit(pid: u32, poke: &Arc<Notify>) {
    let poke = poke.clone();
    match crate::kq::Exit::watch(pid) {
        Ok(exit) => {
            tokio::spawn(async move {
                let _ = exit.exited().await;
                poke.notify_one();
            });
        }
        Err(error) => {
            eprintln!("Cannot watch recorder {pid}: {error}");
            poke.notify_one();
        }
    }
}

/// simctl's line once the movie has its first frame.
const RECORDING_STARTED: &str = "Recording started";

/// Resolves once the recorder whose stderr is `log` says it is recording,
/// or fails with what it said if it exits first. The log's own writes wake
/// this; nothing is read on a timer.
pub(super) async fn recording(recorder: &mut Child, log: &Path) -> Result<()> {
    let changes = crate::kq::Changes::watch(log)?;
    let said = || std::fs::read_to_string(log).unwrap_or_default();
    loop {
        if said().lines().any(|line| line.trim() == RECORDING_STARTED) {
            return Ok(());
        }
        tokio::select! {
            status = recorder.wait() => bail!("it exited ({}): {}", status?, said().trim()),
            changed = changes.next() => changed?,
        }
    }
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
            // Watched before its identity is checked: once it is proven
            // the session's, its exit can't be missed or be another's.
            match crate::kq::Exit::watch(recorder.pid) {
                Ok(exit) if is_recorder(recorder, session) => {
                    let _ = exit.exited().await;
                }
                Ok(_) => {}
                Err(error) => eprintln!("Cannot watch recorder {}: {error}", recorder.pid),
            }
        }
    }
}
