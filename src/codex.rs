use anyhow::{Result, anyhow, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::TryRng;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    sync::{Mutex, Notify},
    time::Instant,
};

const ORIGIN: &str = "https://auth.openai.com";
const REDIRECT: &str = "http://127.0.0.1:1455/auth/callback";
const LEGACY_REDIRECT: &str = "http://localhost:1455/auth/callback";
const LEGACY_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const RESOURCE: &str = "https://api.openai.com/v1";
const SCOPE: &str = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Credentials {
    device_id: String,
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    access_token: String,
    #[serde(default)]
    refresh_token: String,
    #[serde(default)]
    id_token: String,
    #[serde(default)]
    scope: String,
    #[serde(default)]
    expires_at: i64,
    #[serde(default)]
    obtained_at: i64,
    #[serde(default)]
    refresh_status: RefreshStatus,
}

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum RefreshStatus {
    #[default]
    Ready,
    InvalidClient,
}

impl Credentials {
    fn registration(&self) -> Self {
        Self {
            device_id: self.device_id.clone(),
            client_id: self.client_id.clone(),
            ..Self::default()
        }
    }
}

struct Pending {
    state: String,
    nonce: String,
    verifier: String,
    device_id: String,
    client_id: String,
    expires: Instant,
}

struct State {
    credentials: Credentials,
    pending: Option<Pending>,
    generation: u64,
    refreshing: bool,
    retry_at: Option<Instant>,
}

pub struct Session {
    directory: PathBuf,
    client: reqwest::Client,
    origin: String,
    legacy: bool,
    state: Mutex<State>,
    refreshed: Notify,
    login: Mutex<()>,
}

#[derive(Debug, Serialize)]
pub struct Status {
    pub status: &'static str,
    pub pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthError {
    NoPendingLogin,
    LoginExpired,
    InvalidCallback,
    CredentialSaveFailed,
    ExchangeFailed,
}

impl std::fmt::Display for AuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for AuthError {}

impl Session {
    /// The caller supplies the shared client, including proxy and redirect policy.
    pub fn load(directory: PathBuf, client: reqwest::Client) -> Result<Arc<Self>> {
        Self::load_flow(directory, client, false)
    }

    pub fn load_legacy(directory: PathBuf, client: reqwest::Client) -> Result<Arc<Self>> {
        Self::load_flow(directory, client, true)
    }

    fn load_flow(directory: PathBuf, client: reqwest::Client, legacy: bool) -> Result<Arc<Self>> {
        let credentials = match fs::read(directory.join(if legacy {
            "codex-legacy.json"
        } else {
            "codex.json"
        })) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Credentials::default(),
            Err(error) => return Err(error.into()),
        };
        Ok(Arc::new(Self {
            directory,
            client,
            origin: ORIGIN.into(),
            legacy,
            state: Mutex::new(State {
                credentials,
                pending: None,
                generation: 0,
                refreshing: false,
                retry_at: None,
            }),
            refreshed: Notify::new(),
            login: Mutex::new(()),
        }))
    }

    pub fn is_legacy(&self) -> bool {
        self.legacy
    }

