//! 进程内的设备同步:几台「Mac」各起一个引擎,不走中继、不开 mDNS,直接拿对方
//! 的地址拨号。
//!
//! 文档用一个只增集合代替 Loro:版本就是整个集合,差量是对方没有的元素,合并是
//! 并集。它满足引擎需要的全部性质(可对账、可导出差量、合并幂等),又简单到
//! 测试失败时一眼看得出是引擎的问题。

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh_tickets::Ticket;
use sha2::{Digest, Sha256};
use vt_sync::{
    DeviceIdentity, DocId, DocumentStore, EndpointId, GroupId, Membership, PairError,
    PairRejection, PairingTicket, StoreError, SyncConfig, SyncEngine, VersionDigest,
};

#[derive(Default)]
struct SetStore {
    docs: Mutex<BTreeMap<DocId, BTreeSet<String>>>,
}

impl SetStore {
    fn add(&self, doc: &str, item: &str) {
        self.docs
            .lock()
            .unwrap()
            .entry(doc.into())
            .or_default()
            .insert(item.into());
    }

    fn items(&self, doc: &str) -> BTreeSet<String> {
        self.docs
            .lock()
            .unwrap()
            .get(doc)
            .cloned()
            .unwrap_or_default()
    }

    fn snapshot(&self) -> BTreeMap<DocId, BTreeSet<String>> {
        self.docs.lock().unwrap().clone()
    }
}

fn encode(items: &BTreeSet<String>) -> Vec<u8> {
    postcard::to_stdvec(items).unwrap()
}

impl DocumentStore for SetStore {
    fn summary(&self) -> Vec<(DocId, VersionDigest)> {
        let docs = self.docs.lock().unwrap();
        docs.iter()
            .map(|(doc, items)| (doc.clone(), Sha256::digest(encode(items)).into()))
            .collect()
    }

    fn digest(&self, doc: &DocId) -> Option<VersionDigest> {
        let docs = self.docs.lock().unwrap();
        docs.get(doc)
            .map(|items| Sha256::digest(encode(items)).into())
    }

    fn version(&self, doc: &DocId) -> Option<Vec<u8>> {
        self.docs.lock().unwrap().get(doc).map(encode)
    }

    fn updates_since(&self, doc: &DocId, from: &[u8]) -> Option<Vec<u8>> {
        let theirs: BTreeSet<String> = if from.is_empty() {
            BTreeSet::new()
        } else {
            postcard::from_bytes(from).ok()?
        };
        let docs = self.docs.lock().unwrap();
        let missing: BTreeSet<String> = docs.get(doc)?.difference(&theirs).cloned().collect();
        (!missing.is_empty()).then(|| encode(&missing))
    }

    fn apply(&self, doc: &DocId, update: &[u8]) -> Result<bool, StoreError> {
        let incoming: BTreeSet<String> =
            postcard::from_bytes(update).map_err(|e| StoreError::Rejected(e.to_string()))?;
        let mut docs = self.docs.lock().unwrap();
        let items = docs.entry(doc.clone()).or_default();
        let before = items.len();
        items.extend(incoming);
        Ok(items.len() > before)
    }

    fn accepts(&self, doc: &DocId) -> bool {
        doc == "library" || doc.starts_with("recording/")
    }
}

#[derive(Default)]
struct Roster {
    state: Mutex<(Option<GroupId>, BTreeSet<EndpointId>)>,
}

impl Membership for Roster {
    fn group(&self) -> Option<GroupId> {
        self.state.lock().unwrap().0
    }

    fn members(&self) -> Vec<EndpointId> {
        self.state.lock().unwrap().1.iter().copied().collect()
    }

    fn admit(&self, device: EndpointId, _name: &str) -> Result<GroupId, String> {
        let mut state = self.state.lock().unwrap();
        let group = *state.0.get_or_insert_with(GroupId::generate);
        state.1.insert(device);
        Ok(group)
    }

    fn join(&self, group: GroupId, inviter: EndpointId, _name: &str) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        state.0 = Some(group);
        state.1.insert(inviter);
        Ok(())
    }
}

struct Mac {
    identity: DeviceIdentity,
    store: Arc<SetStore>,
    roster: Arc<Roster>,
    engine: SyncEngine,
}

impl Mac {
    async fn start(name: &str) -> Self {
        Self::restart(
            name,
            DeviceIdentity::generate(),
            Arc::default(),
            Arc::default(),
            Duration::from_secs(60),
        )
        .await
    }

