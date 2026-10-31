use super::*;

fn timed_out() -> Value {
    failure(
        "wait_timeout",
        "Wait timed out; the build was not cancelled",
        "Call build status or wait again with the same build ID.",
    )
}

/// The build's final answer, or None while it is queued or running.
fn terminal(response: Value, build_id: &str) -> Option<Value> {
    if response["ok"] == false {
        return Some(response);
    }
    let state = response["data"]["job"]["state"].as_str().unwrap_or("");
    if state == "succeeded" {
        return Some(response);
    }
    if ["failed", "cancelled", "interrupted"].contains(&state) {
        let mut error = failure(
            "build_not_succeeded",
            format!("Build {build_id} is {state}"),
            "Read build status and build log before retrying.",
        );
        error["data"] = response["data"].clone();
        return Some(error);
    }
    None
}

pub(super) fn deadline(seconds: u64) -> Result<tokio::time::Instant> {
    ensure!(seconds <= 86400, "Timeout cannot exceed 86400 seconds");
    Ok(tokio::time::Instant::now() + Duration::from_secs(seconds))
}

/// Follows the build until it is done: each request is
/// answered by the service once the build's status changes, so nothing is
/// fetched on a timer. The caller's `--timeout` bounds the whole wait,
/// requests included. Submission is outside this loop and is never repeated.
pub(super) async fn poll(
    cli: &Cli,
    build_id: &str,
    deadline: tokio::time::Instant,
) -> Result<Value> {
    let path = format!("/v1/builds/{build_id}");
    follow(build_id, deadline, |held| {
        let path = &path;
        async move { get_changed(cli, path, held.as_deref()).await }
    })
    .await
}

/// `poll` over any `fetch` (given the ETag it holds, the next status and
/// its ETag).
async fn follow<F, Fut>(
    build_id: &str,
    deadline: tokio::time::Instant,
    mut fetch: F,
) -> Result<Value>
where
    F: FnMut(Option<String>) -> Fut,
    Fut: std::future::Future<Output = Result<(Value, Option<String>)>>,
{
    let mut held = None;
    loop {
        let (response, etag) = match tokio::time::timeout_at(deadline, fetch(held.take())).await {
            Ok(response) => response?,
            Err(_) => return Ok(timed_out()),
        };
        if let Some(done) = terminal(response, build_id) {
            return Ok(done);
        }
        held = Some(etag.context("The service's build status has no ETag")?);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The caller's deadline ends the wait even while a request hangs, and
    /// each request after the first holds the status it already has. On
    /// tokio's paused clock: the minute passes without waiting.
    #[tokio::test(start_paused = true)]
    async fn the_deadline_ends_a_wait_whose_request_hangs() {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        let mut asked = vec![];
        let result = follow("b", deadline, |held| {
            asked.push(held.clone());
            async move {
                match held {
                    None => Ok((
                        serde_json::json!({"ok": true, "data": {"job": {"state": "running"}}}),
                        Some("\"running\"".to_string()),
                    )),
                    Some(_) => std::future::pending().await,
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(result["error"]["code"], "wait_timeout");
        assert_eq!(asked, [None, Some("\"running\"".to_string())]);
    }
}
