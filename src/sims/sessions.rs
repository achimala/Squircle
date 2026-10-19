use super::*;

impl Sims {
    // MARK: Stop

    /// Stops a thread's session (or one by ID) and files its recording.
    pub async fn stop(&self, thread: Option<&str>, id: Option<&str>) -> Result<StopReceipt> {
        let session = self
            .ledger()
            .sessions
            .iter()
            .rev()
            .find(|s| {
                s.active()
                    && (id.is_some_and(|i| s.id == i)
                        || (id.is_none() && thread.is_some_and(|t| s.thread_id == t)))
            })
            .cloned();
        let Some(session) = session else {
            bail!(
                "No simulator session is running{}",
                thread
                    .map(|t| format!(" for thread {t}"))
                    .unwrap_or_default()
            );
        };
        let session = self.finish(&session.id, "stopped").await?;
        let media_id = match &session.phase {
            Phase::Finished { media_id, .. } => Some(media_id.clone()),
            _ => None,
        };
        Ok(StopReceipt {
            session: Served::from(&session),
            media_id,
        })
    }

    /// Ends the recording, closes T3's device session, has the pool release
    /// the simulator and files the recording. Problems are recorded on the
    /// session; an error means a save failed, or another stop has it.
    pub(super) async fn finish(&self, id: &str, reason: &str) -> Result<Session> {
        let _finish = self
            .claim(id, Work::Finish)
            .await
            .context("The session is already being stopped")?;
        self.halt(id, reason, RECORDER_GRACE, false)
            .await?
            .context("The session is already being stopped")?;
        self.cleanup(id, false).await;
        self.file(id, true).await
    }

    /// A session left part-way (a previous run's, or one whose step couldn't
    /// be saved) is finished from where it stands.
    pub(super) async fn resume(&self, id: &str, reason: &str) {
        let Some(_finish) = self.claim(id, Work::Finish).await else {
            return;
        };
        if let Err(error) = self.halt(id, reason, RECORDER_GRACE, true).await {
            eprintln!("Simulator session {id} not stopped: {error:#}");
        }
        self.cleanup(id, false).await;
        if let Err(error) = self.file(id, true).await {
            eprintln!("Simulator session {id} not filed: {error:#}");
        }
    }

