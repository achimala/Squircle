use super::*;

pub(super) async fn start_build(state: AppState, mut request: BuildRequest) -> ApiResult<Value> {
    if request.scheme.trim().is_empty() || request.configuration.trim().is_empty() {
        return Err(ApiError::bad("Scheme and configuration are required"));
    }
    request.project = request.project.canonicalize().map_err(ApiError::bad)?;
    if !matches!(
        request.project.extension().and_then(|s| s.to_str()),
        Some("xcodeproj" | "xcworkspace")
    ) || !request.project.is_dir()
    {
        return Err(ApiError::bad(
            "Project must be an .xcodeproj or .xcworkspace directory",
        ));
    }
    if let Some(options) = &request.export_options {
        request.export_options = Some(options.canonicalize().map_err(ApiError::bad)?);
    }
    if request.mode == BuildMode::Archive && request.export_options.is_none() {
        return Err(ApiError::bad("Archive builds require --export-options"));
    }
    if let Some(key) = &request.request_id
        && (key.is_empty()
            || key.len() > 128
            || !key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "_-".contains(c)))
    {
        return Err(ApiError::bad(
            "Request ID must contain 1–128 letters, digits, underscores or hyphens",
        ));
    }
    if let Some(thread) = &request.thread
        && (thread.is_empty() || thread.len() > 128)
    {
        return Err(ApiError::bad("Thread must be a T3 thread ID"));
    }
    // A worker that didn't say who it is is known by its worktree.
    if request.thread.is_none() {
        request.thread = state
            .agents
            .as_ref()
            .and_then(|a| a.worker_at(&request.project));
    }
    let (revision, dirty) = source_provenance(&request.project).await;
    if state.draining.load(Ordering::Acquire) {
        return Err(ApiError::unavailable());
    }
    let replay = |prior: JobView| -> ApiResult<Value> {
        if prior.job.request() != Some(&request) {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "request_id_conflict",
                "Request ID already belongs to different build arguments",
                "Use a new request ID for different work.",
            ));
        }
        Ok(success(json!({"job":prior,"replayed":true})))
    };
    if let Some(key) = &request.request_id
        && let Some(prior) = state.jobs.with_request_id(key)
    {
        return replay(prior);
    }
    let job = Job {
        id: uuid::Uuid::new_v4().to_string(),
        created_at: now(),
        updated_at: now(),
        origin: BuildOrigin::Project {
            request: request.clone(),
            provenance: Provenance {
                revision,
                dirty,
                main_project: crate::git::main_checkout(&request.project),
            },
        },
        phase: JobPhase::Queued,
    };
    let dir = state.files.job_dir(&job.id).map_err(ApiError::internal)?;
    // The jobs owner looks for the request ID again as it admits: two
    // starts with one ID admit one build.
    let lease = match state.jobs.admit(job.clone()).await {
        Ok(lease) => lease,
        Err(AdmitError::Duplicate(prior)) => return replay(*prior),
        Err(error) => return Err(admit_error(error)),
    };
    let response = state.jobs.get(&job.id);
    tokio::spawn(async move {
        let mut job = job;
        if let Some(agents) = &state.agents
            && let Err(error) = agents
                .build_started(&job.id, request.thread.as_deref())
                .await
        {
            eprintln!(
                "Build {} start not recorded for its agent: {error:#}",
                job.id
            );
        }
        let cancel = lease.cancelled.clone();
        let lane = state.clone();
        in_build_lane(&lane, cancel, move |admitted| async move {
        let receiver = lease.cancelled.clone();
        if !admitted || *receiver.borrow() {
            job.phase = JobPhase::Cancelled { message: None };
        } else {
            job.phase = JobPhase::Running;
            job.updated_at = now();
            let result = match state.jobs.commit(&lease, &job).await {
                Ok(()) => xcode::run(&request, &dir, receiver.clone()).await,
                Err(error) => {
                    state.draining.store(true, Ordering::Release);
                    Err(error.context("Could not persist Running state; Xcode was not started"))
                }
            };
            job.phase = match result {
                Ok(output) => JobPhase::Succeeded { output },
                Err(error) if *receiver.borrow() => JobPhase::Cancelled {
                    message: Some(format!("{error:#}")),
                },
                Err(error) => JobPhase::Failed {
                    message: format!("{error:#}"),
                },
            };
        }
        job.updated_at = now();
        if let Err(error) = state.jobs.finish(lease, &job).await {
            eprintln!(
                "Cannot persist job {}: {error:#}. Service paused; the result is served from memory until shutdown.",
                job.id
            );
            state.draining.store(true, Ordering::Release);
        }
        xcode::shed(dir.clone(), job.request().map(|r| r.mode.clone())).await;
        let app = build_app(&state, &job).await;
        if let Some(push) = &state.push {
            push.build_finished(&job, app.as_ref());
        }
        tell_agent(&state, &job, app.as_ref()).await;
        })
        .await;
    });
    Ok(success(json!({"job":response,"replayed":false})))
}

