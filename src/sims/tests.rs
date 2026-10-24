#![cfg(test)]
// Test fakes only: leaf locks never held across a call.
#![allow(clippy::disallowed_types)]

use super::*;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};

const THREAD: &str = "f56d4de2-8173-425d-b251-84d841fd8d97";
const B: &str = "0e7c4a1d-5f0b-4c8e-9a51-2b6f1c3d4e5f";
const C: &str = "1e7c4a1d-5f0b-4c8e-9a51-2b6f1c3d4e5f";
const D: &str = "2e7c4a1d-5f0b-4c8e-9a51-2b6f1c3d4e5f";

/// simctl's recorder: says it is recording, then idles until SIGINT, when
/// it writes its movie (`$1`) and exits. `wait` returns at the signal.
const RECORDER: &str = "trap 'kill $idle; printf movie > \"$1\"; exit 0' INT; \
    echo 'Recording started' >&2; sleep 86400 & idle=$!; wait $idle";

/// T3 and simctl stand-ins: two simulators, a recorder that writes its
/// movie on SIGINT like simctl, closes and releases that fail on request,
/// and T3's list of open device sessions.
#[derive(Default)]
struct Fake {
    calls: Mutex<Vec<String>>,
    close_fails: AtomicBool,
    /// T3 still lists the closed device sessions (so a failed close stays owed).
    lists_open: AtomicBool,
    release_fails: AtomicBool,
    boot: Mutex<Option<std::result::Result<(), ()>>>,
    /// Told when a boot that never ends (`boot` None) has begun.
    booting: tokio::sync::Notify,
    seen: Mutex<Option<Seen>>,
    /// Per-thread T3 state, over `seen`.
    threads: Mutex<HashMap<String, Seen>>,
    woken: Mutex<Vec<(String, String)>>,
    waiting: Mutex<Vec<String>>,
    max: AtomicUsize,
}

impl Fake {
    fn count(&self, call: &str) -> usize {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .filter(|c| *c == call)
            .count()
    }

    fn closes(&self) -> usize {
        self.count("device.close")
    }
}

fn busy(turn: &str) -> Seen {
    Seen::Busy {
        turn: Some(turn.into()),
    }
}
impl Host for Fake {
    fn device<'a>(&'a self, method: &'a str, _: Value) -> Pending<'a, Result<Value>> {
        self.calls.lock().unwrap().push(method.into());
        let fails = method == "device.close" && self.close_fails.load(SeqCst);
        Box::pin(async move {
            ensure!(!fails, "disconnected");
            Ok(
                json!({"agentAccessEnabled": true, "devices": [{"id": "SIM1", "name": "iPhone", "platform": "ios", "hostId": "local", "booted": true},
                                   {"id": "SIM2", "name": "iPad", "platform": "ios", "hostId": "local", "booted": false}]}),
            )
        })
    }
    fn device_sessions(&self) -> Pending<'_, Result<Vec<(String, String)>>> {
        let open = self.lists_open.load(SeqCst);
        Box::pin(async move {
            ensure!(open, "T3 is offline");
            Ok(vec![
                (THREAD.to_string(), "SIM1".to_string()),
                (B.to_string(), "SIM1".to_string()),
            ])
        })
    }
    fn seen(&self, thread: &str) -> Seen {
        self.threads
            .lock()
            .unwrap()
            .get(thread)
            .cloned()
            .unwrap_or_else(|| self.seen.lock().unwrap().clone().unwrap_or(busy("t0")))
    }
    fn create<'a>(&'a self, _: &'a str) -> Pending<'a, Result<String>> {
        Box::pin(async { Err(anyhow::anyhow!("no simulators are created in these tests")) })
    }
    fn cli(&self) -> String {
        "squircle".into()
    }
    fn boot<'a>(&'a self, _: &'a str) -> Pending<'a, Result<()>> {
        let outcome = *self.boot.lock().unwrap();
        Box::pin(async move {
            match outcome {
                None => {
                    self.booting.notify_one();
                    std::future::pending().await
                }
                Some(Ok(())) => Ok(()),
                Some(Err(())) => bail!("boot failed"),
            }
        })
    }
    fn record(&self, _: &str, path: &Path, log: std::fs::File) -> Result<Child> {
        Ok(Command::new("/bin/sh")
            .args(["-c", RECORDER, "sh"])
            .arg(path)
            .stderr(log)
            .process_group(0)
            .spawn()?)
    }
    fn shrink<'a>(&'a self, _: &'a Path) -> Pending<'a, ()> {
        Box::pin(async {})
    }
    fn free<'a>(&'a self, _: &'a [Lease]) -> Pending<'a, Vec<String>> {
        Box::pin(async { vec!["SIM1".into()] })
    }
    fn release<'a>(
        &'a self,
        device: &'a str,
        _: &'a str,
        _: &'a [Lease],
    ) -> Pending<'a, Result<Released>> {
        self.calls.lock().unwrap().push(format!("release {device}"));
        let fails = self.release_fails.load(SeqCst);
        Box::pin(async move {
            ensure!(!fails, "simctl shutdown failed");
            Ok(Released::ShutDown)
        })
    }
    fn max_leases(&self) -> usize {
        self.max.load(SeqCst).max(1)
    }
    fn title(&self, _: &str) -> Option<String> {
        None
    }
    fn wake<'a>(&'a self, thread: &'a str, id: &'a str, _: String) -> Pending<'a, Result<()>> {
        self.woken.lock().unwrap().push((thread.into(), id.into()));
        Box::pin(async { Ok(()) })
    }
    fn waiting(&self, threads: Vec<String>) {
        *self.waiting.lock().unwrap() = threads
    }
}

