use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail, ensure};
use indexmap::IndexMap;
use serde::{
    Deserialize, Deserializer,
    de::{MapAccess, Visitor},
};
use sha2::{Digest, Sha256};

pub struct Config {
    pub listen: SocketAddr,
    pub clients: Vec<Client>,
    pub admin: Option<Client>,
    pub admin_directory: Option<PathBuf>,
    pub upstreams: Vec<Upstream>,
    pub proxy: Option<String>,
}

#[derive(Debug)]
pub struct Client {
    pub label: String,
    pub key_hash: [u8; 32],
}

#[derive(Debug)]
pub struct Upstream<A = Auth> {
    pub name: String,
    pub base_url: String,
    pub aliases: IndexMap<String, String>,
    pub auth: A,
}

// Do not derive Debug: API keys must not appear in configuration diagnostics.
pub enum Auth {
    None,
    ApiKey(String),
    Codex(PathBuf),
}

impl std::fmt::Debug for Auth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::None => f.write_str("None"),
            Self::ApiKey(_) => f.write_str("ApiKey([redacted])"),
            Self::Codex(path) => f.debug_tuple("Codex").field(path).finish(),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    #[serde(default, rename = "$schema")]
    _schema: String,
    #[serde(default = "default_listen")]
    listen: String,
    proxy_env: Option<String>,
    #[serde(default, deserialize_with = "ordered_map")]
    clients: IndexMap<String, ClientOptions>,
    admin: Option<AdminOptions>,
    #[serde(default, deserialize_with = "ordered_map")]
    upstreams: IndexMap<String, UpstreamOptions>,
}

fn default_listen() -> String {
    "127.0.0.1:8080".into()
}
fn default_admin_env() -> String {
    "FUMO_ADMIN_KEY".into()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClientOptions {
    key_env: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AdminOptions {
    #[serde(default = "default_admin_env")]
    key_env: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UpstreamOptions {
    base_url: String,
    #[serde(default, deserialize_with = "ordered_map")]
    aliases: IndexMap<String, String>,
    auth: Option<AuthOptions>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthOptions {
    provider: AuthProvider,
    credentials_dir: Option<String>,
    key_env: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum AuthProvider {
    Codex,
    ApiKey,
}

// Deserialize directly from the JSON stream to reject duplicate definitions,
// independently of serde_json's map feature flags.
fn ordered_map<'de, D, V>(deserializer: D) -> std::result::Result<IndexMap<String, V>, D::Error>
where
    D: Deserializer<'de>,
    V: Deserialize<'de>,
{
    struct Ordered<V>(std::marker::PhantomData<V>);
    impl<'de, V: Deserialize<'de>> Visitor<'de> for Ordered<V> {
        type Value = IndexMap<String, V>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("an object")
        }
        fn visit_map<A: MapAccess<'de>>(
            self,
            mut input: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut map = IndexMap::new();
            while let Some((key, value)) = input.next_entry::<String, V>()? {
                if map.insert(key, value).is_some() {
                    return Err(serde::de::Error::custom("duplicate definition"));
                }
            }
            Ok(map)
        }
    }
    deserializer.deserialize_map(Ordered(std::marker::PhantomData))
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        use std::io::Read;
        let file = std::fs::File::open(path).context("opening configuration")?;
        let mut text = Vec::new();
        file.take(1024 * 1024 + 1)
            .read_to_end(&mut text)
            .context("reading configuration")?;
        ensure!(text.len() <= 1024 * 1024, "configuration exceeds 1 MiB");
        Self::parse(&text, &|name| std::env::var(name).ok())
    }

    fn parse(text: &[u8], env: &impl Fn(&str) -> Option<String>) -> Result<Self> {
        let document: Document = serde_json::from_slice(text).context("invalid configuration")?;
        let proxy = document
            .proxy_env
            .map(|name| {
                validate_env(&name)?;
                let value = env(&name).context("missing proxy URL")?;
                validate_proxy(&value)?;
                Ok::<_, anyhow::Error>(value)
            })
            .transpose()?;
        let mut upstreams = Vec::new();
        for (name, options) in document.upstreams {
            ensure!(
                !name.is_empty()
                    && name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
                "invalid upstream name"
            );
            let base_url = options.base_url.trim_end_matches('/').to_owned();
            validate_upstream_url(&base_url)?;
            let auth = match options.auth {
                None => Auth::None,
                Some(auth) => match auth.provider {
                    AuthProvider::Codex => {
                        ensure!(auth.key_env.is_none(), "invalid upstream auth");
                        let directory = match auth.credentials_dir {
                            Some(path) => {
                                ensure!(
                                    !path.trim_matches([' ', '\t', '\r', '\n']).is_empty(),
                                    "invalid directory"
                                );
                                PathBuf::from(path)
                            }
                            None => default_directory(env)?,
                        };
                        ensure!(
                            base_url == "https://api.openai.com/v1",
                            "invalid Codex endpoint"
                        );
                        Auth::Codex(directory)
                    }
                    AuthProvider::ApiKey => {
                        ensure!(auth.credentials_dir.is_none(), "invalid upstream auth");
                        Auth::ApiKey(resolve_key(
                            auth.key_env.as_deref().context("invalid upstream auth")?,
                            env,
                            "upstream",
                        )?)
                    }
                },
            };
            for (alias, model) in &options.aliases {
                ensure!(!alias.is_empty(), "empty model alias");
                ensure!(!model.is_empty(), "empty upstream model");
            }
            upstreams.push(Upstream {
                name,
                base_url,
                aliases: options.aliases,
                auth,
            });
        }
        let listen: SocketAddr = document.listen.parse().context("invalid listen address")?;
        ensure!(listen.port() != 0, "invalid listen address");
        let admin_env = document
            .admin
            .as_ref()
            .map_or("FUMO_ADMIN_KEY", |admin| admin.key_env.as_str());
        validate_env(admin_env)?;
        let admin = if document.admin.is_some() || env(admin_env).is_some() {
            Some(client(
                "admin".into(),
                resolve_key(admin_env, env, "admin")?,
            ))
        } else {
            None
        };
        let mut clients: Vec<Client> = Vec::new();
        for (label, options) in document.clients {
            ensure!(!label.is_empty(), "empty client label");
            let entry = client(label, resolve_key(&options.key_env, env, "client")?);
            ensure!(
                !admin
                    .as_ref()
                    .is_some_and(|admin| admin.key_hash == entry.key_hash),
                "shared admin key"
            );
            ensure!(
                !clients
                    .iter()
                    .any(|previous| previous.key_hash == entry.key_hash),
                "duplicate client key"
            );
            clients.push(entry);
        }
        let admin_directory = if admin.is_some()
            && !upstreams
                .iter()
                .any(|upstream| matches!(upstream.auth, Auth::Codex(_)))
        {
            Some(default_directory(env)?)
        } else {
            None
        };
        Ok(Self {
            listen,
            clients,
            admin,
            admin_directory,
            upstreams,
            proxy,
        })
    }
}

fn validate_env(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty() && !name.contains(['=', '\0']),
        "invalid environment variable name"
    );
    Ok(())
}

