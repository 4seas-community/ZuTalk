//! Agreement with the city's own code.
//!
//! Every expected value in `tests/fixtures/*.json` was computed by the
//! city's JavaScript (see `tools/city-interop/gen-fixtures.mjs`); these tests
//! run offline and need no checkout. A failure here means a record this
//! crate signs would not verify in a browser, or a record a browser shows
//! would be dropped here.

use std::collections::BTreeMap;

use serde_json::{json, Value};
use vt_city::calendar::{reduce_events, CityEvent};
use vt_city::channels::{reduce_channels, Channel};
use vt_city::identity::{Identity, StoredIdentity};
use vt_city::link::{agree, open_box, LinkKey, LinkSession, LinkStep, SharedKey};
use vt_city::{jcs, publish, record, CityError};

fn fixture(text: &str) -> Value {
    serde_json::from_str(text).expect("fixture parses")
}

fn text<'a>(value: &'a Value, name: &str) -> &'a str {
    value[name]
        .as_str()
        .unwrap_or_else(|| panic!("{name} is text"))
}

fn list<'a>(value: &'a Value, name: &str) -> &'a [Value] {
    value[name]
        .as_array()
        .unwrap_or_else(|| panic!("{name} is a list"))
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .expect("a list")
        .iter()
        .map(|item| item.as_str().expect("text").to_string())
        .collect()
}

fn scalar(hex_text: &str) -> [u8; 32] {
    hex::decode(hex_text)
        .expect("hex")
        .try_into()
        .expect("32 bytes")
}

#[test]
fn canonical_json_matches_byte_for_byte() {
    let fixtures = fixture(include_str!("fixtures/jcs.json"));
    for case in list(&fixtures, "cases") {
        let value: Value = serde_json::from_str(text(case, "text")).expect("case parses");
        assert_eq!(
            jcs::canonical(&value).unwrap(),
            text(case, "canonical"),
            "{case}"
        );
        assert_eq!(
            jcs::fingerprint(&value).unwrap(),
            text(case, "fingerprint"),
            "{case}"
        );
    }
}

#[test]
fn a_recovery_key_restores_the_same_person() {
    let fixtures = fixture(include_str!("fixtures/identity.json"));
    for person in list(&fixtures, "people") {
        let identity = Identity::from_key_string(text(person, "key_string")).unwrap();
        assert_eq!(identity.id(), text(person, "id"));
        assert_eq!(identity.did_key(), text(person, "did_key"));
        // Ed25519 is deterministic: the inception is the same record, signature included.
        assert_eq!(identity.inception(), &person["inception"]);
        assert_eq!(identity.controller(), None);
        assert!(identity.signs_with_inception_key());
    }
    for spelling in list(&fixtures, "spellings") {
        let identity = Identity::from_key_string(spelling.as_str().unwrap()).unwrap();
        assert_eq!(identity.id(), text(&fixtures, "spellings_id"), "{spelling}");
    }
    for bad in list(&fixtures, "rejected") {
        assert!(
            Identity::from_key_string(bad.as_str().unwrap()).is_err(),
            "{bad}"
        );
    }
}

#[test]
fn a_moved_identity_arrives_whole_or_not_at_all() {
    let fixtures = fixture(include_str!("fixtures/identity.json"));
    let moved = &fixtures["migrated"];
    let (identity, name) = Identity::from_link_payload(&json!({ "v2": moved["bundle"] })).unwrap();
    assert_eq!(name, "");
    assert_eq!(identity.id(), text(moved, "id"));
    assert_eq!(identity.did_key(), text(moved, "did_key"));
    assert_eq!(identity.controller(), Some(text(moved, "controller")));
    assert!(!identity.signs_with_inception_key());
    assert_eq!(identity.inception()["e"]["key"], moved["inception_key"]);

    let stored: StoredIdentity =
        serde_json::from_str(&serde_json::to_string(&identity.to_stored()).unwrap()).unwrap();
    assert_eq!(stored.version, 2);
    let back = Identity::from_stored(&stored).unwrap();
    assert_eq!(
        (back.id(), back.did_key(), back.controller()),
        (identity.id(), identity.did_key(), identity.controller())
    );

    // Each of these is a bundle the city's own receiver turns away.
    let damage: [Damage; 7] = [
        ("identity number changed", |b| {
            b["id"] = json!("0".repeat(64))
        }),
        ("inception signature changed", |b| {
            b["inc"]["s"] = json!(b["inc"]["s"].as_str().unwrap().replacen(
                |c: char| c.is_ascii_lowercase(),
                "A",
                1
            ));
        }),
        ("inception no longer canonical", |b| {
            b["inc"]["e"]["at"] = json!(1)
        }),
        ("no signing seed", |b| b["sign"] = Value::Null),
        ("short signing seed", |b| b["sign"] = json!("AAAA")),
        ("no device root", |b| b["root"] = Value::Null),
        ("key index zero", |b| b["j"] = json!(0)),
    ];
    for (note, break_it) in damage {
        let mut bundle = moved["bundle"].clone();
        break_it(&mut bundle);
        assert!(
            Identity::from_link_payload(&json!({ "v2": bundle })).is_err(),
            "{note}"
        );
    }
    // A controller that is not plainly this person's is dropped, not adopted.
    let mut bundle = moved["bundle"].clone();
    bundle["webvh"] = json!(format!(
        "did:webvh:{}:city.example:u:{}",
        "1".repeat(46),
        "0".repeat(16)
    ));
    let (stranger, _) = Identity::from_link_payload(&json!({ "v2": bundle })).unwrap();
    assert_eq!(stranger.controller(), None);
}

