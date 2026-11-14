//! The whole path against a city server on this machine: sign in by the
//! device-link exchange, find the city and an event, publish the sample
//! recording, correct one sentence, then add the recording's audio a part at
//! a time.
//!
//! Driven by `tools/city-interop/e2e.mjs`, which starts the server, plays the
//! already-signed-in device, and checks afterwards what the server holds.
//! Progress is printed as one JSON object per line.
//!
//!   CITY_BASE     the server, e.g. http://city.localhost:8765
//!   CITY_RESOLVE  optional `host=ip:port`, for a name only this test knows
//!   CITY_EVENT    the title of the event to publish to
//!   CITY_AUDIO    optional JSON list of parts to upload, each
//!                 `{ "path", "t0", "dur", "lv" }` — an encoded file and where
//!                 it sits on the recording's timeline
//!
//! It refuses to run against anything but this machine.

use std::net::SocketAddr;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use vt_city::calendar::{recording_tags, reduce_events, CITY_KINDS, KINDS};
use vt_city::channels::{may_put, reduce_channels};
use vt_city::hub::{
    city_tag, event_tag, file_name, Hub, POST_MAX_BYTES, ROLE_COORDINATOR, ROLE_RESIDENT,
};
use vt_city::link::{LinkSession, LinkStep};
use vt_city::publish::{
    batches, build_part, build_take, build_update, for_tag, PartInput, MIME_M4A,
};

#[path = "common/sample.rs"]
mod sample;

type Fallible<T> = Result<T, Box<dyn std::error::Error>>;

fn say(value: Value) {
    println!("{value}");
}

async fn post(hub: &Hub, tag: &str, card: &[Value], records: &[Value]) -> Fallible<Value> {
    let (mut took, mut refused) = (0, Vec::new());
    for batch in batches(card, &for_tag(tag, records), POST_MAX_BYTES) {
        let outcome = hub.tag_post(tag, &batch).await?;
        took += outcome.took;
        refused.extend(outcome.refused);
    }
    Ok(json!({ "tag": tag, "took": took, "refused": refused }))
}

