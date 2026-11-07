//! Black-box compatibility contracts for the gateway HTTP transport.
use serde_json::{Value, json};
use std::{
    process::{Child, Command, Stdio},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    time::timeout,
};

const LIMIT: Duration = Duration::from_secs(5);

struct Gateway {
    child: Child,
    _directory: tempfile::TempDir,
    url: String,
    http: reqwest::Client,
}
impl Drop for Gateway {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Gateway {
    async fn start(base: &str, proxy: Option<&str>) -> Self {
        let reservation = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = reservation.local_addr().unwrap();
        let directory = tempfile::tempdir().unwrap();
        let mut config = json!({
            "listen": address.to_string(),
            "clients": {"test": {"key_env": "TEST_CLIENT_KEY"}},
            "upstreams": {"fixture": {"base_url": base,
                "auth": {"provider": "api_key", "key_env": "TEST_UPSTREAM_KEY"},
                "aliases": {"alias": "native", "fallback": "missing"}}}
        });
        if proxy.is_some() {
            config["proxy_env"] = json!("TEST_PROXY");
        }
        let path = directory.path().join("gateway.json");
        let log_path = directory.path().join("gateway.log");
        std::fs::write(&path, config.to_string()).unwrap();
        let log = std::fs::File::create(&log_path).unwrap();
        drop(reservation);
        let mut command = Command::new(env!("CARGO_BIN_EXE_fumo-gateway"));
        command
            .args(["--config"])
            .arg(path)
            .env_clear()
            .env("HOME", directory.path())
            .env("TEST_CLIENT_KEY", "client-secret")
            .env("FUMO_ADMIN_KEY", "admin-secret")
            .env("TEST_UPSTREAM_KEY", "upstream-secret")
            .stdout(Stdio::null())
            .stderr(Stdio::from(log));
        if let Some(proxy) = proxy {
            command.env("TEST_PROXY", proxy);
        }
        let child = command.spawn().unwrap();
        let mut gateway = Self {
            child,
            _directory: directory,
            url: format!("http://{address}"),
            http: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(LIMIT)
                .build()
                .unwrap(),
        };
        timeout(LIMIT, async {
            loop {
                let log = std::fs::read_to_string(&log_path).unwrap();
                assert!(
                    gateway.child.try_wait().unwrap().is_none(),
                    "gateway exited before readiness: {log}"
                );
                // A port may temporarily belong to another test after reservation
                // is released. Wait for this child to report that it bound it.
                if log
                    .lines()
                    .any(|line| line == format!("event=server_started address={address}"))
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("gateway readiness timed out");
        gateway
    }
    fn get(&self, path: &str) -> reqwest::RequestBuilder {
        self.http
            .get(format!("{}{path}", self.url))
            .bearer_auth("client-secret")
    }
    fn post(&self, path: &str, body: &str) -> reqwest::RequestBuilder {
        self.http
            .post(format!("{}{path}", self.url))
            .bearer_auth("client-secret")
            .header("content-type", "application/json")
            .body(body.to_owned())
    }
}

async fn head(socket: &mut TcpStream) -> String {
    let mut bytes = Vec::new();
    while !bytes.ends_with(b"\r\n\r\n") {
        assert!(bytes.len() < 32768, "oversized fixture request head");
        bytes.push(socket.read_u8().await.unwrap());
    }
    String::from_utf8(bytes).unwrap()
}
async fn request(socket: &mut TcpStream) -> (String, String) {
    let headers = head(socket).await;
    let length = headers
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().unwrap())
        })
        .unwrap_or(0);
    let mut body = vec![0; length];
    socket.read_exact(&mut body).await.unwrap();
    (headers, String::from_utf8(body).unwrap())
}
async fn listener() -> (TcpListener, String) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/prefix", listener.local_addr().unwrap());
    (listener, url)
}
async fn reply(socket: &mut TcpStream, status: &str, headers: &str, body: &str) {
    socket.write_all(format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}", body.len()).as_bytes()).await.unwrap();
}

