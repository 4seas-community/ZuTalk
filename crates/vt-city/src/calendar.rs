//! A city's events, reduced from their records.
//!
//! An event is the `ev/event` record its first host signed. Everything
//! after is a record linking it: `ev/edit` changes what it says (title,
//! time, place, who records), `ev/hosts` replaces the list of hosts,
//! `ev/state` starts, ends, cancels or removes it. Each counts only if
//! whoever signed it was a host at the moment of signing.
//!
//! This follows the city's own reduction as it behaves on a device that
//! holds an event's records but not the city's roster. Rules that need the
//! roster are therefore not applied, and the difference is worth knowing:
//!
//! - an event a city reviewer entered on a resident's behalf lists the
//!   reviewer, not the resident, as its host;
//! - an event imported from an outside calendar is hosted, in the city's
//!   eyes, by its reviewers. [`reduce_events`] cannot know who they are, so
//!   there it has only the importing key as host. A caller that has asked
//!   the city who reviews it passes them to [`reduce_events_curated`], and
//!   their edits to imported events (naming a recorder, for instance) count;
//! - a reviewer deletes an event by signing `polis/trash` for it. Without
//!   knowing who reviews, [`reduce_events`] still lists it;
//!   [`reduce_events_curated`] leaves it out. Host lists signed by reviewers
//!   who are not hosts are not seen by either;
//! - a recorder named by a placeholder the person later claimed is listed
//!   under the placeholder.
//!
//! None of these makes this client publish something a browser would then
//! show under false pretences; they make it offer too little or, for a
//! deleted event, one event too many.

use std::collections::HashMap;

use serde_json::Value;

use crate::facts::{self, Fact};
use crate::hub::{city_tag, event_tag};

/// The `kinds=` filter for reading one event from its own `ev:` tag: the
/// event, the records that change what [`reduce_events`] reports, and what
/// ties their authors to their keys. Each value names one exact record type.
pub const KINDS: &[&str] = &[
    "ev/event",
    "ev/edit",
    "ev/state",
    "ev/hosts",
    "id/inception",
    "id/did",
];

/// The `kinds=` filter for reading a city's `polis:` tag for both
/// [`reduce_events_curated`] and [`crate::channels::reduce_channels`].
///
/// `arc/edit` is left out on purpose. It would carry a channel's later
/// retitling or closing, but the server cannot narrow it to channels, and on
/// a real city it is mostly link previews with their pictures inline: a
/// quarter of the whole answer, for a calendar that is read on a venue's
/// network. A channel is offered under the title it was made with.
pub const CITY_KINDS: &[&str] = &[
    "ev/event",
    "ev/edit",
    "ev/state",
    "ev/hosts",
    "polis/trash",
    "arc/channel",
    "id/inception",
    "id/did",
];

const HOUR_MS: f64 = 3_600_000.0;
const CREW_MAX: usize = 8;
const MODS_MAX: usize = 8;

/// An event as it stands now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CityEvent {
    pub id: String,
    pub title: String,
    pub place: String,
    /// An IANA time zone name as the host wrote it. It is checked for shape
    /// only; treat a name the platform does not know as UTC, as the city does.
    pub tz: String,
    /// `public`, `polis` (residents only) or `link` (unlisted).
    pub scope: String,
    /// The city the event belongs to, or empty.
    pub city: String,
    /// The first host: whoever signed the event.
    pub by: String,
    pub start_ms: i64,
    /// The stated end, or three hours after the start when none was given.
    pub end_ms: i64,
    pub hosts: Vec<String>,
    /// The people the hosts named to record the event.
    pub crew: Vec<String>,
    pub cancelled: bool,
    /// Brought in from an outside calendar by someone the city lets do that,
    /// so the city's reviewers act as its hosts. Only ever set by
    /// [`reduce_events_curated`].
    pub imported: bool,
}

impl CityEvent {
    /// Whether this person hosts or records the event — the people whose
    /// recording the event's archive channel will show.
    pub fn involves(&self, person_id: &str) -> bool {
        !person_id.is_empty()
            && (self.hosts.iter().any(|host| host == person_id)
                || self.crew.iter().any(|member| member == person_id))
    }
}

