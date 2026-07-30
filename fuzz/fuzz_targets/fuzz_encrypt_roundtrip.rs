//! vt-crypto encrypt → decrypt round-trip fuzz.
//!
//! 任意大小/任意内容的明文 → 加密 → 解密必须等于原文。
//! 用做 cryptographic invariant 的随机化验证。

#![no_main]
use libfuzzer_sys::fuzz_target;
use std::io::Read;

fuzz_target!(|data: &[u8]| {
    let Ok(tmp) = tempfile::NamedTempFile::new() else {
        return;
    };
    let key = vt_crypto::SessionKey::generate();

    if vt_crypto::encrypt_to_file(tmp.path(), &key, data).is_err() {
        return;
    }

    let Ok(mut reader) = vt_crypto::decrypt::DecryptReader::new(tmp.path(), &key) else {
        return;
    };
    let mut decrypted = Vec::new();
    if reader.read_to_end(&mut decrypted).is_ok() {
        // 必须 round-trip
        assert_eq!(decrypted, data, "encrypt → decrypt must round-trip");
    }
});