    pub async fn headers(self: &Arc<Self>) -> Result<reqwest::header::HeaderMap> {
        use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue, USER_AGENT};
        let authorization = self.authorization().await?;
        let mut headers = HeaderMap::new();
        if self.legacy {
            let token = authorization
                .strip_prefix("Bearer ")
                .ok_or_else(|| anyhow!("InvalidCredentials"))?;
            headers.insert(
                "chatgpt-account-id",
                HeaderValue::from_str(&account_id(token)?)?,
            );
            headers.insert("originator", HeaderValue::from_static("fumo-gateway"));
            headers.insert(
                "openai-beta",
                HeaderValue::from_static("responses=experimental"),
            );
        }
        headers.insert(AUTHORIZATION, HeaderValue::from_str(&authorization)?);
        headers.insert(USER_AGENT, HeaderValue::from_static("fumo-gateway"));
        Ok(headers)
    }

    fn redirect(&self) -> &'static str {
        if self.legacy {
            LEGACY_REDIRECT
        } else {
            REDIRECT
        }
    }

    fn save(&self, credentials: &Credentials) -> Result<()> {
        save(&self.directory, credentials, self.legacy)
    }

    /// Refresh valid tokens in the background; wait for refresh after expiry.
    pub async fn authorization(self: &Arc<Self>) -> Result<String> {
        let mut state = self.state.lock().await;
        let current = &state.credentials;
        if i128::from(current.expires_at) - i128::from(now()) <= 300
            && !current.refresh_token.is_empty()
            && current.refresh_status == RefreshStatus::Ready
            && !state.refreshing
            && state.retry_at.is_none_or(|at| Instant::now() >= at)
        {
            let snapshot = current.clone();
            let generation = state.generation;
            state.refreshing = true;
            let session = Arc::clone(self);
            tokio::spawn(async move { session.refresh(snapshot, generation).await });
        }
        if state.credentials.expires_at <= now() && state.refreshing {
            let refreshed = self.refreshed.notified();
            drop(state);
            refreshed.await;
            state = self.state.lock().await;
        }
        if state.credentials.expires_at <= now() {
            bail!("CredentialsUnavailable");
        }
        Ok(format!("Bearer {}", state.credentials.access_token))
    }

    pub async fn status(&self) -> Status {
        let state = self.state.lock().await;
        let current = &state.credentials;
        Status {
            status: if current.refresh_status != RefreshStatus::InvalidClient
                && (current.expires_at > now() || !current.refresh_token.is_empty())
            {
                "connected"
            } else {
                "login_required"
            },
            pending: state
                .pending
                .as_ref()
                .is_some_and(|p| Instant::now() < p.expires),
        }
    }

    pub async fn start(&self) -> Result<Value> {
        let _login = self.login.lock().await;
        let mut state = self.state.lock().await;
        state.pending = None;
        let saved = &state.credentials;
        let pending = Pending {
            state: random_token(),
            nonce: random_token(),
            verifier: random_token(),
            device_id: if saved.device_id.is_empty() {
                uuid::Uuid::new_v4().to_string()
            } else {
                saved.device_id.clone()
            },
            client_id: if self.legacy {
                LEGACY_CLIENT_ID.into()
            } else {
                saved.client_id.clone()
            },
            expires: Instant::now() + Duration::from_secs(300),
        };
        let path = if self.legacy {
            "/oauth/authorize"
        } else {
            "/api/accounts/authorize"
        };
        let mut url = url::Url::parse(&format!("{}{path}", self.origin))?;
        {
            let mut query = url.query_pairs_mut();
            query.extend_pairs([
                (
                    "client_id",
                    if pending.client_id.is_empty() {
                        "dynamic_agent_client"
                    } else {
                        &pending.client_id
                    },
                ),
                ("response_type", "code"),
                ("redirect_uri", self.redirect()),
                (
                    "scope",
                    if self.legacy {
                        "openid profile email offline_access"
                    } else {
                        SCOPE
                    },
                ),
                ("state", &pending.state),
                (
                    "code_challenge",
                    &URL_SAFE_NO_PAD.encode(Sha256::digest(pending.verifier.as_bytes())),
                ),
                ("code_challenge_method", "S256"),
            ]);
            if self.legacy {
                query.extend_pairs([
                    ("id_token_add_organizations", "true"),
                    ("codex_cli_simplified_flow", "true"),
                    ("originator", "fumo-gateway"),
                ]);
            } else {
                query.append_pair(
                    "ext_agent_host_id",
                    &format!("urn:uuid:{}", pending.device_id),
                );
                query.append_pair("resource", RESOURCE);
                query.append_pair("nonce", &pending.nonce);
                if pending.client_id.is_empty() {
                    query.append_pair("agent_name_hint", "fumo-gateway");
                }
            }
        }
        state.pending = Some(pending);
        Ok(json!({"authorization_url": url.as_str(), "expires_in": 300}))
    }

    pub async fn complete(&self, callback: &str) -> std::result::Result<(), AuthError> {
        let _login = self.login.lock().await;
        let mut state = self.state.lock().await;
        let pending = state.pending.as_ref().ok_or(AuthError::NoPendingLogin)?;
        if Instant::now() >= pending.expires {
            state.pending = None;
            return Err(AuthError::LoginExpired);
        }
        let (code, client_id) = parse_callback(callback, pending, self.redirect())?;
        let verifier = pending.verifier.clone();
        let device_id = pending.device_id.clone();
        let expires = pending.expires;
        drop(state);
        let mut form = vec![
            ("grant_type", "authorization_code"),
            ("client_id", &client_id),
            ("code", &code),
            ("code_verifier", &verifier),
            ("redirect_uri", self.redirect()),
        ];
        if !self.legacy {
            form.push(("resource", RESOURCE));
        }
        let exchange = async {
            let (ok, body) = self.post_tokens(&form).await?;
            if !ok {
                bail!("TokenExchangeFailed");
            }
            parse_tokens(&body, &client_id, &device_id, None, self.legacy)
        };
        let replacement = tokio::time::timeout_at(expires, exchange)
            .await
            .map_err(|_| AuthError::LoginExpired)?
            .map_err(|_| AuthError::ExchangeFailed)?;
        let mut state = self.state.lock().await;
        // No await between persistence and publication: cancellation cannot split them.
        self.save(&replacement)
            .map_err(|_| AuthError::CredentialSaveFailed)?;
        state.credentials = replacement;
        state.generation += 1;
        state.retry_at = None;
        state.pending = None;
        Ok(())
    }

    pub async fn disconnect(&self) -> Result<()> {
        let _login = self.login.lock().await;
        let mut state = self.state.lock().await;
        let retained = state.credentials.registration();
        self.save(&retained)?;
        state.credentials = retained;
        state.generation += 1;
        state.retry_at = None;
        state.pending = None;
        Ok(())
    }

    async fn refresh(&self, snapshot: Credentials, generation: u64) {
        let exchange = async {
            let mut form = vec![
                ("grant_type", "refresh_token"),
                ("client_id", &snapshot.client_id),
                ("refresh_token", &snapshot.refresh_token),
            ];
            if !self.legacy {
                form.push(("resource", RESOURCE));
            }
            let (ok, body) = self.post_tokens(&form).await?;
            if ok {
                return parse_tokens(
                    &body,
                    &snapshot.client_id,
                    &snapshot.device_id,
                    Some(&snapshot.id_token),
                    self.legacy,
                );
            }
            let failure: Value = serde_json::from_slice(&body)?;
            match failure["error"].as_str().unwrap_or("") {
                "invalid_grant"
                | "invalid_refresh_token"
                | "token_expired"
                | "refresh_token_expired"
                | "refresh_token_invalidated"
                | "refresh_token_reused" => Ok(snapshot.registration()),
                "invalid_client" => {
                    let mut retained = snapshot.clone();
                    retained.refresh_status = RefreshStatus::InvalidClient;
                    Ok(retained)
                }
                _ => bail!("TokenRefreshFailed"),
            }
        };
        let result = tokio::time::timeout(Duration::from_secs(30), exchange).await;
        let mut state = self.state.lock().await;
        state.refreshing = false;
        self.refreshed.notify_waiters();
        if state.generation != generation {
            return;
        }
        let category = match result {
            Err(_) => "timeout",
            Ok(Err(_)) => "exchange",
            Ok(Ok(replacement)) => {
                if self.save(&replacement).is_ok() {
                    state.credentials = replacement;
                    state.retry_at = None;
                    return;
                }
                "save"
            }
        };
        // Never log exchange errors or persistence paths: they may contain secrets.
        eprintln!("event=codex_refresh_failed category={category}");
        state.retry_at = Some(Instant::now() + Duration::from_secs(30));
    }

    async fn post_tokens(&self, form: &[(&str, &str)]) -> Result<(bool, Vec<u8>)> {
        let response = self
            .client
            .post(format!(
                "{}{}",
                self.origin,
                if self.legacy {
                    "/oauth/token"
                } else {
                    "/api/accounts/oauth/token"
                }
            ))
            .header(reqwest::header::ACCEPT, "application/json")
            .header(reqwest::header::ACCEPT_ENCODING, "identity")
            .form(form)
            .send()
            .await?;
        let ok = response.status() == reqwest::StatusCode::OK;
        let body =
            crate::outbound::read_body(response, 1024 * 1024, "TokenResponseTooLarge").await?;
        Ok((ok, body))
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before Unix epoch")
        .as_secs() as i64
}

