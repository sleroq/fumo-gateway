use std::{
    collections::HashSet,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, ensure};
use serde_json::{Map, Value, json};

use crate::{
    config,
    gateway::{Gateway, Provider, ProviderAuth},
};

#[derive(Default)]
pub(crate) struct Cache {
    models: Option<Vec<Value>>,
    next_refresh: Option<Instant>,
}

pub(crate) async fn list(gateway: &Gateway) -> Result<Value> {
    let mut available = gateway.providers.is_empty();
    let mut data = Vec::new();
    let mut seen = HashSet::new();
    for provider in &gateway.providers {
        let native = snapshot(provider, &gateway.http).await;
        available |= native.is_some() || !provider.config.aliases.is_empty();
        let native = native.unwrap_or_default();
        let owner = &provider.config.name;
        let mut models = Vec::new();
        for (alias, target) in &provider.config.aliases {
            let target = format!("{owner}/{target}");
            let mut model = native
                .iter()
                .find(|model| model["id"] == target)
                .cloned()
                .unwrap_or_else(|| base_model(owner, alias));
            model["id"] = Value::String(format!("{owner}/{alias}"));
            models.push(model);
        }
        models.extend(native);
        for model in models {
            let model = with_constraints(model, &provider.config.auth);
            let id = model["id"]
                .as_str()
                .expect("normalized model ID")
                .to_owned();
            if seen.insert(id) {
                data.push(model);
            }
        }
    }
    ensure!(available, "ModelDiscoveryUnavailable");
    Ok(json!({"object": "list", "data": data}))
}

async fn snapshot(provider: &Provider, http: &reqwest::Client) -> Option<Vec<Value>> {
    // Keep authorization outside the cache lock, like inference/session callers.
    let headers = provider.headers().await;
    let mut cache = provider.cache.lock().await;
    let now = Instant::now();
    if cache.next_refresh.is_none_or(|next| now >= next) {
        let result = async { discover(http, &provider.config, headers?).await }.await;
        let delay = match result {
            Ok(models) => {
                cache.models = Some(models);
                300
            }
            Err(error) => {
                eprintln!(
                    "event=model_discovery_failed upstream={} error={error:#}",
                    provider.config.name
                );
                30
            }
        };
        cache.next_refresh = Some(now + Duration::from_secs(delay));
    }
    cache.models.clone()
}

async fn discover(
    http: &reqwest::Client,
    upstream: &config::Upstream<ProviderAuth>,
    headers: reqwest::header::HeaderMap,
) -> Result<Vec<Value>> {
    tokio::time::timeout(Duration::from_secs(5), async {
        let siwc = matches!(upstream.auth, ProviderAuth::Codex(_));
        let mut request = http
            .get(format!("{}/models", upstream.base_url))
            .header(reqwest::header::ACCEPT_ENCODING, "identity")
            .headers(headers);
        if let ProviderAuth::Codex(session) = &upstream.auth
            && session.is_legacy()
        {
            // Codex selects its catalog by Codex CLI version, not Fumo's version.
            request = request.query(&[("client_version", "0.167.0")]);
        }
        let response = request.send().await?;
        ensure!(
            response.status() == reqwest::StatusCode::OK,
            "ModelsHttpFailure"
        );
        let body =
            crate::outbound::read_body(response, 4 * 1024 * 1024, "ModelsBodyTooLarge").await?;
        parse(&body, &upstream.name, siwc)
    })
    .await
    .context("ModelsTimedOut")?
}

fn base_model(owner: &str, id: &str) -> Value {
    json!({"id": format!("{owner}/{id}"), "object": "model", "owned_by": owner})
}

fn optional<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a Value> {
    object.get(key).filter(|value| !value.is_null())
}

fn parse(body: &[u8], owner: &str, siwc: bool) -> Result<Vec<Value>> {
    let root: Value = serde_json::from_slice(body)?;
    let entries = root[if siwc { "models" } else { "data" }]
        .as_array()
        .ok_or_else(|| anyhow!("InvalidModelCatalog"))?;
    let mut models = Vec::new();
    for entry in entries {
        let metadata = entry.as_object().ok_or_else(|| anyhow!("InvalidModel"))?;
        let required = |key: &str| {
            metadata
                .get(key)
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("InvalidModelField: {key}"))
        };
        let created = optional(metadata, "created");
        ensure!(
            created.is_none_or(|value| value.as_i64().is_some()),
            "InvalidModelCreated"
        );
        let (id, name) = if siwc {
            let id = required("slug")?;
            let name = required("display_name")?;
            if required("visibility")? != "list" {
                continue;
            }
            (id, Some(Value::String(name.into())))
        } else {
            let name = optional(metadata, "name");
            ensure!(name.is_none_or(Value::is_string), "InvalidModelName");
            (required("id")?, name.cloned())
        };
        ensure!(!id.is_empty(), "EmptyModelId");
        let mut model = base_model(owner, id);
        let object = model.as_object_mut().expect("base model");
        if let Some(name) = name {
            object.insert("name".into(), name);
        }
        if let Some(created) = created {
            object.insert("created".into(), created.clone());
        }
        for (key, value) in metadata {
            if ![
                "id",
                "object",
                "owned_by",
                "name",
                "created",
                "request_constraints",
            ]
            .contains(&key.as_str())
            {
                object.insert(key.clone(), value.clone());
            }
        }
        models.push(model);
    }
    Ok(models)
}

