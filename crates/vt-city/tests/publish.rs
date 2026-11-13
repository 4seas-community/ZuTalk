//! The shape of what gets published. Whether the city's own reducers read it
//! back as intended is checked against the city's code by
//! `tools/city-interop/check-take.mjs`; these tests pin the properties that
//! must hold for any input.

use serde_json::{json, Value};
use vt_city::identity::Identity;
use vt_city::publish::{
    batches, build_take, build_update, build_withdraw, for_tag, text_mark, Correction, Sentence,
    TakeInput, Translated, SENTENCES_PER_RECORD, SENTENCE_MAX, TRANSLATIONS_PER_RECORD,
};
use vt_city::record;

const NOW: i64 = 1_794_528_000_000;

fn who() -> Identity {
    let fixtures: Value = serde_json::from_str(include_str!("fixtures/identity.json")).unwrap();
    Identity::from_key_string(fixtures["people"][0]["key_string"].as_str().unwrap()).unwrap()
}

fn sentence(t_ms: i64, speaker: &str, text: &str) -> Sentence {
    Sentence {
        t_ms,
        d_ms: 900,
        speaker: speaker.into(),
        text: text.into(),
    }
}

fn input(sentences: usize) -> TakeInput {
    let lines: Vec<Sentence> = (0..sentences)
        .map(|n| {
            sentence(
                n as i64 * 1_000,
                if n % 2 == 0 { "host" } else { "guest" },
                &format!("Sentence {n}."),
            )
        })
        .collect();
    let translated = |language: &str| {
        (
            language.to_string(),
            lines
                .iter()
                .map(|line| Translated {
                    t_ms: line.t_ms,
                    source_text: line.text.clone(),
                    text: format!("[{language}] {}", line.text),
                })
                .collect::<Vec<_>>(),
        )
    };
    TakeInput {
        event_id: "ab".repeat(32),
        title: "Recording · Morning circle".into(),
        started_ms: NOW - 3_600_000,
        duration_ms: sentences as i64 * 1_000,
        translations: vec![translated("zh-Hans"), translated("th")],
        sentences: lines,
        speakers: vec![
            ("guest".into(), "Ben".into()),
            ("host".into(), " Ada ".into()),
            ("nobody".into(), "Unused".into()),
        ],
        marks_ms: vec![5_000, 1_000, 5_000],
        channel_ids: vec!["cd".repeat(32), "ab".repeat(32), "cd".repeat(32)],
    }
}

fn kinds(records: &[Value]) -> Vec<&str> {
    records
        .iter()
        .map(|rec| rec["e"]["type"].as_str().unwrap())
        .collect()
}

fn of_kind<'a>(records: &'a [Value], kind: &str) -> Vec<&'a Value> {
    records
        .iter()
        .filter(|rec| rec["e"]["type"] == kind)
        .collect()
}

#[test]
fn a_take_is_one_verifiable_chain() {
    let who = who();
    let built = build_take(&who, &input(5), NOW).unwrap();
    assert_eq!(
        kinds(&built.records),
        [
            "tape/take",
            "tape/text",
            "tape/who",
            "tape/who",
            "tape/who",
            "tape/mark",
            "tape/mark",
            "tape/tr",
            "tape/tr",
            "tape/end",
            "arc/block",
            "arc/connect",
            "arc/connect"
        ]
    );
    let mut dep = who.id().to_string();
    for (index, rec) in built.records.iter().enumerate() {
        assert!(record::verify(rec), "record {index} verifies");
        assert_eq!(rec["e"]["by"], who.id());
        // Each record depends on the one before; the first on the author.
        assert_eq!(rec["e"]["deps"], json!([dep]));
        assert_eq!(rec["e"]["at"], NOW + index as i64);
        dep = record::record_id(rec).unwrap();
    }
    assert_eq!(record::record_id(&built.records[0]).unwrap(), built.take_id);
    let take = &built.records[0]["e"];
    assert_eq!(take["links"], json!(["ab".repeat(32)]));
    assert_eq!(
        take["body"],
        json!({"mime": "", "started": NOW - 3_600_000})
    );

    let block = of_kind(&built.records, "arc/block")[0];
    assert_eq!(record::record_id(block).unwrap(), built.block_id);
    assert_eq!(
        block["e"]["body"],
        json!({"kind": "audio", "title": "Recording · Morning circle", "take": built.take_id, "dur": 5_000})
    );
    assert_eq!(block["e"]["links"], json!([built.take_id]));
    // The event first, then each other channel once; the event is not repeated.
    let placed: Vec<&Value> = of_kind(&built.records, "arc/connect")
        .iter()
        .map(|rec| &rec["e"]["links"])
        .collect();
    assert_eq!(
        placed,
        [
            &json!(["ab".repeat(32), built.block_id]),
            &json!(["cd".repeat(32), built.block_id])
        ]
    );
    // Everything about the take links the take.
    for rec in built
        .records
        .iter()
        .filter(|rec| rec["e"]["type"].as_str().unwrap().starts_with("tape/"))
        .skip(1)
    {
        assert_eq!(rec["e"]["links"], json!([built.take_id]));
    }
}