fn sims(root: &Path, boot: Option<std::result::Result<(), ()>>) -> (Arc<Sims>, Arc<Fake>) {
    let fake = Arc::new(Fake {
        boot: Mutex::new(boot),
        ..Fake::default()
    });
    (Sims::with_host(root, fake.clone()).unwrap(), fake)
}

fn state(session: &Session) -> String {
    Served::from(session).state
}

fn only(sims: &Sims) -> Session {
    sims.ledger().sessions.last().cloned().unwrap()
}

fn only_of(sims: &Sims, thread: &str) -> Session {
    sims.ledger()
        .sessions
        .iter()
        .rev()
        .find(|s| s.thread_id == thread)
        .cloned()
        .unwrap()
}

fn queue(sims: &Sims) -> Vec<(String, bool)> {
    sims.ledger()
        .queue
        .iter()
        .map(|w| (w.thread_id.clone(), w.grant.is_some()))
        .collect()
}

/// Makes every owed retry due now.
async fn due_now(sims: &Sims) {
    sims.owner
        .ask(|state| {
            state.change(|ledger| {
                for s in &mut ledger.sessions {
                    if let DeviceLease::CloseOwed(retry) = &mut s.device {
                        retry.retry_at = 0.0
                    }
                    if let session::Release::Owed(retry) = &mut s.release {
                        retry.retry_at = 0.0
                    }
                }
                Ok(())
            })
        })
        .await
        .unwrap();
}

/// Waits for every letter told so far (a dropped guard's) to be read.
async fn settled(sims: &Sims) {
    sims.owner.ask(|_| ()).await;
}

/// A second cleanup of a session already being cleaned up (`sim stop`
/// racing the watchdog) is turned away without touching the first's
/// claim, and one whose ask was cancelled holds nothing. Claims once
/// self-deadlocked on the state lock and hung the service.
#[tokio::test]
async fn overlapping_claims_neither_deadlock_nor_release_the_holder() {
    let dir = tempfile::tempdir().unwrap();
    let (sims, _) = sims(dir.path(), None);
    let held = sims.claim("s", Work::Release).await.expect("first claim");
    assert!(sims.claim("s", Work::Release).await.is_none());
    assert!(
        sims.claim("s", Work::Release).await.is_none(),
        "a refused claim released the holder's"
    );
    drop(held);
    let again = sims
        .claim("s", Work::Release)
        .await
        .expect("released on drop");
    drop(again);
    // Cancelled after asking, before the owner granted it: the guard,
    // made first, still releases what the owner then grants.
    let mut cancelled = Box::pin(sims.claim("s", Work::Close));
    assert!(
        std::future::poll_fn(|cx| std::task::Poll::Ready(cancelled.as_mut().poll(cx).is_pending()))
            .await
    );
    drop(cancelled);
    assert!(
        sims.claim("s", Work::Close).await.is_some()
            && sims.claim("s", Work::Release).await.is_some()
    );
}

