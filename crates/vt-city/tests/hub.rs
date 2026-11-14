//! `Hub` against a stand-in server on this machine: what is asked for, in
//! which words, and what is made of each answer. No city is contacted.

use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use vt_city::hub::{city_tag, event_tag, file_name, Hub, PostOutcome, FILE_MAX_BYTES};
use vt_city::identity::Identity;
use vt_city::{record, CityError};

type Seen = Arc<Mutex<Vec<(String, String)>>>;

/// Serves one canned answer per request, chosen by method and target, and
/// remembers what was asked.
async fn serve(
    answer: impl Fn(&str, &str, &str) -> (u16, String) + Send + Sync + 'static,
) -> (Hub, Seen) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen: Seen = Arc::default();
    let log = seen.clone();
    let answer = Arc::new(answer);
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let (log, answer) = (log.clone(), answer.clone());
            tokio::spawn(async move {
                let Some((head, body)) = read_request(&mut socket).await else {
                    return;
                };
                let mut words = head.split_whitespace();
                let (method, target) = (words.next().unwrap_or(""), words.next().unwrap_or(""));
                let body = String::from_utf8_lossy(&body).to_string();
                log.lock()
                    .unwrap()
                    .push((format!("{method} {target}"), body.clone()));
                let (status, reply) = answer(method, target, &body);
                let response = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                    reply.len()
                );
                let _ = socket.write_all(response.as_bytes()).await;
            });
        }
    });
    (Hub::new(&base, reqwest::Client::new()).unwrap(), seen)
}

/// One whole request: its head as sent, and its body to the stated length.
async fn read_request(socket: &mut TcpStream) -> Option<(String, Vec<u8>)> {
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    let (head_end, length) = loop {
        let read = socket.read(&mut chunk).await.unwrap_or(0);
        if read == 0 {
            return None;
        }
        bytes.extend_from_slice(&chunk[..read]);
        if let Some(at) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&bytes[..at]).to_lowercase();
            let length = head
                .lines()
                .find_map(|line| line.strip_prefix("content-length:"))
                .and_then(|value| value.trim().parse::<usize>().ok())
                .unwrap_or(0);
            break (at + 4, length);
        }
    };
    while bytes.len() < head_end + length {
        let read = socket.read(&mut chunk).await.unwrap_or(0);
        if read == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..read]);
    }
    let head = String::from_utf8_lossy(&bytes[..head_end]).to_string();
    Some((head, bytes[head_end..].to_vec()))
}

/// What the file store was asked: the request line, its headers in lower
/// case, and the bytes that came with it.
struct FileAsk {
    line: String,
    head: String,
    body: Vec<u8>,
}

/// A stand-in for the file store: one status per request, with any extra
/// header lines, and a record of every request in full.
async fn serve_files(
    answer: impl Fn(&str) -> (u16, &'static str) + Send + Sync + 'static,
) -> (Hub, Arc<Mutex<Vec<FileAsk>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen: Arc<Mutex<Vec<FileAsk>>> = Arc::default();
    let log = seen.clone();
    let answer = Arc::new(answer);
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let (log, answer) = (log.clone(), answer.clone());
            tokio::spawn(async move {
                let Some((head, body)) = read_request(&mut socket).await else {
                    return;
                };
                let line = head.lines().next().unwrap_or("").to_string();
                let line = line.trim_end_matches(" HTTP/1.1").to_string();
                let (status, headers) = answer(&line);
                log.lock().unwrap().push(FileAsk {
                    line,
                    head: head.to_lowercase(),
                    body,
                });
                let response = format!(
                    "HTTP/1.1 {status} X\r\n{headers}Content-Length: 0\r\nConnection: close\r\n\r\n"
                );
                let _ = socket.write_all(response.as_bytes()).await;
            });
        }
    });
    (Hub::new(&base, reqwest::Client::new()).unwrap(), seen)
}

fn asked(seen: &Seen) -> Vec<String> {
    seen.lock()
        .unwrap()
        .iter()
        .map(|(line, _)| line.clone())
        .collect()
}

fn person() -> Identity {
    let fixtures: Value = serde_json::from_str(include_str!("fixtures/identity.json")).unwrap();
    Identity::from_key_string(fixtures["people"][0]["key_string"].as_str().unwrap()).unwrap()
}