#[tokio::main]
async fn main() -> Fallible<()> {
    let base = std::env::var("CITY_BASE")?;
    if !base.starts_with("http://") {
        return Err("this example only talks to a server on this machine".into());
    }
    let mut client = reqwest::Client::builder();
    if let Ok(pin) = std::env::var("CITY_RESOLVE") {
        let (host, addr) = pin.split_once('=').ok_or("CITY_RESOLVE is host=ip:port")?;
        let addr: SocketAddr = addr.parse()?;
        if !addr.ip().is_loopback() {
            return Err("this example only talks to a server on this machine".into());
        }
        client = client.resolve(host, addr);
    }
    let hub = Hub::new(&base, client.build()?)?;

    // Sign in: show the code, poll the relay, show the digits, take the identity.
    let mut session = LinkSession::new()?;
    say(json!({ "step": "code", "code": session.code() }));
    let mut shown = false;
    let (who, name) = loop {
        let (msgs, n) = hub.relay_get(session.room(), session.since()).await?;
        match session.absorb(&msgs, n)? {
            LinkStep::Waiting => {}
            LinkStep::Check(digits) => {
                if !shown {
                    say(json!({ "step": "check", "digits": digits }));
                    shown = true;
                }
            }
            LinkStep::Done { identity, name } => break (identity, name),
            LinkStep::Cancelled => return Err("the other device called it off".into()),
        }
    };
    say(
        json!({ "step": "signed-in", "id": who.id(), "name": name, "did_key": who.did_key(), "controller": who.controller() }),
    );

    // Which city, which events, which channels, and what this person may do.
    let door = hub.door().await?;
    let city = door.city.ok_or("this server opens into no city")?;
    let records = hub.tag_get(&city_tag(&city.id), CITY_KINDS, &[]).await?;
    let events = reduce_events(&records);
    let channels = reduce_channels(&records);
    let roles = hub.roles(&city.id, who.id()).await?;
    let resident = roles.iter().any(|role| role == ROLE_RESIDENT);
    let coordinator = roles.iter().any(|role| role == ROLE_COORDINATOR);
    let wanted = std::env::var("CITY_EVENT")?;
    let event = events
        .iter()
        .find(|event| event.title == wanted && event.involves(who.id()))
        .ok_or("the event is not on the city's calendar, or is not this person's")?;
    // The event's own tag tells the same story.
    let own = reduce_events(&hub.tag_get(&event_tag(&event.id), KINDS, &[]).await?);
    let open: Vec<String> = channels
        .iter()
        .filter(|channel| may_put(channel, who.id(), resident, coordinator))
        .map(|channel| channel.id.clone())
        .collect();
    say(json!({
        "step": "found", "server": door.server, "city": city.id, "city_name": city.name, "members": city.members,
        "roles": roles, "events": events.iter().map(|event| &event.title).collect::<Vec<_>>(),
        "event": event.id, "same_from_event_tag": own.first() == Some(event),
        "channels": channels.iter().map(|channel| &channel.title).collect::<Vec<_>>(), "may_put": open,
    }));

    // Publish, each tag getting what belongs on it, the card first.
    let now_ms = i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())?;
    let card = hub.card(&city.id, &who).await?;
    let built = build_take(
        &who,
        &sample::take(&event.id, &open, now_ms - 3_600_000),
        now_ms,
    )?;
    let tags = recording_tags(event, resident);
    let mut posted = Vec::new();
    for tag in &tags {
        posted.push(post(&hub, tag, &card, &built.records).await?);
    }
    // Posting again changes nothing: the server already has every record.
    let again = post(&hub, &tags[0], &card, &built.records).await?;
    say(json!({
        "step": "published", "take": built.take_id, "block": built.block_id, "records": built.records.len(),
        "card": card.iter().map(|rec| &rec["e"]["type"]).collect::<Vec<_>>(), "posted": posted, "again": again,
    }));

    // A correction and the translations made from it go to the event's tag.
    let mut update = build_update(
        &who,
        &built.take_id,
        &sample::correction(),
        &[],
        now_ms + 1_000,
    )?;
    update.extend(build_update(
        &who,
        &built.take_id,
        &[],
        &sample::retranslation(),
        now_ms + 2_000,
    )?);
    let corrected = post(&hub, &tags[0], &card, &update).await?;
    say(json!({ "step": "corrected", "posted": corrected, "expected": sample::expected() }));

    // The audio. For each part: the record that claims the file goes to the
    // event's tag — the take with it, as the server looks the claim up among
    // the records it holds — and only then the file.
    if let Ok(list) = std::env::var("CITY_AUDIO") {
        let parts: Vec<Value> = serde_json::from_str(&list)?;
        // Bytes no record claims are turned away.
        let stray = b"bytes nobody claimed".to_vec();
        let unclaimed = hub.file_put(&file_name(&stray), stray).await;
        let take = built.records[0].clone();
        let mut sent = Vec::new();
        for (n, part) in parts.iter().enumerate() {
            let bytes = std::fs::read(part["path"].as_str().ok_or("a part needs a path")?)?;
            let file = file_name(&bytes);
            let signed = build_part(
                &who,
                &PartInput {
                    take_id: built.take_id.clone(),
                    n: u32::try_from(n)?,
                    file: file.clone(),
                    size: bytes.len() as u64,
                    t0_ms: part["t0"].as_i64().ok_or("a part needs a start")?,
                    dur_ms: part["dur"].as_i64().ok_or("a part needs a length")?,
                    mime: MIME_M4A.to_string(),
                    levels: part["lv"].as_str().unwrap_or("").to_string(),
                },
                now_ms + 10_000 + i64::try_from(n)?,
            )?;
            let before = hub.file_exists(&file).await?;
            // The file before its record: refused, and nothing is stored.
            let early = hub.file_put(&file, bytes.clone()).await;
            let posted = post(&hub, &tags[0], &card, &[take.clone(), signed.rec]).await?;
            hub.file_put(&file, bytes.clone()).await?;
            let after = hub.file_exists(&file).await?;
            // The same bytes again: accepted, nothing changes.
            let again = hub.file_put(&file, bytes).await;
            sent.push(json!({
                "n": n, "file": file, "before": before, "early": format!("{early:?}"),
                "posted": posted, "after": after, "again": format!("{again:?}"),
            }));
        }
        say(json!({ "step": "audio", "unclaimed": format!("{unclaimed:?}"), "parts": sent }));
    }
    Ok(())
}