struct Draft {
    host: String,
    title: String,
    place: String,
    start: f64,
    end: Option<f64>,
    tz: String,
    scope: String,
    city: String,
    state: String,
    crew: Vec<String>,
    mods: Vec<String>,
    removed: bool,
    /// The host list over time: from when, who.
    hosts: Vec<(f64, Vec<String>)>,
    /// Whether the city's reviewers act as hosts of this event.
    imported: bool,
}

/// The events among `recs`, each as it now stands, earliest first.
///
/// Records that do not verify are dropped, and so are records whose key
/// cannot be tied to the person they claim to be by: pass the authors'
/// `id/inception` (and `id/did`) records along with the `ev/*` ones, as
/// [`KINDS`] and [`CITY_KINDS`] ask for. An event removed by its host is not
/// returned; a cancelled one is, marked.
pub fn reduce_events(recs: &[Value]) -> Vec<CityEvent> {
    reduce_events_curated(recs, &[])
}

/// [`reduce_events`], knowing who curates the city.
///
/// Most of a busy city's calendar is imported: a key the city authorised, or
/// one of its reviewers, signs an event that carries where it came from, and
/// from then on the city treats every reviewer as a host of it. `curators`
/// are those people and keys — whoever [`curator_candidates`] names that the
/// city confirms is a coordinator or curator, or is the importing key itself.
/// For an event one of them imported, records the others sign count as a
/// host's, so a recorder a coordinator named is a recorder here too. An
/// event one of them has deleted from the city (`polis/trash`) is left out:
/// the city shows nothing filed under it.
///
/// Only pass records read from the city's own tag: its server admits nothing
/// there from anyone who neither lives in the city nor holds its import key,
/// which is what makes "signed by a curator" mean something.
pub fn reduce_events_curated(recs: &[Value], curators: &[String]) -> Vec<CityEvent> {
    let facts = facts::admit(recs);
    let mut drafts: HashMap<&str, Draft> = HashMap::new();
    for fact in facts.iter().filter(|fact| fact.kind == "ev/event") {
        let scope = fact
            .get("scope")
            .and_then(Value::as_str)
            .filter(|scope| ["public", "polis", "link"].contains(scope))
            .unwrap_or("public");
        let mut draft = Draft {
            host: fact.by.to_string(),
            title: String::new(),
            place: String::new(),
            start: fact.at,
            end: None,
            tz: "UTC".to_string(),
            scope: scope.to_string(),
            city: facts::text_cap(fact.get("polis"), 128)
                .unwrap_or("")
                .to_string(),
            state: String::new(),
            crew: Vec::new(),
            mods: facts::people(fact.get("mods"), MODS_MAX).unwrap_or_default(),
            removed: false,
            hosts: Vec::new(),
            imported: sourced(fact) && curators.iter().any(|curator| curator == fact.by),
        };
        apply(&mut draft, fact);
        drafts.insert(fact.id.as_str(), draft);
    }
    host_lists(&facts, &mut drafts);

    // In causal order: an edit is judged by who hosted when it was signed,
    // and of two edits to the same field the later one stands.
    for fact in &facts {
        let Some(draft) = drafts.get_mut(fact.link(0)) else {
            continue;
        };
        let hosted = hosts_at(draft, fact.at).iter().any(|host| host == fact.by)
            || (draft.imported && curators.iter().any(|curator| curator == fact.by));
        if !hosted {
            continue;
        }
        match fact.kind {
            "ev/edit" => apply(draft, fact),
            // Once a host has removed an event, nothing brings it back.
            "ev/state" if !draft.removed => match fact.get("to").and_then(Value::as_str) {
                Some("removed") => draft.removed = true,
                Some("upcoming") => draft.state.clear(),
                Some(to @ ("live" | "ended" | "cancelled")) => draft.state = to.to_string(),
                _ => {}
            },
            _ => {}
        }
    }

    // A reviewer's deletion, or its undoing: the latest one about an event
    // decides, and it must name the city the event belongs to.
    let mut verdicts: HashMap<&str, (f64, &str, bool)> = HashMap::new();
    for fact in facts.iter().filter(|fact| fact.kind == "polis/trash") {
        let Some(draft) = drafts.get(fact.link(1)) else {
            continue;
        };
        if draft.city.is_empty()
            || fact.link(0) != draft.city
            || !curators.iter().any(|curator| curator == fact.by)
        {
            continue;
        }
        let verdict = (fact.at, fact.id.as_str(), facts::truthy(fact.get("on")));
        let latest = verdicts.entry(fact.link(1)).or_insert(verdict);
        if (verdict.0, verdict.1) > (latest.0, latest.1) {
            *latest = verdict;
        }
    }
    for (id, (_, _, deleted)) in verdicts {
        if let (true, Some(draft)) = (deleted, drafts.get_mut(id)) {
            draft.removed = true;
        }
    }

    let mut events: Vec<CityEvent> = drafts
        .into_iter()
        .filter(|(_, draft)| !draft.removed)
        .map(|(id, draft)| CityEvent {
            id: id.to_string(),
            title: draft.title,
            place: draft.place,
            tz: draft.tz,
            scope: draft.scope,
            city: draft.city,
            by: draft.host,
            start_ms: draft.start as i64,
            end_ms: draft.end.unwrap_or(draft.start + 3.0 * HOUR_MS) as i64,
            hosts: draft
                .hosts
                .last()
                .map(|(_, hosts)| hosts.clone())
                .unwrap_or_default(),
            crew: draft.crew,
            cancelled: draft.state == "cancelled",
            imported: draft.imported,
        })
        .collect();
    events.sort_by(|a, b| (a.start_ms, &a.id).cmp(&(b.start_ms, &b.id)));
    events
}