fn moved() -> (Identity, Value) {
    let fixtures: Value = serde_json::from_str(include_str!("fixtures/identity.json")).unwrap();
    let (identity, _) =
        Identity::from_link_payload(&json!({ "v2": fixtures["migrated"]["bundle"] })).unwrap();
    // The fixture's calendar carries this person's real id/did record.
    let calendar: Value = serde_json::from_str(include_str!("fixtures/calendar.json")).unwrap();
    let log = calendar["recs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|rec| rec["e"]["type"] == "id/did" && record::verify(rec))
        .unwrap()
        .clone();
    (identity, log)
}

const CITY: &str = "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00";

#[tokio::test]
async fn the_door_names_the_city_this_address_opens_into() {
    let city =
        json!({"id": CITY, "name": "Harbour Town", "about": "", "slug": "harbour", "members": 42});
    for (door, expect) in [
        (
            json!({"here": city, "home": null, "cities": []}),
            Some(("Harbour Town", 42)),
        ),
        (
            json!({"here": null, "home": city, "cities": []}),
            Some(("Harbour Town", 42)),
        ),
        (json!({"here": null, "home": null, "cities": [city]}), None),
        (
            json!({"here": {"id": "not-a-city", "name": "x", "members": 1}}),
            None,
        ),
    ] {
        let doc =
            json!({"sibian": 1, "server": "https://city.example", "door": door, "extra": [1, 2]})
                .to_string();
        let (hub, seen) = serve(move |_, _, _| (200, doc.clone())).await;
        let found = hub.door().await.unwrap();
        assert_eq!(found.server, "https://city.example");
        assert_eq!(
            found
                .city
                .as_ref()
                .map(|city| (city.name.as_str(), city.members)),
            expect
        );
        assert_eq!(asked(&seen), ["GET /.well-known/sibian"]);
    }
}

#[tokio::test]
async fn a_relay_poll_returns_messages_and_where_to_ask_next() {
    let (hub, seen) = serve(|_, target, _| {
        if target.ends_with("since=0") {
            (
                200,
                json!({"msgs": [{"t": "hi", "pub": "x"}, 7], "n": 2}).to_string(),
            )
        } else {
            (200, json!({"msgs": [], "n": 0}).to_string())
        }
    })
    .await;
    let room = "0f".repeat(16);
    let (msgs, n) = hub.relay_get(&room, 0).await.unwrap();
    assert_eq!((msgs.len(), n), (2, 2));
    // A room the server has forgotten answers zero; the position does not rewind.
    assert_eq!(hub.relay_get(&room, 2).await.unwrap().1, 2);
    assert_eq!(
        asked(&seen),
        [
            format!("GET /relay/{room}?since=0"),
            format!("GET /relay/{room}?since=2")
        ]
    );
    assert!(hub.relay_get("../hub/x", 0).await.is_err());
    assert!(hub.relay_get("", 0).await.is_err());
}

#[tokio::test]
async fn a_tag_is_read_to_the_end_page_by_page() {
    let rec = |kind: &str| json!({"e": {"type": kind}});
    let (a, b, c) = (rec("ev/event"), rec("ev/edit"), rec("id/inception"));
    let pages = [
        json!({"recs": [a, b], "n": 2, "more": true, "te": "k1"}).to_string(),
        json!({"recs": [c], "n": 3, "e": "x"}).to_string(),
    ];
    let (hub, seen) =
        serve(move |_, target, _| (200, pages[usize::from(target.contains("since=2"))].clone()))
            .await;
    let tag = event_tag(&"ab".repeat(32));
    let recs = hub
        .tag_get(&tag, &["ev", "id/inception"], &[])
        .await
        .unwrap();
    assert_eq!(recs, [a, b, c]);
    assert_eq!(
        asked(&seen),
        [
            "GET /hub/ev%3Aabababababababab?since=0&wait=0&kinds=ev,id/inception",
            "GET /hub/ev%3Aabababababababab?since=2&wait=0&kinds=ev,id/inception",
        ]
    );
    // What the server would silently ignore is refused before it is sent.
    assert!(hub.tag_get(&tag, &["Ev"], &[]).await.is_err());
    assert!(hub.tag_get("ev:with space", &[], &[]).await.is_err());
    assert!(hub.tag_get(&tag, &[], &["short"]).await.is_err());
    assert_eq!(asked(&seen).len(), 2);
}

#[tokio::test]
async fn a_tag_renumbered_mid_read_is_read_again_from_the_start() {
    let calls = Arc::new(Mutex::new(0));
    let counter = calls.clone();
    let (hub, _) = serve(move |_, target, _| {
        let mut call = counter.lock().unwrap();
        *call += 1;
        let page = match (*call, target.contains("since=0")) {
            (1, true) => json!({"recs": [{"e": {"type": "old"}}], "n": 5, "more": true}),
            (2, false) => json!({"recs": [], "n": 0, "more": true}),
            (3, true) => json!({"recs": [{"e": {"type": "new"}}], "n": 1}),
            other => panic!("unexpected request {other:?}"),
        };
        (200, page.to_string())
    })
    .await;
    let recs = hub
        .tag_get("polis:c0ffee00c0ffee00", &[], &[])
        .await
        .unwrap();
    assert_eq!(recs, [json!({"e": {"type": "new"}})]);

    // A server that never finishes is given up on, not followed forever.
    let (stuck, _) =
        serve(|_, _, _| (200, json!({"recs": [], "n": 0, "more": true}).to_string())).await;
    assert!(matches!(
        stuck.tag_get("polis:c0ffee00c0ffee00", &[], &[]).await,
        Err(CityError::Protocol(_))
    ));
}

#[tokio::test]
async fn asking_about_people_filters_types_locally() {
    let who = person();
    let page = json!({"recs": [who.inception(), {"e": {"type": "polis/admit"}}, {"e": {"type": "id/profile"}}], "te": "k"}).to_string();
    let (hub, seen) = serve(move |_, _, _| (200, page.clone())).await;
    let all = hub
        .tag_get(&city_tag(CITY), &[], &[who.id()])
        .await
        .unwrap();
    assert_eq!(all.len(), 3);
    let ids = hub
        .tag_get(&city_tag(CITY), &["id"], &[who.id()])
        .await
        .unwrap();
    assert_eq!(ids.len(), 2);
    assert_eq!(
        asked(&seen)[0],
        format!("GET /hub/polis%3Ac0ffee00c0ffee00?who={}", who.id())
    );
}

#[tokio::test]
async fn posting_reports_what_was_kept_and_what_was_turned_away() {
    let (hub, seen) = serve(|method, target, body| {
        assert_eq!(method, "POST");
        let recs: Vec<Value> = serde_json::from_str(body).unwrap();
        if target.contains("polis") {
            (
                200,
                json!({"took": recs.len() - 1, "n": 9, "refused": ["zSignature"]}).to_string(),
            )
        } else {
            (
                200,
                json!({"took": recs.len(), "n": 9, "log": {"size": 1}}).to_string(),
            )
        }
    })
    .await;
    let who = person();
    let recs = vec![who.inception().clone(), json!({"e": {"type": "x"}})];
    let kept = hub
        .tag_post(&event_tag(&"ab".repeat(32)), &recs)
        .await
        .unwrap();
    assert_eq!(
        kept,
        PostOutcome {
            took: 2,
            refused: vec![]
        }
    );
    assert_eq!(kept.accepted(), Ok(2));
    let partly = hub.tag_post(&city_tag(CITY), &recs).await.unwrap();
    assert_eq!(partly.refused, ["zSignature"]);
    assert_eq!(partly.accepted(), Err(CityError::Refused));
    {
        let sent = seen.lock().unwrap();
        assert_eq!(sent[0].0, "POST /hub/ev%3Aabababababababab");
        assert_eq!(
            serde_json::from_str::<Vec<Value>>(&sent[0].1).unwrap(),
            recs
        );
    }

    // Larger than the server accepts: refused here, never sent.
    let huge = vec![json!({"e": {"body": "x".repeat(1024 * 1024)}})];
    assert!(matches!(
        hub.tag_post("ev:abababababababab", &huge).await,
        Err(CityError::Malformed(_))
    ));
    assert_eq!(asked(&seen).len(), 2);
}

#[tokio::test]
async fn failures_are_told_apart() {
    let (refusing, _) = serve(|_, _, _| {
        (
            413,
            json!({"type": "/ns/err#too-big", "status": 413}).to_string(),
        )
    })
    .await;
    assert_eq!(
        refusing.tag_post("ev:abababababababab", &[]).await,
        Err(CityError::Http { status: 413 })
    );
    assert_eq!(refusing.door().await, Err(CityError::Http { status: 413 }));
    let (babbling, _) = serve(|_, _, _| (200, "<html>not json</html>".to_string())).await;
    assert!(matches!(babbling.door().await, Err(CityError::Protocol(_))));
    assert!(matches!(
        babbling.tag_get("ev:abababababababab", &[], &[]).await,
        Err(CityError::Protocol(_))
    ));

    // Nothing listens here: bind a port, then let it go.
    let gone = TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap();
    let nobody = Hub::new(&format!("http://{gone}"), reqwest::Client::new()).unwrap();
    assert_eq!(nobody.door().await, Err(CityError::Offline));
    assert_eq!(
        nobody.tag_post("ev:abababababababab", &[]).await,
        Err(CityError::Offline)
    );
    // The error a caller logs says nothing of where or with what.
    assert_eq!(
        CityError::Offline.to_string(),
        "the city could not be reached"
    );
}

#[tokio::test]
async fn roles_are_read_from_the_citys_credentials() {
    let who = person();
    let credential = |role: &str, polis: &str| {
        json!({"type": ["VerifiableCredential", "SibianCityRole"], "issuer": {"id": "did:webvh:x"},
               "credentialSubject": {"id": "did:key:z", "role": role, "city": {"id": "did:webvh:x", "name": "Harbour Town", "polis": polis}},
               "proof": {"proofValue": "z"}})
    };
    let other_city = "c0ffee00c0ffee00".to_string() + &"1".repeat(48);
    let reply = json!({"credentials": [credential("resident", CITY), credential("steward", CITY), credential("resident", CITY),
                                       credential("founder", &other_city), {"credentialSubject": 5}]}).to_string();
    let (hub, seen) = serve(move |_, _, _| (200, reply.clone())).await;
    assert_eq!(
        hub.roles(CITY, who.id()).await.unwrap(),
        ["resident", "coordinator"]
    );
    assert_eq!(
        asked(&seen),
        [format!("GET /p/c0ffee00c0ffee00/vc?id={}", who.id())]
    );
    assert!(hub.roles("short", who.id()).await.is_err());

    let (empty, _) = serve(|_, _, _| (200, json!({"credentials": []}).to_string())).await;
    assert!(empty.roles(CITY, who.id()).await.unwrap().is_empty());
    let (absent, _) = serve(|_, _, _| (404, String::new())).await;
    assert_eq!(
        absent.roles(CITY, who.id()).await,
        Err(CityError::Http { status: 404 })
    );
}

#[tokio::test]
async fn a_card_starts_with_the_inception_and_adds_what_readers_need() {
    // Someone who signs with the key that opened their account: inception, then profile.
    let who = person();
    let profile = |at: i64, name: &str| {
        record::make(
            &who,
            "id/profile",
            json!({"name": name}),
            &[],
            &[who.id().to_string()],
            at,
        )
        .unwrap()
        .rec
    };
    let (old, new) = (profile(1_000, "Ada"), profile(2_000, "Ada of the Garden"));
    let mut forged = profile(3_000, "Not Ada");
    forged["e"]["body"]["name"] = json!("Changed after signing");
    let page = json!({"recs": [new, old, forged, who.inception(), {"e": {"type": "polis/admit", "by": "x"}}]}).to_string();
    let (hub, seen) = serve(move |_, _, _| (200, page.clone())).await;
    let card = hub.card(CITY, &who).await.unwrap();
    assert_eq!(card, [who.inception().clone(), new.clone()]);
    assert_eq!(
        asked(&seen).len(),
        1,
        "no DID log is looked for when none is needed"
    );

    // Someone who moved: the DID log goes right after the inception. The city
    // tag does not hold it here, so the person's own tag is asked.
    let (moved, log) = moved();
    let own_tag = format!("/hub/me%3A{}", &moved.id()[..16]);
    let reply = json!({"recs": [log], "n": 1}).to_string();
    let (hub, seen) = serve(move |_, target, _| {
        if target.starts_with("/hub/me%3A") {
            (200, reply.clone())
        } else {
            (200, json!({"recs": []}).to_string())
        }
    })
    .await;
    let card = hub.card(CITY, &moved).await.unwrap();
    assert_eq!(card, [moved.inception().clone(), log.clone()]);
    assert_eq!(
        asked(&seen)[1],
        format!("GET {own_tag}?since=0&wait=0&kinds=id/did")
    );
}

#[tokio::test]
async fn a_file_is_asked_after_by_its_first_byte() {
    let name = file_name(b"part zero");
    let (has, seen) = serve_files(|_| (206, "Content-Range: bytes 0-0/9\r\n")).await;
    assert_eq!(has.file_exists(&name).await, Ok(true));
    {
        let asks = seen.lock().unwrap();
        assert_eq!(asks.len(), 1);
        assert_eq!(asks[0].line, format!("GET /files/{name}"));
        assert!(asks[0].head.contains("range: bytes=0-0"));
    }
    // A server that ignores the range and answers with the whole file has it too.
    let (whole, _) = serve_files(|_| (200, "")).await;
    assert_eq!(whole.file_exists(&name).await, Ok(true));
    let (lacks, _) = serve_files(|_| (404, "")).await;
    assert_eq!(lacks.file_exists(&name).await, Ok(false));
    // Anything else is not an answer to the question.
    let (broken, _) = serve_files(|_| (502, "")).await;
    assert_eq!(
        broken.file_exists(&name).await,
        Err(CityError::Http { status: 502 })
    );
    // A name that is not a fingerprint is never put in an address.
    let (hub, seen) = serve_files(|_| (200, "")).await;
    for bad in ["", "abc", "../hub/ev%3Aabababababababab", &"AB".repeat(32)] {
        assert!(matches!(
            hub.file_exists(bad).await,
            Err(CityError::Malformed(_))
        ));
    }
    assert!(seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_file_is_uploaded_whole_with_its_length_stated() {
    let bytes: Vec<u8> = (0..70_000u32).map(|n| (n % 251) as u8).collect();
    let name = file_name(&bytes);
    let (hub, seen) = serve_files(|_| (200, "")).await;
    assert_eq!(hub.file_put(&name, bytes.clone()).await, Ok(()));
    let asks = seen.lock().unwrap();
    assert_eq!(asks.len(), 1);
    assert_eq!(asks[0].line, format!("PUT /files/{name}"));
    assert!(asks[0].head.contains("content-length: 70000"));
    // The server takes no chunked uploads and no credential.
    assert!(!asks[0].head.contains("transfer-encoding"));
    assert!(!asks[0].head.contains("authorization"));
    assert!(!asks[0].head.contains("cookie"));
    assert_eq!(asks[0].body, bytes);
}

#[tokio::test]
async fn what_the_server_would_refuse_is_never_uploaded() {
    let (hub, seen) = serve_files(|_| (200, "")).await;
    let bytes = b"a part".to_vec();
    assert!(matches!(
        hub.file_put("not a name", bytes.clone()).await,
        Err(CityError::Malformed(_))
    ));
    // Bytes that are not the file the name promises: the server would take
    // them all and then answer 400.
    assert!(matches!(
        hub.file_put(&file_name(b"another part"), bytes).await,
        Err(CityError::Malformed(_))
    ));
    assert!(matches!(
        hub.file_put(&file_name(b""), Vec::new()).await,
        Err(CityError::Malformed(_))
    ));
    let large = vec![0u8; FILE_MAX_BYTES as usize + 1];
    assert_eq!(
        hub.file_put(&file_name(&large), large).await,
        Err(CityError::FileTooBig)
    );
    assert!(seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn each_refusal_of_a_file_is_told_apart() {
    let bytes = b"a part".to_vec();
    let name = file_name(&bytes);
    for (status, headers, expect) in [
        (403, "", CityError::Unclaimed),
        (413, "", CityError::FileTooBig),
        (
            429,
            "Retry-After: 4711\r\n",
            CityError::DailyCap {
                retry_after_secs: Some(4711),
            },
        ),
        (
            429,
            "",
            CityError::DailyCap {
                retry_after_secs: None,
            },
        ),
        (
            429,
            "Retry-After: Fri, 13 Nov 2026 00:00:00 GMT\r\n",
            CityError::DailyCap {
                retry_after_secs: None,
            },
        ),
        (507, "", CityError::ServerFull),
        (400, "", CityError::BadFile),
        (500, "", CityError::Http { status: 500 }),
        (404, "", CityError::Http { status: 404 }),
    ] {
        let (hub, _) = serve_files(move |_| (status, headers)).await;
        assert_eq!(
            hub.file_put(&name, bytes.clone()).await,
            Err(expect),
            "{status} {headers}"
        );
    }

    // Nothing listens here: bind a port, then let it go.
    let gone = TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap();
    let nobody = Hub::new(&format!("http://{gone}"), reqwest::Client::new()).unwrap();
    assert_eq!(nobody.file_put(&name, bytes).await, Err(CityError::Offline));
    assert_eq!(nobody.file_exists(&name).await, Err(CityError::Offline));
}
