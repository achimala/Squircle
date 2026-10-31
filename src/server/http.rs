use super::*;

#[derive(Debug)]
pub(super) struct ApiError {
    pub(super) status: StatusCode,
    pub(super) code: &'static str,
    pub(super) message: String,
    pub(super) next: &'static str,
    /// Refused before any side effect; see `model::failure_with`.
    pub(super) retryable: bool,
}

impl ApiError {
    pub(super) fn new(
        status: StatusCode,
        code: &'static str,
        message: impl ToString,
        next: &'static str,
    ) -> Self {
        Self {
            status,
            code,
            message: message.to_string(),
            next,
            retryable: false,
        }
    }
    pub(super) fn bad(message: impl ToString) -> Self {
        Self::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            message,
            "Check the command help and supplied values.",
        )
    }
    pub(super) fn missing(message: impl ToString) -> Self {
        Self::new(
            StatusCode::NOT_FOUND,
            "not_found",
            message,
            "Check the build ID or request a new install link.",
        )
    }
    pub(super) fn internal(error: impl ToString) -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "operation_failed",
            error,
            "Inspect the saved build log or run squircle doctor.",
        )
    }
    pub(super) fn unavailable() -> Self {
        // Admission is refused before any work starts; retry after a restart.
        Self {
            retryable: true,
            ..Self::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "service_draining",
                "Service is shutting down or paused after a persistence error",
                "Inspect service output and storage, then restart before submitting work.",
            )
        }
    }
    pub(super) fn too_large(message: impl ToString) -> Self {
        Self::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "payload_too_large",
            message,
            "Send a smaller request body.",
        )
    }
    /// Axum's own rejections (query, path, body, size, method) in the same
    /// envelope as handler errors.
    pub(super) fn rejection(status: StatusCode, message: String) -> Self {
        let (code, next) = match status {
            StatusCode::UNAUTHORIZED => (
                "unauthorized",
                "Use the control token for builds; the diagnostics token only permits uploads.",
            ),
            StatusCode::NOT_FOUND => ("not_found", "Check the endpoint and IDs."),
            StatusCode::METHOD_NOT_ALLOWED => (
                "method_not_allowed",
                "Check the HTTP method for this endpoint.",
            ),
            StatusCode::PAYLOAD_TOO_LARGE => ("payload_too_large", "Send a smaller request body."),
            StatusCode::UNSUPPORTED_MEDIA_TYPE => (
                "invalid_request",
                "Send JSON with Content-Type: application/json.",
            ),
            s if s.is_client_error() => (
                "invalid_request",
                "Check the command help and supplied values.",
            ),
            _ => (
                "operation_failed",
                "Inspect service output or run squircle doctor.",
            ),
        };
        let message = if message.is_empty() {
            status
                .canonical_reason()
                .unwrap_or("Request failed")
                .to_string()
        } else {
            message
        };
        Self {
            retryable: matches!(
                status,
                StatusCode::TOO_MANY_REQUESTS | StatusCode::SERVICE_UNAVAILABLE
            ),
            ..Self::new(status, code, message, next)
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(failure_with(
                self.code,
                self.message,
                self.next,
                self.retryable,
            )),
        )
            .into_response()
    }
}

pub(super) type ApiResult<T> = std::result::Result<T, ApiError>;

pub(super) fn auth(state: &AppState, headers: &HeaderMap, diagnostics: bool) -> ApiResult<()> {
    let supplied = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .unwrap_or("");
    let settings = &state.files.settings;
    let expected = if diagnostics {
        &settings.diagnostic_token
    } else {
        &settings.control_token
    };
    let a = Sha256::digest(supplied.as_bytes());
    let b = Sha256::digest(expected.as_bytes());
    if a.iter().zip(b).fold(0u8, |x, (a, b)| x | (a ^ b)) != 0 {
        return Err(ApiError::rejection(
            StatusCode::UNAUTHORIZED,
            "A valid token for this operation is required".into(),
        ));
    }
    Ok(())
}

pub(super) fn body<T>(value: std::result::Result<Json<T>, JsonRejection>) -> ApiResult<T> {
    value
        .map(|Json(v)| v)
        .map_err(|e| ApiError::rejection(e.status(), e.body_text()))
}

pub(super) fn parse_query<T>(value: std::result::Result<Query<T>, QueryRejection>) -> ApiResult<T> {
    value
        .map(|Query(v)| v)
        .map_err(|e| ApiError::rejection(e.status(), e.body_text()))
}

/// Runs before any extractor, so a rejected request's body is never read.
pub(super) async fn require_control(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    match auth(&state, request.headers(), false) {
        Ok(()) => next.run(request).await,
        Err(error) => error.into_response(),
    }
}

pub(super) async fn require_diagnostics(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    match auth(&state, request.headers(), true) {
        Ok(()) => next.run(request).await,
        Err(error) => error.into_response(),
    }
}