/// Recovery signals a saved PID only while it is still that session's
/// recorder: its command line and its start time.
#[test]
fn recorder_identity_is_the_session_file_and_start() {
    let id = uuid::Uuid::new_v4().to_string();
    let mut child = std::process::Command::new("/bin/sh")
        .args(["-c", "sleep 5; true", "sh"])
        .arg(format!("/tmp/.{id}.recording.mp4"))
        .spawn()
        .unwrap();
    let pid = child.id();
    let start = process_start(pid);
    assert!(start.is_some());
    assert!(is_recorder(RecorderID { pid, start }, &id));
    assert!(is_recorder(RecorderID { pid, start: None }, &id));
    assert!(
        !is_recorder(
            RecorderID {
                pid,
                start: Some((1, 0))
            },
            &id
        ),
        "a different start time passed"
    );
    assert!(!is_recorder(
        RecorderID { pid, start },
        &uuid::Uuid::new_v4().to_string()
    ));
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(!is_recorder(RecorderID { pid, start }, &id));
}

/// A process that took over a saved recorder PID is never signalled.
#[tokio::test]
async fn restart_leaves_a_reused_pid_alone() {
    let dir = tempfile::tempdir().unwrap();
    let mut stranger = std::process::Command::new("/bin/sleep")
        .arg("5")
        .spawn()
        .unwrap();
    let ledger = json!({"sessions": [{"id": uuid::Uuid::new_v4().to_string(), "thread_id": THREAD, "host_id": "local",
        "device_id": "SIM1", "device_name": "iPhone", "started_at": 1.0, "state": "recording", "recorder_pid": stranger.id()}]});
    std::fs::write(dir.path().join("sims.json"), ledger.to_string()).unwrap();
    let (sims, fake) = sims(dir.path(), Some(Ok(())));
    let id = sims
        .owner
        .ask(|s| std::mem::take(&mut s.orphans))
        .await
        .pop()
        .unwrap();
    sims.resume(&id, "service restarted").await;
    let session = only(&sims);
    assert!(
        stranger.try_wait().unwrap().is_none(),
        "the unrelated process was signalled"
    );
    assert!(matches!(&session.phase, Phase::Failed { error, .. } if error.contains("left alone")));
    // A pre-upgrade record owes no close; the release is owed and runs.
    assert_eq!((fake.closes(), fake.count("release SIM1")), (0, 1));
    assert!(session.settled());
    stranger.kill().unwrap();
    stranger.wait().unwrap();
}

/// A failed or cancelled start kills its recorder and still closes T3's
/// device session and releases the simulator.
#[tokio::test]
async fn failed_or_cancelled_start_rolls_back() {
    let dir = tempfile::tempdir().unwrap();
    let (sims, fake) = sims(dir.path(), Some(Err(())));
    assert!(sims.start(THREAD, None).await.is_err());
    let session = only(&sims);
    assert_eq!(
        (state(&session).as_str(), session.settled()),
        ("failed", true)
    );
    assert_eq!((fake.closes(), fake.count("release SIM1")), (1, 1));

    // Cancelled while it boots.
    *fake.boot.lock().unwrap() = None;
    tokio::select! {
        _ = sims.start(THREAD, None) => panic!("a boot that never ends ended"),
        _ = fake.booting.notified() => {}
    }
    settled(&sims).await;
    let session = only(&sims);
    assert!(
        session.reserves()
            && matches!(&session.phase, Phase::Failed { error, .. } if error.contains("cancelled"))
    );
    sims.tick().await;
    assert!(only(&sims).settled());
    assert_eq!((fake.closes(), fake.count("release SIM1")), (2, 2));
}

