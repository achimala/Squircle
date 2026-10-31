//! HTTP boundary and application services. Shared owners are wired here;
//! endpoint modules only adapt requests to the existing owners and services.

use crate::actor::{Lane, Owner, Rank};
use crate::{
    agents::Agents,
    apps, artifact,
    model::*,
    preview, projects,
    push::Push,
    simpool::Pool,
    sims::{Exit, Sims},
    store::{AdmitError, JobView, Jobs, MAX_OPERATIONS, Store},
    tasks::{self, Tasks},
    xcode,
};
use anyhow::Result;
use axum::{
    Json, Router,
    body::Body,
    extract::{
        DefaultBodyLimit, Path, Query, Request, State,
        rejection::{JsonRejection, QueryRejection},
    },
    http::{HeaderMap, HeaderValue, Method, StatusCode, header},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::{get, post, put},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::OpenOptions,
    io::Write,
    net::SocketAddr,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
};
use tokio_util::io::ReaderStream;

mod http;
use http::*;
mod router;
pub use router::router;
mod runtime;
pub use http::WAIT_FOR_CHANGE;
pub use runtime::{LISTENING, serve};
mod build_routes;
use build_routes::*;
mod build_service;
use build_service::*;
mod catalog_service;
use catalog_service::*;
mod catalog_routes;
use catalog_routes::*;
mod media_routes;
use media_routes::*;
mod install_routes;
use install_routes::*;
mod diagnostic_routes;
use diagnostic_routes::*;
mod sim_routes;
use sim_routes::*;
mod agent_routes;
use agent_routes::*;
mod push_routes;
use push_routes::*;
mod task_routes;
use task_routes::*;
mod waiting_routes;
use waiting_routes::*;
mod event_routes;
use event_routes::*;

#[derive(Clone)]
pub struct AppState {
    /// The store's immutable root and credentials, for authentication, paths
    /// and reads (records are replaced atomically).
    pub files: Arc<Store>,
    /// Install-link tickets: their read/modify/write is this owner's.
    tickets: Owner<Store>,
    /// App catalog writes, one at a time.
    catalog: Arc<Lane>,
    /// Counts catalog writes, so the phone's event stream hears of them.
    catalog_changed: Arc<tokio::sync::watch::Sender<u64>>,
    /// Counts install-link transfer marks, for the same stream.
    installs_changed: Arc<tokio::sync::watch::Sender<u64>>,
    /// Per-build diagnostic appends and reads (append-only files), one at a time.
    diagnostics: Arc<Lane>,
    /// Build jobs: records, unpersisted results and live operations.
    jobs: Arc<Jobs>,
    /// Builds and previews, one at a time.
    builds: Arc<Lane>,
    /// Xcode inspections running now; more than two are refused, not queued.
    inspections: Arc<AtomicUsize>,
    /// Counts stored diagnostics, so a build's status waiting for a change
    /// hears of new launch evidence.
    diagnosed: Arc<tokio::sync::watch::Sender<u64>>,
    public_url: Option<String>,
    draining: Arc<AtomicBool>,
    /// Cancelled as shutdown begins: requests waiting for a change answer
    /// with what they have.
    closing: tokio_util::sync::CancellationToken,
    agents: Option<Arc<Agents>>,
    sims: Option<Arc<Sims>>,
    pool: Option<Arc<Pool>>,
    push: Option<Arc<Push>>,
    tasks: Option<Arc<Tasks>>,
}

/// One of at most two Xcode inspections at once: a third is refused,
/// never queued. Dropping it frees its place.
pub(super) struct Inspection(Arc<AtomicUsize>);

impl Drop for Inspection {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

impl AppState {
    /// One item each time something a build's status shows may have
    /// changed: its job, its launch diagnostics, the agent that owns it.
    /// Ends as shutdown begins.
    pub(super) fn build_changes(&self) -> futures_util::stream::BoxStream<'static, ()> {
        use futures_util::StreamExt;
        let mut sources = vec![self.jobs.changes(), counted(&self.diagnosed)];
        sources.extend(self.agents.as_ref().map(|a| a.changes()));
        futures_util::stream::select_all(sources)
            .take_until(self.closing.clone().cancelled_owned())
            .boxed()
    }

    /// A place for one Xcode inspection, if one is free now.
    pub(super) fn inspection(&self) -> Option<Inspection> {
        self.inspections
            .try_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < 2).then_some(n + 1)
            })
            .ok()
            .map(|_| Inspection(self.inspections.clone()))
    }

    /// Loads the job index; work a previous service left unfinished is
    /// recorded as interrupted. Call inside the runtime.
    pub fn new(store: Store, public_url: Option<String>) -> Result<Self> {
        Ok(Self {
            jobs: Arc::new(Jobs::open(&store)?),
            files: Arc::new(store.clone()),
            tickets: Owner::spawn("install tickets", store),
            catalog: Arc::new(Lane::new(Rank::Catalog)),
            catalog_changed: Arc::new(tokio::sync::watch::channel(0).0),
            installs_changed: Arc::new(tokio::sync::watch::channel(0).0),
            diagnostics: Arc::new(Lane::new(Rank::Diagnostics)),
            builds: Arc::new(Lane::new(Rank::Build)),
            inspections: Arc::new(AtomicUsize::new(0)),
            diagnosed: Arc::new(tokio::sync::watch::channel(0).0),
            public_url,
            draining: Arc::new(AtomicBool::new(false)),
            closing: tokio_util::sync::CancellationToken::new(),
            agents: None,
            sims: None,
            pool: None,
            push: None,
            tasks: None,
        })
    }
}

/// Runs blocking file work in `lane`, off the async workers, to its end even
/// if the request that asked for it goes away (so the lane is held for as
/// long as the work runs).
async fn in_lane<T: Send + 'static>(
    lane: &Arc<Lane>,
    work: impl FnOnce() -> T + Send + 'static,
) -> std::result::Result<T, tokio::task::JoinError> {
    let lane = lane.clone();
    tokio::spawn(async move { lane.run(tokio::task::spawn_blocking(work)).await }).await?
}

/// Where catalog writes run: its lane, and the count they bump.
pub(super) struct CatalogWrites(Arc<Lane>, Arc<tokio::sync::watch::Sender<u64>>);

impl AppState {
    pub(super) fn catalog_writes(&self) -> CatalogWrites {
        CatalogWrites(self.catalog.clone(), self.catalog_changed.clone())
    }
}

/// [`in_lane`] in the catalog's lane, then tells the catalog's readers.
async fn in_catalog<T: Send + 'static>(
    writes: CatalogWrites,
    work: impl FnOnce() -> T + Send + 'static,
) -> std::result::Result<T, tokio::task::JoinError> {
    let done = in_lane(&writes.0, work).await;
    writes.1.send_modify(|n| *n = n.wrapping_add(1));
    done
}

/// One item after each change `sender` counts.
pub(super) fn counted(
    sender: &tokio::sync::watch::Sender<u64>,
) -> futures_util::stream::BoxStream<'static, ()> {
    use futures_util::StreamExt;
    let mut counted = sender.subscribe();
    counted.mark_unchanged();
    futures_util::stream::unfold(counted, |mut c| async move {
        c.changed().await.ok()?;
        Some(((), c))
    })
    .boxed()
}

#[cfg(test)]
mod tests;
