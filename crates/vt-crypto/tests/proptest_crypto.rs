//! vt-crypto property tests：
//! - encrypt → decrypt round-trip 对任意输入
//! - decrypt 任意字节不 panic（fuzz 替代）
//! - 不同 key 不能解密
//! - 不同 nonce 产生不同 ciphertext

use proptest::prelude::*;
use tempfile::NamedTempFile;
use vt_crypto::{decrypt::DecryptReader, encrypt_to_file, SessionKey};

proptest! {
    /// 任意大小的输入数据 encrypt → decrypt 必须 round-trip
    #[test]
    fn prop_encrypt_decrypt_roundtrip(data in prop::collection::vec(any::<u8>(), 0..16384)) {
        let key = SessionKey::generate();
        let tmp = NamedTempFile::new().unwrap();
        encrypt_to_file(tmp.path(), &key, &data).unwrap();

        use std::io::Read;
        let mut reader = DecryptReader::new(tmp.path(), &key).unwrap();
        let mut decrypted = Vec::new();
        reader.read_to_end(&mut decrypted).unwrap();
        prop_assert_eq!(decrypted, data);
    }

    /// 用错误的 key 解密必须失败（不能 panic 也不能返回明文）
    #[test]
    fn prop_wrong_key_fails(data in prop::collection::vec(any::<u8>(), 1..1024)) {
        let key = SessionKey::generate();
        let wrong_key = SessionKey::generate();
        let tmp = NamedTempFile::new().unwrap();
        encrypt_to_file(tmp.path(), &key, &data).unwrap();

        use std::io::Read;
        let result = DecryptReader::new(tmp.path(), &wrong_key);
        if let Ok(mut reader) = result {
            let mut buf = Vec::new();
            let read_result = reader.read_to_end(&mut buf);
            // 要么 read 出错，要么解密出来的内容不等于原文
            if read_result.is_ok() {
                prop_assert_ne!(buf, data, "wrong key must not decrypt to original");
            }
        }
        // Err 路径：header 验证就失败 — OK
    }

    /// 同一个 key 加密两次相同数据，密文应当不同（nonce 随机）
    #[test]
    fn prop_same_key_different_nonces_produce_different_ciphertext(
        data in prop::collection::vec(any::<u8>(), 16..1024)
    ) {
        let key = SessionKey::generate();
        let tmp1 = NamedTempFile::new().unwrap();
        let tmp2 = NamedTempFile::new().unwrap();
        encrypt_to_file(tmp1.path(), &key, &data).unwrap();
        encrypt_to_file(tmp2.path(), &key, &data).unwrap();

        let bytes1 = std::fs::read(tmp1.path()).unwrap();
        let bytes2 = std::fs::read(tmp2.path()).unwrap();
        prop_assert_ne!(bytes1, bytes2, "ciphertexts must differ due to random nonce");
    }

    /// 解密任意字节（损坏的 .enc 文件）不能 panic
    /// 这相当于 cargo-fuzz 但用 proptest 跑
    #[test]
    fn prop_decrypt_arbitrary_bytes_no_panic(garbage in prop::collection::vec(any::<u8>(), 0..2048)) {
        let key = SessionKey::generate();
        let tmp = NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), &garbage).unwrap();

        use std::io::Read;
        // 任何输入都不应 panic — 必须返回 Err
        let result = std::panic::catch_unwind(|| {
            let r = DecryptReader::new(tmp.path(), &key);
            if let Ok(mut reader) = r {
                let mut buf = Vec::new();
                let _ = reader.read_to_end(&mut buf);
            }
        });
        prop_assert!(result.is_ok(), "decrypt arbitrary bytes must not panic");
    }
}

#[test]
fn smoke_proptest_module_compiles() {
    // 确保 proptest 模块本身能加载
    let key = SessionKey::generate();
    assert_eq!(key.as_bytes().len(), 32);
}
