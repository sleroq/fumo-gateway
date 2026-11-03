use anyhow::{Result, anyhow, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::RngCore;
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
use tokio::{sync::Mutex, time::Instant};

const ORIGIN: &str = "https://auth.openai.com";
const REDIRECT: &str = "http://127.0.0.1:1455/auth/callback";
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
    state: Mutex<State>,
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
        let credentials = match fs::read(directory.join("codex.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Credentials::default(),
            Err(error) => return Err(error.into()),
        };
        Ok(Arc::new(Self {
            directory,
            client,
            origin: ORIGIN.into(),
            state: Mutex::new(State {
                credentials,
                pending: None,
                generation: 0,
                refreshing: false,
                retry_at: None,
            }),
            login: Mutex::new(()),
        }))
    }

    /// Token exchange never delays the current request, even after expiry.
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
            client_id: saved.client_id.clone(),
            expires: Instant::now() + Duration::from_secs(300),
        };
        let mut url = url::Url::parse(&format!("{}/api/accounts/authorize", self.origin))?;
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
                (
                    "ext_agent_host_id",
                    &format!("urn:uuid:{}", pending.device_id),
                ),
                ("response_type", "code"),
                ("redirect_uri", REDIRECT),
                ("resource", RESOURCE),
                ("scope", SCOPE),
                ("state", &pending.state),
                ("nonce", &pending.nonce),
                (
                    "code_challenge",
                    &URL_SAFE_NO_PAD.encode(Sha256::digest(pending.verifier.as_bytes())),
                ),
                ("code_challenge_method", "S256"),
            ]);
            if pending.client_id.is_empty() {
                query.append_pair("agent_name_hint", "fumo-gateway");
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
        let (code, client_id) = parse_callback(callback, pending)?;
        let verifier = pending.verifier.clone();
        let device_id = pending.device_id.clone();
        let expires = pending.expires;
        drop(state);
        let form = [
            ("grant_type", "authorization_code"),
            ("client_id", &client_id),
            ("code", &code),
            ("code_verifier", &verifier),
            ("redirect_uri", REDIRECT),
            ("resource", RESOURCE),
        ];
        let exchange = async {
            let (ok, body) = self.post_tokens(&form).await?;
            if !ok {
                bail!("TokenExchangeFailed");
            }
            parse_tokens(&body, &client_id, &device_id, None)
        };
        let replacement = tokio::time::timeout_at(expires, exchange)
            .await
            .map_err(|_| AuthError::LoginExpired)?
            .map_err(|_| AuthError::ExchangeFailed)?;
        let mut state = self.state.lock().await;
        // No await between persistence and publication: cancellation cannot split them.
        save(&self.directory, &replacement).map_err(|_| AuthError::CredentialSaveFailed)?;
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
        save(&self.directory, &retained)?;
        state.credentials = retained;
        state.generation += 1;
        state.retry_at = None;
        state.pending = None;
        Ok(())
    }

    async fn refresh(&self, snapshot: Credentials, generation: u64) {
        let exchange = async {
            let (ok, body) = self
                .post_tokens(&[
                    ("grant_type", "refresh_token"),
                    ("client_id", &snapshot.client_id),
                    ("refresh_token", &snapshot.refresh_token),
                    ("resource", RESOURCE),
                ])
                .await?;
            if ok {
                return parse_tokens(
                    &body,
                    &snapshot.client_id,
                    &snapshot.device_id,
                    Some(&snapshot.id_token),
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
        if state.generation != generation {
            return;
        }
        let category = match result {
            Err(_) => "timeout",
            Ok(Err(_)) => "exchange",
            Ok(Ok(replacement)) => {
                if save(&self.directory, &replacement).is_ok() {
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
            .post(format!("{}/api/accounts/oauth/token", self.origin))
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
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn parse_tokens(
    body: &[u8],
    client_id: &str,
    device_id: &str,
    previous_id: Option<&str>,
) -> Result<Credentials> {
    #[derive(Deserialize)]
    struct Tokens {
        access_token: String,
        refresh_token: String,
        id_token: Option<String>,
        scope: String,
        expires_in: i64,
    }
    let tokens: Tokens = serde_json::from_slice(body)?;
    if tokens.expires_in <= 0 {
        bail!("InvalidTokenExpiry");
    }
    let obtained_at = now();
    let expires_at = obtained_at
        .checked_add(tokens.expires_in)
        .ok_or_else(|| anyhow!("InvalidTokenExpiry"))?;
    let id_token = tokens
        .id_token
        .filter(|id| !id.is_empty())
        .or_else(|| previous_id.map(str::to_owned))
        .ok_or_else(|| anyhow!("InvalidCredentials"))?;
    Ok(Credentials {
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        id_token,
        scope: tokens.scope,
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
) -> std::result::Result<(String, String), AuthError> {
    let invalid = AuthError::InvalidCallback;
    let query = callback
        .strip_prefix(&format!("{REDIRECT}?"))
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

fn save(directory: &Path, credentials: &Credentials) -> Result<()> {
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
        fs::rename(&temporary, directory.join("codex.json"))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const TOKENS: &str = r#"{"access_token":"new-access","refresh_token":"new-refresh","id_token":"new-id","scope":"chatgpt.tokens.use.direct","expires_in":3600}"#;

    fn session(directory: &Path) -> Arc<Session> {
        Session::load(
            directory.to_path_buf(),
            reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
        )
        .unwrap()
    }

    async fn fixture(status: &str, body: &str) -> (String, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let reply = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                let mut bytes = [0; 4096];
                let count = stream.read(&mut bytes).await.unwrap();
                assert_ne!(count, 0);
                request.extend_from_slice(&bytes[..count]);
                if let Some(start) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&request[..start]);
                    let length: usize = headers
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse().unwrap())
                        })
                        .unwrap();
                    if request.len() >= start + 4 + length {
                        break;
                    }
                }
            }
            stream.write_all(reply.as_bytes()).await.unwrap();
            String::from_utf8(request).unwrap()
        });
        (origin, task)
    }

    fn callback(pending: &Pending) -> String {
        format!(
            "{REDIRECT}?state={}&code=code%20%2B%2F%26%3D%3F%25&client_id=issued-client",
            pending.state
        )
    }

    fn assert_private(directory: &Path) {
        assert_eq!(
            fs::metadata(directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(directory.join("codex.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(fs::read_dir(directory).unwrap().count(), 1);
    }

    #[tokio::test]
    async fn login_exchanges_pkce_and_persists_registration() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("credentials");
        let (origin, request) = fixture("200 OK", TOKENS).await;
        let mut session = session(&directory);
        Arc::get_mut(&mut session).unwrap().origin = origin;
        let start = session.start().await.unwrap();
        let url = url::Url::parse(start["authorization_url"].as_str().unwrap()).unwrap();
        let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query["client_id"], "dynamic_agent_client");
        assert_eq!(query["agent_name_hint"], "fumo-gateway");
        let state = session.state.lock().await;
        let pending = state.pending.as_ref().unwrap();
        let verifier = pending.verifier.clone();
        assert_eq!(
            query["code_challenge"],
            URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
        );
        assert_ne!(pending.state, pending.nonce);
        let callback = callback(pending);
        drop(state);
        session.complete(&callback).await.unwrap();
        let request = request.await.unwrap();
        assert!(request.starts_with("POST /api/accounts/oauth/token HTTP/1.1\r\n"));
        let form: std::collections::HashMap<_, _> =
            url::form_urlencoded::parse(request.split_once("\r\n\r\n").unwrap().1.as_bytes())
                .into_owned()
                .collect();
        assert_eq!(form["code"], "code +/&=?%");
        assert_eq!(form["code_verifier"], verifier);
        assert_eq!(form["client_id"], "issued-client");
        assert_eq!(form["redirect_uri"], REDIRECT);
        assert_eq!(session.authorization().await.unwrap(), "Bearer new-access");
        assert_private(&directory);
        let loaded = super::Session::load(directory.clone(), session.client.clone()).unwrap();
        assert_eq!(loaded.authorization().await.unwrap(), "Bearer new-access");
        loaded.disconnect().await.unwrap();
        assert!(loaded.authorization().await.is_err());
        let saved: Credentials =
            serde_json::from_slice(&fs::read(directory.join("codex.json")).unwrap()).unwrap();
        assert_eq!(saved.client_id, "issued-client");
        assert!(saved.access_token.is_empty());
        assert_private(&directory);
    }

    #[tokio::test]
    async fn refresh_failures_retain_credentials_and_schedule_retry() {
        for (status, body, fail_save) in [
            (
                "500 Internal Server Error",
                r#"{"error":"secret-error"}"#,
                false,
            ),
            ("200 OK", TOKENS, true),
        ] {
            let root = tempfile::tempdir().unwrap();
            let directory = root.path().join("credentials");
            let current = Credentials {
                access_token: "old-access".into(),
                refresh_token: "old-refresh".into(),
                expires_at: now() + 60,
                ..Credentials::default()
            };
            save(&directory, &current).unwrap();
            let (origin, request) = fixture(status, body).await;
            let mut session = session(&directory);
            Arc::get_mut(&mut session).unwrap().origin = origin;
            if fail_save {
                fs::remove_file(directory.join("codex.json")).unwrap();
                fs::remove_dir(&directory).unwrap();
                fs::write(&directory, "not a directory").unwrap();
            }
            session.state.lock().await.refreshing = true;
            session.refresh(current, 0).await;
            request.await.unwrap();
            let state = session.state.lock().await;
            assert!(!state.refreshing);
            assert!(state.retry_at.is_some_and(|at| at > Instant::now()));
            assert_eq!(state.credentials.access_token, "old-access");
            assert_eq!(state.credentials.refresh_token, "old-refresh");
        }
    }

    #[tokio::test]
    async fn refresh_rotates_and_reloads_credentials() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("credentials");
        let current = Credentials {
            device_id: "host".into(),
            client_id: "client".into(),
            access_token: "old-access".into(),
            refresh_token: "refresh +/&=?%".into(),
            id_token: "old-id".into(),
            expires_at: now() + 10,
            ..Credentials::default()
        };
        save(&directory, &current).unwrap();
        let (origin, request) = fixture("200 OK", TOKENS).await;
        let mut session = session(&directory);
        Arc::get_mut(&mut session).unwrap().origin = origin;
        assert_eq!(session.authorization().await.unwrap(), "Bearer old-access");
        let request = request.await.unwrap();
        assert!(request.starts_with("POST /api/accounts/oauth/token HTTP/1.1\r\n"));
        assert!(request.contains("grant_type=refresh_token"));
        assert!(request.contains("refresh_token=refresh+%2B%2F%26%3D%3F%25"));
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if !session.state.lock().await.refreshing {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(session.authorization().await.unwrap(), "Bearer new-access");
        assert_private(&directory);
        let loaded = Session::load(directory, session.client.clone()).unwrap();
        assert_eq!(loaded.authorization().await.unwrap(), "Bearer new-access");
        let state = loaded.state.lock().await;
        assert_eq!(state.credentials.refresh_token, "new-refresh");
        assert_eq!(state.credentials.id_token, "new-id");
    }
}