/// Whose standing in the city decides how its calendar reduces: whoever
/// signed an event that says it came from an outside calendar, whoever
/// signed a change to one, and whoever signed an event's deletion. Ask the
/// city about each and pass those it confirms to [`reduce_events_curated`].
pub fn curator_candidates(recs: &[Value]) -> Vec<String> {
    let facts = facts::admit(recs);
    let imports: Vec<&str> = facts
        .iter()
        .filter(|fact| fact.kind == "ev/event" && sourced(fact))
        .map(|fact| fact.id.as_str())
        .collect();
    let mut candidates: Vec<String> = facts
        .iter()
        .filter(|fact| match fact.kind {
            "ev/event" => sourced(fact),
            "ev/edit" | "ev/state" => imports.contains(&fact.link(0)),
            // Deleting an event is a reviewer's act whatever the event.
            "polis/trash" => true,
            _ => false,
        })
        .map(|fact| fact.by.to_string())
        .collect();
    candidates.sort();
    candidates.dedup();
    candidates
}

/// Whoever signed an event that says it came from an outside calendar. The
/// city's server lets only residents and the import key it authorised write
/// to its tag, so one of these who holds no standing in the city at all is
/// that key.
pub fn importers(recs: &[Value]) -> Vec<String> {
    let mut signers: Vec<String> = facts::admit(recs)
        .iter()
        .filter(|fact| fact.kind == "ev/event" && sourced(fact))
        .map(|fact| fact.by.to_string())
        .collect();
    signers.sort();
    signers.dedup();
    signers
}

/// Whether an event says where it was imported from, in the shape the city
/// accepts: a source name and that source's own id for the event.
fn sourced(fact: &Fact<'_>) -> bool {
    let Some(source) = fact.get("src").filter(|source| source.is_object()) else {
        return false;
    };
    source.get("from").is_some_and(Value::is_string)
        && source.get("id").and_then(Value::as_str).is_some_and(|id| {
            (1..=80).contains(&id.len())
                && id
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_.:-".contains(c))
        })
}

/// The tags a recording of this event is posted to, as the city's own
/// recorder decides: always the event's; the city's too when the event
/// belongs to one, is not link-only, and the signer lives there.
///
/// The city's recorder also requires the event's first host to be a
/// resident. That holds whenever the signer is the host; when a recorder
/// publishes for someone else's event, pass `false` unless the host
/// ([`CityEvent::by`]) is known to live in the city as well.
///
/// Not every record goes to both: see [`crate::publish::for_tag`].
pub fn recording_tags(event: &CityEvent, signer_is_resident: bool) -> Vec<String> {
    let mut tags = vec![event_tag(&event.id)];
    if signer_is_resident && !event.city.is_empty() && event.scope != "link" {
        tags.push(city_tag(&event.city));
    }
    tags
}

