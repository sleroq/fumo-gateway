use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
};

use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{ConnectInfo, Request, State},
    http::{HeaderMap, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::any,
};
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{
    codex::{AuthError, Session},
    config::Client,
};

pub struct Account {
    pub id: String,
    pub configured: bool,
    pub session: Arc<Session>,
}

pub struct Admin {
    admin: Option<Client>,
    accounts: Vec<Account>,
    sessions: Mutex<HashMap<String, bool>>,
}

impl Admin {
    pub fn new(admin: Option<Client>, accounts: Vec<Account>) -> Self {
        Self {
            admin,
            accounts,
            sessions: Mutex::new(HashMap::new()),
        }
    }

    pub fn router(self: Arc<Self>) -> Router {
        Router::new()
            .route("/admin", any(handle))
            .route("/admin/", any(handle))
            .route("/admin/{*path}", any(handle))
            .with_state(self)
    }

    fn lookup(&self, token: &str, revoke: bool) -> Option<bool> {
        let mut sessions = self.sessions.lock().unwrap();
        if revoke {
            sessions.remove(token)
        } else {
            sessions.get(token).copied()
        }
    }
}

fn response(status: StatusCode, body: impl Into<Body>, content_type: &'static str) -> Response {
    let mut response = (status, body.into()).into_response();
    for (name, value) in [
        ("content-type", content_type),
        ("cache-control", "no-store"),
        ("x-content-type-options", "nosniff"),
        ("referrer-policy", "no-referrer"),
        (
            "content-security-policy",
            "default-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
        ),
    ] {
        response
            .headers_mut()
            .insert(name, HeaderValue::from_static(value));
    }
    response
}

fn json_response(status: StatusCode, value: Value) -> Response {
    response(status, value.to_string(), "application/json")
}

fn error(status: StatusCode, message: &str) -> Response {
    json_response(status, json!({"error": message}))
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    let mut values = headers.get_all(name).iter();
    let value = values.next()?.to_str().ok()?;
    if values.next().is_some() {
        return None;
    }
    Some(value)
}

fn browser_request(headers: &HeaderMap) -> bool {
    for name in ["origin", "host", "sec-fetch-site", "x-requested-with"] {
        if headers.get_all(name).iter().count() > 1 {
            return false;
        }
    }
    if header(headers, "x-requested-with") != Some("fumo-admin")
        || header(headers, "sec-fetch-site") == Some("cross-site")
    {
        return false;
    }
    if let Some(origin) = header(headers, "origin") {
        let Some(authority) = origin
            .strip_prefix("https://")
            .or_else(|| origin.strip_prefix("http://"))
        else {
            return false;
        };
        return header(headers, "host").is_some_and(|host| authority.eq_ignore_ascii_case(host));
    }
    true
}

fn cookie_token(headers: &HeaderMap) -> Result<Option<&str>, ()> {
    let mut token = None;
    for value in headers.get_all("cookie") {
        let value = value.to_str().map_err(|_| ())?;
        for cookie in value.split(';') {
            if let Some(("fumo_admin_session", value)) =
                cookie.trim_matches([' ', '\t']).split_once('=')
                && token.replace(value).is_some()
            {
                return Err(());
            }
        }
    }
    Ok(token)
}

fn session_response(token: &str, secure: bool, clear: bool) -> Response {
    let cookie = format!(
        "fumo_admin_session={token}; HttpOnly; SameSite=Strict; Path=/admin/{}{}",
        if secure { "; Secure" } else { "" },
        if clear { "; Max-Age=0" } else { "" }
    );
    let mut result = json_response(StatusCode::OK, json!({}));
    result
        .headers_mut()
        .insert("set-cookie", HeaderValue::from_str(&cookie).unwrap());
    result
}

fn asset(headers: &HeaderMap, bytes: &'static [u8], content_type: &'static str) -> Response {
    let etag = format!("\"{:x}\"", Sha256::digest(bytes));
    let unchanged = headers
        .get_all("if-none-match")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .any(|tag| {
            let tag = tag.trim_matches([' ', '\t']);
            tag == "*" || tag.strip_prefix("W/").unwrap_or(tag) == etag
        });
    let mut result = response(
        if unchanged {
            StatusCode::NOT_MODIFIED
        } else {
            StatusCode::OK
        },
        if unchanged { &b""[..] } else { bytes },
        content_type,
    );
    result
        .headers_mut()
        .insert("cache-control", HeaderValue::from_static("no-cache"));
    result
        .headers_mut()
        .insert("etag", HeaderValue::from_str(&etag).unwrap());
    result
}