/// Wraps any error response that is not already Squircle JSON (Axum's plain
/// text extractor rejections, 405s, empty 413s) in the versioned envelope.
pub(super) async fn envelope_errors(response: Response) -> Response {
    let status = response.status();
    let is_json = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("application/json"));
    if !(status.is_client_error() || status.is_server_error()) || is_json {
        return response;
    }
    let text = axum::body::to_bytes(response.into_body(), 16 * 1024)
        .await
        .map(|bytes| String::from_utf8_lossy(&bytes).trim().to_string())
        .unwrap_or_default();
    ApiError::rejection(status, text).into_response()
}

/// GET replies in JSON carry an ETag: a poll that already holds that exact
/// body gets an empty 304, and a client that accepts gzip gets the body
/// compressed. The phone polls several of these every few seconds, often
/// over cellular (the build list alone is over 100 KB of JSON).
pub(super) async fn compact_json(request: Request, next: Next) -> Response {
    let get = request.method() == Method::GET;
    let known = request.headers().get(header::IF_NONE_MATCH).cloned();
    let gzip = request
        .headers()
        .get(header::ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .is_some_and(accepts_gzip);
    let response = next.run(request).await;
    let json = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("application/json"));
    if !get
        || response.status() != StatusCode::OK
        || !json
        || response.headers().contains_key(header::CONTENT_ENCODING)
    {
        return response;
    }
    let (mut parts, body) = response.into_parts();
    let Ok(bytes) = axum::body::to_bytes(body, 64 << 20).await else {
        return ApiError::rejection(StatusCode::INTERNAL_SERVER_ERROR, "Reply too large".into())
            .into_response();
    };
    let etag = HeaderValue::from_str(&etag(&bytes)).expect("hex ETag");
    parts.headers.insert(header::ETAG, etag.clone());
    parts
        .headers
        .insert(header::VARY, HeaderValue::from_static("accept-encoding"));
    if known.as_ref().is_some_and(|k| holds(k, etag.as_bytes())) {
        parts.status = StatusCode::NOT_MODIFIED;
        parts.headers.remove(header::CONTENT_TYPE);
        parts.headers.remove(header::CONTENT_LENGTH);
        return Response::from_parts(parts, Body::empty());
    }
    if gzip && bytes.len() >= 1024 {
        let mut encoder = flate2::write::GzEncoder::new(
            Vec::with_capacity(bytes.len() / 4),
            flate2::Compression::fast(),
        );
        if encoder.write_all(&bytes).is_ok()
            && let Ok(compressed) = encoder.finish()
        {
            parts
                .headers
                .insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));
            parts.headers.remove(header::CONTENT_LENGTH);
            return Response::from_parts(parts, Body::from(compressed));
        }
    }
    Response::from_parts(parts, Body::from(bytes))
}

/// A JSON body's ETag, quoted.
pub(super) fn etag(body: &[u8]) -> String {
    let digest = Sha256::digest(body);
    let tag: String = digest[..12].iter().map(|b| format!("{b:02x}")).collect();
    format!("\"{tag}\"")
}

/// Whether an If-None-Match value names `etag`.
fn holds(known: &HeaderValue, etag: &[u8]) -> bool {
    known
        .as_bytes()
        .split(|&c| c == b',')
        .any(|t| t.trim_ascii() == etag)
}

/// The ETag a GET asked to wait past: `If-None-Match` with `Prefer:
/// wait-for-change` holds the reply until it would differ, instead of an
/// immediate 304. Nothing but a change, the client leaving or shutdown
/// ends it.
pub(super) fn waits_past(headers: &HeaderMap) -> Option<HeaderValue> {
    let wait = headers
        .get_all(header::HeaderName::from_static("prefer"))
        .iter()
        .any(|v| {
            v.to_str().is_ok_and(|v| {
                v.split(',')
                    .any(|p| p.trim().eq_ignore_ascii_case(WAIT_FOR_CHANGE))
            })
        });
    wait.then(|| headers.get(header::IF_NONE_MATCH).cloned())
        .flatten()
}

/// The `Prefer` token for [`waits_past`].
pub const WAIT_FOR_CHANGE: &str = "wait-for-change";

/// Whether `reply`, sent as JSON, is the one the client already holds.
pub(super) fn unchanged(reply: &Value, known: &HeaderValue) -> bool {
    serde_json::to_vec(reply).is_ok_and(|body| holds(known, etag(&body).as_bytes()))
}

/// Whether an Accept-Encoding value allows gzip: listed (or `*` when gzip
/// isn't) with a nonzero quality, so `gzip;q=0` refuses it.
pub(super) fn accepts_gzip(header: &str) -> bool {
    let quality = |coding: &str| {
        header.split(',').find_map(|entry| {
            let mut parts = entry.split(';');
            if !parts.next()?.trim().eq_ignore_ascii_case(coding) {
                return None;
            }
            let q = parts.find_map(|p| {
                p.trim()
                    .strip_prefix("q=")
                    .or_else(|| p.trim().strip_prefix("Q="))
            });
            Some(
                q.map_or(Some(1.0), |q| q.trim().parse::<f32>().ok())
                    .unwrap_or(0.0),
            )
        })
    };
    quality("gzip")
        .or_else(|| quality("*"))
        .is_some_and(|q| q > 0.0)
}