/// A succeeded or failed build goes to its app agent's conversation.
pub(super) async fn tell_agent(state: &AppState, job: &Job, app: Option<&apps::AppRecord>) {
    let (Some(agents), Some(request)) = (&state.agents, job.request()) else {
        return;
    };
    let succeeded = match job.state() {
        BuildState::Succeeded => true,
        BuildState::Failed => false,
        _ => return,
    };
    let reason = if succeeded {
        None
    } else {
        let log = state
            .files
            .job_dir(&job.id)
            .ok()
            .map(|dir| dir.join("build.log"));
        let text = match log {
            Some(log) => log_tail(&log, FAILURE_LOG_TAIL_BYTES).await,
            None => vec![],
        };
        let root = request
            .project
            .parent()
            .map(|p| p.to_string_lossy().into_owned());
        let failure = crate::buildlog::failure(&String::from_utf8_lossy(&text), root.as_deref());
        let first = failure
            .errors
            .first()
            .map(|e| e.message.clone())
            .or_else(|| {
                job.error()
                    .map(|e| e.rsplit_once("; see /").map_or(e, |(m, _)| m).to_string())
            });
        first.map(|r| {
            let line = r.lines().next().unwrap_or_default().trim().to_string();
            if line.chars().count() > 200 {
                line.chars().take(199).collect::<String>() + "…"
            } else {
                line
            }
        })
    };
    let title = app
        .map(|a| a.name.clone())
        .or_else(|| job.output().map(|o| o.title.clone()))
        .unwrap_or_else(|| request.scheme.clone());
    let build = crate::agents::FinishedBuild {
        id: job.id.clone(),
        thread: request.thread.clone(),
        app: title,
        succeeded,
        reason,
    };
    if let Err(error) = agents.build_finished(&build).await {
        eprintln!("Build {} not queued for its agent: {error:#}", job.id);
    }
}

pub(super) fn admit_error(error: AdmitError) -> ApiError {
    match error {
        AdmitError::Full => ApiError::bad(format!(
            "Build queue is full ({MAX_OPERATIONS} jobs); wait or cancel a job"
        )),
        AdmitError::Refused(message) => ApiError::bad(message),
        AdmitError::Persist(error) => ApiError::internal(format!("{error:#}")),
        AdmitError::Closed => ApiError::unavailable(),
        AdmitError::Duplicate(prior) => ApiError::bad(format!(
            "Build {} already has this request ID",
            prior.job.id
        )),
    }
}

/// Best-effort submission-time observations. Builds still use the working tree;
/// these fields deliberately do not claim that queued work uses a Git snapshot.
pub(super) async fn source_provenance(project: &std::path::Path) -> (Option<String>, Option<bool>) {
    let Some(directory) = project.parent() else {
        return (None, None);
    };
    let Ok(revision) =
        crate::git::run(directory, &["rev-parse", "--verify", "HEAD^{commit}"], 128).await
    else {
        return (None, None);
    };
    let Ok(revision) = String::from_utf8(revision) else {
        return (None, None);
    };
    let revision = revision.trim();
    if !matches!(revision.len(), 40 | 64) || !revision.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return (None, None);
    }
    let status = [
        "status",
        "--porcelain=v1",
        "--untracked-files=normal",
        "--ignore-submodules=none",
    ];
    let dirty = crate::git::run(directory, &status, 1024 * 1024)
        .await
        .ok()
        .map(|output| !output.is_empty());
    (Some(revision.to_owned()), dirty)
}