async fn handle(
    State(admin): State<Arc<Admin>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
) -> Response {
    if !peer.ip().is_loopback() {
        return error(StatusCode::FORBIDDEN, "loopback_required");
    }
    let path = request.uri().path().to_owned();
    let method = request.method();
    let headers = request.headers();
    if !path.starts_with("/admin/api/") {
        if method == Method::GET {
            let (bytes, content_type): (&'static [u8], _) = match path.as_str() {
                "/admin" | "/admin/" => (
                    include_bytes!(concat!(env!("OUT_DIR"), "/index.html")),
                    "text/html; charset=utf-8",
                ),
                "/admin/assets/admin.js" => (
                    include_bytes!(concat!(env!("OUT_DIR"), "/assets/admin.js")),
                    "text/javascript; charset=utf-8",
                ),
                "/admin/assets/admin.css" => (
                    include_bytes!(concat!(env!("OUT_DIR"), "/assets/admin.css")),
                    "text/css; charset=utf-8",
                ),
                "/admin/logo.svg" => (
                    include_bytes!(concat!(env!("OUT_DIR"), "/logo.svg")),
                    "image/svg+xml",
                ),
                _ => return error(StatusCode::NOT_FOUND, "not_found"),
            };
            return asset(headers, bytes, content_type);
        }
        return error(StatusCode::NOT_FOUND, "not_found");
    }
    let Some(client) = &admin.admin else {
        return error(StatusCode::SERVICE_UNAVAILABLE, "admin_disabled");
    };
    let bearer = crate::auth::authenticate(std::slice::from_ref(client), headers).is_some();
    let session_route = path == "/admin/api/session";
    let token = match cookie_token(headers) {
        Ok(token) => token,
        Err(()) => return error(StatusCode::UNAUTHORIZED, "unauthorized"),
    };
    if (session_route || (!bearer && token.is_some())) && !browser_request(headers) {
        return error(StatusCode::FORBIDDEN, "forbidden");
    }
    let secure = header(headers, "origin").is_some_and(|origin| origin.starts_with("https://"));
    if session_route && method == Method::POST && bearer {
        let mut bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        let token: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        admin.sessions.lock().unwrap().insert(token.clone(), secure);
        return session_response(&token, secure, false);
    }
    if session_route && method == Method::DELETE {
        let secure = token
            .and_then(|token| admin.lookup(token, true))
            .unwrap_or(secure);
        return session_response("", secure, true);
    }
    if !bearer && !token.is_some_and(|token| admin.lookup(token, false).is_some()) {
        return error(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    if path == "/admin/api/accounts" && method == Method::GET {
        let mut accounts = Vec::with_capacity(admin.accounts.len());
        for account in &admin.accounts {
            let state = account.session.status().await;
            let provider = if account.session.is_legacy() {
                "codex_legacy"
            } else {
                "codex"
            };
            accounts.push(json!({"id": account.id, "provider": provider, "status": state.status, "configured": account.configured, "pending": state.pending}));
        }
        return json_response(StatusCode::OK, json!({"accounts": accounts}));
    }
    if method != Method::POST {
        return error(StatusCode::NOT_FOUND, "not_found");
    }
    let Some((id, action)) = path
        .strip_prefix("/admin/api/accounts/")
        .and_then(|tail| tail.split_once('/'))
    else {
        return error(StatusCode::NOT_FOUND, "not_found");
    };
    let Some(account) = admin.accounts.iter().find(|account| account.id == id) else {
        return error(StatusCode::NOT_FOUND, "not_found");
    };
    match action {
        "auth/disconnect" => match account.session.disconnect().await {
            Ok(()) => json_response(StatusCode::OK, json!({"status": "login_required"})),
            Err(_) => error(StatusCode::INTERNAL_SERVER_ERROR, "credential_save_failed"),
        },
        "auth/start" => match account.session.start().await {
            Ok(value) => json_response(StatusCode::OK, value),
            Err(_) => error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "authentication_start_failed",
            ),
        },
        "auth/complete" => complete(account, request).await,
        _ => error(StatusCode::NOT_FOUND, "not_found"),
    }
}

async fn complete(account: &Account, request: Request) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Callback {
        callback_url: String,
    }
    let body = match to_bytes(request.into_body(), 16384).await {
        Ok(body) => body,
        Err(err) => return crate::gateway::body_error(err),
    };
    let Ok(input) = serde_json::from_slice::<Callback>(&body) else {
        return error(StatusCode::BAD_REQUEST, "invalid_request");
    };
    match account.session.complete(&input.callback_url).await {
        Ok(()) => json_response(StatusCode::OK, json!({"status": "connected"})),
        Err(err) => {
            let (status, message) = match err {
                AuthError::NoPendingLogin => (StatusCode::CONFLICT, "no_pending_login"),
                AuthError::LoginExpired => (StatusCode::GONE, "login_expired"),
                AuthError::InvalidCallback => (StatusCode::BAD_REQUEST, "invalid_callback"),
                AuthError::CredentialSaveFailed => {
                    (StatusCode::INTERNAL_SERVER_ERROR, "credential_save_failed")
                }
                AuthError::ExchangeFailed => {
                    (StatusCode::BAD_GATEWAY, "authentication_exchange_failed")
                }
            };
            error(status, message)
        }
    }
}
