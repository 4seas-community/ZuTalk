//! 黄金祖先生成器,照抄 macro 的 generate-golden 模式。
//!
//! 每 kind 写一份版本化 `.bin` 到 crates/vt-store/golden/。字节一旦提交
//! 即冻结;要换代就升文件名里的版本号并同步改
//! `document_schema::golden_snapshot` 的 include 路径 —— 永远不要原地
//! 覆盖已发布的 golden,那会让存量文档失去共同祖先。
//!
//! 运行:cargo run -p vt-store --example generate_document_goldens

use std::fs;
use std::path::Path;

use vt_store::document_schema::{build_golden_bytes, DocumentKind};

fn main() {
    let golden_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("golden");
    fs::create_dir_all(&golden_dir).expect("create golden dir");

    for (kind, file_name) in [
        (DocumentKind::Transcript, "document-golden-transcript.1.bin"),
        (DocumentKind::Note, "document-golden-note.1.bin"),
    ] {
        let path = golden_dir.join(file_name);
        // 已发布的 golden 不可再生成覆盖,删除文件即表示明确要换代。
        // 空文件是 include_bytes! 的编译占位,视为「尚未生成」。
        if path.exists() && fs::metadata(&path).map(|m| m.len() > 0).unwrap_or(false) {
            println!("skip(已存在,字节冻结): {}", path.display());
            continue;
        }
        let bytes = build_golden_bytes(kind);
        fs::write(&path, &bytes).expect("write golden");
        println!("wrote {} bytes → {}", bytes.len(), path.display());
    }
}
