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
    DeviceIdentity, DocId, DocumentStore, EndpointId, InvitePurpose, Membership, PairError,
    PairRejection, PairingTicket, SpaceId, StoreError, SyncConfig, SyncEngine, VersionDigest,
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

    fn doc_ids(&self) -> BTreeSet<DocId> {
        self.docs.lock().unwrap().keys().cloned().collect()
    }

    fn snapshot(&self) -> BTreeMap<DocId, BTreeSet<String>> {
        self.docs.lock().unwrap().clone()
    }
}

fn encode(items: &BTreeSet<String>) -> Vec<u8> {
    postcard::to_stdvec(items).unwrap()
}

/// 一个空间看到的文档:底下是整台设备的文档,按前缀过滤。
struct View {
    all: Arc<SetStore>,
    prefixes: Mutex<Vec<&'static str>>,
}

impl View {
    fn covers(&self, doc: &str) -> bool {
        self.prefixes
            .lock()
            .unwrap()
            .iter()
            .any(|prefix| doc.starts_with(prefix))
    }
}

impl DocumentStore for View {
    fn summary(&self) -> Vec<(DocId, VersionDigest)> {
        let docs = self.all.docs.lock().unwrap();
        docs.iter()
            .filter(|(doc, _)| self.covers(doc))
            .map(|(doc, items)| (doc.clone(), Sha256::digest(encode(items)).into()))
            .collect()
    }

    fn digest(&self, doc: &DocId) -> Option<VersionDigest> {
        if !self.covers(doc) {
            return None;
        }
        let docs = self.all.docs.lock().unwrap();
        docs.get(doc)
            .map(|items| Sha256::digest(encode(items)).into())
    }

    fn version(&self, doc: &DocId) -> Option<Vec<u8>> {
        if !self.covers(doc) {
            return None;
        }
        self.all.docs.lock().unwrap().get(doc).map(encode)
    }

    fn updates_since(&self, doc: &DocId, from: &[u8]) -> Option<Vec<u8>> {
        if !self.covers(doc) {
            return None;
        }
        let theirs: BTreeSet<String> = if from.is_empty() {
            BTreeSet::new()
        } else {
            postcard::from_bytes(from).ok()?
        };
        let docs = self.all.docs.lock().unwrap();
        let missing: BTreeSet<String> = docs.get(doc)?.difference(&theirs).cloned().collect();
        (!missing.is_empty()).then(|| encode(&missing))
    }

    fn apply(&self, doc: &DocId, update: &[u8]) -> Result<bool, StoreError> {
        if !self.covers(doc) {
            return Err(StoreError::NotAccepted(doc.clone()));
        }
        let incoming: BTreeSet<String> =
            postcard::from_bytes(update).map_err(|e| StoreError::Rejected(e.to_string()))?;
        let mut docs = self.all.docs.lock().unwrap();
        let items = docs.entry(doc.clone()).or_default();
        let before = items.len();
        items.extend(incoming);
        Ok(items.len() > before)
    }

    fn accepts(&self, doc: &DocId) -> bool {
        self.covers(doc)
    }
}

/// 设备组看得到的文档。清单外的(比如 `scratch/`)不同步。
const LIBRARY: &[&str] = &["library", "recording/", "topic/"];

#[derive(Default)]
struct Roster {
    members: Mutex<BTreeSet<EndpointId>>,
}

impl Roster {
    fn with(devices: &[EndpointId]) -> Arc<Self> {
        Arc::new(Self {
            members: Mutex::new(devices.iter().copied().collect()),
        })
    }
}

impl Membership for Roster {
    fn members(&self) -> Vec<EndpointId> {
        self.members.lock().unwrap().iter().copied().collect()
    }

    fn admit(&self, device: EndpointId, _name: &str) -> Result<(), String> {
        self.members.lock().unwrap().insert(device);
        Ok(())
    }
}

struct Mac {
    identity: DeviceIdentity,
    store: Arc<SetStore>,
    /// 设备组。每台 Mac 生来就有一个只有自己的设备组。
    group: Mutex<(SpaceId, Arc<Roster>)>,
    engine: SyncEngine,
}

