//! Explicit state machines (docs/fsm-architecture.md): pure reducers whose
//! effects are values, run by a thin owner. `core` holds the shared
//! contracts and the durable commit gate (C00); each owner has its own
//! module.

pub mod coordinator;
pub mod core;
pub mod sims;
pub mod tasks;
