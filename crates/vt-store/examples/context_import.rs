//! Imports a Context Pack file written by `context_export` or by the app's
//! "Import a library" button, as a new Library Pack.
//!
//! The app must not be running (see `context_export` for why).
//!
//! Usage:
//!   cargo run -p vt-store --example context_import -- \
//!     --data-dir <app support dir> --file <file.json> [--title <name>]
//!     [--notebook <id>]
//!
//! `--notebook` binds the new Pack to that Notebook and prints the compiled
//! Soniox context so the scalar budget can be checked immediately.

use std::path::PathBuf;
use std::sync::Arc;

use vt_crypto::FileKeyStore;
use vt_store::{ContextPackDocument, ContextPackStore, SONIOX_CONTEXT_MAX_SCALARS};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut data_dir: Option<PathBuf> = None;
    let mut file: Option<PathBuf> = None;
    let mut title: Option<String> = None;
    let mut notebook_id: Option<String> = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => data_dir = args.next().map(PathBuf::from),
            "--file" => file = args.next().map(PathBuf::from),
            "--title" => title = args.next(),
            "--notebook" => notebook_id = args.next(),
            other => return Err(format!("unexpected argument '{other}'").into()),
        }
    }

    let data_dir = data_dir.ok_or("--data-dir is required")?;
    let file = file.ok_or("--file is required")?;
    vt_store_example_support::require_app_quit(&data_dir)?;

    let keys = Arc::new(FileKeyStore::new(
        data_dir.join("Secrets").join("content-keys.json"),
    )?);
    let store = ContextPackStore::new(&data_dir.join("zulangue.db"), keys)?;

    let document: ContextPackDocument = serde_json::from_slice(&std::fs::read(&file)?)?;
    let pack = store.import_pack_document(&document, title.as_deref())?;
    println!("imported '{}' ({})", pack.title, pack.id);
    for source in store.list_sources(&pack.id)? {
        println!("  + {} [{:?}]", source.title, source.content_kind);
    }

    if let Some(notebook_id) = notebook_id {
        store.bind_library_pack(&notebook_id, &pack.id, 0)?;
        let compilation = store.compile_notebook_context(&notebook_id)?;
        println!(
            "\nbound to {notebook_id}: {} / {SONIOX_CONTEXT_MAX_SCALARS} scalars",
            compilation.receipt.serialized_scalars
        );
        println!(
            "  translation_terms={} terms={} general={} text={} scalars",
            compilation.context.translation_terms.len(),
            compilation.context.terms.len(),
            compilation.context.general.len(),
            compilation.context.text.chars().count()
        );
        for omission in &compilation.receipt.omissions {
            println!(
                "  OMITTED {:?} {:?} items={} scalars={}",
                omission.section, omission.reason, omission.omitted_items, omission.omitted_scalars
            );
        }
    }
    Ok(())
}

#[path = "common/mod.rs"]
mod vt_store_example_support;
