use std::{
    collections::HashMap,
    path::{Component, Path, PathBuf},
    sync::Arc,
};

use anyhow::Context;
use axum::{
    Router,
    body::{Body, to_bytes},
    extract::State,
    http::{HeaderMap, HeaderName, HeaderValue, Method, Request, StatusCode, header},
    response::Response,
    routing::any,
};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::{
    admin::{Account, Admin},
    auth,
    codex::Session,
    config::{Auth, Client, Config, Upstream},
    models, outbound,
};

const MAX_BODY: usize = 16 * 1024 * 1024;

pub(crate) struct Gateway {
    pub(crate) clients: Vec<Client>,
    pub(crate) providers: Vec<Provider>,
    pub(crate) http: reqwest::Client,
}

pub(crate) struct Provider {
    pub(crate) config: Upstream<ProviderAuth>,
    pub(crate) cache: Mutex<models::Cache>,
}

pub(crate) enum ProviderAuth {
    None,
    ApiKey(String),
    Codex(Arc<Session>),
}

impl Provider {
    pub(crate) async fn authorization(&self) -> anyhow::Result<Option<String>> {
        match &self.config.auth {
            ProviderAuth::None => Ok(None),
            ProviderAuth::ApiKey(key) => Ok(Some(format!("Bearer {key}"))),
            ProviderAuth::Codex(session) => Ok(Some(session.authorization().await?)),
        }
    }
}

impl Gateway {
    fn new(config: Config) -> anyhow::Result<(Arc<Self>, Arc<Admin>)> {
        let http = outbound::client(config.proxy.as_deref())?;
        let mut sessions = HashMap::new();
        let mut accounts = Vec::new();
        let mut providers = Vec::new();
        for upstream in config.upstreams {
            let auth = match upstream.auth {
                Auth::None => ProviderAuth::None,
                Auth::ApiKey(key) => ProviderAuth::ApiKey(key),
                Auth::Codex(directory) => {
                    let directory = absolute_path(&directory)?;
                    let session = if let Some(session) = sessions.get(&directory) {
                        Arc::clone(session)
                    } else {
                        let session = Session::load(directory.clone(), http.clone())?;
                        sessions.insert(directory, Arc::clone(&session));
                        accounts.push(Account {
                            id: upstream.name.clone(),
                            configured: true,
                            session: Arc::clone(&session),
                        });
                        session
                    };
                    ProviderAuth::Codex(session)
                }
            };
            providers.push(Provider {
                config: Upstream {
                    name: upstream.name,
                    base_url: upstream.base_url,
                    aliases: upstream.aliases,
                    auth,
                },
                cache: Mutex::default(),
            });
        }
        if accounts.is_empty()
            && let Some(directory) = config.admin_directory
        {
            accounts.push(Account {
                id: "codex".into(),
                configured: false,
                session: Session::load(absolute_path(&directory)?, http.clone())?,
            });
        }
        let gateway = Arc::new(Self {
            clients: config.clients,
            providers,
            http,
        });
        Ok((gateway, Arc::new(Admin::new(config.admin, accounts))))
    }
}

fn absolute_path(path: &Path) -> anyhow::Result<PathBuf> {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                result.pop();
            }
            Component::CurDir => {}
            other => result.push(other.as_os_str()),
        }
    }
    Ok(result)
}

pub(crate) async fn serve(config: Config) -> anyhow::Result<()> {
    let listen = config.listen;
    let (gateway, admin) = Gateway::new(config)?;
    let router = Router::new()
        .route("/healthz", any(health))
        .route("/v1", any(v1))
        .route("/v1/", any(v1))
        .route("/v1/{*path}", any(v1))
        .fallback(not_found)
        .with_state(gateway)
        .merge(admin.router());
    let listener = tokio::net::TcpListener::bind(listen)
        .await
        .context("listen failed")?;
    eprintln!("event=server_started address={listen}");
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await?;
    Ok(())
}

async fn health(method: Method) -> Response {
    if method == Method::GET {
        json_response(StatusCode::OK, json!({"status":"ok"}))
    } else {
        error(StatusCode::NOT_FOUND, "not_found")
    }
}

async fn not_found() -> Response {
    error(StatusCode::NOT_FOUND, "not_found")
}

async fn v1(State(gateway): State<Arc<Gateway>>, request: Request<Body>) -> Response {
    let Some(client) = auth::authenticate(&gateway.clients, request.headers()) else {
        let mut response = error(StatusCode::UNAUTHORIZED, "unauthorized");
        response
            .headers_mut()
            .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        return response;
    };
    let client = client.to_owned();
    let response = match (request.method(), request.uri().path()) {
        (&Method::GET, "/v1/models") => match models::list(&gateway).await {
            Ok(list) => json_response(StatusCode::OK, list),
            Err(_) => error(StatusCode::BAD_GATEWAY, "model_discovery_unavailable"),
        },
        (&Method::POST, "/v1/responses") => forward(&gateway, request, "/responses").await,
        (&Method::POST, "/v1/chat/completions") => {
            forward(&gateway, request, "/chat/completions").await
        }
        _ => error(StatusCode::NOT_FOUND, "not_found"),
    };
    eprintln!(
        "event=request status={} client={}",
        response.status().as_u16(),
        json!(client)
    );
    response
}

