//! Bounded subprocess groups shared by Git, Xcode and diagnostic tools.
//! Killing the group before reaping its leader preserves process identity.
use anyhow::{Result, ensure};
use std::os::unix::process::CommandExt;
use std::{fs::File, path::Path, process::Stdio};
use tokio::{process::Command, sync::watch};

/// Resolves when the build is cancelled or its supervisor is gone; never
/// without a receiver.
pub(crate) async fn cancelled(cancel: Option<watch::Receiver<bool>>) {
    let Some(mut cancel) = cancel else {
        return std::future::pending().await;
    };
    loop {
        if *cancel.borrow_and_update() {
            return;
        }
        // Losing the supervisor is also cancellation; do not leave an orphan.
        if cancel.changed().await.is_err() {
            return;
        }
    }
}

fn is_cancelled(cancel: &watch::Receiver<bool>) -> bool {
    *cancel.borrow() || cancel.has_changed().is_err()
}

/// Kills every process left in a group whose leader is not yet reaped. The
/// child creates its own group before exec, and a negative pid only addresses
/// that group, never the server's.
fn kill_group(leader: libc::pid_t) {
    if leader > 0 {
        unsafe {
            libc::kill(-leader, libc::SIGKILL);
        }
    }
}

/// A helper and the process group it leads. The leader is held unreaped while
/// the group is owned, so signalling the group can never reach a reused id;
/// `reap` kills the group before it reaps the leader. Leader exit is not group
/// completion: whatever the leader left running dies with the group, also when
/// this is dropped.
struct OwnedGroup {
    pid: libc::pid_t,
    leader: Option<tokio::process::Child>,
}

impl OwnedGroup {
    fn spawn(command: &mut Command) -> std::io::Result<Self> {
        command.kill_on_drop(true);
        command.as_std_mut().process_group(0);
        let leader = command.spawn()?;
        let pid = leader
            .id()
            .ok_or_else(|| std::io::Error::other("helper has no process id"))?;
        Ok(Self {
            pid: pid as libc::pid_t,
            leader: Some(leader),
        })
    }

    /// Resolves once the leader has exited; it stays unreaped, so its pid
    /// can't be reused meanwhile. The kernel reports the exit, also one that
    /// came before this was called.
    async fn leader_exit(&self) -> std::io::Result<()> {
        crate::kq::exited(self.pid as u32).await
    }

    fn kill(&self) {
        kill_group(self.pid);
    }

    async fn reap(mut self) -> std::io::Result<std::process::ExitStatus> {
        self.kill();
        let mut leader = self.leader.take().expect("an owned group holds its leader");
        // SIGKILL can't be caught or ignored: the leader's exit follows it.
        leader.wait().await
    }
}

impl Drop for OwnedGroup {
    fn drop(&mut self) {
        if self.leader.is_some() {
            self.kill();
        }
    }
}

/// Where a helper's output stream goes.
pub(crate) enum Sink {
    Discard,
    File(File),
    /// Collected in memory; more than this many bytes is an error.
    Capture(usize),
}

impl Sink {
    fn stdio(&self) -> std::io::Result<(Stdio, Option<usize>)> {
        Ok(match self {
            Sink::Discard => (Stdio::null(), None),
            Sink::File(file) => (file.try_clone()?.into(), None),
            Sink::Capture(limit) => (Stdio::piped(), Some(*limit)),
        })
    }
}

pub(crate) struct Finished {
    pub status: std::process::ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Why a helper produced no exit status. Callers word their own messages.
#[derive(Debug)]
pub(crate) enum RunError {
    Cancelled,
    Failed(anyhow::Error),
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunError::Cancelled => write!(f, "cancelled"),
            RunError::Failed(error) => write!(f, "{error:#}"),
        }
    }
}

impl std::error::Error for RunError {}

async fn read_limited(
    pipe: Option<impl tokio::io::AsyncRead + Unpin>,
    limit: Option<usize>,
) -> Result<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    let (Some(pipe), Some(limit)) = (pipe, limit) else {
        return Ok(Vec::new());
    };
    let mut bytes = Vec::new();
    pipe.take(limit as u64 + 1).read_to_end(&mut bytes).await?;
    ensure!(bytes.len() <= limit, "output exceeds {limit} bytes");
    Ok(bytes)
}

/// Runs one helper in its own process group until it ends, bounded by
/// `cancel` and output limits. Whatever stops it early, including dropping
/// this future (the request or job that wanted it is gone), kills the whole
/// group. A nonzero exit is returned, not an error.
pub(crate) async fn run_bounded(
    command: Command,
    stdout: Sink,
    stderr: Sink,
    cancel: Option<watch::Receiver<bool>>,
) -> Result<Finished, RunError> {
    run_bounded_with_input(command, None, stdout, stderr, cancel).await
}