/// Imports an IPA as a finished job: copying, ZIP inspection and fsync run
/// off the HTTP workers and block nothing else; the job is published once
/// its IPA is in place, even if the request goes away meanwhile.
pub(super) async fn import_job(
    state: AppState,
    source: PathBuf,
    prepare: impl FnOnce(&std::path::Path, &std::path::Path) -> Result<BuildOutput> + Send + 'static,
) -> Result<Job> {
    tokio::spawn(async move {
        let importing = state.clone();
        let job =
            tokio::task::spawn_blocking(move || import_ipa(&importing, &source, prepare)).await??;
        state.jobs.insert(job.clone()).await?;
        Ok(job)
    })
    .await?
}

pub(super) fn copy_and_inspect_ipa(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> Result<BuildOutput> {
    std::fs::copy(source, destination)?;
    std::fs::File::open(destination)?.sync_all()?;
    artifact::inspect_ipa(destination)
}

/// Copies and validates an IPA into a new job's directory; the caller then
/// publishes the job.
pub(super) fn import_ipa(
    state: &AppState,
    source: &std::path::Path,
    prepare: impl FnOnce(&std::path::Path, &std::path::Path) -> Result<BuildOutput>,
) -> Result<Job> {
    let source = source.canonicalize()?;
    let metadata = std::fs::metadata(&source)?;
    anyhow::ensure!(metadata.is_file(), "IPA must be a regular file");
    anyhow::ensure!(
        metadata.len() <= 4 * 1024 * 1024 * 1024u64,
        "IPA exceeds 4 GiB"
    );
    let id = uuid::Uuid::new_v4().to_string();
    anyhow::ensure!(
        !state.draining.load(Ordering::Acquire),
        "Service is shutting down or paused"
    );
    let dir = state.files.job_dir(&id)?;
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&dir)?;
    let output = match prepare(&source, &dir.join("app.ipa")) {
        Ok(output) => output,
        Err(error) => {
            // No job record exists yet. Clean up only this import's staging
            // directory; never erase evidence after attempting publication.
            let _ = std::fs::remove_dir_all(&dir);
            return Err(error);
        }
    };
    let job = Job {
        id,
        created_at: now(),
        updated_at: now(),
        origin: BuildOrigin::Imported,
        phase: JobPhase::Succeeded { output },
    };
    // Work admitted before shutdown may finish. Publication (`Jobs::insert`)
    // occurs only after the copied IPA has been synced and its metadata validated.
    Ok(job)
}

/// Runs `work` in the build lane: one build at a time, in
/// order. Its argument says whether it got there; a job cancelled while it
/// waits runs `work(false)` at once, outside the lane, to record that.
async fn in_build_lane<F, Fut>(
    state: &AppState,
    cancel: tokio::sync::watch::Receiver<bool>,
    work: F,
) where
    F: FnOnce(bool) -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let entered = AtomicBool::new(false);
    let mut work = Some(work);
    let waited_out = tokio::select! {
        biased;
        () = state.builds.run(async {
            entered.store(true, Ordering::Release);
            (work.take().expect("runs once"))(true).await
        }) => false,
        () = cancelled_outside(&entered, cancel) => true,
    };
    if waited_out {
        (work.take().expect("runs once"))(false).await;
    }
}

/// Resolves when the job is cancelled (or its record goes) before it has
/// entered the lane; once in, cancellation is the work's own to handle.
async fn cancelled_outside(entered: &AtomicBool, mut cancel: tokio::sync::watch::Receiver<bool>) {
    loop {
        if entered.load(Ordering::Acquire) {
            return std::future::pending().await;
        }
        if *cancel.borrow_and_update() || cancel.changed().await.is_err() {
            if entered.load(Ordering::Acquire) {
                return std::future::pending().await;
            }
            return;
        }
    }
}