#[test]
fn speakers_marks_and_languages_are_written_for_the_citys_readers() {
    let built = build_take(&who(), &input(5), NOW).unwrap();
    let text = &of_kind(&built.records, "tape/text")[0]["e"]["body"]["segs"];
    assert_eq!(
        text[0],
        json!({"t": 0, "d": 900, "sp": "host", "text": "Sentence 0."})
    );
    assert_eq!(text[1]["sp"], "guest");
    // One name per label, trimmed, in label order.
    let names: Vec<&Value> = of_kind(&built.records, "tape/who")
        .iter()
        .map(|rec| &rec["e"]["body"])
        .collect();
    assert_eq!(
        names,
        [
            &json!({"sp": "guest", "name": "Ben"}),
            &json!({"sp": "host", "name": "Ada"}),
            &json!({"sp": "nobody", "name": "Unused"})
        ]
    );
    let marks: Vec<&Value> = of_kind(&built.records, "tape/mark")
        .iter()
        .map(|rec| &rec["e"]["body"]["t"])
        .collect();
    assert_eq!(marks, [&json!(1_000), &json!(5_000)]);
    let translations = of_kind(&built.records, "tape/tr");
    assert_eq!(translations[0]["e"]["body"]["lang"], "th");
    assert_eq!(translations[1]["e"]["body"]["lang"], "zh");
    assert_eq!(
        translations[1]["e"]["body"]["segs"][2],
        json!({"t": 2_000, "of": text_mark("Sentence 2."), "text": "[zh-Hans] Sentence 2."})
    );
}

#[test]
fn building_is_deterministic_and_indifferent_to_input_order() {
    let who = who();
    let forward = input(40);
    let mut shuffled = forward.clone();
    shuffled.sentences.reverse();
    shuffled.translations.reverse();
    for (_, lines) in &mut shuffled.translations {
        lines.reverse();
    }
    shuffled.speakers.reverse();
    let first = build_take(&who, &forward, NOW).unwrap();
    assert_eq!(first, build_take(&who, &forward, NOW).unwrap());
    assert_eq!(first, build_take(&who, &shuffled, NOW).unwrap());
    assert_ne!(
        first.take_id,
        build_take(&who, &forward, NOW + 1).unwrap().take_id
    );
}

#[test]
fn long_recordings_are_cut_into_records_readers_accept() {
    let count = 2 * SENTENCES_PER_RECORD + 50;
    let built = build_take(&who(), &input(count), NOW).unwrap();
    let per_text: Vec<usize> = of_kind(&built.records, "tape/text")
        .iter()
        .map(|rec| rec["e"]["body"]["segs"].as_array().unwrap().len())
        .collect();
    assert_eq!(per_text, [SENTENCES_PER_RECORD, SENTENCES_PER_RECORD, 50]);
    let translations = of_kind(&built.records, "tape/tr");
    assert!(translations
        .iter()
        .all(|rec| rec["e"]["body"]["segs"].as_array().unwrap().len() <= TRANSLATIONS_PER_RECORD));
    let thai: usize = translations
        .iter()
        .filter(|rec| rec["e"]["body"]["lang"] == "th")
        .map(|rec| rec["e"]["body"]["segs"].as_array().unwrap().len())
        .sum();
    assert_eq!(thai, count);

    // Maximal sentences in a script that takes three bytes a unit: no record
    // may grow past what a single post can carry.
    let mut heavy = input(0);
    heavy.sentences = (0..400)
        .map(|n| sentence(n, "", &"ก".repeat(SENTENCE_MAX)))
        .collect();
    heavy.translations.clear();
    let built = build_take(&who(), &heavy, NOW).unwrap();
    for rec in &built.records {
        assert!(serde_json::to_vec(rec).unwrap().len() < 300_000);
    }
}