#[tokio::test]
async fn responses_and_chat_preserve_payload_status_and_safe_headers() {
    let (origin, base) = listener().await;
    let gateway = Gateway::start(&base, None).await;
    let server = tokio::spawn(async move {
        for (path, status, headers, body) in [
            (
                "responses",
                "429 Too Many Requests",
                "Retry-After: 17\r\n",
                "busy",
            ),
            (
                "chat/completions",
                "200 OK",
                "Content-Type: application/json\r\n",
                r#"{"id":"chat-result"}"#,
            ),
        ] {
            let (mut socket, _) = origin.accept().await.unwrap();
            let (head, body_in) = request(&mut socket).await;
            assert!(head.starts_with(&format!("POST /prefix/{path} HTTP/1.1\r\n")));
            let lower = head.to_lowercase();
            assert!(lower.contains("authorization: bearer upstream-secret\r\n"));
            assert!(lower.contains("openai-beta: responses=experimental\r\n"));
            assert!(lower.contains("x-request-id: forward-me\r\n"));
            for secret in [
                "client-secret",
                "private",
                "cookie:",
                "proxy-authorization:",
            ] {
                assert!(!lower.contains(secret), "{head}");
            }
            let value: Value = serde_json::from_str(&body_in).unwrap();
            assert_eq!(value["model"], "native");
            assert_eq!(value["prompt_cache_options"], json!({"mode": "explicit"}));
            assert_eq!(
                value["opaque"]["nested"],
                json!([null, true, {"x": "unchanged"}])
            );
            assert!(body_in.contains("184467440737095516170"));
            assert!(body_in.contains("0.12345678901234567890123456789"));
            reply(
                &mut socket,
                status,
                &format!("{headers}Authorization: private\r\nX-Upstream: original\r\n"),
                body,
            )
            .await;
        }
    });
    let body = r#"{"model":"fixture/alias","prompt_cache_options":{"mode":"explicit"},"opaque":{"nested":[null,true,{"x":"unchanged"}],"integer":184467440737095516170,"decimal":0.12345678901234567890123456789}}"#;
    for (path, status, header, expected, text) in [
        ("/v1/responses", 429, "retry-after", "17", "busy"),
        (
            "/v1/chat/completions",
            200,
            "content-type",
            "application/json",
            r#"{"id":"chat-result"}"#,
        ),
    ] {
        let response = gateway
            .post(path, body)
            .header("cookie", "private")
            .header("proxy-authorization", "private")
            .header("x-api-key", "private")
            .header("openai-beta", "responses=experimental")
            .header("x-request-id", "forward-me")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(response.headers()[header], expected);
        assert_eq!(response.headers()["x-upstream"], "original");
        assert!(!response.headers().contains_key("authorization"));
        assert_eq!(response.text().await.unwrap(), text);
    }
    timeout(LIMIT, server).await.unwrap().unwrap();
}

#[tokio::test]
async fn discovery_inherits_alias_metadata_preserves_precision_and_caches() {
    let (origin, base) = listener().await;
    let gateway = Gateway::start(&base, None).await;
    let server = tokio::spawn(async move {
        let (mut socket, _) = origin.accept().await.unwrap();
        let (head, _) = request(&mut socket).await;
        assert!(head.starts_with("GET /prefix/models HTTP/1.1\r\n"));
        assert!(
            head.to_lowercase()
                .contains("authorization: bearer upstream-secret\r\n")
        );
        reply(&mut socket, "200 OK", "Content-Type: application/json\r\n", r#"{"data":[{"id":"native","name":"Native label","created":123,"owned_by":"spoof","object":"spoof","request_constraints":{"spoof":true},"metadata":{"integer":184467440737095516170,"decimal":0.12345678901234567890123456789,"null":null}}]}"#).await;
    });
    let first = gateway.get("/v1/models").send().await.unwrap();
    assert_eq!(first.status(), 200);
    let text = first.text().await.unwrap();
    assert!(text.contains("184467440737095516170"));
    assert!(text.contains("0.12345678901234567890123456789"));
    let first: Value = serde_json::from_str(&text).unwrap();
    let data = first["data"].as_array().unwrap();
    assert_eq!(
        data.iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["fixture/alias", "fixture/fallback", "fixture/native"]
    );
    assert_eq!(data[0]["metadata"], data[2]["metadata"]);
    assert_eq!(data[0]["name"], "Native label");
    assert_eq!(data[0]["created"], 123);
    assert_eq!(data[0]["owned_by"], "fixture");
    assert_eq!(data[0]["object"], "model");
    assert!(data[0].get("request_constraints").is_none());
    assert!(data[1].get("metadata").is_none());
    // Once the origin is closed, a second successful catalog read proves cache reuse.
    timeout(LIMIT, server).await.unwrap().unwrap();
    assert_eq!(
        gateway
            .get("/v1/models")
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap(),
        first
    );
}

#[tokio::test]
async fn sse_first_event_arrives_before_upstream_finishes() {
    let (origin, base) = listener().await;
    let gateway = Gateway::start(&base, None).await;
    let (release, wait) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (mut socket, _) = origin.accept().await.unwrap();
        request(&mut socket).await;
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nD\r\ndata: first\n\n\r\n").await.unwrap();
        timeout(LIMIT, wait).await.unwrap().unwrap();
        socket
            .write_all(b"E\r\ndata: [DONE]\n\n\r\n0\r\n\r\n")
            .await
            .unwrap();
    });
    let mut response = gateway
        .post(
            "/v1/responses",
            r#"{"model":"fixture/alias","stream":true}"#,
        )
        .send()
        .await
        .unwrap();
    assert_eq!(response.headers()["content-type"], "text/event-stream");
    let mut bytes = Vec::new();
    while bytes.len() < b"data: first\n\n".len() {
        bytes.extend_from_slice(
            &timeout(LIMIT, response.chunk())
                .await
                .unwrap()
                .unwrap()
                .expect("premature EOF"),
        );
    }
    assert_eq!(bytes, b"data: first\n\n");
    release.send(()).unwrap();
    while let Some(chunk) = response.chunk().await.unwrap() {
        bytes.extend_from_slice(&chunk);
    }
    assert_eq!(bytes, b"data: first\n\ndata: [DONE]\n\n");
    timeout(LIMIT, server).await.unwrap().unwrap();
}