    async fn restart(
        name: &str,
        identity: DeviceIdentity,
        store: Arc<SetStore>,
        roster: Arc<Roster>,
        invite_ttl: Duration,
    ) -> Self {
        let config = SyncConfig {
            device_name: name.into(),
            invite_ttl,
            loopback_only: true,
            ..SyncConfig::default()
        };
        let engine = SyncEngine::start(identity.clone(), config, store.clone(), roster.clone())
            .await
            .expect("离线绑定应当成功");
        Self {
            identity,
            store,
            roster,
            engine,
        }
    }

    fn change(&self, doc: &str, item: &str) {
        self.store.add(doc, item);
        self.engine.notify_changed(&doc.to_string());
    }
}

async fn pair(inviter: &Mac, joiner: &Mac) {
    let ticket = inviter.engine.create_invite().await;
    let text = ticket.to_string();
    let started = std::time::Instant::now();
    let joined = match joiner.engine.join(&text.parse().unwrap()).await {
        Ok(joined) => joined,
        Err(e) => panic!(
            "配对失败 {e:?} 用时 {:?} 地址 {:?}",
            started.elapsed(),
            ticket.inviter
        ),
    };
    assert_eq!(joined.inviter, inviter.engine.device_id());
}

async fn eventually(what: &str, mut check: impl FnMut() -> bool) {
    for _ in 0..200 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("等了 10 秒还没有:{what}");
}

