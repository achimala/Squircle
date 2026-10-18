use super::*;

#[derive(Clone, Copy)]
pub(super) enum WaitFor {
    Build,
    Preview,
}
impl WaitFor {
    pub(super) fn timeout(self) -> Value {
        match self {
            Self::Build => failure(
                "wait_timeout",
                "Wait timed out; the build was not cancelled",
                "Call build status or wait again with the same build ID.",
            ),
            Self::Preview => failure(
                "wait_timeout",
                "Preview wait timed out; accepted capture was not cancelled",
                "Call build status or build cancel with the same build ID; do not resubmit blindly.",
            ),
        }
    }
    fn terminal(self, response: Value, build_id: &str) -> Option<Value> {
        if response["ok"] == false {
            return Some(response);
        }
        let job = &response["data"]["job"];
        match self {
            Self::Build => {
                let state = job["state"].as_str().unwrap_or("");
                let preview_busy = matches!(
                    job["output"]["preview_state"].as_str(),
                    Some("pending" | "running")
                );
                if state == "succeeded" && !preview_busy {
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
            }
            Self::Preview => match job["output"]["preview_state"].as_str() {
                Some("succeeded") => return Some(response),
                Some("failed") => {
                    let mut error = failure(
                        "preview_failed",
                        job["output"]["preview_error"]
                            .as_str()
                            .unwrap_or("Preview failed"),
                        "Inspect build log and simulator; the signed IPA is unchanged.",
                    );
                    error["data"] = response["data"].clone();
                    return Some(error);
                }
                _ => {}
            },
        }
        None
    }
}

pub(super) fn deadline(seconds: u64) -> Result<tokio::time::Instant> {
    ensure!(seconds <= 86400, "Timeout cannot exceed 86400 seconds");
    Ok(tokio::time::Instant::now() + Duration::from_secs(seconds))
}

/// One fetch/sleep deadline mechanism. Completion and failure policy stay
/// distinct; submission is outside this loop and is never repeated.
pub(super) async fn poll(
    cli: &Cli,
    build_id: &str,
    deadline: tokio::time::Instant,
    policy: WaitFor,
) -> Result<Value> {
    loop {
        let response =
            match tokio::time::timeout_at(deadline, get(cli, &format!("/v1/builds/{build_id}")))
                .await
            {
                Ok(response) => response?,
                Err(_) => return Ok(policy.timeout()),
            };
        if let Some(done) = policy.terminal(response, build_id) {
            return Ok(done);
        }
        if tokio::time::Instant::now() >= deadline {
            return Ok(policy.timeout());
        }
        tokio::time::sleep_until(
            (tokio::time::Instant::now() + Duration::from_millis(500)).min(deadline),
        )
        .await;
    }
}