fn resolve_key(name: &str, env: &impl Fn(&str) -> Option<String>, kind: &str) -> Result<String> {
    validate_env(name)?;
    let key = env(name).with_context(|| format!("missing {kind} key"))?;
    ensure!(!key.is_empty(), "empty {kind} key");
    ensure!(
        !key.bytes()
            .any(|b| b.is_ascii_whitespace() || b.is_ascii_control()),
        "invalid {kind} key"
    );
    Ok(key)
}

fn client(label: String, key: String) -> Client {
    Client {
        label,
        key_hash: Sha256::digest(key.as_bytes()).into(),
    }
}

fn default_directory(env: &impl Fn(&str) -> Option<String>) -> Result<PathBuf> {
    if let Some(xdg) = env("XDG_STATE_HOME").filter(|value| !value.is_empty()) {
        ensure!(Path::new(&xdg).is_absolute(), "invalid state home");
        return Ok(PathBuf::from(xdg).join("fumo-gateway"));
    }
    let home = env("HOME").context("home not found")?;
    ensure!(Path::new(&home).is_absolute(), "invalid home");
    Ok(PathBuf::from(home).join(".local/state/fumo-gateway"))
}

fn validate_upstream_url(value: &str) -> Result<()> {
    // Validate the raw authority too: URL parsing normalizes empty ports,
    // default ports and malformed slash counts, which must not bypass checks.
    let (_, rest) = value.split_once("://").context("invalid upstream URL")?;
    let authority = rest.split('/').next().unwrap_or_default();
    ensure!(
        !authority.is_empty()
            && !authority.contains('@')
            && !value.contains(['?', '#'])
            && !value.bytes().any(|b| b <= 32 || b == 127),
        "invalid upstream URL"
    );
    validate_authority(authority, false).context("invalid upstream URL")?;
    let url = url::Url::parse(value).context("invalid upstream URL")?;
    ensure!(
        matches!(url.scheme(), "http" | "https") && url.host_str().is_some(),
        "invalid upstream URL"
    );
    Ok(())
}