    /// Claims a session (saved), stops its recorder and saves that it
    /// stopped: from then on its close, release and filing are owed. None if
    /// it isn't this call's to stop.
    pub(super) async fn halt(
        &self,
        id: &str,
        reason: &str,
        grace: Duration,
        recovering: bool,
    ) -> Result<Option<Session>> {
        let (stopping, reason) = (id.to_string(), reason.to_string());
        let halted = self
            .owner
            .ask(move |s| -> Result<Option<(Session, Option<Recorder>)>> {
                let (disposition, _) = s.step(&stopping, Event::Stop { reason, recovering })?;
                if disposition != Disposition::Applied {
                    return Ok(None);
                }
                let session = s
                    .ledger()
                    .session(&stopping)
                    .cloned()
                    .context("No such simulator session")?;
                s.clocks.remove(&stopping);
                Ok(Some((session, s.recorders.remove(&stopping))))
            })
            .await?;
        let Some((session, recorder)) = halted else {
            return Ok(None);
        };
        if let Ok(raw) = media::recording_path(&self.root, &session.thread_id, id) {
            self.host
                .poster(&session.device_id, &raw.with_extension("poster.jpg"))
                .await;
        }
        let mut warning = None;
        match recorder {
            Some(Recorder::Owned(mut child)) => {
                if let Some(pid) = child.id() {
                    // simctl writes the movie's index when interrupted.
                    unsafe { libc::kill(pid as i32, libc::SIGINT) };
                }
                if tokio::time::timeout(grace, child.wait()).await.is_err() {
                    let _ = child.kill().await;
                }
            }
            // Checked again just before the signal: the PID may have been reused since.
            Some(Recorder::Recovered(recorder)) if is_recorder(recorder, id) => {
                unsafe { libc::kill(recorder.pid as i32, libc::SIGINT) };
                let polls = (grace.as_millis() / 250).max(1);
                for _ in 0..polls {
                    if !is_recorder(recorder, id) {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
            }
            _ => {
                if let Some(recorder) = session.recorder().filter(|r| alive(r.pid)) {
                    warning = Some(format!(
                        "Process {} is no longer this session's recorder; it was left alone",
                        recorder.pid
                    ));
                }
            }
        }
        self.step(
            id,
            Event::RecorderStopped {
                now: now(),
                warning,
            },
        )
        .await?;
        Ok(self.ledger().session(id).cloned())
    }

    /// Runs a session's owed cleanup now: T3's close, then the pool's
    /// release. `force` ignores retry backoff (the service is stopping).
    pub(super) async fn cleanup(&self, id: &str, force: bool) {
        self.close(id, force).await;
        self.release(id, force).await;
    }

    /// Closes the session's T3 device session if a close is owed. A lost
    /// answer is settled by T3's list of open sessions; a failure stays owed.
    pub(super) async fn close(&self, id: &str, force: bool) {
        let Some(_close) = self.claim(id, Work::Close).await else {
            return;
        };
        let time = if force { f64::INFINITY } else { now() };
        let Some(session) = self
            .ledger()
            .session(id)
            .cloned()
            .filter(|s| s.close_due(time))
        else {
            return;
        };
        let closed = self
            .host
            .device(
                "device.close",
                json!({"threadId": session.thread_id, "hostId": session.host_id,
            "deviceId": session.device_id, "platform": "ios"}),
            )
            .await;
        let outcome = match closed {
            Ok(_) => Closed::Closed,
            Err(error) => match self.host.device_sessions().await {
                Ok(open)
                    if !open.iter().any(|(t, d)| {
                        *t == session.thread_id && d.eq_ignore_ascii_case(&session.device_id)
                    }) =>
                {
                    Closed::Absent
                }
                _ => Closed::Failed(format!("T3 did not close the simulator: {error:#}")),
            },
        };
        if let Err(error) = self
            .step(
                id,
                Event::CloseResult {
                    outcome,
                    now: now(),
                },
            )
            .await
        {
            eprintln!("{error:#}");
        }
    }

    /// Asks the pool to release the simulator once T3's device session is
    /// closed. Its answer is the receipt that frees the slot; a failure stays owed.
    pub(super) async fn release(&self, id: &str, force: bool) {
        let Some(_release) = self.claim(id, Work::Release).await else {
            return;
        };
        let time = if force { f64::INFINITY } else { now() };
        let ledger = self.ledger();
        let Some(session) = ledger.session(id).cloned().filter(|s| s.release_due(time)) else {
            return;
        };
        let others: Vec<Lease> = ledger
            .sessions
            .iter()
            .filter(|s| s.id != id && s.reserves())
            .map(|s| Lease {
                device_id: s.device_id.to_ascii_uppercase(),
                thread_id: s.thread_id.clone(),
            })
            .collect();
        let outcome = self
            .host
            .release(&session.device_id, &session.thread_id, &others)
            .await
            .map_err(|e| format!("{e:#}"));
        if let Err(error) = &outcome {
            eprintln!(
                "Simulator {} not released after its session: {error}",
                session.device_id
            );
        }
        if let Err(error) = self
            .step(
                id,
                Event::ReleaseResult {
                    outcome,
                    now: now(),
                },
            )
            .await
        {
            eprintln!("{error:#}");
        }
    }

    /// Moves a stopped session's recording into the thread's media.
    pub(super) async fn file(&self, id: &str, shrink: bool) -> Result<Session> {
        let session = self
            .ledger()
            .session(id)
            .cloned()
            .context("The session disappeared")?;
        let Phase::Filing {
            ended_at, warning, ..
        } = session.phase.clone()
        else {
            return Ok(session);
        };
        let raw = media::recording_path(&self.root, &session.thread_id, id);
        let path = match &raw {
            Ok(raw) => {
                let _ = std::fs::remove_file(raw.with_extension("log"));
                let nonempty = |p: &Path| p.metadata().is_ok_and(|m| m.len() > 0);
                if nonempty(raw) {
                    Some(raw.clone())
                } else {
                    // An earlier version compacted it but stopped before filing.
                    Some(compacted(raw)).filter(|p| nonempty(p))
                }
            }
            Err(_) => None,
        };
        let filed = path.map(|p| {
            media::add_recording(
                &self.root,
                &session.thread_id,
                &p,
                SimulatorClip {
                    session_id: id.into(),
                    device_id: session.device_id.clone(),
                    device_name: session.device_name.clone(),
                    started_at: session.started_at,
                    ended_at,
                },
            )
        });
        if let (Ok(raw), Some(Ok(media))) = (&raw, &filed) {
            let _ = std::fs::rename(
                raw.with_extension("poster.jpg"),
                media.file.with_extension("poster.jpg"),
            );
        }
        if let (true, Some(Ok(media))) = (shrink, &filed) {
            // Filed as recorded so the turn shows it now; made light in the
            // background and replaced in place (a long one takes minutes).
            let (host, file) = (self.host.clone(), media.file.clone());
            tokio::spawn(async move { host.shrink(&file).await });
        }
        let result = match filed {
            Some(Ok(media)) => Ok(media.id),
            Some(Err(error)) => Err(format!("{error:#}")),
            None => Err(warning.unwrap_or_else(|| "simctl wrote no video".into())),
        };
        self.step(id, Event::Filed(result)).await?;
        self.ledger()
            .session(id)
            .cloned()
            .context("The session disappeared")
    }

    /// This Mac's iOS simulators, and which thread (if any) is using each.
    pub async fn devices(&self) -> Result<Value> {
        let inventory = inventory(&*self.host).await?;
        let simulators = local_simulators(&inventory);
        ensure!(!simulators.is_empty(), "{}", no_simulators(&inventory));
        let ledger = self.ledger();
        let held: Vec<&Session> = ledger
            .sessions
            .iter()
            .filter(|s| s.holds_device())
            .collect();
        let devices: Vec<Value> = simulators.into_iter()
            .map(|d| {
                let session = held.iter().find(|s| Some(s.device_id.as_str()) == d["id"].as_str());
                json!({"id": d["id"], "name": d["name"], "version": d["version"], "booted": d["booted"],
                       "recording_for_thread": session.map(|s| s.thread_id.clone())})
            }).collect();
        Ok(json!({"devices": devices}))
    }
}

/// Why a session's cleanup is failing, if it is.
pub(super) fn cleanup_error(session: &Session) -> Option<String> {
    let retry = match (&session.device, &session.release) {
        (DeviceLease::CloseOwed(retry), _)
        | (DeviceLease::Closed, session::Release::Owed(retry)) => retry,
        _ => return None,
    };
    retry.error.clone()
}
