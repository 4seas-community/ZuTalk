//! A short, invented, trilingual recording: English and Thai spoken by two
//! people, every sentence translated into Chinese, each spoken language
//! translated into the other. Shared by the interop examples so that the
//! city-side checks know what to expect.

use serde_json::{json, Value};
use vt_city::publish::{Correction, PartInput, Sentence, TakeInput, Translated, MIME_M4A};

const LINES: [(i64, i64, &str, &str, &str, &str); 6] = [
    (
        0,
        3_800,
        "host",
        "Good morning, everyone. Welcome to the morning circle.",
        "th",
        "สวัสดีตอนเช้าทุกคน ยินดีต้อนรับสู่วงสนทนายามเช้า",
    ),
    (
        4_200,
        4_500,
        "host",
        "วันนี้เรามีแขกมาเล่าเรื่องสวนของชุมชน",
        "en",
        "Today we have a guest to tell us about the community garden.",
    ),
    (
        9_100,
        5_600,
        "guest",
        "Thanks. We planted the kitchen garden behind the library in spring.",
        "th",
        "ขอบคุณครับ เราปลูกสวนครัวไว้หลังห้องสมุดตั้งแต่ฤดูใบไม้ผลิ",
    ),
    (
        15_300,
        4_900,
        "guest",
        "ตอนนี้ผักโตเร็วมาก แต่ยังขาดคนรดน้ำ",
        "en",
        "The vegetables are growing fast now, but we are short of people to water them.",
    ),
    (
        21_000,
        2_700,
        "host",
        "Who waters it on weekends?",
        "th",
        "ใครรดน้ำในวันหยุดสุดสัปดาห์",
    ),
    (
        25_500,
        4_100,
        "guest",
        "ยังไม่มีใครรับหน้าที่นี้เลย",
        "en",
        "Nobody has taken that on yet.",
    ),
];

const CHINESE: [&str; 6] = [
    "大家早上好，欢迎来到晨间圆桌。",
    "今天有一位客人来讲讲社区菜园。",
    "谢谢。春天的时候，我们在图书馆后面种了一片菜园。",
    "现在菜长得很快，但浇水的人手不够。",
    "周末谁来浇水？",
    "还没有人接下这件事。",
];

/// The sentence that is corrected after publishing, and its new wording and
/// translations.
pub const FIXED_AT: i64 = 21_000;
pub const FIXED_TEXT: &str = "Who waters it on weekends and holidays?";
const FIXED_CHINESE: &str = "周末和节假日谁来浇水？";
const FIXED_THAI: &str = "ใครรดน้ำในวันหยุดสุดสัปดาห์และวันหยุดนักขัตฤกษ์";

pub fn take(event_id: &str, channel_ids: &[String], started_ms: i64) -> TakeInput {
    let line = |t_ms: i64, source: &str, text: &str| Translated {
        t_ms,
        source_text: source.to_string(),
        text: text.to_string(),
    };
    let other = |language: &str| -> Vec<Translated> {
        LINES
            .iter()
            .filter(|(.., into, _)| *into == language)
            .map(|(t_ms, _, _, text, _, translated)| line(*t_ms, text, translated))
            .collect()
    };
    TakeInput {
        event_id: event_id.to_string(),
        title: "Recording · Morning circle".to_string(),
        started_ms,
        duration_ms: 30_000,
        sentences: LINES
            .iter()
            .map(|(t_ms, d_ms, speaker, text, ..)| Sentence {
                t_ms: *t_ms,
                d_ms: *d_ms,
                speaker: speaker.to_string(),
                text: text.to_string(),
            })
            .collect(),
        translations: vec![
            (
                "zh-Hans".to_string(),
                LINES
                    .iter()
                    .zip(CHINESE)
                    .map(|((t_ms, _, _, text, ..), chinese)| line(*t_ms, text, chinese))
                    .collect(),
            ),
            ("en".to_string(), other("en")),
            ("th".to_string(), other("th")),
        ],
        speakers: vec![
            ("host".to_string(), "Ada".to_string()),
            ("guest".to_string(), "Ben".to_string()),
        ],
        channel_ids: channel_ids.to_vec(),
    }
}

/// The sample's audio as two invented parts: twenty seconds, then ten. The
/// files are named by a stand-in for their SHA-256; nothing here has bytes.
#[allow(dead_code)]
pub fn parts(take_id: &str) -> Vec<PartInput> {
    [
        (0, "a1", 161_803, 0, 20_000, "01234567899876543210"),
        (1, "b2", 80_902, 20_000, 10_000, "5550005550"),
    ]
    .into_iter()
    .map(|(n, digit, size, t0_ms, dur_ms, levels)| PartInput {
        take_id: take_id.to_string(),
        n,
        file: digit.repeat(32),
        size,
        t0_ms,
        dur_ms,
        mime: MIME_M4A.to_string(),
        levels: levels.to_string(),
    })
    .collect()
}

/// The second part again, exported a second time with other bytes.
#[allow(dead_code)]
pub fn part_again(take_id: &str) -> PartInput {
    PartInput {
        file: "c3".repeat(32),
        size: 80_911,
        ..parts(take_id).remove(1)
    }
}

pub fn correction() -> Vec<Correction> {
    vec![Correction {
        t_ms: FIXED_AT,
        text: FIXED_TEXT.to_string(),
    }]
}

/// Translations made from the corrected sentence.
pub fn retranslation() -> Vec<(String, Vec<Translated>)> {
    let line = |text: &str| Translated {
        t_ms: FIXED_AT,
        source_text: FIXED_TEXT.to_string(),
        text: text.to_string(),
    };
    vec![
        ("zh-Hans".to_string(), vec![line(FIXED_CHINESE)]),
        ("th".to_string(), vec![line(FIXED_THAI)]),
    ]
}

/// What the city's readers should make of the sample, in their vocabulary.
pub fn expected() -> Value {
    let by_language = |language: &str| -> Value {
        LINES
            .iter()
            .filter(|(.., into, _)| *into == language)
            .map(|(t_ms, .., translated)| (t_ms.to_string(), json!(translated)))
            .collect::<serde_json::Map<_, _>>()
            .into()
    };
    json!({
        "title": "Recording · Morning circle",
        "duration_ms": 30_000,
        "sentences": LINES.iter().map(|(t, d, speaker, text, ..)| json!({
            "t": t, "d": d, "sp": speaker, "text": text,
        })).collect::<Vec<_>>(),
        "names": {"host": "Ada", "guest": "Ben"},
        "parts": [
            {"n": 0, "file": "a1".repeat(32), "size": 161_803, "t0": 0, "dur": 20_000, "mime": "audio/mp4", "lv": "01234567899876543210"},
            {"n": 1, "file": "b2".repeat(32), "size": 80_902, "t0": 20_000, "dur": 10_000, "mime": "audio/mp4", "lv": "5550005550"},
        ],
        "part_again": {"n": 1, "file": "c3".repeat(32), "size": 80_911, "t0": 20_000, "dur": 10_000, "mime": "audio/mp4", "lv": "5550005550"},
        "languages": {
            "zh": LINES.iter().zip(CHINESE).map(|((t, ..), chinese)| (t.to_string(), json!(chinese))).collect::<serde_json::Map<_, _>>(),
            "en": by_language("en"),
            "th": by_language("th"),
        },
        "fixed": {"t": FIXED_AT, "text": FIXED_TEXT, "zh": FIXED_CHINESE, "th": FIXED_THAI},
    })
}
