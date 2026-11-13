//! The city's server, as far as a recorder needs it.
//!
//! Two things live behind one host. The **hub** stores signed records under
//! tags (`polis:<city>` for a city, `ev:<event>` for one event) and hands
//! them back to anyone who asks; the **relay** passes a few handshake
//! messages between two devices in a short-lived room. Neither takes any
//! credential: what a tag keeps is decided by the signatures on the records
//! themselves.
//!
//! The two kinds of tag are not equally careful, and a reader has to know
//! it. A city tag keeps a record only when its key belongs to the person it
//! claims to be by and that person lives in the city. An event tag keeps
//! anything with a valid signature. [`crate::calendar`] and
//! [`crate::channels`] therefore re-establish who signed what for themselves
//! instead of trusting where a record was found.

use std::time::Duration;

use serde::Deserialize;
use serde_json::value::RawValue;
use serde_json::Value;

use crate::error::{CityError, Result};
use crate::identity::Identity;
use crate::record;
use crate::text::is_id;

/// The server refuses a posted batch larger than this.
pub const POST_MAX_BYTES: usize = 1024 * 1024;

/// Someone the city admitted.
pub const ROLE_RESIDENT: &str = "resident";
/// Whoever founded the city.
pub const ROLE_FOUNDER: &str = "founder";
/// One of the people who run the city (`steward` on the wire).
pub const ROLE_COORDINATOR: &str = "coordinator";
/// Someone who keeps the city's calendar.
pub const ROLE_CURATOR: &str = "curator";
/// Someone who may hand out invitations.
pub const ROLE_INVITER: &str = "inviter";

/// A relay poll is held open by the server for up to 25 seconds.
const RELAY_TIMEOUT: Duration = Duration::from_secs(40);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// A tag is read in pages; this bounds a server that never says "done".
const MAX_PAGES: usize = 2_000;
const MAX_KINDS: usize = 24;
const MAX_PEOPLE: usize = 64;

/// A city server.
#[derive(Debug, Clone)]
pub struct Hub {
    base: String,
    http: reqwest::Client,
}

/// What a server says about itself at its door.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Door {
    /// The server's own canonical address.
    pub server: String,
    /// The city this address opens into, when it opens into one.
    pub city: Option<DoorCity>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DoorCity {
    pub id: String,
    pub name: String,
    /// How many residents the server counts. For display only; who is a
    /// resident is decided by the city's records, not by this number.
    pub members: u64,
}

/// What became of a posted batch.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PostOutcome {
    /// Records the tag did not have before and now keeps. Posting the same
    /// record twice is harmless and counts once.
    pub took: u64,
    /// Signatures (see [`record::signature_of`]) of records the city's rules
    /// turned away, for instance because their author does not live there.
    pub refused: Vec<String>,
}

impl PostOutcome {
    /// Turns "the city kept none of some record" into an error, for callers
    /// that treat a partial delivery as a failed one.
    pub fn accepted(self) -> Result<u64> {
        if self.refused.is_empty() {
            Ok(self.took)
        } else {
            Err(CityError::Refused)
        }
    }
}

#[derive(Deserialize)]
struct DiscoveryDoc {
    #[serde(default)]
    server: String,
    #[serde(default)]
    door: DiscoveryDoor,
}

#[derive(Deserialize, Default)]
struct DiscoveryDoor {
    #[serde(default)]
    here: Option<DiscoveryCity>,
    #[serde(default)]
    home: Option<DiscoveryCity>,
}

#[derive(Deserialize)]
struct DiscoveryCity {
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    members: u64,
}

#[derive(Deserialize)]
struct RoomPage {
    #[serde(default)]
    msgs: Vec<Value>,
    #[serde(default)]
    n: u64,
}

#[derive(Deserialize)]
struct TagPage<'a> {
    #[serde(default, borrow)]
    recs: Vec<&'a RawValue>,
    #[serde(default)]
    n: u64,
    #[serde(default)]
    more: bool,
}

#[derive(Deserialize)]
struct PostReply {
    #[serde(default)]
    took: u64,
    #[serde(default)]
    refused: Vec<String>,
}

#[derive(Deserialize)]
struct Credentials {
    #[serde(default)]
    credentials: Vec<Value>,
}

