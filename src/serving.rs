//! The HTTP accept loop, with a shutdown that cannot be held open by a peer.
//!
//! axum's graceful shutdown waits for every open connection, so one client
//! that stops reading a streamed movie or IPA (a paused player behind the
//! Tailscale proxy) or stops sending an upload kept a stopped service alive,
//! and its data-directory lock, indefinitely. Here shutdown is a sequence:
//! stop accepting and close idle connections; fail request bodies still being
//! read; run the service's own wind-down; wait for handlers already running
//! (their own work, which ends); then drop every connection that remains,
//! which only peer-paced response streams can be.

use axum::{
    Router,
    body::{Body, Bytes},
    extract::Request,
};
use http_body::{Frame, SizeHint};
use hyper_util::{
    rt::{TokioExecutor, TokioIo},
    server::conn::auto,
};
use std::{
    future::Future,
    pin::{Pin, pin},
    task::{Context, Poll},
};
use tokio::net::TcpListener;
use tokio_util::{
    sync::{CancellationToken, WaitForCancellationFutureOwned},
    task::TaskTracker,
};
use tower::ServiceExt;

/// Serves `app` until `signal` resolves, then shuts down as described above;
/// `wind_down` gets what the signal resolved to, and runs while in-flight
/// handlers may still finish.
pub async fn serve<S, F>(
    listener: TcpListener,
    app: Router,
    signal: impl Future<Output = S>,
    wind_down: impl FnOnce(S) -> F,
) where
    F: Future<Output = ()>,
{
    let closing = CancellationToken::new();
    let cut = CancellationToken::new();
    let connections = TaskTracker::new();
    let handlers = TaskTracker::new();
    let mut listener = listener;
    let mut signal = pin!(signal);
    let reason = loop {
        let (stream, _) = tokio::select! {
            accepted = axum::serve::Listener::accept(&mut listener) => accepted,
            reason = &mut signal => break reason,
        };
        let (app, closing, cut, handlers) = (app.clone(), closing.clone(), cut.clone(), handlers.clone());
        connections.spawn(async move {
            let bodies = closing.clone();
            let service = hyper::service::service_fn(move |request: Request<hyper::body::Incoming>| {
                let request = request.map(|body| Body::new(Closing::new(body, bodies.clone())));
                handlers.track_future(app.clone().oneshot(request))
            });
            let builder = auto::Builder::new(TokioExecutor::new());
            let mut connection = pin!(builder.serve_connection(TokioIo::new(stream), service));
            tokio::select! {
                _ = connection.as_mut() => return,
                () = closing.cancelled() => connection.as_mut().graceful_shutdown(),
            }
            tokio::select! {
                _ = connection => {}
                () = cut.cancelled() => {}
            }
        });
    };
    drop(listener);
    closing.cancel();
    wind_down(reason).await;
    handlers.close();
    handlers.wait().await;
    cut.cancel();
    connections.close();
    connections.wait().await;
}

/// A request body that fails once shutdown begins, so a handler reading an
/// upload from a stalled client returns instead of waiting on it.
struct Closing {
    body: hyper::body::Incoming,
    closed: Pin<Box<WaitForCancellationFutureOwned>>,
}

impl Closing {
    fn new(body: hyper::body::Incoming, closing: CancellationToken) -> Self {
        Self { body, closed: Box::pin(closing.cancelled_owned()) }
    }
}

impl http_body::Body for Closing {
    type Data = Bytes;
    type Error = axum::Error;

    fn poll_frame(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Result<Frame<Bytes>, axum::Error>>> {
        if self.body.is_end_stream() {
            return Poll::Ready(None);
        }
        if self.closed.as_mut().poll(cx).is_ready() {
            return Poll::Ready(Some(Err(axum::Error::new("the service is shutting down"))));
        }
        Pin::new(&mut self.body).poll_frame(cx).map_err(axum::Error::new)
    }

    fn is_end_stream(&self) -> bool {
        self.body.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.body.size_hint()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::routing::{get, post};
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// A client that never reads a long download, and one that never finishes
    /// an upload, cannot keep a stopped service running; a request already
    /// being handled still gets its answer.
    #[tokio::test]
    async fn shutdown_ends_with_stalled_clients() {
        let movie = Bytes::from(vec![7u8; 64 * 1024 * 1024]);
        let app = Router::new()
            .route("/movie", get(move || async move { Body::from_stream(futures_util::stream::iter([Ok::<_, std::io::Error>(movie)])) }))
            .route("/upload", post(|body: Bytes| async move { body.len().to_string() }))
            .route("/slow", get(|| async {
                tokio::time::sleep(Duration::from_millis(200)).await;
                "done"
            }));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let stop = CancellationToken::new();
        let server = tokio::spawn(serve(listener, app, stop.clone().cancelled_owned(), |()| async {}));

        let mut download = tokio::net::TcpStream::connect(address).await.unwrap();
        download.write_all(b"GET /movie HTTP/1.1\r\nhost: x\r\n\r\n").await.unwrap();
        let mut head = [0u8; 12];
        download.read_exact(&mut head).await.unwrap();
        assert_eq!(&head, b"HTTP/1.1 200");
        let mut upload = tokio::net::TcpStream::connect(address).await.unwrap();
        upload.write_all(b"POST /upload HTTP/1.1\r\nhost: x\r\ncontent-length: 1000\r\n\r\npartial").await.unwrap();
        let mut slow = tokio::net::TcpStream::connect(address).await.unwrap();
        slow.write_all(b"GET /slow HTTP/1.1\r\nhost: x\r\n\r\n").await.unwrap();
        let _idle = tokio::net::TcpStream::connect(address).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;

        stop.cancel();
        tokio::time::timeout(Duration::from_secs(5), server).await.expect("shutdown waited on a client").unwrap();
        let mut answer = String::new();
        slow.read_to_string(&mut answer).await.unwrap();
        assert!(answer.starts_with("HTTP/1.1 200") && answer.ends_with("done"), "{answer}");
    }
}