/// One way to break a handed-over bundle, and what to call it.
type Damage = (&'static str, fn(&mut Value));

/// The identities the signed fixtures were made with.
fn signers() -> BTreeMap<&'static str, Identity> {
    let fixtures = fixture(include_str!("fixtures/identity.json"));
    let first =
        Identity::from_key_string(text(&list(&fixtures, "people")[0], "key_string")).unwrap();
    let (moved, _) =
        Identity::from_link_payload(&json!({ "v2": fixtures["migrated"]["bundle"] })).unwrap();
    BTreeMap::from([("v1", first), ("v2", moved)])
}

#[test]
fn records_are_signed_exactly_as_the_city_signs_them() {
    let fixtures = fixture(include_str!("fixtures/records.json"));
    let signers = signers();
    for case in list(&fixtures, "made") {
        let who = &signers[text(case, "who")];
        let made = record::make(
            who,
            text(case, "kind"),
            case["body"].clone(),
            &strings(&case["links"]),
            &strings(&case["deps"]),
            case["at"].as_i64().unwrap(),
        )
        .unwrap();
        assert_eq!(made.id, text(case, "id"));
        assert_eq!(made.rec, case["rec"], "{}", text(case, "kind"));
        assert_eq!(record::record_id(&case["rec"]).unwrap(), text(case, "id"));
        assert_eq!(
            record::signature_of(&case["rec"]).as_deref(),
            Some(text(case, "signature"))
        );
        assert!(record::verify(&case["rec"]));
    }
}

#[test]
fn the_verdict_on_a_damaged_record_is_the_citys() {
    let fixtures = fixture(include_str!("fixtures/records.json"));
    let verdicts = list(&fixtures, "verdicts");
    assert!(verdicts.len() > 30);
    for case in verdicts {
        assert_eq!(
            record::verify(&case["rec"]),
            text(case, "verdict") == "ok",
            "{}",
            text(case, "note")
        );
    }
    for junk in [
        json!(null),
        json!([]),
        json!({}),
        json!({"e": 1}),
        json!({"e": {}, "s": ""}),
    ] {
        assert!(!record::verify(&junk));
        assert_eq!(record::signature_of(&junk).filter(|s| !s.is_empty()), None);
    }
}

#[test]
fn signing_refuses_what_readers_would_refuse() {
    let who = &signers()["v1"];
    let dep = vec![who.id().to_string()];
    let make = |kind: &str, links: &[String], deps: &[String], at: i64| {
        record::make(who, kind, json!({}), links, deps, at).map(|signed| signed.id)
    };
    assert!(make("tape/end", &[], &dep, 0).is_ok());
    assert!(make("", &[], &dep, 0).is_err());
    assert!(make(&"x".repeat(65), &[], &dep, 0).is_err());
    assert!(make("id/inception", &[], &dep, 0).is_err());
    assert!(make("tape/end", &[], &[], 0).is_err(), "no dependency");
    assert!(make("tape/end", &vec!["a".to_string(); 65], &dep, 0).is_err());
    assert!(make("tape/end", &["a".repeat(129)], &dep, 0).is_err());
    assert!(make("tape/end", &[], &dep, -1).is_err());
    assert!(make("tape/end", &[], &dep, 253_402_300_800_000).is_err());
    let mut deep = json!(1);
    for _ in 0..400 {
        deep = json!([deep]);
    }
    assert!(record::make(who, "tape/end", deep, &[], &dep, 0).is_err());
}

