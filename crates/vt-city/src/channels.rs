//! The channels of a city's archive that a recording can be placed in.
//!
//! A channel is an `arc/channel` record; whoever signed it owns it and may
//! retitle or close it with `arc/edit`. Three kinds matter to a recorder:
//!
//! - an ordinary channel, open (anyone — any resident, when it belongs to a
//!   city — may add to it) or closed (only its owner);
//! - a *set*, a city's curated collection, which only the city's
//!   coordinators may add to;
//! - an event, which is a channel in its own right and needs no record here
//!   (see [`crate::calendar`]).
//!
//! The city's browsers also check two things against the city's roster that
//! this crate does not hold: that a channel claiming a city was created by a
//! resident, and that a set was created by a coordinator. A city tag only
//! keeps records signed by residents, so the first holds for anything read
//! from one. The second is not checked: a resident who is not a coordinator
//! can sign something that looks like a set, browsers ignore it, and here it
//! is listed — where only a coordinator could act on it, to no effect.

use serde_json::Value;

use crate::facts;
use crate::text::is_id;

/// A channel as it stands now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Channel {
    pub id: String,
    pub title: String,
    /// The owner: whoever created it.
    pub by: String,
    /// The city it belongs to, when it says it belongs to one.
    pub city: Option<String>,
    /// Whether people other than the owner may add to it.
    pub open: bool,
    /// Whether it is a city's curated collection.
    pub set: bool,
}

/// The channels among `recs`, in the order they were created.
///
/// As with events, records that do not verify, or whose key cannot be tied
/// to their author, are dropped: pass the authors' `id/inception` and
/// `id/did` records along (see [`crate::calendar::CITY_KINDS`]).
pub fn reduce_channels(recs: &[Value]) -> Vec<Channel> {
    let facts = facts::admit(recs);
    let mut channels: Vec<Channel> = Vec::new();
    for fact in facts.iter().filter(|fact| fact.kind == "arc/channel") {
        let city = fact
            .get("polis")
            .and_then(Value::as_str)
            .filter(|city| is_id(city))
            .map(str::to_string);
        let set = facts::truthy(fact.get("set"));
        // A set without a city is not a set, and not a channel either.
        if set && city.is_none() {
            continue;
        }
        channels.push(Channel {
            id: fact.id.clone(),
            title: text(fact.get("title")).unwrap_or_default(),
            by: fact.by.to_string(),
            city,
            open: !set && fact.get("status").and_then(Value::as_str) != Some("closed"),
            set,
        });
    }
    // Only the owner's edits count; later ones (in causal order) win.
    for fact in facts.iter().filter(|fact| fact.kind == "arc/edit") {
        let Some(channel) = channels
            .iter_mut()
            .find(|channel| channel.id == fact.link(0) && channel.by == fact.by)
        else {
            continue;
        };
        if let Some(title) = text(fact.get("title")) {
            channel.title = title;
        }
        if !channel.set {
            match fact.get("status").and_then(Value::as_str) {
                Some("open") => channel.open = true,
                Some("closed") => channel.open = false,
                _ => {}
            }
        }
    }
    channels
}

/// Whether this person may place something in the channel.
///
/// `is_resident` and `is_coordinator` are about the channel's own city (see
/// `Hub::roles`).
pub fn may_put(ch: &Channel, person_id: &str, is_resident: bool, is_coordinator: bool) -> bool {
    if person_id.is_empty() {
        return false;
    }
    if ch.set {
        return is_coordinator;
    }
    ch.by == person_id || (ch.open && (ch.city.is_none() || is_resident))
}

fn text(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn channel(open: bool, set: bool, city: bool) -> Channel {
        Channel {
            id: "c".into(),
            title: "t".into(),
            by: "owner".into(),
            city: city.then(|| "city".into()),
            open,
            set,
        }
    }

    #[test]
    fn who_may_put_where() {
        // The owner always may; a closed channel is the owner's alone.
        assert!(may_put(&channel(false, false, true), "owner", false, false));
        assert!(!may_put(&channel(false, false, true), "other", true, true));
        // An open city channel takes residents; an open free one, anyone.
        assert!(may_put(&channel(true, false, true), "other", true, false));
        assert!(!may_put(&channel(true, false, true), "other", false, false));
        assert!(may_put(&channel(true, false, false), "other", false, false));
        // A set is the coordinators', and not even its creator's otherwise.
        assert!(may_put(&channel(false, true, true), "other", true, true));
        assert!(!may_put(&channel(false, true, true), "owner", true, false));
        assert!(!may_put(&channel(true, false, false), "", true, true));
    }
}
