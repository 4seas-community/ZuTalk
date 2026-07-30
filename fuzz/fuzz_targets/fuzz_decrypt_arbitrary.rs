//! vt-crypto arbitrary-input fuzz target.
//!
//! 任意字节作为 .enc 文件解密都不能 panic — 防御损坏/恶意 .enc 文件。
//!
//! 运行：
//!   cargo +nightly fuzz run fuzz_decrypt_arbitrary -- -max_total_time=60

#![no_main]
use libfuzzer_sys::fuzz_target;
use std::io::Read;
use std::io::Write;

fuzz_target!(|data: &[u8]| {
    // 写到临时文件再让 DecryptReader 打开
    let Ok(mut tmp) = tempfile::NamedTempFile::new() else {
        return;
    };
    if tmp.write_all(data).is_err() {
        return;
    }
    let _ = tmp.flush();

    let key = vt_crypto::SessionKey::generate();

    // DecryptReader::new + read_to_end 路径都不能 panic
    if let Ok(mut reader) = vt_crypto::decrypt::DecryptReader::new(tmp.path(), &key) {
        let mut buf = Vec::new();
        let _ = reader.read_to_end(&mut buf);
    }
});
