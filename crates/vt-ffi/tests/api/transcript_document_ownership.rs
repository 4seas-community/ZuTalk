//! T2 转录稿块文档:机器与用户各写各的,谁也不许盖谁。
//!
//! 转录稿是证据。它和笔记共用一个引擎却不共用规则手册:句序不可变
//! (普通 LoroList 在类型层面就没有 move)、采集块归机器、用户只能改
//! 自己的块和插批注。这几条之前只有 vt-store 的门面单测,跨 FFI 的
//! 落盘/重开一路没人走过。
//!
//! 最要紧的一条是**让行**:用户订正过的车道,机器下一轮再来时必须绕开。
//! 会议里改错一句译文,下一帧字幕又把它盖回去,人是不会再改第二次的。

use tempfile::TempDir;
use vt_ffi::block_document_api::{FfiDocumentKind, FfiMachineBlockWrite};
use vt_ffi::ZulangueCore;

fn make_core(dir: &TempDir) -> ZulangueCore {
    ZulangueCore::new_for_test(dir.path().to_str().unwrap().to_string()).unwrap()
}

fn machine_write(id: &str, text: &str, lanes: &[(&str, &str)]) -> FfiMachineBlockWrite {
    FfiMachineBlockWrite {
        id: id.into(),
        owner: "capture:sess-1".into(),
        text: text.into(),
        lanes: lanes
            .iter()
            .map(|(lane, value)| ((*lane).to_string(), (*value).to_string()))
            .collect(),
    }
}

fn open_transcript(core: &ZulangueCore, doc_id: &str) {
    core.block_document_open(doc_id.to_string(), FfiDocumentKind::Transcript)
        .unwrap();
}

#[test]
fn machine_blocks_arrive_in_order_and_update_in_place() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    open_transcript(&core, "t1");

    core.transcript_machine_upsert("t1".into(), machine_write("u1", "第一句", &[]), vec![])
        .unwrap();
    core.transcript_machine_upsert("t1".into(), machine_write("u2", "第二句", &[]), vec![])
        .unwrap();
    // 同一个 id 再来一次 = 原地更新,不是又追加一句。
    core.transcript_machine_upsert(
        "t1".into(),
        machine_write("u1", "第一句(改准了)", &[]),
        vec![],
    )
    .unwrap();

    let blocks = core.transcript_blocks("t1".into()).unwrap();
    assert_eq!(
        blocks.iter().map(|b| b.id.clone()).collect::<Vec<_>>(),
        vec!["u1", "u2"],
        "句序按到达顺序,原地更新不改位置 —— 时间序是证据"
    );
    assert_eq!(blocks[0].text, "第一句(改准了)");
}

#[test]
fn the_machine_steps_around_a_lane_the_user_has_taken_over() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    open_transcript(&core, "t1");
    core.transcript_machine_upsert(
        "t1".into(),
        machine_write("u1", "hello", &[("zh", "你好"), ("ja", "こんにちは")]),
        vec![],
    )
    .unwrap();

    core.transcript_user_replace_lane("t1".into(), "u1".into(), "zh".into(), "您好".into())
        .unwrap();

    // 机器带着自己的译文又来一轮,并被告知 zh 已被接管。
    core.transcript_machine_upsert(
        "t1".into(),
        machine_write(
            "u1",
            "hello there",
            &[("zh", "你好"), ("ja", "こんにちは!")],
        ),
        vec!["zh".into()],
    )
    .unwrap();

    let blocks = core.transcript_blocks("t1".into()).unwrap();
    assert_eq!(
        blocks[0].lanes.get("zh").map(String::as_str),
        Some("您好"),
        "用户订正过的车道,机器必须绕开 —— 盖回去一次,人就不会再改第二次"
    );
    assert_eq!(
        blocks[0].lanes.get("ja").map(String::as_str),
        Some("こんにちは!"),
        "没被接管的车道照常更新"
    );
    assert_eq!(blocks[0].text, "hello there", "原文车道没被接管,照常更新");
}