#[test]
fn both_devices_derive_the_same_key_and_digits() {
    let fixtures = fixture(include_str!("fixtures/link.json"));
    let ours = LinkKey::from_scalar(&scalar(text(&fixtures, "new_scalar"))).unwrap();
    let theirs = LinkKey::from_scalar(&scalar(text(&fixtures, "old_scalar"))).unwrap();
    assert_eq!(ours.public(), text(&fixtures, "new_public"));
    assert_eq!(theirs.public(), text(&fixtures, "old_public"));
    let agreed = agree(&ours, theirs.public()).unwrap();
    assert_eq!(agreed.check, text(&fixtures, "check"));
    assert_eq!(agree(&theirs, ours.public()).unwrap().check, agreed.check);
    // A box the city sealed opens with the key derived here, and with the
    // key bytes the city derived: they are the same key.
    let sealed = text(&fixtures, "sealed");
    assert_eq!(open_box(&agreed.key, sealed).unwrap(), fixtures["value"]);
    let recorded = SharedKey::from_bytes(scalar(text(&fixtures, "key")));
    assert_eq!(open_box(&recorded, sealed).unwrap(), fixtures["value"]);
    let stranger = LinkKey::from_scalar(&[0x55; 32]).unwrap();
    let wrong = agree(&stranger, theirs.public()).unwrap();
    assert_eq!(open_box(&wrong.key, sealed).unwrap_err(), CityError::Crypto);
}

#[test]
fn a_scripted_old_device_signs_this_one_in() {
    let fixtures = fixture(include_str!("fixtures/link.json"));
    for case in list(&fixtures, "sessions") {
        let key = LinkKey::from_scalar(&scalar(text(&fixtures, "new_scalar"))).unwrap();
        let mut session = LinkSession::with_key(text(&fixtures, "room").to_string(), key);
        assert_eq!(session.code(), text(&fixtures, "code"));
        assert_eq!(session.room(), text(&fixtures, "room"));
        let msgs = list(case, "msgs");
        // The greeting alone gives the digits; the rest gives the identity.
        let step = session.absorb(&msgs[..1], 1).unwrap();
        assert!(matches!(step, LinkStep::Check(ref digits) if digits == text(&fixtures, "check")));
        let step = session.absorb(&msgs[1..], msgs.len() as u64).unwrap();
        let LinkStep::Done { identity, name } = step else {
            panic!("{}: expected an identity", text(case, "note"));
        };
        assert_eq!(session.since(), msgs.len() as u64);
        assert_eq!(identity.id(), text(case, "id"));
        assert_eq!(identity.did_key(), text(case, "did_key"));
        assert_eq!(identity.controller(), case["controller"].as_str());
        assert_eq!(name, text(case, "name"));
        // Further polls keep reporting the same outcome.
        assert!(matches!(
            session.absorb(&[], 0).unwrap(),
            LinkStep::Done { .. }
        ));

        // The same messages in one poll end in the same place.
        let key = LinkKey::from_scalar(&scalar(text(&fixtures, "new_scalar"))).unwrap();
        let mut at_once = LinkSession::with_key(text(&fixtures, "room").to_string(), key);
        assert!(matches!(
            at_once.absorb(msgs, msgs.len() as u64).unwrap(),
            LinkStep::Done { .. }
        ));
    }
}

