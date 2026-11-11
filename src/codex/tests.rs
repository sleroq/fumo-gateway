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
async fn legacy_login_refresh_and_disconnect_are_isolated() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("credentials");
    let siwc = Credentials {
        access_token: "siwc".into(),
        expires_at: now() + 3600,
        ..Credentials::default()
    };
    save(&directory, &siwc, false).unwrap();
    let jwt = |account: &str| {
        format!(
            "header.{}.signature",
            URL_SAFE_NO_PAD.encode(
                json!({"https://api.openai.com/auth": {"chatgpt_account_id": account}}).to_string()
            )
        )
    };
    let first = jwt("account-one");
    let second = jwt("account-two");
    let body = json!({"access_token": first, "refresh_token": "refresh-one", "expires_in": 3600})
        .to_string();
    let (origin, request) = fixture("200 OK", &body).await;
    let mut legacy = Session::load_legacy(
        directory.clone(),
        reqwest::Client::builder().no_proxy().build().unwrap(),
    )
    .unwrap();
    Arc::get_mut(&mut legacy).unwrap().origin = origin;
    assert!(legacy.is_legacy());
    assert!(!session(&directory).is_legacy());
    let start = legacy.start().await.unwrap();
    let url = url::Url::parse(start["authorization_url"].as_str().unwrap()).unwrap();
    assert_eq!(url.path(), "/oauth/authorize");
    let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(query["client_id"], LEGACY_CLIENT_ID);
    assert_eq!(query["redirect_uri"], LEGACY_REDIRECT);
    assert_eq!(query["scope"], "openid profile email offline_access");
    assert_eq!(query["response_type"], "code");
    assert_eq!(query["code_challenge_method"], "S256");
    assert_eq!(query["id_token_add_organizations"], "true");
    assert_eq!(query["codex_cli_simplified_flow"], "true");
    assert_eq!(query["originator"], "fumo-gateway");
    for name in ["resource", "nonce", "ext_agent_host_id", "agent_name_hint"] {
        assert!(!query.contains_key(name));
    }
    let state = legacy.state.lock().await;
    let pending = state.pending.as_ref().unwrap();
    let verifier = pending.verifier.clone();
    assert_eq!(
        query["code_challenge"],
        URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
    );
    let callback = format!("{LEGACY_REDIRECT}?state={}&code=code", pending.state);
    drop(state);
    assert_eq!(
        legacy
            .complete(&callback.replace(LEGACY_REDIRECT, REDIRECT))
            .await,
        Err(AuthError::InvalidCallback)
    );
    legacy.complete(&callback).await.unwrap();
    let request = request.await.unwrap();
    assert!(request.starts_with("POST /oauth/token HTTP/1.1\r\n"));
    let form: std::collections::HashMap<_, _> =
        url::form_urlencoded::parse(request.split_once("\r\n\r\n").unwrap().1.as_bytes())
            .into_owned()
            .collect();
    assert_eq!(form["grant_type"], "authorization_code");
    assert_eq!(form["client_id"], LEGACY_CLIENT_ID);
    assert_eq!(form["code_verifier"], verifier);
    assert_eq!(form["redirect_uri"], LEGACY_REDIRECT);
    assert!(!form.contains_key("resource"));
    let headers = legacy.headers().await.unwrap();
    assert_eq!(headers["authorization"], format!("Bearer {first}"));
    assert_eq!(headers["user-agent"], "fumo-gateway");
    assert_eq!(headers["chatgpt-account-id"], "account-one");
    assert_eq!(headers["originator"], "fumo-gateway");
    assert_eq!(headers["openai-beta"], "responses=experimental");
    let body = json!({"access_token": second, "refresh_token": "refresh-two", "expires_in": 3600})
        .to_string();
    let (origin, request) = fixture("200 OK", &body).await;
    Arc::get_mut(&mut legacy).unwrap().origin = origin;
    {
        let mut state = legacy.state.lock().await;
        state.credentials.expires_at = now() - 1;
    }
    assert_eq!(
        legacy.headers().await.unwrap()["chatgpt-account-id"],
        "account-two"
    );
    let request = request.await.unwrap();
    assert!(request.starts_with("POST /oauth/token HTTP/1.1\r\n"));
    let form: std::collections::HashMap<_, _> =
        url::form_urlencoded::parse(request.split_once("\r\n\r\n").unwrap().1.as_bytes())
            .into_owned()
            .collect();
    assert_eq!(form["grant_type"], "refresh_token");
    assert_eq!(form["client_id"], LEGACY_CLIENT_ID);
    assert_eq!(form["refresh_token"], "refresh-one");
    assert!(!form.contains_key("resource"));
    let loaded = Session::load_legacy(directory.clone(), legacy.client.clone()).unwrap();
    assert_eq!(
        loaded.headers().await.unwrap()["chatgpt-account-id"],
        "account-two"
    );
    assert_eq!(
        loaded.state.lock().await.credentials.refresh_token,
        "refresh-two"
    );
    loaded.disconnect().await.unwrap();
    assert!(loaded.authorization().await.is_err());
    assert_eq!(
        session(&directory).authorization().await.unwrap(),
        "Bearer siwc"
    );
    assert!(
        parse_tokens(
            json!({"access_token": jwt(""), "refresh_token": "refresh", "expires_in": 3600})
                .to_string()
                .as_bytes(),
            LEGACY_CLIENT_ID,
            "",
            None,
            true
        )
        .is_err()
    );
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
        save(&directory, &current, false).unwrap();
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
async fn expired_requests_wait_for_the_same_refresh() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("credentials");
    save(
        &directory,
        &Credentials {
            access_token: "old-access".into(),
            refresh_token: "old-refresh".into(),
            expires_at: now() - 1,
            ..Credentials::default()
        },
        false,
    )
    .unwrap();
    let (origin, request) = fixture("200 OK", TOKENS).await;
    let mut session = session(&directory);
    Arc::get_mut(&mut session).unwrap().origin = origin;
    let (first, second) = tokio::join!(session.authorization(), session.authorization());
    assert_eq!(first.unwrap(), "Bearer new-access");
    assert_eq!(second.unwrap(), "Bearer new-access");
    request.await.unwrap();
}

#[tokio::test]
async fn expired_request_fails_when_refresh_fails() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("credentials");
    save(
        &directory,
        &Credentials {
            refresh_token: "old-refresh".into(),
            expires_at: now() - 1,
            ..Credentials::default()
        },
        false,
    )
    .unwrap();
    let (origin, request) = fixture("500 Internal Server Error", r#"{"error":"failure"}"#).await;
    let mut session = session(&directory);
    Arc::get_mut(&mut session).unwrap().origin = origin;
    assert!(session.authorization().await.is_err());
    request.await.unwrap();
    assert!(session.authorization().await.is_err());
    assert!(session.state.lock().await.retry_at.is_some());
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
    save(&directory, &current, false).unwrap();
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