/// The recording is filed even when T3 is unreachable; the close is owed
/// (and the slot held, Q4) until T3 answers or shows it gone; a failed
/// release is owed too, never cleared.
#[tokio::test]
async fn failed_cleanup_is_retried_and_holds_the_slot() {
    let dir = tempfile::tempdir().unwrap();
    let (sims, fake) = sims(dir.path(), Some(Ok(())));
    sims.start(THREAD, None).await.unwrap();
    fake.close_fails.store(true, SeqCst);
    fake.lists_open.store(true, SeqCst);
    let session = sims.stop(Some(THREAD), None).await.unwrap().session;
    assert_eq!(session.state, "finished");
    assert!(matches!(
        &session.device_session,
        Some(DeviceLease::CloseOwed(crate::fsm::sims::RetryState {
            error: Some(_),
            ..
        }))
    ));
    assert_eq!(media::list(dir.path(), THREAD).unwrap().len(), 1);
    // The blocked close keeps the slot: the next thread waits.
    assert_eq!(sims.start(B, None).await.unwrap()["status"], "queued");

    fake.close_fails.store(false, SeqCst);
    fake.release_fails.store(true, SeqCst);
    sims.tick().await;
    assert!(
        only_of(&sims, THREAD).device.owed(),
        "retried before its backoff"
    );
    due_now(&sims).await;
    sims.tick().await;
    let s = only_of(&sims, THREAD);
    assert!(
        !s.device.owed() && s.release_owed() && s.reserves(),
        "a failed release was cleared"
    );
    assert_eq!(queue(&sims), [(B.into(), false)]);
    fake.release_fails.store(false, SeqCst);
    due_now(&sims).await;
    sims.tick().await;
    assert!(only_of(&sims, THREAD).settled());
    assert_eq!(queue(&sims), [(B.into(), true)]);
    // Saved: a restart owes nothing.
    let (reopened, _) = super::tests::sims(dir.path(), Some(Ok(())));
    assert!(
        reopened.owner.ask(|s| s.orphans.is_empty()).await && only_of(&reopened, THREAD).settled()
    );
}

/// A close whose answer is lost is settled by T3 no longer listing the session.
#[tokio::test]
async fn a_lost_close_is_settled_by_t3s_list() {
    let dir = tempfile::tempdir().unwrap();
    let (sims, fake) = sims(dir.path(), Some(Ok(())));
    sims.start(B, Some("SIM2")).await.unwrap();
    fake.close_fails.store(true, SeqCst);
    fake.lists_open.store(true, SeqCst);
    // T3 lists (THREAD, SIM1) and (B, SIM1); B's session is on SIM2.
    let session = sims.stop(Some(B), None).await.unwrap().session;
    assert_eq!(session.device_session, Some(DeviceLease::Closed));
    assert!(!session.release_pending);
}

/// Shutdown ends recordings, files them, closes the device session and refuses new starts.
#[tokio::test]
async fn shutdown_files_and_refuses_starts() {
    let dir = tempfile::tempdir().unwrap();
    let (sims, fake) = sims(dir.path(), Some(Ok(())));
    sims.start(THREAD, None).await.unwrap();
    sims.shutdown(Exit::Stop).await;
    let session = only(&sims);
    assert_eq!(
        (state(&session).as_str(), session.settled()),
        ("finished", true)
    );
    assert_eq!(fake.closes(), 1);
    assert!(sims.start(THREAD, None).await.is_err());
    assert!(sims.owner.ask(|s| s.recorders.is_empty()).await);
}

