#!/usr/bin/env bash
# 共享路径不得携带音频。
#
# 设计见 docs/architecture/share-links.md 第 4 节。共享只有两条出口:加密链接
# (crates/vt-ffi/src/link_share.rs)与「发送副本」(同一文件里的 transcript_file,
# 由 App 的共享面板写成 .md / .srt)。这道门禁把「音频不可共享」从约定变成构建期
# 事实,分四层:
#   1. 共享模块碰不到音频:不引用 vt_audio、音频解密、PCM 类型;
#   2. 链接密钥只能现生成:不从密钥库取任何已有的 SessionKey(那是音频的钥匙);
#   3. 发送副本只走纯文字导出:不走会打包 audio.wav 的 zip 导出;
#   4. App 的共享界面同样不碰音频导出。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LINK_SHARE="$ROOT_DIR/crates/vt-ffi/src/link_share.rs"
SWIFT_DIR="$ROOT_DIR/macos/ZuTalk/ZuTalk"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$LINK_SHARE" ]] || fail "缺少 $LINK_SHARE"

# 断言都跑在「去掉注释」的副本上:注释里正当地写着「音频从不经过这里」这类
# 字样,拿注释当证据会让门禁对着自己的说明文字报警 —— 或者更糟,有人为了让
# 门禁闭嘴而删掉解释。行内 `//` 一并剥掉;误伤字符串里的 `https://` 无影响。
#
# 测试模块也剥掉:测试里正当地断言「帧里不该出现 audio」。
STRIPPED="$(mktemp)"
trap 'rm -f "$STRIPPED"' EXIT
awk '/^#\[cfg\(test\)\]$/{exit} {print}' "$LINK_SHARE" | sed 's://.*::' >"$STRIPPED"
[[ -s "$STRIPPED" ]] || fail "没能从 $LINK_SHARE 取出非测试代码"

# ── 第一层:碰不到音频 ─────────────────────────────────────────────────────
if grep -En "vt_audio|decrypt_session_audio|DecryptReader|decrypt_range|audio_journal|AudioFrame|AudioChunk|\[i16\]|Vec<i16>|\[f32\]|Vec<f32>" \
    "$STRIPPED" >/dev/null; then
  fail "link_share.rs 引用了音频读取、解密或 PCM 类型;共享载荷只有文字"
fi

# 加密前的线上结构体:字段名里不得出现音频。
WIRE_FIELDS="$(
  awk '/^struct (LinkMeta|Web[A-Za-z]+) \{/{flag=1; next} flag&&/^\}/{flag=0} flag{print}' "$STRIPPED" \
    | grep -Eo '^[[:space:]]*[a-z_][a-z0-9_]*[[:space:]]*:' | tr -d ' :'
)"
[[ -n "$WIRE_FIELDS" ]] || fail "未能从 link_share.rs 解析出线上结构体的字段"
while IFS= read -r field; do
  [[ -n "$field" ]] || continue
  if grep -Eiq "audio|pcm|wav|waveform|sample" <<<"$field"; then
    fail "线上结构体出现了音频字段: $field"
  fi
done <<<"$WIRE_FIELDS"

# ── 第二层:链接密钥只能现生成 ─────────────────────────────────────────────
# 音频以每 Session 一把 SessionKey 加密落盘。链接用的是另一把现生成的钥匙 ——
# 拿到链接的人因此永远拿不到能解音频的东西。
grep -Eq "SessionKey::generate\(\)" "$STRIPPED" \
  || fail "link_share.rs 的链接密钥不是现生成的"
if grep -En "key_store|KeyStore|load_key|get_key|audio_key|session_key_ref|SessionKey::from_bytes" \
    "$STRIPPED" >/dev/null; then
  fail "link_share.rs 从密钥库或已有字节取了密钥;链接密钥只能现生成"
fi

# ── 第三层:发送副本只走纯文字导出 ─────────────────────────────────────────
# ExportOptions::default() 的 include_audio 是 true,会打包 audio.wav。
if grep -En "export_session_zip|ExportOptions|include_audio|audio\.wav|\.wav\"" \
    "$STRIPPED" >/dev/null; then
  fail "link_share.rs 走了会打包音频的导出;发送副本只能是 Markdown / SRT"
fi
grep -Eq "export_markdown|export_srt" "$STRIPPED" \
  || fail "link_share.rs 的发送副本没有走纯文字导出"

# ── 第四层:App 的共享界面 ─────────────────────────────────────────────────
SHARE_SWIFT=()
while IFS= read -r file; do
  SHARE_SWIFT+=("$file")
done < <(find "$SWIFT_DIR" -type f \( -name 'Share*.swift' -o -name '*Share*.swift' \) 2>/dev/null | sort)
[[ ${#SHARE_SWIFT[@]} -gt 0 ]] || fail "在 $SWIFT_DIR 下没找到共享界面的源文件"
for file in "${SHARE_SWIFT[@]}"; do
  if sed 's://.*::' "$file" | grep -En "exportSessionZip|includeAudio|audio\.wav|\"wav\"|AVAudioFile|decryptSessionAudio" >/dev/null; then
    fail "${file#"$ROOT_DIR/"} 碰了音频导出;共享只发文字"
  fi
done

echo "✓ [share] 音频不可共享的四层约束成立"