fn validate_authority(authority: &str, required_port: bool) -> Result<()> {
    let suffix = if authority.starts_with('[') {
        let end = authority.find(']').context("invalid host")?;
        authority[1..end]
            .parse::<std::net::Ipv6Addr>()
            .context("invalid host")?;
        &authority[end + 1..]
    } else {
        let host = authority.split(':').next().unwrap_or_default();
        ensure!(
            !host.is_empty()
                && host
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_')),
            "invalid host"
        );
        &authority[host.len()..]
    };
    if suffix.is_empty() {
        ensure!(!required_port, "missing port");
    } else {
        let port = suffix.strip_prefix(':').context("invalid port")?;
        ensure!(
            !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()),
            "invalid port"
        );
        ensure!(
            port.parse::<u16>().context("invalid port")? != 0,
            "invalid port"
        );
    }
    Ok(())
}

fn validate_proxy(value: &str) -> Result<()> {
    ensure!(
        !value.bytes().any(|b| b <= 32 || b == 127),
        "invalid proxy URL"
    );
    let (socks, rest) = if let Some(rest) = value.strip_prefix("http://") {
        (false, rest)
    } else if let Some(rest) = value.strip_prefix("socks5://") {
        (true, rest)
    } else {
        bail!("invalid proxy URL")
    };
    ensure!(!rest.contains(['?', '#']), "invalid proxy URL");
    let authority = rest.strip_suffix('/').unwrap_or(rest);
    ensure!(!authority.contains('/'), "invalid proxy URL");
    let host = if let Some((userinfo, host)) = authority.split_once('@') {
        let (user, password) = userinfo.split_once(':').unwrap_or((userinfo, ""));
        let user = decode_credential(user)?;
        let password = decode_credential(password)?;
        ensure!(
            !user.is_empty()
                && user.len() <= 255
                && !user.contains(&b':')
                && password.len() <= 255
                && (!socks || !password.is_empty()),
            "invalid proxy URL"
        );
        host
    } else {
        authority
    };
    validate_authority(host, true).context("invalid proxy URL")
}

fn decode_credential(value: &str) -> Result<Vec<u8>> {
    let mut bytes = value.bytes();
    let mut decoded = Vec::new();
    while let Some(byte) = bytes.next() {
        let byte = if byte == b'%' {
            let high = bytes
                .next()
                .and_then(|b| (b as char).to_digit(16))
                .context("invalid proxy URL")?;
            let low = bytes
                .next()
                .and_then(|b| (b as char).to_digit(16))
                .context("invalid proxy URL")?;
            (high * 16 + low) as u8
        } else {
            byte
        };
        ensure!(byte > 32 && byte != 127, "invalid proxy URL");
        decoded.push(byte);
    }
    std::str::from_utf8(&decoded).context("proxy credentials must be valid UTF-8")?;
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configured_codex_does_not_resolve_fallback_admin_directory() {
        let text = br#"{"admin":{},"upstreams":{"personal":{"base_url":"https://api.openai.com/v1","auth":{"provider":"codex","credentials_dir":"/credentials"}}}}"#;
        let config = Config::parse(text, &|name| match name {
            "FUMO_ADMIN_KEY" => Some("admin-key".into()),
            _ => panic!("unexpected environment lookup: {name}"),
        })
        .unwrap();
        assert!(config.admin.is_some());
        assert!(config.admin_directory.is_none());
        assert!(
            matches!(&config.upstreams[0].auth, Auth::Codex(path) if path == Path::new("/credentials"))
        );
    }

    #[test]
    fn fallback_admin_directory_uses_injected_environment() {
        let text = br#"{"admin":{},"upstreams":{"local":{"base_url":"http://localhost:8000"}}}"#;
        let config = Config::parse(text, &|name| match name {
            "FUMO_ADMIN_KEY" => Some("admin-key".into()),
            "XDG_STATE_HOME" => Some("/injected/state".into()),
            _ => panic!("unexpected environment lookup: {name}"),
        })
        .unwrap();
        assert_eq!(
            config.admin_directory.unwrap(),
            Path::new("/injected/state/fumo-gateway")
        );
        assert!(
            Config::parse(text, &|name| match name {
                "FUMO_ADMIN_KEY" => Some("admin-key".into()),
                "XDG_STATE_HOME" => Some("relative".into()),
                _ => None,
            })
            .is_err()
        );
    }

    #[test]
    fn disabled_admin_does_not_resolve_directory() {
        let config = Config::parse(b"{}", &|name| {
            assert_eq!(name, "FUMO_ADMIN_KEY");
            None
        })
        .unwrap();
        assert!(config.admin_directory.is_none());
    }
}