#[tokio::test]
async fn http_proxy_authenticates_and_forwards_inference() {
    let (proxy, _) = listener().await;
    let proxy_url = format!("http://user:password@{}", proxy.local_addr().unwrap());
    let gateway = Gateway::start("http://upstream.invalid:9876/prefix", Some(&proxy_url)).await;
    let server = tokio::spawn(async move {
        let (mut socket, _) = proxy.accept().await.unwrap();
        let (headers, body) = request(&mut socket).await;
        assert!(
            headers.starts_with("POST http://upstream.invalid:9876/prefix/responses HTTP/1.1\r\n")
        );
        let lower = headers.to_lowercase();
        assert!(lower.contains("host: upstream.invalid:9876\r\n"));
        assert!(lower.contains("proxy-authorization: basic dxnlcjpwyxnzd29yza==\r\n"));
        assert!(lower.contains("authorization: bearer upstream-secret\r\n"));
        assert!(!headers.contains("client-secret"));
        assert!(!headers.contains("password"));
        assert_eq!(
            serde_json::from_str::<Value>(&body).unwrap()["model"],
            "native"
        );
        reply(&mut socket, "200 OK", "", "proxied").await;
    });
    let response = gateway
        .post("/v1/responses", r#"{"model":"fixture/alias"}"#)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.text().await.unwrap(), "proxied");
    timeout(LIMIT, server).await.unwrap().unwrap();
}
#[tokio::test]
async fn socks5_proxy_authenticates_and_forwards_inference() {
    let (proxy, _) = listener().await;
    let proxy_url = format!("socks5://user:password@{}", proxy.local_addr().unwrap());
    let gateway = Gateway::start("http://localhost:9876/prefix", Some(&proxy_url)).await;
    let server = tokio::spawn(async move {
        let (mut socket, _) = proxy.accept().await.unwrap();
        assert_eq!(socket.read_u8().await.unwrap(), 5);
        let count = socket.read_u8().await.unwrap();
        let mut methods = vec![0; count as usize];
        socket.read_exact(&mut methods).await.unwrap();
        assert!(methods.contains(&2));
        socket.write_all(&[5, 2]).await.unwrap();
        assert_eq!(socket.read_u8().await.unwrap(), 1);
        for expected in [b"user".as_slice(), b"password".as_slice()] {
            let size = socket.read_u8().await.unwrap();
            let mut value = vec![0; size as usize];
            socket.read_exact(&mut value).await.unwrap();
            assert_eq!(value, expected);
        }
        socket.write_all(&[1, 0]).await.unwrap();
        let mut prefix = [0; 4];
        socket.read_exact(&mut prefix).await.unwrap();
        assert_eq!(&prefix[..3], &[5, 1, 0]);
        match prefix[3] {
            1 => {
                let mut ip = [0; 4];
                socket.read_exact(&mut ip).await.unwrap();
                assert!(std::net::Ipv4Addr::from(ip).is_loopback());
            }
            4 => {
                let mut ip = [0; 16];
                socket.read_exact(&mut ip).await.unwrap();
                assert!(std::net::Ipv6Addr::from(ip).is_loopback());
            }
            other => panic!("SOCKS must resolve DNS locally, address type {other}"),
        }
        assert_eq!(socket.read_u16().await.unwrap(), 9876);
        socket
            .write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0])
            .await
            .unwrap();
        let (headers, body) = request(&mut socket).await;
        assert!(headers.starts_with("POST /prefix/responses HTTP/1.1\r\n"));
        assert!(!headers.to_lowercase().contains("proxy-authorization"));
        assert!(!headers.contains("password"));
        assert_eq!(
            serde_json::from_str::<Value>(&body).unwrap()["model"],
            "native"
        );
        reply(&mut socket, "200 OK", "", "tunneled").await;
    });
    let response = gateway
        .post("/v1/responses", r#"{"model":"fixture/alias"}"#)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.text().await.unwrap(), "tunneled");
    timeout(LIMIT, server).await.unwrap().unwrap();
}