/// Applies what an `ev/event` or `ev/edit` says. A field that is absent or
/// of the wrong type leaves what was there.
fn apply(draft: &mut Draft, fact: &Fact<'_>) {
    if let Some(title) = facts::text_cap(fact.get("title"), 120) {
        draft.title = title.to_string();
    }
    if let Some(place) = facts::text_cap(fact.get("place"), 200) {
        draft.place = place.to_string();
    }
    if let Some(start) = facts::number(fact.get("start")) {
        draft.start = start;
    }
    match fact.get("end") {
        Some(Value::Null) => draft.end = None,
        end => {
            if let Some(end) = facts::number(end) {
                draft.end = Some(end);
            }
        }
    }
    if let Some(tz) = fact
        .get("tz")
        .and_then(Value::as_str)
        .filter(|tz| tz_shaped(tz))
    {
        draft.tz = tz.to_string();
    }
    // An end that is not after the start is no end at all.
    if draft.end.is_some_and(|end| end <= draft.start) {
        draft.end = None;
    }
    if let Some(crew) = facts::people(fact.get("crew"), CREW_MAX) {
        draft.crew = crew;
    }
}

/// The shape of an IANA zone name. The city asks its runtime whether the
/// zone exists; this crate carries no zone database, so the caller's
/// platform has the last word.
fn tz_shaped(tz: &str) -> bool {
    (1..=64).contains(&tz.len())
        && tz.as_bytes()[0].is_ascii_alphabetic()
        && tz
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"/_+-".contains(&byte))
}

/// Works out each event's host list over time. It starts as the first host
/// and the moderators they named before any explicit list; each `ev/hosts`
/// then replaces it whole, and only the first host — while still on the
/// list — may sign one (and cannot write themselves off it).
fn host_lists(facts: &[Fact<'_>], drafts: &mut HashMap<&str, Draft>) {
    let mut about: HashMap<&str, Vec<&Fact<'_>>> = HashMap::new();
    for fact in facts {
        if matches!(fact.kind, "ev/hosts" | "ev/edit") && drafts.contains_key(fact.link(0)) {
            about.entry(fact.link(0)).or_default().push(fact);
        }
    }
    for (id, draft) in drafts.iter_mut() {
        let mut recs = about.remove(id).unwrap_or_default();
        recs.sort_by(|a, b| a.at.total_cmp(&b.at).then_with(|| a.id.cmp(&b.id)));
        let first_list = recs
            .iter()
            .find(|fact| fact.kind == "ev/hosts")
            .map_or(f64::INFINITY, |fact| fact.at);
        for fact in &recs {
            if fact.kind == "ev/edit" && fact.at < first_list && fact.by == draft.host {
                if let Some(mods) = facts::people(fact.get("mods"), MODS_MAX) {
                    draft.mods = mods;
                }
            }
        }
        let mut current = vec![draft.host.clone()];
        merge(&mut current, &draft.mods);
        draft.hosts.push((f64::NEG_INFINITY, current.clone()));
        for fact in recs.iter().filter(|fact| fact.kind == "ev/hosts") {
            let Some(list) = facts::people(fact.get("hosts"), usize::MAX) else {
                continue;
            };
            if fact.by != draft.host || !current.contains(&draft.host) {
                continue;
            }
            current = vec![draft.host.clone()];
            merge(&mut current, &list);
            draft.hosts.push((fact.at, current.clone()));
        }
    }
}

fn merge(into: &mut Vec<String>, more: &[String]) {
    for one in more {
        if !into.contains(one) {
            into.push(one.clone());
        }
    }
}

/// Who hosted at a given moment.
fn hosts_at(draft: &Draft, at: f64) -> &[String] {
    let mut current: &[String] = &[];
    for (from, hosts) in &draft.hosts {
        if *from > at {
            break;
        }
        current = hosts;
    }
    current
}