/// A restart hands a recording over: its recorder keeps running and T3's
/// device session stays open; the next run adopts it (no "service
/// restarted" stop), watches it, and a later stop files the whole movie.
/// One whose recorder died meanwhile is finished instead.
#[tokio::test]
async fn handover_keeps_recording_into_the_next_run() {
    let dir = tempfile::tempdir().unwrap();
    let (sims, fake) = sims(dir.path(), Some(Ok(())));
    fake.max.store(2, SeqCst);
    sims.start(THREAD, None).await.unwrap();
    sims.start(B, Some("SIM2")).await.unwrap();
    let (ids, recorders): (Vec<String>, Vec<RecorderID>) = sims
        .ledger()
        .sessions
        .iter()
        .map(|s| (s.id.clone(), s.recorder().unwrap()))
        .unzip();
    assert!(recorders.iter().all(|r| r.start.is_some()));
    sims.shutdown(Exit::Handover).await;
    assert!(
        sims.start(THREAD, None).await.is_err(),
        "started while handing over"
    );
    assert_eq!((fake.closes(), fake.count("release SIM1")), (0, 0));
    assert!(
        sims.ledger()
            .sessions
            .iter()
            .all(|s| s.active() && s.device == DeviceLease::Open)
    );
    drop(sims);
    assert!(
        recorders.iter().all(|r| alive(r.pid)),
        "a recorder stopped with the old run"
    );
    // The second session's recorder dies between the runs.
    let exit = crate::kq::Exit::watch(recorders[1].pid).unwrap();
    // Its group: the recorder and what it idles on.
    unsafe { libc::kill(-(recorders[1].pid as i32), libc::SIGKILL) };
    exit.exited().await.unwrap();

    let reopened = Sims::with_host(dir.path(), fake.clone()).unwrap();
    let orphans = reopened.owner.ask(|s| s.orphans.clone()).await;
    assert_eq!(orphans, [ids[1].clone()]);
    // Watched again: only the one whose recorder died is due to end.
    assert_eq!(reopened.due().await, [(ids[1].clone(), "recorder stopped")]);
    let receipt = reopened.stop(Some(THREAD), None).await.unwrap();
    assert!(
        matches!(only_of(&reopened, THREAD).phase, Phase::Finished { ref reason, .. } if reason == "stopped")
    );
    assert!(receipt.media_id.is_some());
    assert_eq!(
        std::fs::read(&media::list(dir.path(), THREAD).unwrap()[0].file).unwrap(),
        b"movie"
    );
    assert_eq!(fake.closes(), 1);
}

/// The upgrade: a ledger from before cleanup receipts, with a live
/// recording handed over (its recorder saved by PID only) and a line with
/// a woken grant, opens with its original kept beside it; the recording
/// is adopted and given its recorder's start time, the line and grant
/// survive, and nobody is woken twice.
#[tokio::test]
async fn an_earlier_ledger_is_migrated_with_its_sessions_and_line() {
    let dir = tempfile::tempdir().unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    std::fs::create_dir_all(dir.path().join("media")).unwrap();
    let path = media::recording_path(dir.path(), THREAD, &id).unwrap();
    let mut recorder = Command::new("/bin/sh")
        .args(["-c", RECORDER, "sh"])
        .arg(&path)
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let pid = recorder.id().unwrap();
    let ledger = json!({
        "sessions": [
            {"id": id, "thread_id": THREAD, "host_id": "local", "device_id": "SIM1", "device_name": "iPhone", "started_at": now(),
             "ended_at": null, "state": "recording", "media_id": null, "stop_reason": null, "error": null, "recorder_pid": pid,
             "device_session": {"phase": "open"}, "release_pending": false},
            {"id": "old", "thread_id": C, "host_id": "local", "device_id": "SIM2", "device_name": "iPad", "started_at": 1.0,
             "ended_at": 2.0, "state": "finished", "media_id": "m", "stop_reason": "stopped", "error": null, "recorder_pid": null,
             "device_session": {"phase": "closed"}, "release_pending": true}],
        "queue": [{"id": "w1", "thread_id": B, "queued_at": 1.0, "grant": {"at": 2.0, "turn": "t1", "woken": true}}]});
    std::fs::write(dir.path().join("sims.json"), ledger.to_string()).unwrap();
    let fake = Arc::new(Fake {
        boot: Mutex::new(Some(Ok(()))),
        ..Fake::default()
    });
    fake.max.store(3, SeqCst);
    let sims = Sims::with_host(dir.path(), fake.clone()).unwrap();

    let original: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("sims.schema1.json")).unwrap())
            .unwrap();
    assert_eq!(original, ledger);
    let saved: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("sims.json")).unwrap()).unwrap();
    assert_eq!(
        (
            saved["schema"].as_u64(),
            saved["queue"][0]["grant"]["wake"].as_str()
        ),
        (Some(2), Some("queued"))
    );
    let live = only_of(&sims, THREAD);
    assert!(
        live.active()
            && live.recorder().unwrap().start.is_some()
            && sims.owner.ask(|s| s.orphans.is_empty()).await
    );
    // The pre-upgrade release is still owed and runs; the grant is not woken again.
    sims.tick().await;
    assert_eq!(
        (fake.count("release SIM2"), fake.woken.lock().unwrap().len()),
        (1, 0)
    );
    assert_eq!(queue(&sims), [(B.into(), true)]);
    // The handed-over recording still files as a whole movie.
    let receipt = sims.stop(Some(THREAD), None).await.unwrap();
    assert!(receipt.media_id.is_some());
    let _ = recorder.wait().await;
}

