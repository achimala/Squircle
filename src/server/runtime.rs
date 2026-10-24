use super::*;

pub async fn serve(root: PathBuf, listen: SocketAddr, public_url: Option<String>) -> Result<()> {
    let mut store = Store::open(root)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(store.root.join("service.lock"))?;
    // The kernel releases this lock when its holder exits, however it exits,
    // so only a running service can refuse a start; its PID says which.
    if let Err(error) = lock.try_lock() {
        let holder = std::fs::read_to_string(store.root.join("service.lock")).unwrap_or_default();
        return Err(anyhow::Error::new(error).context(format!(
            "Another Squircle service owns this data directory (process {})",
            holder.trim()
        )));
    }
    lock.set_len(0)?;
    (&lock).write_all(std::process::id().to_string().as_bytes())?;
    // Given once, the public URL is kept for every later start.
    let public_url = match public_url {
        Some(url) => {
            let url = artifact::validate_public_url(&url)?;
            store.set_public_url(url.clone())?;
            Some(url)
        }
        None => store
            .settings
            .public_url
            .as_deref()
            .map(artifact::validate_public_url)
            .transpose()?,
    };
    let listener = tokio::net::TcpListener::bind(listen).await?;
    let tasks = Arc::new(Tasks::open(&store.root)?);
    let agents = Agents::open(
        &store.root,
        &format!("http://{}", listener.local_addr()?),
        tasks.clone(),
    )?;
    let push = Push::open(&store.root)?;
    agents.attach_push(push.clone());
    let pool = Pool::open(&store.root, agents.clone())?;
    let sims = Sims::open(&store.root, agents.clone(), pool.clone())?;
    pool.remember_leased(sims.used()).await;
    let mut state = tokio::task::spawn_blocking(move || AppState::new(store, public_url)).await??;
    state.agents = Some(agents.clone());
    state.sims = Some(sims.clone());
    state.pool = Some(pool.clone());
    state.push = Some(push.clone());
    state.tasks = Some(tasks.clone());
    // Service loops, stopped explicitly once requests have drained.
    let mut background = Vec::new();
    {
        // Linked workers and builds move tasks on, as T3, the builds and the
        // tasks themselves change; old ones age into History when due.
        let state = state.clone();
        let mut changes = futures_util::stream::select_all([
            agents.changes(),
            state.jobs.changes(),
            tasks.changes(),
        ]);
        background.push(tokio::spawn(async move {
            use futures_util::StreamExt;
            loop {
                if let Err(error) = tasks.tick(|task| task_signals(&state, task)).await {
                    eprintln!("Tasks not updated: {error:#}");
                }
                let aged = tasks.next_age().map(|at| at as f64);
                tokio::select! {
                    changed = changes.next() => if changed.is_none() { return },
                    _ = crate::clock::until(aged) => {}
                }
            }
        }));
    }
    eprintln!(
        "Squircle listening on {}. Keep this process running; HTTPS/Tailscale is managed separately.",
        listener.local_addr()?
    );
    // After the announcement, which is the first line supervisors read.
    background.push(tokio::spawn(agents.clone().run()));
    background.push(tokio::spawn(agents.clone().upkeep()));
    background.push(tokio::spawn(push.clone().run()));
    background.push(tokio::spawn(sims.clone().run()));
    background.push(tokio::spawn(pool.clone().run(sims.clone())));
    background.push(tokio::spawn(
        crate::simwatch::Watch {
            pool: pool.clone(),
            sims: sims.clone(),
            agents: agents.clone(),
        }
        .run(),
    ));
    // SIGTERM is a restart (`squircle service restart`, or a supervisor
    // replacing the binary): simulator sessions are handed to the next run.
    // SIGINT (Ctrl-C, `squircle service stop`) is a real stop that ends them.
    #[cfg(unix)]
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let signal = async move {
        #[cfg(unix)]
        tokio::select! { _ = tokio::signal::ctrl_c() => Exit::Stop, _ = terminate.recv() => Exit::Handover }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
            Exit::Stop
        }
    };
    let shutdown = state.clone();
    crate::serving::serve(listener, router(state), signal, |exit| async move {
        eprintln!(
            "{}",
            match exit {
                Exit::Handover =>
                    "Restarting: simulator sessions keep running for the next start to adopt.",
                Exit::Stop => "Stopping: simulator sessions end and their recordings are filed.",
            }
        );
        // The jobs owner refuses admission and cancels what runs in one turn,
        // so no job registers after the cutoff.
        shutdown.draining.store(true, Ordering::Release);
        shutdown.jobs.close().await;
        // Cancelled runners reap their children and persist terminal state:
        // their group's death ends each, so this ends.
        shutdown.jobs.idle().await;
        // Refuses new simulator starts; on a stop, also stops and files
        // recordings and closes their T3 device sessions. Anything a
        // supervisor cuts off here is left in the durable ledger for the
        // next start to recover.
        sims.shutdown(exit).await;
    })
    .await;
    for task in background {
        task.abort();
    }
    drop(lock);
    Ok(())
}
