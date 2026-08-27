//! Decrypts one capture session's audio chunks into a local WAV.
//!
//! Replay material for the long-capture harness: the encrypted journal is the
//! only copy of a recording that already exercised a lane failure, and the
//! harness needs a decodable file. Paths and session come from the caller.
use std::env;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

use vt_crypto::{decrypt_chunk, FileKeyStore, KeyProvider};

fn main() {
    let data_dir = PathBuf::from(env::var("ZT_DATA_DIR").expect("ZT_DATA_DIR"));
    let session = env::var("ZT_SESSION").expect("ZT_SESSION");
    let out = PathBuf::from(env::var("ZT_OUT").expect("ZT_OUT"));
    let sample_rate: u32 = env::var("ZT_SAMPLE_RATE")
        .unwrap_or_else(|_| "16000".into())
        .parse()
        .unwrap();

    let store = FileKeyStore::new(data_dir.join("Secrets/content-keys.json")).expect("key store");
    let key = store
        .load_key(&format!("zutalk.audio.{session}"))
        .expect("session key");

    let dir = data_dir.join("audio").join(&session);
    let mut names: Vec<_> = fs::read_dir(&dir)
        .expect("audio dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "enc"))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("chunk."))
        })
        .collect();
    names.sort();

    let mut samples: Vec<i16> = Vec::new();
    for path in &names {
        // Each chunk file is a run of length-delimited GCM frames, the shape
        // `encrypt_to_file` writes: a 4-byte little-endian length then that
        // many ciphertext bytes.
        let raw = fs::read(path).expect("chunk");
        let mut offset = 0usize;
        while offset + 4 <= raw.len() {
            let len = u32::from_le_bytes([
                raw[offset],
                raw[offset + 1],
                raw[offset + 2],
                raw[offset + 3],
            ]) as usize;
            offset += 4;
            if offset + len > raw.len() {
                break;
            }
            let plain = decrypt_chunk(&raw[offset..offset + len], &key).expect("decrypt");
            offset += len;
            for frame in plain.chunks_exact(4) {
                let value = f32::from_le_bytes([frame[0], frame[1], frame[2], frame[3]]);
                samples.push((value.clamp(-1.0, 1.0) * 32767.0) as i16);
            }
        }
    }

    let data_len = (samples.len() * 2) as u32;
    let mut file = fs::File::create(&out).expect("out");
    file.write_all(b"RIFF").unwrap();
    file.write_all(&(36 + data_len).to_le_bytes()).unwrap();
    file.write_all(b"WAVEfmt ").unwrap();
    file.write_all(&16u32.to_le_bytes()).unwrap();
    file.write_all(&1u16.to_le_bytes()).unwrap();
    file.write_all(&1u16.to_le_bytes()).unwrap();
    file.write_all(&sample_rate.to_le_bytes()).unwrap();
    file.write_all(&(sample_rate * 2).to_le_bytes()).unwrap();
    file.write_all(&2u16.to_le_bytes()).unwrap();
    file.write_all(&16u16.to_le_bytes()).unwrap();
    file.write_all(b"data").unwrap();
    file.write_all(&data_len.to_le_bytes()).unwrap();
    for sample in &samples {
        file.write_all(&sample.to_le_bytes()).unwrap();
    }
    eprintln!(
        "{} chunks -> {} samples ({:.1} min) -> {}",
        names.len(),
        samples.len(),
        samples.len() as f64 / sample_rate as f64 / 60.0,
        out.display()
    );
}