fn random_token() -> String {
    let mut bytes = [0; 32];
    rand::rngs::SysRng
        .try_fill_bytes(&mut bytes)
        .expect("system random number generator failed");
    URL_SAFE_NO_PAD.encode(bytes)
}

fn parse_tokens(
    body: &[u8],
    client_id: &str,
    device_id: &str,
    previous_id: Option<&str>,
    legacy: bool,
) -> Result<Credentials> {
    #[derive(Deserialize)]
    struct Tokens {
        access_token: String,
        refresh_token: String,
        id_token: Option<String>,
        scope: Option<String>,
        expires_in: i64,
    }
    let tokens: Tokens = serde_json::from_slice(body)?;
    if tokens.expires_in <= 0 {
        bail!("InvalidTokenExpiry");
    }
    if legacy {
        account_id(&tokens.access_token)?;
    }
    let obtained_at = now();
    let expires_at = obtained_at
        .checked_add(tokens.expires_in)
        .ok_or_else(|| anyhow!("InvalidTokenExpiry"))?;
    let id_token = tokens
        .id_token
        .filter(|id| !id.is_empty())
        .or_else(|| previous_id.map(str::to_owned));
    let id_token = if legacy {
        id_token.unwrap_or_default()
    } else {
        id_token.ok_or_else(|| anyhow!("InvalidCredentials"))?
    };
    let scope = if legacy {
        tokens.scope.unwrap_or_default()
    } else {
        tokens.scope.ok_or_else(|| anyhow!("InvalidCredentials"))?
    };
    Ok(Credentials {
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        id_token,
        scope,
        client_id: client_id.into(),
        device_id: device_id.into(),
        expires_at,
        obtained_at,
        refresh_status: RefreshStatus::Ready,
    })
}