/// [`run_bounded`], writing `input` to the helper's stdin (then closing it)
/// instead of giving it none. A helper that exits without reading it all is
/// not an error.
pub(crate) async fn run_bounded_with_input(
    mut command: Command,
    input: Option<Vec<u8>>,
    stdout: Sink,
    stderr: Sink,
    cancel: Option<watch::Receiver<bool>>,
) -> Result<Finished, RunError> {
    if cancel.as_ref().is_some_and(is_cancelled) {
        return Err(RunError::Cancelled);
    }
    let program = command.as_std().get_program().to_owned();
    let failed = |error: std::io::Error| RunError::Failed(error.into());
    let (out, out_limit) = stdout.stdio().map_err(failed)?;
    let (err, err_limit) = stderr.stdio().map_err(failed)?;
    let stdin = if input.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    };
    command.stdin(stdin).stdout(out).stderr(err);
    let mut group = OwnedGroup::spawn(&mut command).map_err(|error| {
        RunError::Failed(
            anyhow::Error::new(error)
                .context(format!("cannot start {}", Path::new(&program).display())),
        )
    })?;
    let leader = group
        .leader
        .as_mut()
        .expect("a spawned group holds its leader");
    let (out, err, pipe) = (
        leader.stdout.take(),
        leader.stderr.take(),
        leader.stdin.take(),
    );
    let work = async {
        let write = async {
            use tokio::io::AsyncWriteExt;
            if let (Some(mut pipe), Some(input)) = (pipe, input) {
                let _ = pipe.write_all(&input).await;
            }
            Ok(())
        };
        let ended = async {
            group.leader_exit().await?;
            // Descendants still holding the pipes would otherwise outlive it.
            group.kill();
            Ok(())
        };
        let (stdout, stderr, (), ()) = tokio::try_join!(
            read_limited(out, out_limit),
            read_limited(err, err_limit),
            ended,
            write
        )?;
        Ok::<_, anyhow::Error>((stdout, stderr))
    };
    let result = tokio::select! {
        biased;
        _ = cancelled(cancel) => Err(RunError::Cancelled),
        result = work => result.map_err(RunError::Failed),
    };
    let status = group.reap().await;
    let (stdout, stderr) = result?;
    Ok(Finished {
        status: status.map_err(failed)?,
        stdout,
        stderr,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[tokio::test]
    async fn cancellation_wakes_when_supervisor_closes() {
        let (sender, receiver) = watch::channel(false);
        drop(sender);
        cancelled(Some(receiver)).await;
    }

    /// A shell that writes `$!` (the background job it leaves) to a marker
    /// file, and the pid once the shell has written it: the file's own
    /// change wakes the wait.
    struct Marker(tempfile::NamedTempFile);

    impl Marker {
        fn new() -> Self {
            Self(tempfile::NamedTempFile::new().unwrap())
        }

        fn shell(&self, script: &str) -> Command {
            let mut command = Command::new("/bin/sh");
            command.args(["-c", script]).arg(self.0.path());
            command
        }

        async fn pid(&self) -> u32 {
            let changes = crate::kq::Changes::watch(self.0.path()).unwrap();
            loop {
                let text = fs::read_to_string(self.0.path()).unwrap();
                if let Some(pid) = text.strip_suffix('\n').and_then(|t| t.parse().ok()) {
                    return pid;
                }
                changes.next().await.unwrap();
            }
        }
    }

    #[tokio::test]
    async fn bounded_helpers_stop_on_cancellation_and_output_limits() {
        let (sender, cancel) = watch::channel(false);
        let marker = Marker::new();
        let run = run_bounded(
            marker.shell("sleep 30 & echo $! > \"$0\"; wait"),
            Sink::Capture(1024),
            Sink::Discard,
            Some(cancel),
        );
        tokio::pin!(run);
        let left = tokio::select! {
            _ = &mut run => panic!("ended before it was cancelled"),
            pid = marker.pid() => pid,
        };
        sender.send(true).unwrap();
        assert!(matches!(run.await, Err(RunError::Cancelled)));
        crate::kq::exited(left).await.unwrap();

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "yes | head -c 4096"]);
        let result = run_bounded(command, Sink::Capture(1024), Sink::Discard, None).await;
        assert!(matches!(result, Err(RunError::Failed(_))));

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "echo out; echo err >&2; exit 3"]);
        let finished = run_bounded(command, Sink::Capture(1024), Sink::Capture(1024), None)
            .await
            .unwrap();
        assert_eq!(finished.status.code(), Some(3));
        assert_eq!(finished.stdout, b"out\n");
        assert_eq!(finished.stderr, b"err\n");
    }

    #[tokio::test]
    async fn input_reaches_stdin_and_an_unread_one_does_not_hang() {
        let run = |program: &str, input: Vec<u8>| {
            run_bounded_with_input(
                Command::new(program),
                Some(input),
                Sink::Capture(1024),
                Sink::Discard,
                None,
            )
        };
        assert_eq!(run("/bin/cat", b"in".to_vec()).await.unwrap().stdout, b"in");
        // More than a pipe holds, to a helper that exits without reading.
        assert!(
            run("/usr/bin/true", vec![0; 1 << 20])
                .await
                .unwrap()
                .status
                .success()
        );
    }

    #[tokio::test]
    async fn leader_exit_kills_what_it_left_running() {
        // The background sleep keeps stdout open after the shell exits.
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30 & echo $!"]);
        let finished = run_bounded(command, Sink::Capture(1024), Sink::Discard, None)
            .await
            .unwrap();
        assert!(finished.status.success());
        let left: u32 = String::from_utf8(finished.stdout)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        crate::kq::exited(left).await.unwrap();

        // Also when nothing holds a pipe.
        let marker = Marker::new();
        let finished = run_bounded(
            marker.shell("sleep 30 >/dev/null 2>&1 & echo $! > \"$0\""),
            Sink::Discard,
            Sink::Discard,
            None,
        )
        .await
        .unwrap();
        assert!(finished.status.success());
        crate::kq::exited(marker.pid().await).await.unwrap();
    }

    #[tokio::test]
    async fn dropping_a_run_kills_its_group() {
        let marker = Marker::new();
        let run = run_bounded(
            marker.shell("sleep 30 & echo $! > \"$0\"; wait"),
            Sink::Discard,
            Sink::Discard,
            None,
        );
        let left = tokio::select! {
            _ = run => panic!("ended on its own"),
            pid = marker.pid() => pid,
        };
        crate::kq::exited(left).await.unwrap();
    }
}