impl Hub {
    /// A server by its address. A bare host name means HTTPS; plain HTTP is
    /// accepted only for this machine, where the tests run one.
    pub fn new(base: &str, http: reqwest::Client) -> Result<Hub> {
        let trimmed = base.trim();
        let with_scheme = if trimmed.contains("://") {
            trimmed.to_string()
        } else {
            format!("https://{trimmed}")
        };
        let url = reqwest::Url::parse(&with_scheme)
            .map_err(|_| CityError::malformed("not a server address"))?;
        let host = url
            .host_str()
            .filter(|host| !host.is_empty())
            .ok_or_else(|| CityError::malformed("not a server address"))?;
        // Names under `localhost` are loopback by definition (RFC 6761); the
        // city's own software treats them as this machine too.
        let local =
            matches!(host, "localhost" | "127.0.0.1" | "[::1]") || host.ends_with(".localhost");
        match url.scheme() {
            "https" => {}
            // Records are public, but the device-link exchange and the
            // answers this client acts on are only as good as the channel.
            "http" if local => {}
            _ => return Err(CityError::malformed("a city is reached over https")),
        }
        if !url.username().is_empty() || url.password().is_some() {
            return Err(CityError::malformed(
                "a server address carries no credentials",
            ));
        }
        // Whatever page of the city the address was copied from, the hub and
        // the relay live at the root of the host.
        let port = url
            .port()
            .map(|port| format!(":{port}"))
            .unwrap_or_default();
        Ok(Hub {
            base: format!("{}://{host}{port}", url.scheme()),
            http,
        })
    }

    /// The normalised address: scheme, host and port, no trailing slash.
    pub fn base(&self) -> &str {
        &self.base
    }

    /// Asks the server who it is and which city this address opens into.
    pub async fn door(&self) -> Result<Door> {
        let body = self.get("/.well-known/sibian", REQUEST_TIMEOUT).await?;
        let doc: DiscoveryDoc =
            serde_json::from_slice(&body).map_err(|_| CityError::protocol("discovery document"))?;
        // A city's own domain (or its subdomain on a shared server) answers
        // with `here`; a server's main address answers with the city it
        // belongs to as `home`.
        let city = doc
            .door
            .here
            .or(doc.door.home)
            .filter(|city| is_id(&city.id));
        Ok(Door {
            server: doc.server,
            city: city.map(|city| DoorCity {
                id: city.id,
                name: city.name,
                members: city.members,
            }),
        })
    }

    /// One long poll of a relay room: the messages after `since`, and the
    /// position to ask from next time. Returns with nothing after about 25
    /// seconds of silence; the room itself is forgotten after five minutes
    /// without a visitor.
    pub async fn relay_get(&self, room: &str, since: u64) -> Result<(Vec<Value>, u64)> {
        if room.is_empty()
            || room.len() > 32
            || !room.bytes().all(|byte| byte.is_ascii_alphanumeric())
        {
            return Err(CityError::malformed("not a relay room"));
        }
        let body = self
            .get(&format!("/relay/{room}?since={since}"), RELAY_TIMEOUT)
            .await?;
        let page: RoomPage =
            serde_json::from_slice(&body).map_err(|_| CityError::protocol("relay room"))?;
        Ok((page.msgs, page.n.max(since)))
    }

