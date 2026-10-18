use super::*;

pub(super) const SANDBOX: &str = "https://api.sandbox.push.apple.com";

pub(super) const PRODUCTION: &str = "https://api.push.apple.com";

// MARK: Key

/// `<data dir>/push/apns.json` (0600): the user's APNs auth key. The key never
/// appears in output or logs.
#[derive(Clone, Serialize, Deserialize)]
pub struct KeyConfig {
    pub key_id: String,
    pub team_id: String,
    pub key_pem: String,
}

pub(super) fn key_path(root: &Path) -> PathBuf {
    root.join("push").join("apns.json")
}

impl KeyConfig {
    pub fn load(root: &Path) -> Result<Option<Self>> {
        let path = key_path(root);
        if !path.try_exists()? {
            return Ok(None);
        }
        read_json(&path).map(Some)
    }
}

pub(super) fn valid_apple_id(id: &str) -> bool {
    id.len() == 10
        && id
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

/// Validates and stores the key; `squircle push setup`.
pub fn setup(
    root: &Path,
    key_file: Option<&Path>,
    key_id: Option<&str>,
    team_id: Option<&str>,
    remove: bool,
) -> Result<Value> {
    let path = key_path(root);
    if remove {
        if path.try_exists()? {
            std::fs::remove_file(&path)?;
        }
        return Ok(json!({"configured": false}));
    }
    let (Some(key_file), Some(key_id), Some(team_id)) = (key_file, key_id, team_id) else {
        bail!("Pass --key-file, --key-id and --team-id (or --remove)");
    };
    ensure!(
        valid_apple_id(key_id),
        "The key ID is the 10-character ID shown with the key (e.g. AB12CD34EF)"
    );
    ensure!(
        valid_apple_id(team_id),
        "The team ID is the 10-character ID under Membership (e.g. 2F26US4NAU)"
    );
    let pem = std::fs::read_to_string(key_file)
        .with_context(|| format!("Cannot read {}", key_file.display()))?;
    let config = KeyConfig {
        key_id: key_id.into(),
        team_id: team_id.into(),
        key_pem: pem.trim().to_string(),
    };
    Signer::new(&config).context("Not an APNs auth key (.p8)")?;
    private_dir(&root.join("push"))?;
    atomic_json(&path, &config)?;
    Ok(
        json!({"configured": true, "key_id": key_id, "team_id": team_id,
        "next": "The running service picks the key up on its next push. Send one: squircle push test"}),
    )
}

pub(super) fn pem_der(pem: &str) -> Result<Vec<u8>> {
    let body: String = pem
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .map(str::trim)
        .collect();
    ensure!(
        pem.contains("BEGIN PRIVATE KEY"),
        "expected a PKCS#8 PEM private key"
    );
    Ok(base64::engine::general_purpose::STANDARD.decode(body)?)
}

pub(super) fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// Signs APNs provider tokens (ES256 JWT).
pub struct Signer {
    pub(super) key: EcdsaKeyPair,
    pub(super) key_id: String,
    pub(super) team_id: String,
}

impl Signer {
    pub fn new(config: &KeyConfig) -> Result<Self> {
        let der = pem_der(&config.key_pem)?;
        let key = EcdsaKeyPair::from_pkcs8(
            &ECDSA_P256_SHA256_FIXED_SIGNING,
            &der,
            &ring::rand::SystemRandom::new(),
        )
        .map_err(|e| anyhow::anyhow!("invalid P-256 key: {e}"))?;
        Ok(Self {
            key,
            key_id: config.key_id.clone(),
            team_id: config.team_id.clone(),
        })
    }

    pub fn jwt(&self, issued_at: u64) -> Result<String> {
        let header = b64url(
            json!({"alg": "ES256", "kid": self.key_id})
                .to_string()
                .as_bytes(),
        );
        let claims = b64url(
            json!({"iss": self.team_id, "iat": issued_at})
                .to_string()
                .as_bytes(),
        );
        let input = format!("{header}.{claims}");
        let signature = self
            .key
            .sign(&ring::rand::SystemRandom::new(), input.as_bytes())
            .map_err(|_| anyhow::anyhow!("signing failed"))?;
        Ok(format!("{input}.{}", b64url(signature.as_ref())))
    }

    pub fn public_key(&self) -> &[u8] {
        ring::signature::KeyPair::public_key(&self.key).as_ref()
    }
}

// MARK: Transport

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Environment {
    /// Xcode-run and development-signed builds (APNs sandbox).
    #[default]
    Development,
    /// Ad hoc, TestFlight and App Store builds.
    Production,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushType {
    Alert,
    LiveActivity,
}

/// One message for one token, independent of how it reaches Apple.
#[derive(Clone, Debug)]
pub struct Delivery {
    pub token: String,
    pub environment: Environment,
    /// The app's bundle ID; Live Activity pushes add `.push-type.liveactivity`.
    pub bundle_id: String,
    pub push_type: PushType,
    /// 10 now, 5 when power allows (Live Activity updates at 5 do not count
    /// against the phone's update budget).
    pub priority: u8,
    pub collapse_id: Option<String>,
    pub payload: Value,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Sent,
    /// The token is no longer valid; forget it.
    Unregistered,
    /// Apple won't take this message; trying it again won't help.
    Rejected(String),
    /// Apple is busy or unreachable; the same message may go through later.
    Retry(String),
}

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub trait Transport: Send + Sync {
    fn send<'a>(&'a self, delivery: &'a Delivery) -> BoxFuture<'a, Result<Outcome>>;
}

/// The signer and the provider token it last made. Apple accepts a token
/// for an hour and rejects refreshing more than every 20 minutes, so one is
/// reused for 40; one owner makes and hands it out, so concurrent sends
/// share it.
pub(super) struct Tokens {
    pub(super) signer: Signer,
    pub(super) cached: Option<(u64, String)>,
}

impl Tokens {
    pub(super) fn token(&mut self, refresh: bool) -> Result<String> {
        let now = crate::model::now();
        if let Some((at, token)) = self.cached.as_ref()
            && !refresh
            && now < at + 40 * 60
        {
            return Ok(token.clone());
        }
        let token = self.signer.jwt(now)?;
        self.cached = Some((now, token.clone()));
        Ok(token)
    }
}

/// Apple's push service, directly, with the user's key.
pub struct Apns {
    pub(super) tokens: Owner<Tokens>,
    pub(super) client: reqwest::Client,
    pub(super) sandbox: String,
    pub(super) production: String,
}

impl Apns {
    pub fn new(config: &KeyConfig) -> Result<Self> {
        Self::with_hosts(config, SANDBOX, PRODUCTION)
    }

    /// Other hosts, for a local fake (`http://` speaks HTTP/2 without TLS).
    pub fn with_hosts(config: &KeyConfig, sandbox: &str, production: &str) -> Result<Self> {
        let mut builder = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(20));
        if sandbox.starts_with("http://") {
            builder = builder.http2_prior_knowledge();
        }
        let tokens = Owner::spawn(
            "APNs tokens",
            Tokens {
                signer: Signer::new(config)?,
                cached: None,
            },
        );
        Ok(Self {
            tokens,
            client: builder.build()?,
            sandbox: sandbox.into(),
            production: production.into(),
        })
    }

    pub(super) async fn post(&self, delivery: &Delivery, refresh: bool) -> Result<(u16, String)> {
        let host = match delivery.environment {
            Environment::Development => &self.sandbox,
            Environment::Production => &self.production,
        };
        let (kind, topic) = match delivery.push_type {
            PushType::Alert => ("alert", delivery.bundle_id.clone()),
            PushType::LiveActivity => (
                "liveactivity",
                format!("{}.push-type.liveactivity", delivery.bundle_id),
            ),
        };
        let token = self.tokens.ask(move |tokens| tokens.token(refresh)).await?;
        let mut request = self
            .client
            .post(format!("{host}/3/device/{}", delivery.token))
            .bearer_auth(token)
            .header("apns-topic", topic)
            .header("apns-push-type", kind)
            .header("apns-priority", delivery.priority.to_string())
            .json(&delivery.payload);
        if let Some(id) = &delivery.collapse_id {
            request = request.header("apns-collapse-id", id);
        }
        let response = request.send().await.context("Cannot reach APNs")?;
        let status = response.status().as_u16();
        let body: Value = response.json().await.unwrap_or(Value::Null);
        Ok((status, body["reason"].as_str().unwrap_or("").to_string()))
    }
}

impl Transport for Apns {
    fn send<'a>(&'a self, delivery: &'a Delivery) -> BoxFuture<'a, Result<Outcome>> {
        Box::pin(async move {
            let (mut status, mut reason) = self.post(delivery, false).await?;
            if status == 403 && reason == "ExpiredProviderToken" {
                (status, reason) = self.post(delivery, true).await?;
            }
            Ok(match (status, reason.as_str()) {
                (200, _) => Outcome::Sent,
                (410, _) | (400, "BadDeviceToken" | "DeviceTokenNotForTopic") => {
                    Outcome::Unregistered
                }
                (429 | 500..=599, reason) | (403, reason @ "ExpiredProviderToken") => {
                    Outcome::Retry(format!("HTTP {status} {reason}").trim().to_string())
                }
                (_, reason) => {
                    Outcome::Rejected(format!("HTTP {status} {reason}").trim().to_string())
                }
            })
        })
    }
}