impl Mac {
    async fn start(name: &str) -> Self {
        let identity = DeviceIdentity::generate();
        let roster = Roster::with(&[identity.id()]);
        Self::restart(
            name,
            identity,
            Arc::default(),
            SpaceId::generate(),
            roster,
            Duration::from_secs(60),
        )
        .await
    }

    async fn restart(
        name: &str,
        identity: DeviceIdentity,
        store: Arc<SetStore>,
        group: SpaceId,
        roster: Arc<Roster>,
        invite_ttl: Duration,
    ) -> Self {
        let config = SyncConfig {
            device_name: name.into(),
            invite_ttl,
            loopback_only: true,
            ..SyncConfig::default()
        };
        let engine = SyncEngine::start(identity.clone(), config)
            .await
            .expect("离线绑定应当成功");
        engine.add_space(group, view(&store, LIBRARY), roster.clone());
        Self {
            identity,
            store,
            group: Mutex::new((group, roster)),
            engine,
        }
    }

    fn group(&self) -> SpaceId {
        self.group.lock().unwrap().0
    }

    fn roster(&self) -> Arc<Roster> {
        self.group.lock().unwrap().1.clone()
    }

    fn change(&self, doc: &str, item: &str) {
        self.store.add(doc, item);
        self.engine.notify_changed(&self.group(), &doc.to_string());
    }

    async fn invite(&self) -> PairingTicket {
        self.engine
            .create_invite(&self.group(), InvitePurpose::Device, "", "")
            .await
            .unwrap()
    }

    /// 加入方拿到答复后在本机换上对方的设备组 —— 这是调用方(vt-ffi)要做的事。
    async fn join(&self, ticket: &PairingTicket) -> Result<(), PairError> {
        let joined = self.engine.join(ticket).await?;
        assert_eq!(joined.purpose, InvitePurpose::Device);
        let roster = Roster::with(&[self.identity.id(), joined.inviter]);
        let old = std::mem::replace(
            &mut *self.group.lock().unwrap(),
            (joined.space, roster.clone()),
        );
        self.engine.remove_space(&old.0);
        self.engine
            .add_space(joined.space, view(&self.store, LIBRARY), roster);
        Ok(())
    }
}