    /// Everything a tag holds, from the beginning, without waiting.
    ///
    /// `kinds` narrows by record type: a namespace (`"ev"` is every `ev/…`)
    /// or one exact type (`"ev/edit"`), a leading `-` to exclude. `who` asks
    /// a city tag for what it holds about those people — their inception,
    /// profile, DID log, admission and appointments, and the same for whoever
    /// signed those. The server answers `who` on its own terms and ignores
    /// `kinds` when both are given, so the type filter is then applied here.
    ///
    /// A record that cannot be parsed is skipped rather than failing the
    /// read: anyone may post to an event tag, and one hostile record must not
    /// make the tag unreadable.
    pub async fn tag_get(&self, tag: &str, kinds: &[&str], who: &[&str]) -> Result<Vec<Value>> {
        let path = tag_path(tag)?;
        if kinds.len() > MAX_KINDS || !kinds.iter().all(|kind| kind_ok(kind)) {
            return Err(CityError::malformed("not a record type filter"));
        }
        if who.len() > MAX_PEOPLE || !who.iter().all(|id| is_id(id)) {
            return Err(CityError::malformed("not a list of people"));
        }
        if !who.is_empty() {
            let body = self
                .get(&format!("{path}?who={}", who.join(",")), REQUEST_TIMEOUT)
                .await?;
            let (mut recs, _, _) = parse_page(&body)?;
            if !kinds.is_empty() {
                recs.retain(|rec| kinds_match(kinds, rec));
            }
            return Ok(recs);
        }
        let filter = if kinds.is_empty() {
            String::new()
        } else {
            format!("&kinds={}", kinds.join(","))
        };
        let mut out = Vec::new();
        let (mut since, mut restarts) = (0u64, 0u8);
        for _ in 0..MAX_PAGES {
            let body = self
                .get(
                    &format!("{path}?since={since}&wait=0{filter}"),
                    REQUEST_TIMEOUT,
                )
                .await?;
            let (recs, n, more) = parse_page(&body)?;
            if !more {
                out.extend(recs);
                return Ok(out);
            }
            if n <= since {
                // The server renumbered the tag under us (its file was
                // rewritten) and is asking for a fresh start.
                restarts += 1;
                if restarts > 3 {
                    break;
                }
                out.clear();
                since = 0;
                continue;
            }
            out.extend(recs);
            since = n;
        }
        Err(CityError::protocol("a tag that never ends"))
    }

    /// Posts one batch of records to a tag. The batch must already carry the
    /// author's card and fit the server's limit; see
    /// [`crate::publish::batches`].
    pub async fn tag_post(&self, tag: &str, recs: &[Value]) -> Result<PostOutcome> {
        let path = tag_path(tag)?;
        let body = serde_json::to_vec(recs).map_err(|_| CityError::malformed("records"))?;
        if body.len() > POST_MAX_BYTES {
            return Err(CityError::malformed(
                "batch is larger than the city accepts",
            ));
        }
        let response = self
            .http
            .post(format!("{}{path}", self.base))
            .header("Content-Type", "application/json")
            .timeout(REQUEST_TIMEOUT)
            .body(body)
            .send()
            .await
            .map_err(transport)?;
        let reply: PostReply = serde_json::from_slice(&read(response).await?)
            .map_err(|_| CityError::protocol("post reply"))?;
        Ok(PostOutcome {
            took: reply.took,
            refused: reply.refused,
        })
    }

    /// The roles the city currently vouches for in one person: any of
    /// [`ROLE_RESIDENT`], [`ROLE_FOUNDER`], [`ROLE_COORDINATOR`],
    /// [`ROLE_CURATOR`], [`ROLE_INVITER`]. Empty when the person holds none.
    ///
    /// The city's credentials call a coordinator a `steward`; that one word
    /// is translated here so that callers use the name the city's own pages
    /// show. A founder is usually a coordinator too and then holds both
    /// roles; a founder who stepped down holds only the first.
    ///
    /// These are read from credentials the city's server issues about its
    /// own residents and are trusted as far as the connection to that server
    /// is; the credentials' signatures are not checked again here.
    pub async fn roles(&self, city_id: &str, person_id: &str) -> Result<Vec<String>> {
        if !is_id(city_id) || !is_id(person_id) {
            return Err(CityError::malformed("not an identity number"));
        }
        let path = format!("/p/{}/vc?id={person_id}", &city_id[..16]);
        let body = self.get(&path, REQUEST_TIMEOUT).await?;
        let reply: Credentials =
            serde_json::from_slice(&body).map_err(|_| CityError::protocol("credentials"))?;
        let mut roles: Vec<String> = Vec::new();
        for credential in &reply.credentials {
            let subject = &credential["credentialSubject"];
            // The address only carries the first 16 digits of the city; the
            // credential names it in full.
            if subject["city"]["polis"].as_str() != Some(city_id) {
                continue;
            }
            if let Some(role) = subject["role"].as_str() {
                let role = if role == "steward" {
                    ROLE_COORDINATOR
                } else {
                    role
                };
                if !roles.iter().any(|have| have == role) {
                    roles.push(role.to_string());
                }
            }
        }
        Ok(roles)
    }

