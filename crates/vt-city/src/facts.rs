//! Which records count, and in what order.
//!
//! A record that verifies has only proved that *some* key signed it. Whether
//! that key speaks for the person named in `by` is a second question, and the
//! one a reader must not skip: a city's event tag keeps anything with a valid
//! signature, so a stranger can put "the host renamed this event" there under
//! the host's identity number and their own key. The city's browsers hold
//! such a record back until they can tie the key to the person; this module
//! applies the same rule to a plain list of records:
//!
//! - a person's inception names the key that opened their account, and that
//!   key signs for them until they publish a DID log;
//! - once a log rooted in that key is at hand ([`crate::didlog`]), the keys
//!   it names now are the ones that sign for them;
//! - a record whose author's inception is not in the list cannot be judged
//!   and is left out.
//!
//! The survivors are put in the city's causal order: a record comes after
//! everything it depends on or links to (when those are present), and among
//! records that are ready, the earlier `at` goes first, the smaller name on a
//! tie. Every reducer walks this order, so "the latest edit wins" means the
//! same thing here as on anyone's phone.

use std::cmp::{Ordering, Reverse};
use std::collections::{BTreeSet, BinaryHeap, HashMap, HashSet};

use serde_json::Value;

use crate::didlog;
use crate::record::{self, INCEPTION};
use crate::text::{is_id, utf16_prefix};

/// One accepted record, borrowed from the caller's list.
pub(crate) struct Fact<'a> {
    pub id: String,
    pub kind: &'a str,
    /// The author's identity number; empty for an inception.
    pub by: &'a str,
    pub at: f64,
    pub links: Vec<&'a str>,
    deps: Vec<&'a str>,
    pub body: &'a Value,
}

impl Fact<'_> {
    pub fn link(&self, index: usize) -> &str {
        self.links.get(index).copied().unwrap_or("")
    }

    /// A member of the body, when the body is an object.
    pub fn get(&self, name: &str) -> Option<&Value> {
        self.body.get(name)
    }
}

/// Verifies, binds authors to keys, and orders. Records that fail any step
/// are dropped without comment: in a public log, most of what does not
/// verify was never meant to.
pub(crate) fn admit(recs: &[Value]) -> Vec<Fact<'_>> {
    // What each record says about itself.
    let mut seen = HashSet::new();
    let mut facts: Vec<(Fact<'_>, &str)> = Vec::new();
    for rec in recs {
        if !record::verify(rec) {
            continue;
        }
        let (Ok(id), Some(entry)) = (record::record_id(rec), rec.get("e")) else {
            continue;
        };
        if !seen.insert(id.clone()) {
            continue;
        }
        let text = |name: &str| entry.get(name).and_then(Value::as_str).unwrap_or("");
        let list = |name: &str| -> Vec<&str> {
            entry
                .get(name)
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default()
        };
        let fact = Fact {
            id,
            kind: text("type"),
            by: text("by"),
            // `-0` and `0` are the same instant to the city.
            at: entry.get("at").and_then(Value::as_f64).unwrap_or(0.0) + 0.0,
            links: list("links"),
            deps: list("deps"),
            body: entry.get("body").unwrap_or(&Value::Null),
        };
        let authored = entry.get("by").is_some_and(Value::is_string);
        // An inception is the only record that speaks for no one yet, and it
        // has exactly one valid form.
        if (fact.kind == INCEPTION || !authored) && !record::canonical_inception(entry) {
            continue;
        }
        facts.push((fact, text("key")));
    }

    let keep: Vec<bool> = judge(&facts);
    let admitted: Vec<Fact<'_>> = facts
        .into_iter()
        .zip(keep)
        .filter_map(|((fact, _), keep)| keep.then_some(fact))
        .collect();
    causal(admitted)
}