#[tokio::test(flavor = "multi_thread")]
async fn pairing_joins_the_group_and_both_libraries_converge() {
    let studio = Mac::start("工作室").await;
    let laptop = Mac::start("笔记本").await;
    studio.store.add("library", "主题:周会");
    studio.store.add("recording/a", "第一句");
    laptop.store.add("library", "主题:访谈");
    laptop.store.add("recording/b", "另一场");
    // 清单外的文档不该被拉过去。
    laptop.store.add("scratch/x", "本机草稿");

    let ticket = studio.engine.create_invite().await;
    let joined = laptop
        .engine
        .join(&ticket.to_string().parse().unwrap())
        .await
        .expect("配对应当成功");
    assert_eq!(joined.inviter, studio.engine.device_id());
    assert_eq!(joined.inviter_name, "工作室");
    assert_eq!(studio.roster.group(), laptop.roster.group());
    assert!(studio.roster.is_member(&laptop.engine.device_id()));

    eventually("两台的文档一致", || {
        studio.store.items("library") == laptop.store.items("library")
            && studio.store.items("recording/b") == laptop.store.items("recording/b")
            && laptop.store.items("recording/a") == studio.store.items("recording/a")
    })
    .await;
    assert_eq!(studio.store.items("library").len(), 2);
    assert!(studio.store.items("scratch/x").is_empty());

    eventually("双方都记下了同步时间", || {
        [&studio, &laptop].iter().all(|mac| {
            let peers = mac.engine.peers();
            peers.len() == 1 && peers[0].connected && peers[0].last_synced_unix_ms.is_some()
        })
    })
    .await;

    studio.engine.shutdown().await;
    laptop.engine.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_reaches_the_other_mac_without_waiting_for_the_next_round() {
    let a = Mac::start("甲").await;
    let b = Mac::start("乙").await;
    pair(&a, &b).await;
    eventually("连上", || {
        a.engine.peers().first().is_some_and(|p| p.connected)
    })
    .await;

    // 反熵间隔是 60 秒;10 秒内到达只能是改动通知起的作用。
    for i in 0..20 {
        a.change("recording/live", &format!("甲的第 {i} 句"));
        b.change("recording/live", &format!("乙的第 {i} 句"));
    }
    eventually("两边都有 40 句", || {
        a.store.items("recording/live").len() == 40 && b.store.items("recording/live").len() == 40
    })
    .await;

    a.engine.shutdown().await;
    b.engine.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_is_passed_on_to_a_mac_that_only_the_middle_one_knows() {
    let a = Mac::start("甲").await;
    let b = Mac::start("乙").await;
    let c = Mac::start("丙").await;
    pair(&b, &a).await;
    pair(&b, &c).await;
    // 甲和丙互不认识(名单还没同步过来),只有乙在中间。
    assert!(!a.roster.is_member(&c.engine.device_id()));
    eventually("乙连着两台", || {
        b.engine.peers().iter().filter(|p| p.connected).count() == 2
    })
    .await;

    a.change("library", "甲新建的主题");
    eventually("丙经乙收到", || {
        c.store.items("library").contains("甲新建的主题")
    })
    .await;

    for mac in [a, b, c] {
        mac.engine.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_large_document_crosses_in_chunks() {
    let a = Mac::start("甲").await;
    let b = Mac::start("乙").await;
    // 约 3 MiB,要切成好几块。
    for i in 0..3000 {
        a.store
            .add("recording/long", &format!("{i:04}{}", "字".repeat(340)));
    }
    pair(&a, &b).await;
    eventually("大文档到齐", || {
        b.store.items("recording/long").len() == 3000
    })
    .await;
    assert_eq!(a.store.snapshot(), b.store.snapshot());

    a.engine.shutdown().await;
    b.engine.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_ticket_works_once_and_a_forged_one_never() {
    let host = Mac::start("工作室").await;
    let first = Mac::start("一").await;
    let second = Mac::start("二").await;

    let ticket = host.engine.create_invite().await;
    first.engine.join(&ticket).await.expect("第一次应当成功");
    let reused = second.engine.join(&ticket).await;
    assert!(
        matches!(
            reused,
            Err(PairError::Rejected(PairRejection::InvalidOrExpired))
        ),
        "{reused:?}"
    );

    // 地址对、密钥是猜的:和用过的码一样被拒,不透露区别。
    let genuine = host.engine.create_invite().await;
    let mut bytes = genuine.encode_bytes();
    // 密钥是编码的最后 32 字节。
    *bytes.last_mut().unwrap() ^= 0x01;
    let forged = PairingTicket::decode_bytes(&bytes).unwrap();
    let guessed = second.engine.join(&forged).await;
    assert!(
        matches!(
            guessed,
            Err(PairError::Rejected(PairRejection::InvalidOrExpired))
        ),
        "{guessed:?}"
    );
    assert!(!host.roster.is_member(&second.engine.device_id()));

    for mac in [host, first, second] {
        mac.engine.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_expired_ticket_is_refused() {
    let host = Mac::restart(
        "工作室",
        DeviceIdentity::generate(),
        Arc::default(),
        Arc::default(),
        Duration::from_millis(200),
    )
    .await;
    let late = Mac::start("迟到").await;
    let ticket = host.engine.create_invite().await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    let result = late.engine.join(&ticket).await;
    assert!(
        matches!(
            result,
            Err(PairError::Rejected(PairRejection::InvalidOrExpired))
        ),
        "{result:?}"
    );
    host.engine.shutdown().await;
    late.engine.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_device_outside_the_group_gets_nothing() {
    let a = Mac::start("甲").await;
    let b = Mac::start("乙").await;
    a.store.add("library", "不该外泄的主题");
    pair(&a, &b).await;

    // 陌生人知道甲的地址,甚至自称同一个组,也连不进来。
    let stranger = Mac::start("陌生人").await;
    {
        let mut state = stranger.roster.state.lock().unwrap();
        state.0 = a.roster.group();
        state.1.insert(a.engine.device_id());
    }
    stranger.engine.add_address_hint(a.engine.addr().await);
    stranger.engine.members_changed();
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(stranger.store.items("library").is_empty());
    assert!(a
        .engine
        .peers()
        .iter()
        .all(|peer| peer.device != stranger.engine.device_id()));

    for mac in [a, b, stranger] {
        mac.engine.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn changes_made_while_apart_arrive_after_a_restart() {
    let a = Mac::start("甲").await;
    let b = Mac::start("乙").await;
    pair(&a, &b).await;
    eventually("连上", || {
        a.engine.peers().first().is_some_and(|p| p.connected)
    })
    .await;

    // 乙关机;两边各自改了东西。
    let Mac {
        identity,
        store,
        roster,
        engine,
    } = b;
    engine.shutdown().await;
    a.change("library", "甲在乙关机时加的");
    store.add("library", "乙离线时加的");

    let b = Mac::restart("乙", identity, store, roster, Duration::from_secs(600)).await;
    // 进程内没有中继与 mDNS,重启后换了端口,只能互相告知新地址。
    a.engine.add_address_hint(b.engine.addr().await);
    b.engine.add_address_hint(a.engine.addr().await);

    eventually("重启后两边一致", || {
        a.store.items("library") == b.store.items("library") && a.store.items("library").len() == 2
    })
    .await;

    a.engine.shutdown().await;
    b.engine.shutdown().await;
}
