//! Zulangue 统一 i18n 层。
//!
//! 所有需要向用户展示文本的 Rust crate（vt-stt / vt-ffi / …）都走这里。
//! 运行时 locale 由 Swift 端在启动 + 设置变更时推入 [`set_locale`]。
//!
//! 使用：
//! ```ignore
//! use vt_i18n::tr;
//! let msg = tr!("error.stt.ws_failed", detail = "dns".to_string());
//! ```
//!
//! 支持的 locale：`en` / `zh-Hans` / `ja`，fallback = `en`。
//!
//! 权威：docs/i18n.md（待建）

rust_i18n::i18n!("locales", fallback = "en");

// 不直接 re-export `rust_i18n::t!`:它展开后引用调用 crate 根的 `_rust_i18n_t`
// (由 `i18n!` 在当前 crate 注入),跨 crate 不可用。改走函数 API。

/// 翻译单个 key(无变量)。
///
/// 使用:
/// ```ignore
/// use vt_i18n::t;
/// let s = t("error.core.cancelled");
/// ```
pub fn t(key: &str) -> String {
    rust_i18n::t!(key).to_string()
}

/// 翻译带变量的 key。参数以 `(name, value)` 对传入。
///
/// ```ignore
/// use vt_i18n::t_args;
/// let s = t_args("error.core.init_failed", &[("detail", "disk full")]);
/// ```
pub fn t_args(key: &str, args: &[(&str, &str)]) -> String {
    // rust_i18n::t! 宏不接受运行期 slice;在这里手动 interpolate %{name} 模板。
    let mut out = rust_i18n::t!(key).to_string();
    for (name, value) in args {
        let placeholder = format!("%{{{name}}}");
        out = out.replace(&placeholder, value);
    }
    out
}

/// 切换全局 locale。accepted 形式：
/// - "en" / "en-US" → `"en"`
/// - "zh" / "zh-Hans" / "zh-CN" → `"zh-Hans"`
/// - "zh-Hant" / "zh-TW" → `"zh-Hans"`（暂无繁体，回退简体）
/// - "ja" / "ja-JP" → `"ja"`
/// - 其它 → `"en"`
pub fn set_locale(tag: &str) {
    rust_i18n::set_locale(normalize_tag(tag));
}

/// 读当前 locale。
pub fn current_locale() -> String {
    rust_i18n::locale().to_string()
}

/// 列出支持的 locale 标签。
pub fn available_locales() -> &'static [&'static str] {
    &["en", "zh-Hans", "ja"]
}

fn normalize_tag(tag: &str) -> &'static str {
    let lower = tag.to_ascii_lowercase();
    let base = lower.split('-').next().unwrap_or("");
    match (base, lower.as_str()) {
        ("zh", _) => "zh-Hans",
        ("ja", _) => "ja",
        ("en", _) => "en",
        _ => "en",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// `rust_i18n::set_locale` 写的是全局状态; `cargo test` 默认线程并行,
    /// `set_and_read_locale_roundtrip` / `tr_returns_localized_for_known_locale`
    /// / `t_noargs_still_works` 三条都在调 set_locale, 彼此交叉写就会读到
    /// 别人刚设的值 -> assertion 乱挂。串行化这些 test 用一把 Mutex 护住。
    static LOCALE_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn normalize_tag_maps_aliases() {
        assert_eq!(normalize_tag("en"), "en");
        assert_eq!(normalize_tag("en-US"), "en");
        assert_eq!(normalize_tag("zh"), "zh-Hans");
        assert_eq!(normalize_tag("zh-CN"), "zh-Hans");
        assert_eq!(normalize_tag("zh-Hant"), "zh-Hans");
        assert_eq!(normalize_tag("ja"), "ja");
        assert_eq!(normalize_tag("ja-JP"), "ja");
        assert_eq!(normalize_tag("fr"), "en");
        assert_eq!(normalize_tag(""), "en");
    }

    #[test]
    fn set_and_read_locale_roundtrip() {
        let _g = LOCALE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_locale("zh-CN");
        assert_eq!(current_locale(), "zh-Hans");
        set_locale("ja");
        assert_eq!(current_locale(), "ja");
        set_locale("en");
        assert_eq!(current_locale(), "en");
    }

    #[test]
    fn macro_loads_locales_folder() {
        // 通过 rust-i18n 内部的 _rust_i18n_available_locales 访问
        let locales = rust_i18n::available_locales!();
        println!("rust-i18n available: {locales:?}");
        assert!(locales.contains(&"en"));
        assert!(locales.contains(&"zh-Hans"));
        assert!(locales.contains(&"ja"));
    }

    #[test]
    fn tr_falls_back_to_english_for_missing_locale() {
        let _g = LOCALE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_locale("fr");
        let s = t_args("error.core.init_failed", &[("detail", "x")]);
        assert!(s.contains("x"));
    }

    #[test]
    fn tr_returns_localized_for_known_locale() {
        let _g = LOCALE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_locale("zh-Hans");
        let zh = t_args("error.core.init_failed", &[("detail", "磁盘满")]);
        set_locale("en");
        let en = t_args("error.core.init_failed", &[("detail", "disk full")]);
        assert!(zh.contains("初始化"), "zh was: {zh}");
        assert!(zh.contains("磁盘满"), "zh was: {zh}");
        assert!(en.starts_with("Initialization"), "en was: {en}");
        assert!(en.contains("disk full"), "en was: {en}");
    }

    #[test]
    fn t_noargs_still_works() {
        // en.yml 里所有 error 片段都是小写 ("parse error", "timeout", ...) —
        // 保持一致,所以 cancelled 也是小写。zh / ja 是词,不存在大小写问题。
        let _g = LOCALE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_locale("zh-Hans");
        assert_eq!(t("error.stt.cancelled"), "已取消");
        set_locale("en");
        assert_eq!(t("error.stt.cancelled"), "cancelled");
    }
}