/// For each record, whether its key speaks for the person it names.
fn judge(facts: &[(Fact<'_>, &str)]) -> Vec<bool> {
    let opened: HashMap<&str, &str> = facts
        .iter()
        .filter(|(fact, _)| fact.kind == INCEPTION)
        .map(|(fact, key)| (fact.id.as_str(), *key))
        .collect();

    // DID logs, and for each author the one that is canonical.
    let mut logs: HashMap<&str, Vec<didlog::VerifiedLog>> = HashMap::new();
    let mut vouched: HashSet<&str> = HashSet::new();
    for (fact, key) in facts {
        if fact.kind != "id/did" {
            continue;
        }
        let (Some(inception_key), Some(log)) = (
            opened.get(fact.by),
            fact.get("log").and_then(Value::as_array),
        ) else {
            continue;
        };
        let multikey = |did: &str| did.strip_prefix("did:key:").map(str::to_string);
        let Some(log) = multikey(inception_key)
            .and_then(|root| didlog::verify(log, &root, utf16_prefix(fact.by, 16)))
        else {
            continue;
        };
        // The record carrying a log must itself come from the person: signed
        // by the key that opened the account, or by one the log has named.
        let carrier_ok = key == inception_key
            || multikey(key).is_some_and(|carrier| log.ever.contains(&carrier));
        if carrier_ok {
            vouched.insert(fact.id.as_str());
            logs.entry(fact.by).or_default().push(log);
        }
    }
    let signing: HashMap<&str, BTreeSet<String>> = logs
        .into_iter()
        .filter_map(|(by, logs)| canonical(logs).map(|log| (by, log.now)))
        .collect();

    let speaks_for = |by: &str, key: &str| match (signing.get(by), opened.get(by)) {
        // With a canonical log, only the keys it names now; the key that
        // opened the account has usually left the person's devices by then.
        (Some(keys), _) => key
            .strip_prefix("did:key:")
            .is_some_and(|multikey| keys.contains(multikey)),
        (None, Some(inception_key)) => key == *inception_key,
        (None, None) => false,
    };
    facts
        .iter()
        .map(|(fact, key)| match fact.kind {
            INCEPTION => true,
            "id/did" => vouched.contains(fact.id.as_str()),
            // Browsers refuse a record with no dependencies outright, so one
            // that reached a tag anyway is not part of anyone's view.
            _ => !fact.deps.is_empty() && speaks_for(fact.by, key),
        })
        .collect()
}

/// The city picks, among a person's verified logs, the one whose pre-rotation
/// was switched on first (the smaller identifier on a tie), and of two copies
/// of the same log the longer. A log that never switched it on does not count.
fn canonical(logs: Vec<didlog::VerifiedLog>) -> Option<didlog::VerifiedLog> {
    logs.into_iter()
        .filter(|log| log.armed_at.is_some())
        .min_by(|a, b| {
            (a.armed_at, &a.scid)
                .cmp(&(b.armed_at, &b.scid))
                .then(b.versions.cmp(&a.versions))
                .then(a.last_version_id.cmp(&b.last_version_id))
        })
}

fn causal(facts: Vec<Fact<'_>>) -> Vec<Fact<'_>> {
    let index: HashMap<&str, usize> = facts
        .iter()
        .enumerate()
        .map(|(position, fact)| (fact.id.as_str(), position))
        .collect();
    let mut waiting = vec![0usize; facts.len()];
    let mut followers: Vec<Vec<usize>> = vec![Vec::new(); facts.len()];
    for (position, fact) in facts.iter().enumerate() {
        let before: BTreeSet<usize> = fact
            .deps
            .iter()
            .chain(&fact.links)
            .filter_map(|id| index.get(id).copied())
            .filter(|other| *other != position)
            .collect();
        waiting[position] = before.len();
        for other in before {
            followers[other].push(position);
        }
    }
    let keyed = |position: usize| {
        Reverse(Keyed {
            at: facts[position].at,
            name: facts[position].id.clone(),
            position,
        })
    };
    let mut order: Vec<usize> = Vec::with_capacity(facts.len());
    let mut heap: BinaryHeap<Reverse<Keyed>> = (0..facts.len())
        .filter(|position| waiting[*position] == 0)
        .map(keyed)
        .collect();
    while let Some(Reverse(next)) = heap.pop() {
        order.push(next.position);
        for follower in &followers[next.position] {
            waiting[*follower] -= 1;
            if waiting[*follower] == 0 {
                heap.push(keyed(*follower));
            }
        }
    }
    // Records that point at each other cannot be made (a name is a hash of
    // its content), but the input is not trusted: whatever is left goes last,
    // by time.
    if order.len() < facts.len() {
        let placed: HashSet<usize> = order.iter().copied().collect();
        let mut rest: Vec<Keyed> = (0..facts.len())
            .filter(|position| !placed.contains(position))
            .map(|position| keyed(position).0)
            .collect();
        rest.sort();
        order.extend(rest.into_iter().map(|keyed| keyed.position));
    }
    let mut slots: Vec<Option<Fact<'_>>> = facts.into_iter().map(Some).collect();
    order
        .into_iter()
        .filter_map(|position| slots[position].take())
        .collect()
}

struct Keyed {
    at: f64,
    name: String,
    position: usize,
}

impl PartialEq for Keyed {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for Keyed {}
impl PartialOrd for Keyed {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Keyed {
    fn cmp(&self, other: &Self) -> Ordering {
        self.at
            .total_cmp(&other.at)
            .then_with(|| self.name.cmp(&other.name))
    }
}

/// `typeof v === "string" ? v.slice(0, max) : undefined`.
pub(crate) fn text_cap(value: Option<&Value>, max: usize) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .map(|text| utf16_prefix(text, max))
}

/// A finite number, as the city's `num`.
pub(crate) fn number(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(Value::as_f64)
        .filter(|number| number.is_finite())
}

/// The distinct identity numbers in a list, in order, at most `max`.
pub(crate) fn people(value: Option<&Value>, max: usize) -> Option<Vec<String>> {
    let items = value?.as_array()?;
    let mut out: Vec<String> = Vec::new();
    for item in items
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| is_id(id))
    {
        if !out.iter().any(|have| have == item) {
            out.push(item.to_string());
        }
    }
    out.truncate(max);
    Some(out)
}

/// JavaScript truthiness of a JSON value.
pub(crate) fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) | Some(Value::Bool(false)) => false,
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Number(number)) => number.as_f64().is_some_and(|number| number != 0.0),
        Some(_) => true,
    }
}
