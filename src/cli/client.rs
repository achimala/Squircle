use super::*;

pub(super) async fn request(
    cli: &Cli,
    method: reqwest::Method,
    path: &str,
    payload: Option<Value>,
    diagnostic: bool,
) -> Result<Value> {
    let store = Store::open(root(cli)?)?;
    let key = if diagnostic {
        store.settings.diagnostic_token
    } else {
        store.settings.control_token
    };
    let origin = squircle::origin::credential_origin(&cli.server, "--server")?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(60))
        .build()?;
    let mut request = client
        .request(method, format!("{origin}{path}"))
        .bearer_auth(key);
    if let Some(payload) = payload {
        request = request.json(&payload);
    }
    let response = request
        .send()
        .await
        .context("Cannot reach Squircle service")?;
    let status = response.status();
    let value: Value = response
        .json()
        .await
        .context("Service did not return JSON")?;
    if value["schema_version"] != SCHEMA_VERSION || !value["ok"].is_boolean() {
        bail!("Unsupported server response schema (HTTP {status})");
    }
    Ok(value)
}
pub(super) async fn get(cli: &Cli, path: &str) -> Result<Value> {
    request(cli, reqwest::Method::GET, path, None, false).await
}
pub(super) async fn post(cli: &Cli, path: &str, payload: Value) -> Result<Value> {
    request(cli, reqwest::Method::POST, path, Some(payload), false).await
}
