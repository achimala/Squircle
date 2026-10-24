//! Waiting on the kernel's own events (kqueue) instead of looking again
//! later: a process exiting, a file or folder changing. Each wait owns a
//! private kqueue that tokio watches like any other descriptor, so nothing
//! polls and nothing sleeps.

use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use tokio::io::unix::AsyncFd;

struct Queue(AsyncFd<OwnedFd>);

impl Queue {
    fn new() -> io::Result<Self> {
        let fd = unsafe { libc::kqueue() };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
        Ok(Self(AsyncFd::with_interest(
            fd,
            tokio::io::Interest::READABLE,
        )?))
    }

    /// Asks for `filter` events on `ident`; they stay armed until the queue goes.
    fn add(&self, ident: usize, filter: i16, fflags: u32) -> io::Result<()> {
        let change = libc::kevent {
            ident,
            filter,
            flags: libc::EV_ADD | libc::EV_CLEAR | libc::EV_RECEIPT,
            fflags,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        let mut receipt: libc::kevent = unsafe { std::mem::zeroed() };
        let found = unsafe {
            libc::kevent(
                self.0.as_raw_fd(),
                &change,
                1,
                &mut receipt,
                1,
                std::ptr::null(),
            )
        };
        if found < 0 {
            return Err(io::Error::last_os_error());
        }
        // EV_RECEIPT reports the registration's own result in `data`.
        if receipt.flags & libc::EV_ERROR != 0 && receipt.data != 0 {
            return Err(io::Error::from_raw_os_error(receipt.data as i32));
        }
        Ok(())
    }

    /// The next event: resolves only when the kernel has one.
    async fn next(&self) -> io::Result<libc::kevent> {
        let zero = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        loop {
            let mut ready = self.0.readable().await?;
            let mut event: libc::kevent = unsafe { std::mem::zeroed() };
            // Zero timeout: takes what is pending, never blocks the thread.
            let found = unsafe {
                libc::kevent(
                    self.0.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    &mut event,
                    1,
                    &zero,
                )
            };
            match found {
                n if n < 0 => return Err(io::Error::last_os_error()),
                0 => ready.clear_ready(),
                _ => return Ok(event),
            }
        }
    }
}

/// A process's exit, whoever its parent is, reaped or not.
pub(crate) struct Exit(Option<Queue>);

impl Exit {
    /// Watches `pid` from now on. One that has already exited, even an
    /// unreaped zombie, is `gone`: the kernel refuses to watch it. The pid
    /// must be one the caller knows is still this process (an unreaped
    /// child, or one whose identity it checked), not a reused one.
    pub(crate) fn watch(pid: u32) -> io::Result<Self> {
        let queue = Queue::new()?;
        match queue.add(pid as usize, libc::EVFILT_PROC, libc::NOTE_EXIT) {
            Ok(()) => Ok(Self(Some(queue))),
            // No such process, or one already exiting: nothing left to watch.
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(Self(None)),
            Err(error) => Err(error),
        }
    }

    /// Whether the process was already gone when watching began.
    #[cfg(test)]
    pub(crate) fn gone(&self) -> bool {
        self.0.is_none()
    }

    /// Resolves once the process has exited.
    pub(crate) async fn exited(&self) -> io::Result<()> {
        match &self.0 {
            None => Ok(()),
            Some(queue) => loop {
                if queue.next().await?.fflags & libc::NOTE_EXIT != 0 {
                    return Ok(());
                }
            },
        }
    }
}

/// Resolves once `pid` has exited (at once if it already has).
pub(crate) async fn exited(pid: u32) -> io::Result<()> {
    Exit::watch(pid)?.exited().await
}

/// Writes to, growth, renames or removal of a file or of a folder's
/// entries, from the moment it is opened.
pub(crate) struct Changes {
    queue: Queue,
    _file: File,
}

impl Changes {
    pub(crate) fn watch(path: &Path) -> io::Result<Self> {
        let name = std::ffi::CString::new(path.as_os_str().as_bytes())?;
        let fd = unsafe { libc::open(name.as_ptr(), libc::O_EVTONLY | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let queue = Queue::new()?;
        queue.add(
            fd as usize,
            libc::EVFILT_VNODE,
            libc::NOTE_WRITE
                | libc::NOTE_EXTEND
                | libc::NOTE_ATTRIB
                | libc::NOTE_RENAME
                | libc::NOTE_DELETE,
        )?;
        Ok(Self { queue, _file: file })
    }

    /// Resolves at the next change after the last one returned.
    pub(crate) async fn next(&self) -> io::Result<()> {
        self.queue.next().await.map(drop)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The race this exists for: an exit before watching (here an unreaped
    /// zombie) and one after it are both seen, never waited for forever.
    #[tokio::test]
    async fn exits_are_seen_before_and_after_watching() {
        let mut reader = tokio::process::Command::new("/bin/cat")
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let pid = reader.id().unwrap();
        let exit = Exit::watch(pid).unwrap();
        assert!(!exit.gone());
        drop(reader.stdin.take());
        exit.exited().await.unwrap();
        // Exited and not yet reaped: a zombie still answers kill(0).
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, 0);
        assert!(Exit::watch(pid).unwrap().gone());
        exited(pid).await.unwrap();
        reader.wait().await.unwrap();
    }

    #[tokio::test]
    async fn file_changes_wake_the_watcher() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let changes = Changes::watch(file.path()).unwrap();
        std::fs::write(file.path(), b"Recording started\n").unwrap();
        changes.next().await.unwrap();
    }
}
