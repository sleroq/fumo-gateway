use axum::http::{HeaderMap, header::AUTHORIZATION};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::config::Client;

pub(crate) fn authenticate<'a>(clients: &'a [Client], headers: &HeaderMap) -> Option<&'a str> {
    let mut values = headers.get_all(AUTHORIZATION).iter();
    let value = values.next()?.to_str().ok()?;
    if values.next().is_some() {
        return None;
    }
    let (scheme, key) = value.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    let key = key.trim_matches(' ');
    if key.is_empty() {
        return None;
    }
    let hash = Sha256::digest(key.as_bytes());
    clients
        .iter()
        .find(|client| bool::from(client.key_hash.as_slice().ct_eq(&hash)))
        .map(|client| client.label.as_str())
}
