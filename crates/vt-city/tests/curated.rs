//! Imported events: most of a real city's calendar. The city treats its
//! reviewers as their hosts; this client only can once it has been told who
//! they are, and must not when it has not.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use vt_city::calendar::{curator_candidates, importers, reduce_events, reduce_events_curated};
use vt_city::identity::Identity;
use vt_city::record;

const NOW: i64 = 1_794_528_000_000;

/// A person with a key of their own, restored the way a resident's recovery
/// key is: the fixtures only carry two people and these tests need three.
fn person(index: u8) -> Identity {
    let seed = [index + 1; 32];
    let mut hasher = Sha256::new();
    hasher.update(b"sibian-key-1:");
    hasher.update(seed);
    let mut bytes = seed.to_vec();
    bytes.extend_from_slice(&hasher.finalize()[..4]);
    Identity::from_key_string(&format!("sibian-key-1:{}", base58(&bytes))).unwrap()
}

fn base58(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    let mut digits: Vec<u8> = Vec::new();
    for &byte in bytes {
        let mut carry = u32::from(byte);
        for digit in &mut digits {
            carry += u32::from(*digit) << 8;
            *digit = (carry % 58) as u8;
            carry /= 58;
        }
        while carry > 0 {
            digits.push((carry % 58) as u8);
            carry /= 58;
        }
    }
    let zeros = bytes.iter().take_while(|byte| **byte == 0).count();
    let mut out = "1".repeat(zeros);
    out.extend(
        digits
            .iter()
            .rev()
            .map(|digit| ALPHABET[*digit as usize] as char),
    );
    out
}

fn sign(who: &Identity, kind: &str, body: Value, links: &[String], at: i64) -> record::Signed {
    record::make(who, kind, body, links, &[who.id().to_string()], at).unwrap()
}

/// An importer's event, a reviewer naming a recorder for it, and the records
/// that tie the three people to their keys.
fn imported_calendar() -> (Vec<Value>, String, Identity, Identity, Identity) {
    let (importer, reviewer, recorder) = (person(0), person(1), person(2));
    let event = sign(
        &importer,
        "ev/event",
        json!({
            "title": "Language Exchange",
            "place": "Event Space",
            "start": NOW,
            "end": NOW + 7_200_000,
            "tz": "Asia/Bangkok",
            "scope": "public",
            "polis": "c".repeat(64),
            "src": { "from": "Outside Calendar", "id": "abc123", "url": "https://calendar.example/abc123" },
        }),
        &[],
        NOW - 86_400_000,
    );
    let named = sign(
        &reviewer,
        "ev/edit",
        json!({ "crew": [recorder.id()] }),
        std::slice::from_ref(&event.id),
        NOW - 3_600_000,
    );
    let records = vec![
        importer.inception().clone(),
        reviewer.inception().clone(),
        recorder.inception().clone(),
        event.rec,
        named.rec,
    ];
    (records, event.id, importer, reviewer, recorder)
}

#[test]
fn without_a_roster_only_the_importing_key_hosts_an_imported_event() {
    let (records, id, importer, _reviewer, recorder) = imported_calendar();
    let events = reduce_events(&records);
    let event = events.iter().find(|event| event.id == id).unwrap();
    assert!(!event.imported);
    assert_eq!(event.hosts, vec![importer.id().to_string()]);
    assert!(
        !event.involves(recorder.id()),
        "a stranger's edit must not name a recorder"
    );
}

#[test]
fn a_reviewer_names_the_recorder_of_an_imported_event() {
    let (records, id, importer, reviewer, recorder) = imported_calendar();
    let curators = vec![importer.id().to_string(), reviewer.id().to_string()];
    let events = reduce_events_curated(&records, &curators);
    let event = events.iter().find(|event| event.id == id).unwrap();
    assert!(event.imported);
    assert!(event.involves(recorder.id()));
    assert!(
        !event.involves(reviewer.id()),
        "reviewers act as hosts without being listed as one"
    );
}