/// Past the limit, starts wait first come first served: a freed slot is
/// held for the head (a later thread can't take it) and the head is woken
/// once, even across a restart; its next start takes the slot.
#[tokio::test]
async fn full_starts_wait_in_line_and_the_head_is_woken() {
    let dir = tempfile::tempdir().unwrap();
    let (sims, fake) = sims(dir.path(), Some(Ok(())));
    sims.start(THREAD, None).await.unwrap();
    assert_eq!(sims.start(B, None).await.unwrap()["position"], 1);
    assert_eq!(sims.start(C, None).await.unwrap()["position"], 2);
    // Asking again keeps the place.
    assert_eq!(sims.start(B, None).await.unwrap()["position"], 1);
    assert_eq!(*fake.waiting.lock().unwrap(), [B, C]);

    sims.stop(Some(THREAD), None).await.unwrap();
    sims.tick().await;
    assert_eq!(queue(&sims), [(B.into(), true), (C.into(), false)]);
    assert_eq!(
        fake.woken
            .lock()
            .unwrap()
            .iter()
            .map(|w| w.0.as_str())
            .collect::<Vec<_>>(),
        [B]
    );
    // The held slot isn't anyone else's, newcomer or next in line.
    assert_eq!(sims.start(D, None).await.unwrap()["position"], 2);
    assert_eq!(sims.start(C, None).await.unwrap()["status"], "queued");

    // A restart neither loses the line nor wakes the head again.
    drop(sims);
    let reopened = Sims::with_host(dir.path(), fake.clone()).unwrap();
    reopened.tick().await;
    assert_eq!(fake.woken.lock().unwrap().len(), 1);
    assert_eq!(
        queue(&reopened),
        [(B.into(), true), (C.into(), false), (D.into(), false)]
    );

    reopened.start(B, None).await.unwrap();
    assert_eq!(queue(&reopened), [(C.into(), false), (D.into(), false)]);
    assert_eq!(*fake.waiting.lock().unwrap(), [C, D]);
    reopened.stop(Some(B), None).await.unwrap();
}

/// A grant whose save fails is neither seen nor woken; once the ledger
/// can be saved, the grant is saved and then woken, once.
#[tokio::test]
async fn no_wake_before_its_grant_is_saved() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let (sims, fake) = sims(dir.path(), Some(Ok(())));
    sims.start(THREAD, None).await.unwrap();
    assert_eq!(sims.start(B, None).await.unwrap()["status"], "queued");
    sims.stop(Some(THREAD), None).await.unwrap();
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o500)).unwrap();
    sims.tick().await;
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(
        (queue(&sims), fake.woken.lock().unwrap().len()),
        (vec![(B.into(), false)], 0)
    );
    sims.tick().await;
    assert_eq!(
        (queue(&sims), fake.woken.lock().unwrap().len()),
        (vec![(B.into(), true)], 1)
    );
    let saved: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("sims.json")).unwrap()).unwrap();
    assert_eq!(saved["queue"][0]["grant"]["wake"], "queued");
}