#[test]
fn a_handover_that_cannot_be_trusted_ends_the_attempt() {
    let fixtures = fixture(include_str!("fixtures/link.json"));
    let identity_fixtures = fixture(include_str!("fixtures/identity.json"));
    let ours = || LinkKey::from_scalar(&scalar(text(&fixtures, "new_scalar"))).unwrap();
    let theirs = LinkKey::from_scalar(&scalar(text(&fixtures, "old_scalar"))).unwrap();
    let key = agree(&theirs, ours().public()).unwrap().key;
    let hello = json!({"t": "hi", "pub": theirs.public()});
    let sealed = |payload: Value| json!({"t": "key", "box": vt_city::link::seal_box(&key, &payload).unwrap()});

    // A mistyped key inside a well-sealed box: the attempt fails for good.
    let bad_key = identity_fixtures["rejected"][0].clone();
    let mut session = LinkSession::with_key("ab".repeat(16), ours());
    assert!(session
        .absorb(&[hello.clone(), sealed(json!({"key": bad_key}))], 2)
        .is_err());
    assert!(session.absorb(&[], 2).is_err());

    // A box sealed with some other key is noise; the digits stay up.
    let other = agree(&LinkKey::from_scalar(&[0x66; 32]).unwrap(), ours().public())
        .unwrap()
        .key;
    let noise =
        json!({"t": "key", "box": vt_city::link::seal_box(&other, &json!({"key": "x"})).unwrap()});
    let mut session = LinkSession::with_key("ab".repeat(16), ours());
    assert!(matches!(
        session.absorb(&[hello, noise], 2).unwrap(),
        LinkStep::Check(_)
    ));
}

#[test]
fn sentence_marks_match() {
    let fixtures = fixture(include_str!("fixtures/marks.json"));
    for case in list(&fixtures, "marks") {
        assert_eq!(publish::text_mark(text(case, "text")), text(case, "mark"));
    }
}

fn event_from(value: &Value) -> CityEvent {
    CityEvent {
        id: text(value, "id").into(),
        title: text(value, "title").into(),
        place: text(value, "place").into(),
        tz: text(value, "tz").into(),
        scope: text(value, "scope").into(),
        city: text(value, "city").into(),
        by: text(value, "by").into(),
        start_ms: value["start_ms"].as_i64().unwrap(),
        end_ms: value["end_ms"].as_i64().unwrap(),
        hosts: strings(&value["hosts"]),
        crew: strings(&value["crew"]),
        cancelled: value["cancelled"].as_bool().unwrap(),
        // The city's own reducer is fed no roster here, so nothing is curated.
        imported: false,
    }
}

#[test]
fn events_reduce_as_the_city_reduces_them() {
    let fixtures = fixture(include_str!("fixtures/calendar.json"));
    let recs = list(&fixtures, "recs");
    let mut want: Vec<CityEvent> = list(&fixtures, "events").iter().map(event_from).collect();
    want.sort_by(|a, b| (a.start_ms, &a.id).cmp(&(b.start_ms, &b.id)));
    let got = reduce_events(recs);
    assert_eq!(got, want);

    // The order records arrive in does not matter.
    let mut reversed = recs.to_vec();
    reversed.reverse();
    assert_eq!(reduce_events(&reversed), want);

    // Without the authors' inceptions nothing can be attributed, so nothing is listed.
    let orphans: Vec<Value> = recs
        .iter()
        .filter(|rec| rec["e"]["type"] != "id/inception")
        .cloned()
        .collect();
    assert!(reduce_events(&orphans).is_empty());

    // Without the DID log, what the moved person signed with a device key is
    // not theirs yet; the event disappears rather than being taken on trust.
    let moved_title = "Signed after moving, with the first key";
    assert!(got.iter().any(|event| event.title == moved_title));
    let no_log: Vec<Value> = recs
        .iter()
        .filter(|rec| rec["e"]["type"] != "id/did")
        .cloned()
        .collect();
    assert!(!reduce_events(&no_log)
        .iter()
        .any(|event| event.title.contains("Signed after moving")));

    let circle = got
        .iter()
        .find(|event| event.title.starts_with("Morning circle"))
        .unwrap();
    assert!(circle.involves(&circle.hosts[0]));
    assert!(circle.involves(&circle.crew[0]));
    assert!(!circle.involves(&"0".repeat(64)));
    assert!(!circle.involves(""));
}

#[test]
fn channels_reduce_as_the_city_reduces_them() {
    let fixtures = fixture(include_str!("fixtures/channels.json"));
    let by_id = |channels: Vec<Channel>| -> BTreeMap<String, Channel> {
        channels
            .into_iter()
            .map(|channel| (channel.id.clone(), channel))
            .collect()
    };
    let want = by_id(
        list(&fixtures, "channels")
            .iter()
            .map(|value| Channel {
                id: text(value, "id").into(),
                title: text(value, "title").into(),
                by: text(value, "by").into(),
                city: value["city"].as_str().map(str::to_string),
                open: value["open"].as_bool().unwrap(),
                set: value["set"].as_bool().unwrap(),
            })
            .collect(),
    );
    assert_eq!(by_id(reduce_channels(list(&fixtures, "recs"))), want);
}