#[test]
fn text_is_trimmed_and_capped_where_readers_would_cut_it() {
    let mut odd = input(0);
    let long = format!("  {}😀tail  ", "x".repeat(SENTENCE_MAX - 1));
    odd.sentences = vec![
        sentence(0, "a", &long),
        sentence(10, "a", " \n "),
        sentence(20, "b", " kept "),
    ];
    odd.translations = vec![(
        "en".into(),
        vec![
            Translated {
                t_ms: 0,
                source_text: long.clone(),
                text: " translated ".into(),
            },
            Translated {
                t_ms: 20,
                source_text: "an older wording".into(),
                text: "stale".into(),
            },
            Translated {
                t_ms: 20,
                source_text: "kept".into(),
                text: "  ".into(),
            },
        ],
    )];
    odd.title = format!(" {} ", "t".repeat(80));
    let built = build_take(&who(), &odd, NOW).unwrap();
    let segs = of_kind(&built.records, "tape/text")[0]["e"]["body"]["segs"]
        .as_array()
        .unwrap()
        .clone();
    // The pair that would straddle the cap is left out whole; the blank sentence is not published.
    assert_eq!(segs.len(), 2);
    let cut = "x".repeat(SENTENCE_MAX - 1);
    assert_eq!(segs[0]["text"], cut.as_str());
    assert_eq!(
        segs[1],
        json!({"t": 20, "d": 900, "sp": "b", "text": "kept"})
    );
    let translated = &of_kind(&built.records, "tape/tr")[0]["e"]["body"]["segs"];
    // The mark is of the sentence as published, so readers see "translated", not "stale".
    assert_eq!(
        translated[0],
        json!({"t": 0, "of": text_mark(&cut), "text": "translated"})
    );
    // A translation of older wording is published as such; an empty one is not.
    assert_eq!(
        translated[1],
        json!({"t": 20, "of": text_mark("an older wording"), "text": "stale"})
    );
    assert_eq!(
        of_kind(&built.records, "arc/block")[0]["e"]["body"]["title"],
        "t".repeat(60).as_str()
    );
}

#[test]
fn input_that_would_mislead_readers_is_refused() {
    let who = who();
    let refuse = |change: fn(&mut TakeInput)| {
        let mut input = input(3);
        change(&mut input);
        build_take(&who, &input, NOW).is_err()
    };
    assert!(
        refuse(|i| i.sentences[1].t_ms = 0),
        "two sentences at one time"
    );
    assert!(refuse(|i| i.sentences[0].t_ms = -1));
    assert!(refuse(|i| i.event_id = "not an event".into()));
    assert!(refuse(|i| i.channel_ids = vec!["short".into()]));
    assert!(refuse(|i| i.duration_ms = -1));
    assert!(refuse(|i| i.started_ms = -1));
    assert!(refuse(|i| i.marks_ms = vec![-5]));
    assert!(refuse(|i| i.translations[0].0 = "simplified chinese".into()));
    assert!(
        refuse(|i| i.translations[0].1[0].t_ms = 123_456),
        "translation of no sentence"
    );
    assert!(!refuse(|_| {}));
}

