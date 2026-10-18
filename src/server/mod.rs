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
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::OpenOptions,
    io::Write,
    net::SocketAddr,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::Semaphore;
use tokio_util::io::ReaderStream;

mod http;
use http::*;
mod router;
pub use router::router;
mod runtime;
pub use runtime::serve;
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

#[derive(Clone)]
pub struct AppState {
    /// The store's immutable root and credentials, for authentication, paths
    /// and reads (records are replaced atomically).
    pub files: Arc<Store>,
    /// Install-link tickets: their read/modify/write is this owner's.
    tickets: Owner<Store>,
    /// App catalog writes, one at a time.
    catalog: Arc<Lane>,
    /// Per-build diagnostic appends and reads (append-only files), one at a time.
    diagnostics: Arc<Lane>,
    /// Build jobs: records, unpersisted results and live operations.
    jobs: Arc<Jobs>,
    slots: Arc<Semaphore>,
    inspection_slots: Arc<Semaphore>,
    public_url: Option<String>,
    draining: Arc<AtomicBool>,
    agents: Option<Arc<Agents>>,
    sims: Option<Arc<Sims>>,
    pool: Option<Arc<Pool>>,
    push: Option<Arc<Push>>,
    tasks: Option<Arc<Tasks>>,
}

impl AppState {
    /// Loads the job index; work a previous service left unfinished is
    /// recorded as interrupted. Call inside the runtime.
    pub fn new(store: Store, public_url: Option<String>) -> Result<Self> {
        Ok(Self {
            jobs: Arc::new(Jobs::open(&store)?),
            files: Arc::new(store.clone()),
            tickets: Owner::spawn("install tickets", store),
            catalog: Arc::new(Lane::new(Rank::Catalog)),
            diagnostics: Arc::new(Lane::new(Rank::Diagnostics)),
            slots: Arc::new(Semaphore::new(1)),
            inspection_slots: Arc::new(Semaphore::new(2)),
            public_url,
            draining: Arc::new(AtomicBool::new(false)),
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

#[cfg(test)]
mod tests;