fn with_constraints(model: Value, auth: &ProviderAuth) -> Value {
    let ProviderAuth::Codex(session) = auth else {
        return model;
    };
    let mut object = Map::new();
    for (key, value) in model.as_object().expect("normalized model") {
        if !["id", "object", "owned_by", "name", "created"].contains(&key.as_str()) {
            continue;
        }
        object.insert(key.clone(), value.clone());
    }
    let mut constraints = json!({"responses": {
        "omit": ["background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation", "multi_agent", "prompt", "prompt_cache_options", "prompt_cache_retention", "safety_identifier", "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id"],
        "function_tools": "namespaced-or-additional",
        "unsupported_tools": ["image_generation", "file_search", "code_interpreter", "computer_use_preview", "mcp", "tool_search", "programmatic_tool_calling"]
    }});
    if session.is_legacy() {
        constraints["responses"]["function_tools"] = json!("flat");
        constraints["responses"]["instructions"] = json!("You are a helpful assistant.");
    }
    object.insert("request_constraints".into(), constraints);
    for (key, value) in model.as_object().expect("normalized model") {
        if !object.contains_key(key) {
            object.insert(key.clone(), value.clone());
        }
    }
    Value::Object(object)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn discovers_chatgpt_catalog_with_persisted_session() {
        use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        for legacy in [false, true] {
            let token = if legacy {
                format!(
                    "header.{}.signature",
                    URL_SAFE_NO_PAD.encode(
                        br#"{"https://api.openai.com/auth":{"chatgpt_account_id":"test-account"}}"#
                    )
                )
            } else {
                "personal-token".into()
            };
            let expected_token = token.clone();
            let body = br#"{"models":[{"slug":"gpt-6.1-sol","display_name":"Personal Codex","visibility":"list","context_window":272000,"max_output_tokens":16000,"input_modalities":["text","image"],"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"high","description":"Thorough"}],"supports_parallel_tool_calls":false,"request_constraints":{"spoofed":true}},{"slug":"hidden","display_name":"Hidden","visibility":"hidden"}]}"#;
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    request.push(socket.read_u8().await.unwrap());
                }
                let request = String::from_utf8(request).unwrap().to_lowercase();
                let path = if legacy {
                    "/models?client_version=0.167.0"
                } else {
                    "/models"
                };
                assert!(request.starts_with(&format!("get {path} http/1.1\r\n")));
                assert!(request.contains(&format!(
                    "authorization: bearer {}\r\n",
                    expected_token.to_lowercase()
                )));
                assert!(request.contains("user-agent: fumo-gateway\r\n"));
                if legacy {
                    assert!(request.contains("chatgpt-account-id: test-account\r\n"));
                    assert!(request.contains("originator: fumo-gateway\r\n"));
                }
                socket.write_all(format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            ).as_bytes()).await.unwrap();
                socket.write_all(body).await.unwrap();
            });
            let directory = tempfile::tempdir().unwrap();
            std::fs::write(
            directory.path().join(if legacy { "codex-legacy.json" } else { "codex.json" }),
            json!({"device_id":"host","client_id":"client","access_token":token,"expires_at":4102444800_i64}).to_string(),
        ).unwrap();
            let http = reqwest::Client::builder().no_proxy().build().unwrap();
            let session = if legacy {
                crate::codex::Session::load_legacy(directory.path().into(), http.clone()).unwrap()
            } else {
                crate::codex::Session::load(directory.path().into(), http.clone()).unwrap()
            };
            let gateway = Gateway {
                clients: Vec::new(),
                providers: vec![Provider {
                    config: config::Upstream {
                        name: "personal".into(),
                        base_url: format!("http://{address}"),
                        aliases: Default::default(),
                        auth: ProviderAuth::Codex(session),
                    },
                    cache: tokio::sync::Mutex::new(Cache::default()),
                }],
                http,
            };
            let catalog = list(&gateway).await.unwrap();
            server.await.unwrap();
            assert_eq!(catalog["data"].as_array().unwrap().len(), 1);
            let mut fixture: Value =
                serde_json::from_str(include_str!("../tests/fixtures/model-catalog.json")).unwrap();
            if legacy {
                fixture["data"][2]["request_constraints"]["responses"]["function_tools"] =
                    json!("flat");
                fixture["data"][2]["request_constraints"]["responses"]["instructions"] =
                    json!("You are a helpful assistant.");
            }
            assert_eq!(
                serde_json::to_string(&catalog["data"][0]).unwrap(),
                serde_json::to_string(&fixture["data"][2]).unwrap()
            );
        }
    }
}