#[test]
fn a_reviewer_is_not_a_host_of_an_event_nobody_imported() {
    let (host, reviewer, recorder) = (person(0), person(1), person(2));
    let event = sign(
        &host,
        "ev/event",
        json!({ "title": "Reading Club", "start": NOW, "scope": "public" }),
        &[],
        NOW - 86_400_000,
    );
    let meddling = sign(
        &reviewer,
        "ev/edit",
        json!({ "crew": [recorder.id()], "title": "Renamed" }),
        std::slice::from_ref(&event.id),
        NOW - 3_600_000,
    );
    let records = vec![
        host.inception().clone(),
        reviewer.inception().clone(),
        event.rec,
        meddling.rec,
    ];
    let curators = vec![reviewer.id().to_string()];
    let events = reduce_events_curated(&records, &curators);
    assert_eq!(events.len(), 1);
    assert!(!events[0].imported);
    assert_eq!(events[0].title, "Reading Club");
    assert!(events[0].crew.is_empty());
}

#[test]
fn an_import_by_someone_who_does_not_curate_is_an_ordinary_event() {
    let (records, id, _importer, reviewer, recorder) = imported_calendar();
    // The reviewer curates, but whoever signed the event does not: the city
    // ignores where it claims to come from, and so do we.
    let curators = vec![reviewer.id().to_string()];
    let events = reduce_events_curated(&records, &curators);
    let event = events.iter().find(|event| event.id == id).unwrap();
    assert!(!event.imported);
    assert!(!event.involves(recorder.id()));
}

#[test]
fn the_city_is_asked_about_importers_and_those_who_changed_an_import() {
    let (mut records, _id, importer, reviewer, recorder) = imported_calendar();
    let own = sign(
        &recorder,
        "ev/event",
        json!({ "title": "Own event", "start": NOW, "scope": "public" }),
        &[],
        NOW,
    );
    records.push(own.rec);
    let mut expected = vec![importer.id().to_string(), reviewer.id().to_string()];
    expected.sort();
    assert_eq!(curator_candidates(&records), expected);
    assert_eq!(importers(&records), vec![importer.id().to_string()]);
}

/// A city with one event of its own, and the records that tie people to keys.
fn city_event(host: &Identity, city: &str) -> record::Signed {
    sign(
        host,
        "ev/event",
        json!({ "title": "Created by mistake", "start": NOW, "scope": "public", "polis": city }),
        &[],
        NOW - 86_400_000,
    )
}

#[test]
fn an_event_a_reviewer_deleted_is_not_offered() {
    let (host, reviewer) = (person(0), person(1));
    let city = "c".repeat(64);
    let event = city_event(&host, &city);
    let deleted = sign(
        &reviewer,
        "polis/trash",
        json!({ "on": true }),
        &[city.clone(), event.id.clone()],
        NOW - 3_600_000,
    );
    let records = vec![
        host.inception().clone(),
        reviewer.inception().clone(),
        event.rec,
        deleted.rec,
    ];
    let curators = vec![reviewer.id().to_string()];
    assert!(reduce_events_curated(&records, &curators).is_empty());
    assert_eq!(
        reduce_events(&records).len(),
        1,
        "without knowing who reviews, a deletion cannot be believed"
    );
    assert_eq!(curator_candidates(&records), curators);
}

#[test]
fn a_restored_event_is_offered_again_and_a_strangers_deletion_is_ignored() {
    let (host, reviewer, stranger) = (person(0), person(1), person(2));
    let city = "c".repeat(64);
    let event = city_event(&host, &city);
    let links = [city.clone(), event.id.clone()];
    let deleted = sign(
        &reviewer,
        "polis/trash",
        json!({ "on": true }),
        &links,
        NOW - 3_000,
    );
    let restored = sign(
        &reviewer,
        "polis/trash",
        json!({ "on": false }),
        &links,
        NOW - 2_000,
    );
    let meddling = sign(
        &stranger,
        "polis/trash",
        json!({ "on": true }),
        &links,
        NOW - 1_000,
    );
    let elsewhere = sign(
        &reviewer,
        "polis/trash",
        json!({ "on": true }),
        &["d".repeat(64), event.id.clone()],
        NOW - 500,
    );
    let records = vec![
        host.inception().clone(),
        reviewer.inception().clone(),
        stranger.inception().clone(),
        event.rec,
        deleted.rec,
        restored.rec,
        meddling.rec,
        elsewhere.rec,
    ];
    let curators = vec![reviewer.id().to_string()];
    let events = reduce_events_curated(&records, &curators);
    assert_eq!(
        events.len(),
        1,
        "the reviewer's latest word is that it stays"
    );
}
