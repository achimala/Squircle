// No locks or blocking waits: see actor and clippy.toml.
#![deny(clippy::disallowed_types, clippy::disallowed_methods)]

mod cli;

#[tokio::main]
async fn main() {
    cli::main().await;
}