fn parse_callback(
    callback: &str,
    pending: &Pending,
    redirect: &str,
) -> std::result::Result<(String, String), AuthError> {
    let invalid = AuthError::InvalidCallback;
    let query = callback
        .strip_prefix(&format!("{redirect}?"))
        .ok_or(invalid)?;
    if query.contains('#') {
        return Err(invalid);
    }
    let mut fields: [Option<String>; 4] = Default::default();
    for pair in query.split('&') {
        let (name, value) = pair.split_once('=').ok_or(invalid)?;
        let name = decode(name)?;
        let value = decode(value)?;
        if let Some(index) = ["state", "code", "client_id", "error"]
            .iter()
            .position(|known| *known == name)
        {
            if fields[index].is_some()
                || value
                    .trim_matches([' ', '\t', '\r', '\n', '\u{b}', '\u{c}'])
                    .is_empty()
            {
                return Err(invalid);
            }
            fields[index] = Some(value);
        }
    }
    if fields[0].as_deref() != Some(&pending.state) || fields[3].is_some() {
        return Err(invalid);
    }
    let client_id = if pending.client_id.is_empty() {
        fields[2].take().ok_or(invalid)?
    } else {
        if fields[2]
            .as_ref()
            .is_some_and(|id| id != &pending.client_id)
        {
            return Err(invalid);
        }
        pending.client_id.clone()
    };
    if client_id == "dynamic_agent_client" {
        return Err(invalid);
    }
    Ok((fields[1].take().ok_or(invalid)?, client_id))
}

fn decode(input: &str) -> std::result::Result<String, AuthError> {
    let mut output = Vec::with_capacity(input.len());
    let mut bytes = input.bytes();
    while let Some(byte) = bytes.next() {
        output.push(match byte {
            b'+' => b' ',
            b'%' => {
                let high = bytes.next().and_then(|b| (b as char).to_digit(16));
                let low = bytes.next().and_then(|b| (b as char).to_digit(16));
                match (high, low) {
                    (Some(high), Some(low)) => (high * 16 + low) as u8,
                    _ => return Err(AuthError::InvalidCallback),
                }
            }
            _ => byte,
        });
    }
    String::from_utf8(output).map_err(|_| AuthError::InvalidCallback)
}

fn account_id(token: &str) -> Result<String> {
    let payload = token
        .split('.')
        .nth(1)
        .ok_or_else(|| anyhow!("InvalidCredentials"))?;
    let payload: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload)?)?;
    let id = payload["https://api.openai.com/auth"]["chatgpt_account_id"]
        .as_str()
        .filter(|id| !id.trim().is_empty())
        .ok_or_else(|| anyhow!("InvalidCredentials"))?;
    Ok(id.to_owned())
}

fn save(directory: &Path, credentials: &Credentials, legacy: bool) -> Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(directory)?;
    let temporary = directory.join(format!(".codex-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec(credentials)?)?;
        file.sync_all()?;
        fs::rename(
            &temporary,
            directory.join(if legacy {
                "codex-legacy.json"
            } else {
                "codex.json"
            }),
        )?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests;