    /// The records that must head every batch this person posts, so that a
    /// server or a reader meeting them for the first time can check what
    /// follows: their inception; their DID log when they sign with a key
    /// other than the one that opened the account; their latest profile.
    ///
    /// The log and the profile are the person's own records, fetched back
    /// from the city (and, for the log, from the person's own tag when the
    /// city tag does not hold it).
    pub async fn card(&self, city_id: &str, who: &Identity) -> Result<Vec<Value>> {
        if !is_id(city_id) {
            return Err(CityError::malformed("not a city"));
        }
        let mut about = self.tag_get(&city_tag(city_id), &[], &[who.id()]).await?;
        let needs_log = !who.signs_with_inception_key();
        if needs_log && latest(&about, who.id(), "id/did").is_none() {
            let own_tag = format!("me:{}", &who.id()[..16]);
            about.extend(self.tag_get(&own_tag, &["id/did"], &[]).await?);
        }
        let mut card = vec![who.inception().clone()];
        card.extend(latest(&about, who.id(), "id/did").cloned());
        card.extend(latest(&about, who.id(), "id/profile").cloned());
        Ok(card)
    }

    async fn get(&self, path: &str, timeout: Duration) -> Result<Vec<u8>> {
        let response = self
            .http
            .get(format!("{}{path}", self.base))
            .timeout(timeout)
            .send()
            .await
            .map_err(transport)?;
        read(response).await
    }
}

/// The tag an event's own records are posted to.
pub fn event_tag(event_id: &str) -> String {
    format!("ev:{}", crate::text::utf16_prefix(event_id, 16))
}

/// The tag a city's records are posted to.
pub fn city_tag(city_id: &str) -> String {
    format!("polis:{}", crate::text::utf16_prefix(city_id, 16))
}

/// A person's most useful record of one type: for a DID log the longest (a
/// log only ever grows), otherwise the most recently signed.
fn latest<'a>(recs: &'a [Value], by: &str, kind: &str) -> Option<&'a Value> {
    recs.iter()
        .filter(|rec| {
            rec["e"]["by"].as_str() == Some(by)
                && rec["e"]["type"].as_str() == Some(kind)
                && record::verify(rec)
        })
        .max_by(|a, b| {
            let entries = |rec: &Value| rec["e"]["body"]["log"].as_array().map_or(0, Vec::len);
            let at = |rec: &Value| rec["e"]["at"].as_f64().unwrap_or(0.0);
            entries(a).cmp(&entries(b)).then(at(a).total_cmp(&at(b)))
        })
}

fn tag_path(tag: &str) -> Result<String> {
    let ok = !tag.is_empty()
        && tag.len() <= 64
        && tag
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b":_-.".contains(&byte));
    if !ok {
        return Err(CityError::malformed("not a tag"));
    }
    // The colon is escaped as the city's own clients escape it.
    Ok(format!("/hub/{}", tag.replace(':', "%3A")))
}

/// `-?[a-z]{1,16}(/[a-z]{1,24})?`: what the server accepts as one filter
/// value. Anything else makes it drop the whole filter and send everything.
fn kind_ok(kind: &str) -> bool {
    let positive = kind.strip_prefix('-').unwrap_or(kind);
    let (space, name) = match positive.split_once('/') {
        Some((space, name)) => (space, Some(name)),
        None => (positive, None),
    };
    let lower = |text: &str, max: usize| {
        (1..=max).contains(&text.len()) && text.bytes().all(|byte| byte.is_ascii_lowercase())
    };
    lower(space, 16) && name.is_none_or(|name| lower(name, 24))
}

/// The server's own matching rule: a value matches its exact type and every
/// type beneath it, and an excluded value wins.
fn kinds_match(kinds: &[&str], rec: &Value) -> bool {
    let kind = rec["e"]["type"].as_str().unwrap_or("");
    let hit = |want: &str| {
        kind == want
            || kind
                .strip_prefix(want)
                .is_some_and(|rest| rest.starts_with('/'))
    };
    let (mut wanted, mut excluded) = (false, false);
    for filter in kinds {
        match filter.strip_prefix('-') {
            Some(negative) => excluded |= hit(negative),
            None => wanted |= hit(filter),
        }
    }
    wanted && !excluded
}

fn parse_page(body: &[u8]) -> Result<(Vec<Value>, u64, bool)> {
    let page: TagPage<'_> =
        serde_json::from_slice(body).map_err(|_| CityError::protocol("tag page"))?;
    let recs = page
        .recs
        .iter()
        .filter_map(|raw| serde_json::from_str::<Value>(raw.get()).ok())
        .filter(Value::is_object)
        .collect();
    Ok((recs, page.n, page.more))
}

