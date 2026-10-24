//! Implementation shared by Squircle’s CLI, service and integration tests.
//! The supported product interfaces are the CLI and HTTP protocols. Public
//! Rust modules enable those internal consumers; they are not a stable Rust SDK.

// No locks or blocking waits: state is shared only through single owners
// (see `actor` and clippy.toml).
#![deny(clippy::disallowed_types, clippy::disallowed_methods)]

pub mod actor;
pub mod agents;
pub mod apps;
pub mod artifact;
pub mod buildlog;
pub mod fsm;
pub mod git;
pub mod guard;
pub mod history;
pub mod media;
pub mod model;
pub mod notes;
pub mod origin;
pub mod overlay;
pub mod perf;
pub mod preview;
mod process;
pub mod projects;
pub mod push;
pub mod recordings;
pub mod server;
pub mod service;
pub mod serving;
pub mod simpool;
pub mod sims;
pub mod simwatch;
pub mod store;
pub mod symbolicate;
pub mod t3;
mod t3db;
pub mod t3steps;
pub mod tasks;
pub mod upkeep;
mod viewed;
pub mod xcode;
