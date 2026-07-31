//! Exports a Context Pack to one shareable file, byte-identical to what the
//! app's "Export" button writes.
//!
//! The app must not be running: this opens the same SQLite database and the
//! same `Secrets/content-keys.json` key file.
//!
//! The output is PLAINTEXT — it has left the Pack's encryption boundary.
//!
//! Usage:
//!   cargo run -p vt-store --example context_export -- \
//!     --data-dir <app support dir> --pack <pack id> --out <file.json>

use std::path::PathBuf;
use std::sync::Arc;

use vt_crypto::FileKeyStore;
use vt_store::ContextPackStore;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut data_dir: Option<PathBuf> = None;
    let mut pack_id: Option<String> = None;
    let mut out_path: Option<PathBuf> = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => data_dir = args.next().map(PathBuf::from),
            "--pack" => pack_id = args.next(),
            "--out" => out_path = args.next().map(PathBuf::from),
            other => return Err(format!("unexpected argument '{other}'").into()),
        }
    }

    let data_dir = data_dir.ok_or("--data-dir is required")?;
    let pack_id = pack_id.ok_or("--pack is required")?;
    let out_path = out_path.ok_or("--out is required")?;
    vt_store_example_support::require_app_quit(&data_dir)?;

    let keys = Arc::new(FileKeyStore::new(
        data_dir.join("Secrets").join("content-keys.json"),
    )?);
    let store = ContextPackStore::new(&data_dir.join("zulangue.db"), keys)?;

    let document = store.export_pack_document(&pack_id)?;
    std::fs::write(&out_path, serde_json::to_string_pretty(&document)?)?;

    println!(
        "exported '{}' ({} sources)",
        document.title,
        document.sources.len()
    );
    for source in &document.sources {
        println!(
            "  - {} [{:?}] {} scalars",
            source.title,
            source.content_kind,
            source.content.chars().count()
        );
    }
    println!("\nwrote {}", out_path.display());
    println!("this file is PLAINTEXT — it is no longer protected by the Pack key");
    Ok(())
}

#[path = "common/mod.rs"]
mod vt_store_example_support;