fn view(store: &Arc<SetStore>, prefixes: &[&'static str]) -> Arc<View> {
    Arc::new(View {
        all: store.clone(),
        prefixes: Mutex::new(prefixes.to_vec()),
    })
}

async fn pair(inviter: &Mac, joiner: &Mac) {
    let ticket = inviter.invite().await;
    let started = std::time::Instant::now();
    if let Err(e) = joiner.join(&ticket.to_string().parse().unwrap()).await {
        panic!(
            "配对失败 {e:?} 用时 {:?} 地址 {:?}",
            started.elapsed(),
            ticket.inviter
        );
    }
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

fn connected_peers(mac: &Mac) -> usize {
    mac.engine
        .peers(&mac.group())
        .iter()
        .filter(|peer| peer.connected)
        .count()
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

    let ticket = studio.invite().await;
    assert_eq!(ticket.purpose, InvitePurpose::Device);
    let joined = laptop
        .engine
        .join(&ticket.to_string().parse().unwrap())
        .await
        .expect("配对应当成功");
    assert_eq!(joined.inviter, studio.engine.device_id());
    assert_eq!(joined.inviter_name, "工作室");
    assert_eq!(joined.space, studio.group());
    assert!(studio.roster().is_member(&laptop.engine.device_id()));
    // 换上对方的设备组。
    let roster = Roster::with(&[laptop.identity.id(), joined.inviter]);
    let old = std::mem::replace(
        &mut *laptop.group.lock().unwrap(),
        (joined.space, roster.clone()),
    );
    laptop.engine.remove_space(&old.0);
    laptop
        .engine
        .add_space(joined.space, view(&laptop.store, LIBRARY), roster);

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
            let peers = mac.engine.peers(&mac.group());
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
    eventually("连上", || connected_peers(&a) == 1).await;

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
    assert!(!a.roster().is_member(&c.engine.device_id()));
    eventually("乙连着两台", || connected_peers(&b) == 2).await;

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

    let ticket = host.invite().await;
    first.join(&ticket).await.expect("第一次应当成功");
    let reused = second.join(&ticket).await;
    assert!(
        matches!(
            reused,
            Err(PairError::Rejected(PairRejection::InvalidOrExpired))
        ),
        "{reused:?}"
    );

    // 地址对、密钥是猜的:和用过的码一样被拒,不透露区别。
    let genuine = host.invite().await;
    let mut bytes = genuine.encode_bytes();
    // 密钥是编码的最后 32 字节。
    *bytes.last_mut().unwrap() ^= 0x01;
    let forged = PairingTicket::decode_bytes(&bytes).unwrap();
    let guessed = second.join(&forged).await;
    assert!(
        matches!(
            guessed,
            Err(PairError::Rejected(PairRejection::InvalidOrExpired))
        ),
        "{guessed:?}"
    );
    assert!(!host.roster().is_member(&second.engine.device_id()));

    // 取消邀请之后,还没用的码也作废。
    let revoked = host.invite().await;
    host.engine.revoke_invites(&host.group());
    let late = second.join(&revoked).await;
    assert!(
        matches!(
            late,
            Err(PairError::Rejected(PairRejection::InvalidOrExpired))
        ),
        "{late:?}"
    );

    for mac in [host, first, second] {
        mac.engine.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_expired_ticket_is_refused() {
    let identity = DeviceIdentity::generate();
    let roster = Roster::with(&[identity.id()]);
    let host = Mac::restart(
        "工作室",
        identity,
        Arc::default(),
        SpaceId::generate(),
        roster,
        Duration::from_millis(200),
    )
    .await;
    let late = Mac::start("迟到").await;
    let ticket = host.invite().await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    let result = late.join(&ticket).await;
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

    // 陌生人知道甲的地址和设备组 id,自以为在组里,也连不进来。
    let stranger = Mac::start("陌生人").await;
    let roster = Roster::with(&[stranger.identity.id(), a.identity.id()]);
    stranger.engine.remove_space(&stranger.group());
    stranger
        .engine
        .add_space(a.group(), view(&stranger.store, LIBRARY), roster.clone());
    *stranger.group.lock().unwrap() = (a.group(), roster);
    stranger.engine.add_address_hint(a.engine.addr().await);
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(stranger.store.items("library").is_empty());
    assert!(a
        .engine
        .peers(&a.group())
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
    eventually("连上", || connected_peers(&a) == 1).await;

    // 乙关机;两边各自改了东西。
    let Mac {
        identity,
        store,
        group,
        engine,
    } = b;
    engine.shutdown().await;
    let (space, roster) = group.into_inner().unwrap();
    a.change("library", "甲在乙关机时加的");
    store.add("library", "乙离线时加的");

    let b = Mac::restart(
        "乙",
        identity,
        store,
        space,
        roster,
        Duration::from_secs(600),
    )
    .await;
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

/// 一台 Mac 同时在设备组和一个协作主题里:协作的同事只拿得到这个主题的文档,
/// 同事的改动经这台 Mac 转进设备组。
#[tokio::test(flavor = "multi_thread")]
async fn a_topic_space_shares_only_its_own_documents() {
    let mine = Mac::start("我的工作室").await;
    let my_laptop = Mac::start("我的笔记本").await;
    let colleague = Mac::start("同事").await;
    pair(&mine, &my_laptop).await;

    mine.store.add("topic/1", "主题:周会");
    mine.store.add("recording/in-topic", "周会第一句");
    mine.store.add("recording/private", "别的主题的录音");
    mine.store.add("library", "人名名单");

    // 主题空间:只含这个主题和它的录音。
    let topic_space = SpaceId::generate();
    const TOPIC: &[&str] = &["topic/1", "recording/in-topic"];
    let topic_roster = Roster::with(&[mine.identity.id()]);
    mine.engine
        .add_space(topic_space, view(&mine.store, TOPIC), topic_roster.clone());
    let ticket = mine
        .engine
        .create_invite(&topic_space, InvitePurpose::Topic, "周会", "topic-1")
        .await
        .unwrap();
    assert_eq!(ticket.purpose, InvitePurpose::Topic);

    let joined = colleague.engine.join(&ticket).await.expect("应当加入");
    assert_eq!(joined.purpose, InvitePurpose::Topic);
    assert_eq!(joined.label, "周会");
    assert_eq!(joined.context, "topic-1");
    assert_eq!(joined.space, topic_space);
    colleague.engine.add_space(
        joined.space,
        view(&colleague.store, TOPIC),
        Roster::with(&[colleague.identity.id(), joined.inviter]),
    );

    eventually("同事拿到主题里的录音", || {
        colleague
            .store
            .items("recording/in-topic")
            .contains("周会第一句")
    })
    .await;
    assert_eq!(
        colleague.store.doc_ids(),
        ["recording/in-topic", "topic/1"]
            .into_iter()
            .map(String::from)
            .collect::<BTreeSet<_>>(),
        "别的主题、人名名单都不该出去"
    );

    // 同事的订正回到我这台,再由我这台转进设备组(转发是调用方的事)。
    colleague.store.add("recording/in-topic", "同事的订正");
    colleague
        .engine
        .notify_changed(&joined.space, &"recording/in-topic".to_string());
    eventually("我这台收到订正", || {
        mine.store
            .items("recording/in-topic")
            .contains("同事的订正")
    })
    .await;
    mine.engine
        .notify_changed(&mine.group(), &"recording/in-topic".to_string());
    eventually("我的笔记本也有了", || {
        my_laptop
            .store
            .items("recording/in-topic")
            .contains("同事的订正")
    })
    .await;

    // 移出同事:连接断开,之后的改动不再到他那里。
    topic_roster
        .members
        .lock()
        .unwrap()
        .remove(&colleague.identity.id());
    mine.engine.members_changed(&topic_space);
    mine.change("recording/in-topic", "移出之后写的");
    mine.engine
        .notify_changed(&topic_space, &"recording/in-topic".to_string());
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(!colleague
        .store
        .items("recording/in-topic")
        .contains("移出之后写的"));

    for mac in [mine, my_laptop, colleague] {
        mac.engine.shutdown().await;
    }
}

/// 先婉拒、后能收的文档:收下录音之后请对方重发摘要,附属文档马上就到,
/// 不等下一轮反熵(测试里反熵是 60 秒),也不必断线重连。
#[tokio::test(flavor = "multi_thread")]
async fn a_document_refused_earlier_arrives_once_asked_again() {
    const WITH_NOTES: &[&str] = &["library", "recording/", "topic/", "note/"];
    let a = Mac::start("甲").await;
    let b = Mac::start("乙").await;
    a.engine
        .add_space(a.group(), view(&a.store, WITH_NOTES), a.roster());
    a.store.add("note/for-later", "录音的笔记");

    // 乙起初不收 note/。
    let narrow = view(&b.store, LIBRARY);
    let ticket = a.invite().await;
    let joined = b.engine.join(&ticket).await.unwrap();
    let roster = Roster::with(&[b.identity.id(), joined.inviter]);
    b.engine.remove_space(&b.group());
    b.engine
        .add_space(joined.space, narrow.clone(), roster.clone());
    *b.group.lock().unwrap() = (joined.space, roster);
    eventually("连上", || connected_peers(&b) == 1).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(b.store.items("note/for-later").is_empty());

    // 乙现在能收了:只请对方重发摘要。
    narrow.prefixes.lock().unwrap().push("note/");
    b.engine.refresh(&b.group());
    eventually("附属文档到了", || {
        b.store.items("note/for-later").contains("录音的笔记")
    })
    .await;

    a.engine.shutdown().await;
    b.engine.shutdown().await;
}
