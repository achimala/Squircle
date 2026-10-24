use super::*;

pub(super) async fn request(
    cli: &Cli,
    method: reqwest::Method,
    path: &str,
    payload: Option<Value>,
    diagnostic: bool,
) -> Result<Value> {
    Ok(exchange(cli, method, path, payload, diagnostic, None)
        .await?
        .0)
}

/// A GET answered once its reply differs from the one whose ETag is
/// `held` (the service holds it until then); at once without one. Returns
/// the reply and its ETag.
pub(super) async fn get_changed(
    cli: &Cli,
    path: &str,
    held: Option<&str>,
) -> Result<(Value, Option<String>)> {
    exchange(cli, reqwest::Method::GET, path, None, false, held).await
}

async fn exchange(
    cli: &Cli,
    method: reqwest::Method,
    path: &str,
    payload: Option<Value>,
    diagnostic: bool,
    held: Option<&str>,
) -> Result<(Value, Option<String>)> {
    let store = Store::open(root(cli)?)?;
    let key = if diagnostic {
        store.settings.diagnostic_token
    } else {
        store.settings.control_token
    };
    let origin = squircle::origin::credential_origin(&cli.server, "--server")?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let mut request = client
        .request(method, format!("{origin}{path}"))
        .bearer_auth(key);
    if let Some(payload) = payload {
        request = request.json(&payload);
    }
    if let Some(held) = held {
        request = request
            .header(reqwest::header::IF_NONE_MATCH, held)
            .header("prefer", squircle::server::WAIT_FOR_CHANGE);
    }
    let response = request
        .send()
        .await
        .context("Cannot reach Squircle service")?;
    let status = response.status();
    let etag = response
        .headers()
        .get(reqwest::header::ETAG)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let value: Value = response
        .json()
        .await
        .context("Service did not return JSON")?;
    if value["schema_version"] != SCHEMA_VERSION || !value["ok"].is_boolean() {
        bail!("Unsupported server response schema (HTTP {status})");
    }
    Ok((value, etag))
}
pub(super) async fn get(cli: &Cli, path: &str) -> Result<Value> {
    request(cli, reqwest::Method::GET, path, None, false).await
}
pub(super) async fn post(cli: &Cli, path: &str, payload: Value) -> Result<Value> {
    request(cli, reqwest::Method::POST, path, Some(payload), false).await
}