#[test]
fn records_are_divided_between_tags_as_the_citys_apps_divide_them() {
    let built = build_take(&who(), &input(3), NOW).unwrap();
    let event_tag = format!("ev:{}", "ab".repeat(8));
    let for_event = for_tag(&event_tag, &built.records);
    // The event's tag: everything but the placement into another channel.
    assert_eq!(for_event.len(), built.records.len() - 1);
    assert!(for_event
        .iter()
        .all(|rec| rec["e"]["type"] != "arc/connect" || rec["e"]["links"][0] == "ab".repeat(32)));
    // The city's tag: the archive item and both placements, none of the transcript.
    let for_city = for_tag("polis:0123456789abcdef", &built.records);
    assert_eq!(
        kinds(&for_city),
        ["arc/block", "arc/connect", "arc/connect"]
    );
    assert_eq!(
        for_tag("other:tag", &built.records).len(),
        built.records.len()
    );
}

#[test]
fn batches_carry_the_card_and_stay_under_the_limit() {
    let who = who();
    let card = vec![who.inception().clone()];
    let built = build_take(&who, &input(600), NOW).unwrap();
    let whole = batches(&card, &built.records, 1024 * 1024);
    assert_eq!(whole.len(), 1);
    assert_eq!(whole[0].len(), built.records.len() + 1);

    let limit = 40_000;
    let parts = batches(&card, &built.records, limit);
    assert!(parts.len() > 2);
    let mut rejoined = Vec::new();
    for part in &parts {
        assert_eq!(&part[0], who.inception());
        assert!(serde_json::to_vec(part).unwrap().len() <= limit);
        rejoined.extend(part[1..].iter().cloned());
    }
    // Nothing lost, nothing repeated, order kept.
    assert_eq!(rejoined, built.records);

    // A card repeated among the records is sent once; nothing to send is no batch.
    let mut with_card = card.clone();
    with_card.extend(built.records[..2].iter().cloned());
    assert_eq!(batches(&card, &with_card, limit), vec![with_card.clone()]);
    assert!(batches(&card, &[], limit).is_empty());
    assert!(batches(&card, &card, limit).is_empty());
    // A record too large for any batch still goes out, alone.
    let tiny = batches(&card, &built.records[..2], 10);
    assert_eq!(tiny.iter().map(Vec::len).collect::<Vec<_>>(), [2, 2]);
}

#[test]
fn corrections_and_withdrawal() {
    let who = who();
    let take_id = "ef".repeat(32);
    let fixes = [
        Correction {
            t_ms: 2_000,
            text: " Corrected. ".into(),
        },
        Correction {
            t_ms: 0,
            text: "".into(),
        },
    ];
    let retranslated = vec![(
        "zh-Hans".to_string(),
        vec![Translated {
            t_ms: 2_000,
            source_text: "Corrected.".into(),
            text: "更正。".into(),
        }],
    )];
    let update = build_update(&who, &take_id, &fixes, &retranslated, NOW).unwrap();
    assert_eq!(kinds(&update), ["tape/fix", "tape/fix", "tape/tr"]);
    assert!(update.iter().all(record::verify));
    assert_eq!(update[0]["e"]["deps"], json!([take_id]));
    assert_eq!(update[0]["e"]["body"], json!({"t": 0, "text": ""}));
    assert_eq!(
        update[1]["e"]["body"],
        json!({"t": 2_000, "text": "Corrected."})
    );
    assert_eq!(
        update[2]["e"]["body"],
        json!({"lang": "zh", "segs": [{"t": 2_000, "of": text_mark("Corrected."), "text": "更正。"}]})
    );
    assert!(update
        .iter()
        .all(|rec| rec["e"]["links"] == json!([take_id])));
    assert!(build_update(&who, &take_id, &[], &[], NOW)
        .unwrap()
        .is_empty());
    assert!(build_update(&who, "nope", &fixes, &[], NOW).is_err());

    let block_id = "12".repeat(32);
    let withdraw = build_withdraw(&who, &block_id, NOW).unwrap();
    assert_eq!(withdraw.len(), 1);
    assert!(record::verify(&withdraw[0]));
    assert_eq!(withdraw[0]["e"]["type"], "arc/mark");
    assert_eq!(withdraw[0]["e"]["body"], json!({"to": "drop"}));
    assert_eq!(withdraw[0]["e"]["links"], json!([block_id]));
    assert!(build_withdraw(&who, "nope", NOW).is_err());
}
