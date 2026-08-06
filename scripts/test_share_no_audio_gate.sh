#!/usr/bin/env bash
# 分享路径不得携带音频。
#
# 设计见 docs/architecture/share-p2p.md 第 5 节。这道门禁把「音频不可共享」从
# 约定变成构建期事实,分四层:
#   1. vt-share 在依赖图上够不到 vt-crypto / vt-audio,拿不到 SessionKey 就解不开
#      加密音频;
#   2. 对外接口是封闭枚举 ShareableKind,没有音频变体,也没有任意路径发送口;
#   3. 分享路径复用 vt-export 时不得走 include_audio: true 的默认值;
#   4. 线上载荷不得出现 PCM 类型。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SHARE_CRATE="$ROOT_DIR/crates/vt-share"
SHARE_MANIFEST="$SHARE_CRATE/Cargo.toml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$SHARE_MANIFEST" ]] || fail "缺少 $SHARE_MANIFEST"

# 所有针对源码内容的断言都跑在「去掉注释」的副本上。
#
# vt-share 的注释里正当地写着「不要用 ExportOptions::default()」「音频不可共享」
# 这类字样,拿注释当证据会让门禁对着自己的说明文字报警,或者更糟 —— 有人为了让
# 门禁闭嘴而删掉解释。行内 `//` 一并剥掉:对本文件要找的那几个 Rust 标识符来说,
# 误伤字符串里的 `https://` 无影响。
STRIPPED_SRC="$(mktemp -d)"
trap 'rm -rf "$STRIPPED_SRC"' EXIT

if [[ -d "$SHARE_CRATE/src" ]]; then
  while IFS= read -r rs; do
    rel="${rs#"$SHARE_CRATE/src/"}"
    mkdir -p "$STRIPPED_SRC/$(dirname "$rel")"
    sed 's://.*::' "$rs" >"$STRIPPED_SRC/$rel"
  done < <(find "$SHARE_CRATE/src" -name '*.rs' -type f)
fi

# ── 第一层:依赖图 ─────────────────────────────────────────────────────────
# 音频以每 Session 一把 SessionKey 加密落盘。vt-share 不依赖 vt-crypto 就无法
# 解密,不依赖 vt-audio 就碰不到 PCM 环形缓冲。这不是「约定不发」,是发不出来。
FORBIDDEN_CRATES=(vt-crypto vt-audio)

for forbidden in "${FORBIDDEN_CRATES[@]}"; do
  if grep -Eq "^[[:space:]]*${forbidden}[[:space:]]*=" "$SHARE_MANIFEST"; then
    fail "vt-share 直接依赖了 $forbidden;分享层必须够不到音频解密与 PCM"
  fi
done

# 直接依赖挡住了,还要挡传递依赖 —— 例如经由 vt-store 或 vt-pipeline 绕进来。
if command -v cargo >/dev/null 2>&1; then
  for forbidden in "${FORBIDDEN_CRATES[@]}"; do
    if cargo tree --quiet --package vt-share --edges normal --prefix none 2>/dev/null \
        | awk '{print $1}' | grep -Fxq "$forbidden"; then
      fail "vt-share 通过传递依赖引入了 $forbidden;检查中间 crate 的 feature"
    fi
  done
else
  echo "  ! 跳过 cargo tree 传递依赖检查(环境无 cargo)" >&2
fi

# ── 第二层:封闭枚举 ───────────────────────────────────────────────────────
KIND_FILE="$SHARE_CRATE/src/shareable.rs"
[[ -f "$KIND_FILE" ]] || fail "缺少 $KIND_FILE;可分享类型必须集中在一处定义"

if ! grep -q "pub enum ShareableKind" "$KIND_FILE"; then
  fail "$KIND_FILE 未定义 ShareableKind 封闭枚举"
fi

# 枚举体内不得出现音频或 Context Pack 变体。Context Pack 是加密的用户资料,
# 与音频同样不该默认可分享。
#
# 只看变体标识符,不看文档注释 —— 注释里正当地解释着为什么排除音频,拿注释当证据
# 会让这道门禁恒假。变体行形如 `    Foo,` / `    Foo {` / `    Foo(`。
KIND_VARIANTS="$(
  awk '/pub enum ShareableKind/{flag=1; next} flag&&/^}/{exit} flag{print}' "$KIND_FILE" \
    | sed 's://.*::' \
    | grep -Eo '^[[:space:]]*[A-Z][A-Za-z0-9_]*[[:space:]]*[,({]' \
    | tr -d ' ,({'
)"

[[ -n "$KIND_VARIANTS" ]] || fail "未能从 $KIND_FILE 解析出 ShareableKind 的变体"

while IFS= read -r variant; do
  [[ -n "$variant" ]] || continue
  if grep -Eiq "audio|pcm|wav|waveform|contextpack" <<<"$variant"; then
    fail "ShareableKind 出现了音频或 Context Pack 变体: $variant"
  fi
done <<<"$KIND_VARIANTS"

# 不得存在任意路径发送口 —— 有它就等于绕过整个封闭清单。
if grep -rEn "fn share_file|fn send_file|fn share_path|fn send_path" \
    "$STRIPPED_SRC" >/dev/null 2>&1; then
  fail "vt-share 暴露了任意路径发送接口;只允许 share_resource(session_id, ShareableKind)"
fi

# ── 第三层:vt-export 复用点 ───────────────────────────────────────────────
# ExportOptions::default() 的 include_audio 是 true,会打包 audio.wav。
# 分享路径只能走 ExportOptions::shareable()。
if grep -rEn "include_audio[[:space:]]*:[[:space:]]*true|ExportOptions::default\(\)" \
    "$STRIPPED_SRC" >/dev/null 2>&1; then
  fail "vt-share 使用了会打包音频的导出选项;必须走 ExportOptions::shareable()"
fi

# 匹配构造器定义本身,不要匹配「名字以 shareable 开头的测试函数」——
# `fn shareable_options_never_pack_audio` 曾让这条断言恒真。
EXPORT_ZIP="$ROOT_DIR/crates/vt-export/src/zip.rs"
if [[ -f "$EXPORT_ZIP" ]]; then
  grep -Eq "pub fn shareable\(\)[[:space:]]*->" "$EXPORT_ZIP" \
    || fail "vt-export 缺少 ExportOptions::shareable();分享路径没有安全的构造器可用"
  # 构造器必须真的关掉音频,而不是只剩个名字。
  awk '/pub fn shareable\(\)/{flag=1} flag{print} flag&&/^    \}/{exit}' "$EXPORT_ZIP" \
    | grep -Eq "include_audio[[:space:]]*:[[:space:]]*false" \
    || fail "ExportOptions::shareable() 没有把 include_audio 设为 false"
fi

# ── 第四层:线上载荷 ───────────────────────────────────────────────────────
# 采集侧的 PCM 类型不得出现在任何分享 wire 类型里。
if grep -rEn "\bAudioFrame\b|\bAudioChunk\b|\[i16\]|Vec<i16>" \
    "$STRIPPED_SRC" >/dev/null 2>&1; then
  fail "vt-share 出现了 PCM 载荷类型;字幕通道只承载文本结构"
fi

echo "✓ [share] 音频不可共享的四层约束成立"