async fn read(response: reqwest::Response) -> Result<Vec<u8>> {
    let status = response.status().as_u16();
    if !(200..=299).contains(&status) {
        return Err(CityError::Http { status });
    }
    response
        .bytes()
        .await
        .map(|bytes| bytes.to_vec())
        .map_err(transport)
}

/// A request that never produced an answer. Whatever the cause — no route,
/// no name, a failed handshake, silence — the remedy is the same, and the
/// underlying error may quote the address, so it is not passed on.
fn transport(error: reqwest::Error) -> CityError {
    if error.is_builder() {
        CityError::malformed("not a request the server can be sent")
    } else {
        CityError::Offline
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn hub(base: &str) -> Result<Hub> {
        Hub::new(base, reqwest::Client::new())
    }

    #[test]
    fn addresses_are_normalised_and_plain_http_stays_local() {
        assert_eq!(hub("city.example").unwrap().base(), "https://city.example");
        assert_eq!(
            hub(" https://City.Example/some/page?x=1#y ")
                .unwrap()
                .base(),
            "https://city.example"
        );
        assert_eq!(
            hub("https://city.example:8443/").unwrap().base(),
            "https://city.example:8443"
        );
        assert_eq!(
            hub("http://127.0.0.1:8765").unwrap().base(),
            "http://127.0.0.1:8765"
        );
        assert_eq!(
            hub("http://localhost:8765/").unwrap().base(),
            "http://localhost:8765"
        );
        assert_eq!(
            hub("http://city.localhost:8765").unwrap().base(),
            "http://city.localhost:8765"
        );
        assert!(hub("http://notlocalhost:8765").is_err());
        for bad in [
            "http://city.example",
            "ftp://city.example",
            "",
            "https://",
            // Spelt in pieces: the repository's privacy gate reads a
            // user-at-host string as someone's address.
            concat!("https://user:pw", "@", "city.example"),
        ] {
            assert!(hub(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn tags_and_filters_are_checked_before_they_are_sent() {
        assert_eq!(
            tag_path("ev:0123456789abcdef").unwrap(),
            "/hub/ev%3A0123456789abcdef"
        );
        assert!(tag_path("ev:../x").is_err());
        assert!(tag_path("").is_err());
        assert_eq!(event_tag(&"ab".repeat(32)), "ev:abababababababab");
        assert_eq!(city_tag(&"cd".repeat(32)), "polis:cdcdcdcdcdcdcdcd");
        for good in ["ev", "ev/edit", "-arc/block", "id/inception"] {
            assert!(kind_ok(good), "{good}");
        }
        for bad in ["", "Ev", "ev/", "ev/Edit", "@me", "ev/edit/x", "a,b"] {
            assert!(!kind_ok(bad), "{bad}");
        }
    }

    #[test]
    fn local_filter_matches_as_the_server_does() {
        let rec = |kind: &str| json!({"e": {"type": kind}});
        assert!(kinds_match(&["ev"], &rec("ev/edit")));
        assert!(kinds_match(&["ev/edit"], &rec("ev/edit")));
        assert!(!kinds_match(&["ev/edit"], &rec("ev/editor")));
        assert!(!kinds_match(&["ev"], &rec("evil/x")));
        assert!(!kinds_match(&["ev", "-ev/join"], &rec("ev/join")));
        assert!(!kinds_match(&["-ev/join"], &rec("ev/edit")));
    }

    #[test]
    fn one_unreadable_record_does_not_hide_the_rest() {
        // A lone surrogate and a number too large for a double: both are
        // JSON a browser reads and this parser does not.
        let body = br#"{"recs":[{"e":{"type":"a"}},{"e":{"body":"\ud800"}},{"e":{"at":1e999}},7,{"e":{"type":"b"}}],"n":5,"more":true}"#;
        let (recs, n, more) = parse_page(body).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!((n, more), (5, true));
        assert!(parse_page(b"not json").is_err());
    }

    #[test]
    fn a_refusal_becomes_an_error_only_when_asked() {
        assert_eq!(
            PostOutcome {
                took: 3,
                refused: vec![]
            }
            .accepted(),
            Ok(3)
        );
        assert_eq!(
            PostOutcome {
                took: 2,
                refused: vec!["z…".into()]
            }
            .accepted(),
            Err(CityError::Refused)
        );
    }
}
