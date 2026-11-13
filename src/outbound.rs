use anyhow::{Context, Result};

pub(crate) fn client(proxy: Option<&str>) -> Result<reqwest::Client> {
    let mut builder = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never());
    if let Some(proxy) = proxy {
        builder = builder.proxy(reqwest::Proxy::all(proxy).context("invalid proxy URL")?);
    }
    builder.build().context("building outbound client")
}

/// Read a response without allowing the accumulated body to exceed the caller's limit.
pub(crate) async fn read_body(
    mut response: reqwest::Response,
    limit: usize,
    too_large: &'static str,
) -> Result<Vec<u8>> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        anyhow::ensure!(chunk.len() <= limit - body.len(), "{too_large}");
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn body_limit_is_inclusive() {
        for (body, limit, expected) in [("", 0, true), ("test", 4, true), ("test", 3, false)] {
            let response = axum::http::Response::new(body);
            let result = read_body(response.into(), limit, "BodyTooLarge").await;
            if expected {
                assert_eq!(result.unwrap(), body.as_bytes());
            } else {
                assert_eq!(result.unwrap_err().to_string(), "BodyTooLarge");
            }
        }
    }
}
