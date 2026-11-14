//! Prints, as JSON, everything this crate would sign for a sample recording,
//! so that the city's own code can be run over it
//! (`tools/city-interop/check-take.mjs`).
//!
//! The sample's audio is described too — two parts, and one of them a second
//! time with other bytes, as after an upload that never finished — together
//! with the limits this crate holds the city to, so that the check can read
//! the same numbers out of the city's own source.
//!
//! Reads one JSON object from standard input:
//! `{ "key": <recovery key> | "bundle": <handed-over v2 bundle>,
//!    "event_id", "channel_ids": [..], "now_ms", "started_ms",
//!    "link": { "scalar": <hex>, "peer": <public key> } }`.
//! Nothing is sent anywhere.

use std::io::Read;

use serde_json::{json, Value};
use vt_city::hub::{FILE_MAX_BYTES, UPLOAD_BYTES_PER_SEC, UPLOAD_GRACE_SECS};
use vt_city::identity::Identity;
use vt_city::link::{agree, seal_box, LinkKey};
use vt_city::publish::{
    batches, build_part, build_take, build_update, build_withdraw, for_tag, MIME_M4A,
    PART_LEVELS_MAX, PART_MIME_MAX, PART_MS,
};

#[path = "common/sample.rs"]
mod sample;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text)?;
    let ask: Value = serde_json::from_str(&text)?;
    let who = match ask.get("bundle") {
        Some(bundle) => Identity::from_link_payload(&json!({ "v2": bundle }))?.0,
        None => Identity::from_key_string(ask["key"].as_str().ok_or("no key")?)?,
    };
    let event_id = ask["event_id"].as_str().ok_or("no event")?;
    let channel_ids: Vec<String> = ask["channel_ids"]
        .as_array()
        .map(|ids| {
            ids.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let now_ms = ask["now_ms"].as_i64().ok_or("no time")?;
    let started_ms = ask["started_ms"].as_i64().unwrap_or(now_ms - 3_600_000);

    let built = build_take(
        &who,
        &sample::take(event_id, &channel_ids, started_ms),
        now_ms,
    )?;
    let fix = build_update(
        &who,
        &built.take_id,
        &sample::correction(),
        &[],
        now_ms + 60_000,
    )?;
    let retranslate = build_update(
        &who,
        &built.take_id,
        &[],
        &sample::retranslation(),
        now_ms + 120_000,
    )?;
    let withdraw = build_withdraw(&who, &built.block_id, now_ms + 180_000)?;
    // The audio, a part at a time, some while after the text.
    let part_at = now_ms + 30_000;
    let parts = sample::parts(&built.take_id)
        .iter()
        .zip(0..)
        .map(|(part, step)| Ok(build_part(&who, part, part_at + step)?.rec))
        .collect::<Result<Vec<Value>, vt_city::CityError>>()?;
    // The second part exported again. The first export's record names a file
    // that never reached the city; the new one is dated just before it, so
    // that readers — who keep the first record they meet for a part — play
    // the file that exists.
    let part_again = build_part(&who, &sample::part_again(&built.take_id), part_at)?.rec;
    let card = vec![who.inception().clone()];
    let event_tag = vt_city::hub::event_tag(event_id);

    // A box sealed here for the city's code to open, when asked.
    let sealed = match ask.get("link") {
        Some(link) => {
            let scalar: [u8; 32] = hex::decode(link["scalar"].as_str().ok_or("no scalar")?)?
                .try_into()
                .map_err(|_| "scalar is not 32 bytes")?;
            let agreed = agree(
                &LinkKey::from_scalar(&scalar)?,
                link["peer"].as_str().ok_or("no peer")?,
            )?;
            json!({ "check": agreed.check, "box": seal_box(&agreed.key, &sample::expected())? })
        }
        None => Value::Null,
    };

    let out = json!({
        "id": who.id(),
        "did_key": who.did_key(),
        "controller": who.controller(),
        "inception": who.inception(),
        "expected": sample::expected(),
        "take_id": built.take_id,
        "block_id": built.block_id,
        "records": built.records,
        "for_event": for_tag(&event_tag, &built.records),
        "for_city": for_tag("polis:0000000000000000", &built.records),
        "batches": batches(&card, &built.records, 4_000),
        "fix": fix,
        "retranslate": retranslate,
        "withdraw": withdraw,
        "parts": parts,
        "part_again": part_again,
        "limits": {
            "file_max": FILE_MAX_BYTES, "part_ms": PART_MS, "mime": MIME_M4A,
            "levels_max": PART_LEVELS_MAX, "mime_max": PART_MIME_MAX,
            "upload_bytes_per_sec": UPLOAD_BYTES_PER_SEC, "upload_grace_secs": UPLOAD_GRACE_SECS,
        },
        "sealed": sealed,
    });
    println!("{}", serde_json::to_string(&out)?);
    Ok(())
}