async fn forward(gateway: &Gateway, request: Request<Body>, path: &str) -> Response {
    if request
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|length| length > MAX_BODY as u64)
    {
        return error(StatusCode::PAYLOAD_TOO_LARGE, "request_too_large");
    }
    if request
        .headers()
        .get(header::EXPECT)
        .is_some_and(|value| !value.as_bytes().eq_ignore_ascii_case(b"100-continue"))
    {
        return error(StatusCode::EXPECTATION_FAILED, "unsupported_expectation");
    }
    let (parts, body) = request.into_parts();
    let body = match to_bytes(body, MAX_BODY).await {
        Ok(body) => body,
        Err(err) => return body_error(err),
    };
    let (provider, body) = match route_request(&body, &gateway.providers) {
        Ok(value) => value,
        Err(reason) => return error(StatusCode::BAD_REQUEST, reason),
    };
    let authorization = match provider.authorization().await {
        Ok(authorization) => authorization,
        Err(_) => {
            return error(
                StatusCode::SERVICE_UNAVAILABLE,
                "upstream_credentials_unavailable",
            );
        }
    };
    let mut outgoing = gateway
        .http
        .post(format!("{}{path}", provider.config.base_url))
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::ACCEPT_ENCODING, "identity")
        .body(body);
    for (name, value) in &parts.headers {
        if !blocked_request_header(name, &parts.headers) {
            outgoing = outgoing.header(name, value);
        }
    }
    if let Some(authorization) = authorization {
        outgoing = outgoing.header(header::AUTHORIZATION, authorization);
    }
    if matches!(provider.config.auth, ProviderAuth::Codex(_)) {
        outgoing = outgoing.header(header::USER_AGENT, "fumo-gateway");
    }
    let upstream = match outgoing.send().await {
        Ok(response) => response,
        Err(_) => return error(StatusCode::BAD_GATEWAY, "bad_gateway"),
    };
    let status = upstream.status();
    if status == StatusCode::SWITCHING_PROTOCOLS {
        return error(StatusCode::BAD_GATEWAY, "bad_gateway");
    }
    let mut headers = HeaderMap::new();
    for (name, value) in upstream.headers() {
        if !hop_by_hop(name, upstream.headers()) && name != header::AUTHORIZATION {
            headers.append(name, value.clone());
        }
    }
    let body = if status == StatusCode::NO_CONTENT || status == StatusCode::NOT_MODIFIED {
        headers.remove(header::CONTENT_LENGTH);
        Body::empty()
    } else {
        Body::from_stream(upstream.bytes_stream())
    };
    let mut response = Response::new(body);
    *response.status_mut() = status;
    *response.headers_mut() = headers;
    response
}

fn route_request<'a>(
    body: &[u8],
    providers: &'a [Provider],
) -> Result<(&'a Provider, Vec<u8>), &'static str> {
    let mut value: Value = serde_json::from_slice(body).map_err(|_| "invalid_request")?;
    let model = value
        .get("model")
        .and_then(Value::as_str)
        .ok_or("invalid_request")?;
    let (name, native) = model.split_once('/').ok_or("unknown_upstream")?;
    if native.is_empty() {
        return Err("invalid_request");
    }
    let provider = providers
        .iter()
        .find(|p| p.config.name == name)
        .ok_or("unknown_upstream")?;
    let native = provider
        .config
        .aliases
        .get(native)
        .map_or(native, String::as_str)
        .to_owned();
    value["model"] = Value::String(native);
    let body = serde_json::to_vec(&value).map_err(|_| "invalid_request")?;
    Ok((provider, body))
}

pub(crate) fn body_error(err: axum::Error) -> Response {
    use std::error::Error;

    if err
        .source()
        .is_some_and(|source| source.is::<http_body_util::LengthLimitError>())
    {
        error(StatusCode::PAYLOAD_TOO_LARGE, "request_too_large")
    } else {
        error(StatusCode::BAD_REQUEST, "invalid_request")
    }
}

fn blocked_request_header(name: &HeaderName, headers: &HeaderMap) -> bool {
    hop_by_hop(name, headers)
        || matches!(
            name.as_str(),
            "authorization"
                | "host"
                | "content-length"
                | "content-type"
                | "accept-encoding"
                | "expect"
        )
}

fn hop_by_hop(name: &HeaderName, headers: &HeaderMap) -> bool {
    matches!(
        name.as_str(),
        "connection"
            | "keep-alive"
            | "proxy-connection"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
    ) || connection_header(name, headers)
}

fn connection_header(name: &HeaderName, headers: &HeaderMap) -> bool {
    headers
        .get_all(header::CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .any(|token| token.trim().eq_ignore_ascii_case(name.as_str()))
}

fn json_response(status: StatusCode, value: Value) -> Response {
    let mut response = Response::new(Body::from(format!("{value}\n")));
    *response.status_mut() = status;
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    response
}

fn error(status: StatusCode, message: &'static str) -> Response {
    json_response(status, json!({"error": message}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn runtime_auth_preserves_authorization() {
        let http = reqwest::Client::builder().no_proxy().build().unwrap();
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(
            directory.path().join("codex.json"),
            br#"{"device_id":"host","client_id":"client","access_token":"personal-token","expires_at":4102444800}"#,
        ).unwrap();
        let session = Session::load(directory.path().into(), http).unwrap();
        for (auth, expected) in [
            (ProviderAuth::None, None),
            (
                ProviderAuth::ApiKey("api-key".into()),
                Some("Bearer api-key"),
            ),
            (ProviderAuth::Codex(session), Some("Bearer personal-token")),
        ] {
            let provider = Provider {
                config: Upstream {
                    name: "test".into(),
                    base_url: "https://api.openai.com/v1".into(),
                    aliases: Default::default(),
                    auth,
                },
                cache: Mutex::default(),
            };
            assert_eq!(provider.authorization().await.unwrap().as_deref(), expected);
        }
    }
}