#[test]
fn a_user_correction_survives_being_written_to_disk_and_read_back() {
    let dir = TempDir::new().unwrap();
    {
        let core = make_core(&dir);
        open_transcript(&core, "t1");
        core.transcript_machine_upsert(
            "t1".into(),
            machine_write("u1", "hello", &[("zh", "你好")]),
            vec![],
        )
        .unwrap();
        core.transcript_user_replace_text("t1".into(), "u1".into(), "Hello!".into())
            .unwrap();
        core.transcript_user_replace_lane("t1".into(), "u1".into(), "zh".into(), "您好".into())
            .unwrap();
        core.transcript_insert_annotation("t1".into(), 1, "note-1".into(), "这里要跟进".into())
            .unwrap();
        core.block_document_close("t1".into()).unwrap();
        // core 在这里落幕:数据目录的占用要跟着还回去,下一世才开得起来。
    }

    // 关掉 App 再打开:只有磁盘是共同点。
    let reborn = make_core(&dir);
    open_transcript(&reborn, "t1");
    let blocks = reborn.transcript_blocks("t1".into()).unwrap();
    assert_eq!(
        blocks.iter().map(|b| b.id.clone()).collect::<Vec<_>>(),
        vec!["u1", "note-1"],
        "批注按位置插在句块之间,重开后位置不变"
    );
    assert_eq!(blocks[0].text, "Hello!");
    assert_eq!(blocks[0].lanes.get("zh").map(String::as_str), Some("您好"));
    assert_eq!(blocks[1].text, "这里要跟进");
    assert_ne!(
        blocks[1].owner, blocks[0].owner,
        "批注是用户的块,归属跟采集块不一样"
    );
}

#[test]
fn annotations_land_where_they_were_asked_to() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    open_transcript(&core, "t1");
    for (index, id) in ["u1", "u2", "u3"].iter().enumerate() {
        core.transcript_machine_upsert(
            "t1".into(),
            machine_write(id, &format!("第 {index} 句"), &[]),
            vec![],
        )
        .unwrap();
    }

    core.transcript_insert_annotation("t1".into(), 0, "head".into(), "开场".into())
        .unwrap();
    core.transcript_insert_annotation("t1".into(), 2, "middle".into(), "中间".into())
        .unwrap();

    let ids: Vec<String> = core
        .transcript_blocks("t1".into())
        .unwrap()
        .into_iter()
        .map(|b| b.id)
        .collect();
    assert_eq!(ids, vec!["head", "u1", "middle", "u2", "u3"]);

    // 越界的位置不许悄悄落到别处。
    let before = core.transcript_blocks("t1".into()).unwrap().len();
    let far_out = core.transcript_insert_annotation("t1".into(), 999, "tail".into(), "尾".into());
    let after = core.transcript_blocks("t1".into()).unwrap();
    match far_out {
        Ok(()) => {
            assert_eq!(after.len(), before + 1);
            assert_eq!(
                after.last().unwrap().id,
                "tail",
                "要么拒绝,要么落到末尾 —— 不许插到中间某处"
            );
        }
        Err(_) => assert_eq!(after.len(), before, "拒绝了就一个块都别动"),
    }
}

#[test]
fn transcript_verbs_refuse_a_note_document_and_vice_versa() {
    // 两套结构共用一个引擎,但规则手册不同。拿错动词必须大声拒绝 ——
    // 悄悄按另一套规则办事,正是「证据被改了」这类事故的来源。
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    core.block_document_open("note-1".into(), FfiDocumentKind::Note)
        .unwrap();
    open_transcript(&core, "t1");

    assert!(core.transcript_blocks("note-1".into()).is_err());
    assert!(core
        .transcript_machine_upsert("note-1".into(), machine_write("u1", "x", &[]), vec![])
        .is_err());
    assert!(core.note_outline_rows("t1".into()).is_err());
    assert!(core.note_undo("t1".into()).is_err());
}

#[test]
fn correcting_a_block_that_does_not_exist_is_refused() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    open_transcript(&core, "t1");
    core.transcript_machine_upsert("t1".into(), machine_write("u1", "hello", &[]), vec![])
        .unwrap();

    assert!(
        core.transcript_user_replace_text("t1".into(), "ghost".into(), "x".into())
            .is_err(),
        "改一个不存在的句块:拒绝,不许凭空造一个出来"
    );
    assert!(core
        .transcript_user_replace_lane("t1".into(), "ghost".into(), "zh".into(), "x".into())
        .is_err());
    assert_eq!(
        core.transcript_blocks("t1".into()).unwrap().len(),
        1,
        "拒绝之后块数不变"
    );
}

#[test]
fn verbs_on_a_document_that_is_not_open_are_refused() {
    let dir = TempDir::new().unwrap();
    let core = make_core(&dir);
    assert!(core.transcript_blocks("never-opened".into()).is_err());
    assert!(core
        .transcript_machine_upsert("never-opened".into(), machine_write("u1", "x", &[]), vec![])
        .is_err());

    // 开了又关:同样够不到。
    open_transcript(&core, "t1");
    core.block_document_close("t1".into()).unwrap();
    assert!(core.transcript_blocks("t1".into()).is_err());
}