#[tokio::test]
async fn disconnect_cancels_upstream_without_interrupting_another_stream() {
    timeout(LIMIT, async {
        let (origin, base) = listener().await;
        let gateway = Gateway::start(&base, None).await;
        let (release, wait) = oneshot::channel();
        let (ready, seen) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut survivor, _) = origin.accept().await.unwrap();
            request(&mut survivor).await;
            survivor.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nD\r\ndata: first\n\n\r\n").await.unwrap();
            let (mut canceled, _) = origin.accept().await.unwrap();
            request(&mut canceled).await;
            canceled.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nD\r\ndata: first\n\n\r\n").await.unwrap();
            ready.send(()).unwrap();
            let mut byte = [0];
            match timeout(LIMIT, canceled.read(&mut byte)).await.expect("disconnected downstream did not cancel upstream") {
                Ok(0) => {},
                Err(error) if matches!(error.kind(), std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted) => {},
                other => panic!("expected upstream EOF/reset, got {other:?}"),
            }
            release.send(()).unwrap();
            survivor.write_all(b"E\r\ndata: [DONE]\n\n\r\n0\r\n\r\n").await.unwrap();
        });
        let mut survivor = gateway.post("/v1/responses", r#"{"model":"fixture/alias","stream":true}"#).send().await.unwrap();
        assert_eq!(survivor.status(), 200);
        let mut events = Vec::new();
        while events.len() < b"data: first\n\n".len() {
            events.extend_from_slice(&survivor.chunk().await.unwrap().expect("survivor ended before first event"));
        }
        assert_eq!(events, b"data: first\n\n");
        let mut downstream = gateway.post("/v1/responses", r#"{"model":"fixture/alias","stream":true}"#).send().await.unwrap();
        seen.await.unwrap();
        let mut first = Vec::new();
        while first.len() < b"data: first\n\n".len() {
            first.extend_from_slice(&downstream.chunk().await.unwrap().expect("canceled stream ended before first event"));
        }
        assert_eq!(first, b"data: first\n\n");
        drop(downstream);
        wait.await.unwrap();
        while let Some(chunk) = survivor.chunk().await.unwrap() {
            events.extend_from_slice(&chunk);
        }
        assert_eq!(events, b"data: first\n\ndata: [DONE]\n\n");
        server.await.unwrap();
    }).await.expect("concurrent cancellation contract timed out");
}

#[tokio::test]
async fn loopback_admin_http_separates_keys_and_enforces_browser_sessions() {
    let (_origin, base) = listener().await;
    let gateway = Gateway::start(&base, None).await;
    let accounts = format!("{}/admin/api/accounts", gateway.url);
    let session = format!("{}/admin/api/session", gateway.url);
    assert_eq!(
        gateway.http.get(&accounts).send().await.unwrap().status(),
        401
    );
    assert_eq!(
        gateway
            .get("/admin/api/accounts")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let response = gateway
        .http
        .get(&accounts)
        .bearer_auth("admin-secret")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert!(response.json::<Value>().await.unwrap()["accounts"].is_array());
    let response = gateway
        .http
        .post(&session)
        .bearer_auth("admin-secret")
        .header("origin", &gateway.url)
        .header("x-requested-with", "fumo-admin")
        .header("sec-fetch-site", "same-origin")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let cookie = response.headers()["set-cookie"].to_str().unwrap();
    for attribute in ["HttpOnly", "SameSite=Strict", "Path=/admin/"] {
        assert!(cookie.contains(attribute), "{cookie}");
    }
    assert!(!cookie.contains("admin-secret"));
    let cookie = cookie.split(';').next().unwrap().to_owned();
    assert!(cookie.starts_with("fumo_admin_session="));
    assert!(!cookie.ends_with('='));
    for (origin, browser, site, status) in [
        (gateway.url.as_str(), true, "same-origin", 200),
        (gateway.url.as_str(), false, "same-origin", 403),
        ("http://evil.example", true, "same-origin", 403),
        (gateway.url.as_str(), true, "cross-site", 403),
    ] {
        let mut request = gateway
            .http
            .get(&accounts)
            .header("cookie", &cookie)
            .header("origin", origin)
            .header("sec-fetch-site", site);
        if browser {
            request = request.header("x-requested-with", "fumo-admin");
        }
        assert_eq!(request.send().await.unwrap().status(), status);
    }
    let response = gateway
        .http
        .delete(&session)
        .header("cookie", &cookie)
        .header("origin", &gateway.url)
        .header("x-requested-with", "fumo-admin")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert!(
        response.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .contains("Max-Age=0")
    );
    assert_eq!(
        gateway
            .http
            .get(&accounts)
            .header("cookie", &cookie)
            .header("origin", &gateway.url)
            .header("x-requested-with", "fumo-admin")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
}
