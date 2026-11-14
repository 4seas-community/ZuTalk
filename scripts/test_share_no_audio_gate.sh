#!/usr/bin/env bash
# 音频能从哪里离开这台 Mac。
#
# 共享的设计见 docs/architecture/share-links.md 第 4 节,档案馆的见
# docs/architecture/city-archive.md 第 6 节。这道门禁把两句话从约定变成构建期
# 事实:
#
#   · 加密链接、发送副本、设备同步、附近递稿与直播、加密备份 —— **永远不带音频**;
#   · 交到城的档案馆 —— **可以带音频,只走一道闸**。
#
# 第二句是 2026-11-14 改的。在那之前这里守的是「档案馆只交文字」。负责人的
# 原话:「不给标记数据，录音可以给。」问到交上去的音频是公开的、删不掉,要不要
# 默认就交,选的是:要,默认开。同一天又定:升级的人不另加一道确认,
# 「升級後先看到一次提示，不用加这个保护。因为只有主持人，并且做了多次操作，才交了。」
# 所以第 6 层从「不许有音频」改成「音频只许从这一处、在这几个条件下出去」;
# 标记则反过来,从「可以交」改成「不许交」。前五层一个字没松。
#
# 分六层:
#   1. 共享模块碰不到音频:不引用 vt_audio、音频解密、PCM 类型;
#   2. 链接密钥只能现生成:不从密钥库取任何已有的 SessionKey(那是音频的钥匙);
#   3. 发送副本只走纯文字导出:不走会打包 audio.wav 的 zip 导出;
#   4. App 的共享界面同样不碰音频导出;
#   5. 设备同步、附近与加密备份(crates/vt-sync,docs/architecture/local-first-sync.md)
#      在依赖图上够不到 vt-audio 与 vt-crypto,源码里也不碰音频;备份存盘的密钥
#      只能是它自己现生成的那把。
#   6. 交到城的档案馆(crates/vt-city、crates/vt-ffi/src/city_api.rs):
#      a. 协议库 vt-city 在依赖图上够不到音频解密与 PCM —— 它经手的只是别人
#         编好码的文件字节;
#      b. 编排层 city_api.rs 不引用解密、PCM 类型,密钥库只取登录的那一把签名
#         钥匙;
#      c. 签音频分段、传文件,全仓库只有 city_api.rs 的 city_send_part 一处;它要
#         拿着 audio_clearance 给的凭据才调得动,而 audio_clearance 查四条:
#         登录着、这一场的文字稿已交、设置里「连音频一起交」开着、这一场没有
#         单独关掉;
#      d. 别的 crate、vt-ffi 里别的模块(链接、同步、附近、备份)够不到 vt-city,
#         也就够不到传文件的函数;
#      e. 标记不交:vt-city 里没有签标记的代码,city_api.rs 不读标记;
#      f. App 里为档案馆导出音频只许在 CityAudioExport*.swift 里做,而且要先问
#         core 的计划;别的 City*.swift 不碰音频,别处的界面调不到交音频的入口。
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

# ── 第五层:设备同步够不到音频 ─────────────────────────────────────────────
# 音频以每 Session 一把 SessionKey 加密落盘。vt-sync 不依赖 vt-crypto 就拿不到
# 钥匙,不依赖 vt-audio 就碰不到 PCM。这不是「约定不同步」,是同步不出去。
SYNC_CRATE="$ROOT_DIR/crates/vt-sync"
SYNC_MANIFEST="$SYNC_CRATE/Cargo.toml"
[[ -f "$SYNC_MANIFEST" ]] || fail "缺少 $SYNC_MANIFEST"
FORBIDDEN_CRATES=(vt-crypto vt-audio)
for forbidden in "${FORBIDDEN_CRATES[@]}"; do
  if grep -Eq "^[[:space:]]*${forbidden}[[:space:]]*=" "$SYNC_MANIFEST"; then
    fail "vt-sync 直接依赖了 $forbidden;设备同步必须够不到音频解密与 PCM"
  fi
done
# 直接依赖挡住了,还要挡传递依赖 —— 例如经由 vt-store 绕进来。
if command -v cargo >/dev/null 2>&1; then
  SYNC_TREE="$(cargo tree --quiet --offline --package vt-sync --edges normal --prefix none 2>/dev/null \
    | awk '{print $1}')" || fail "cargo tree 没能列出 vt-sync 的依赖"
  [[ -n "$SYNC_TREE" ]] || fail "cargo tree 没能列出 vt-sync 的依赖"
  for forbidden in "${FORBIDDEN_CRATES[@]}"; do
    if grep -Fxq "$forbidden" <<<"$SYNC_TREE"; then
      fail "vt-sync 通过传递依赖引入了 $forbidden;检查中间 crate"
    fi
  done
else
  echo "  ! 跳过 cargo tree 传递依赖检查(环境无 cargo)" >&2
fi
while IFS= read -r file; do
  if awk '/^#\[cfg\(test\)\]$/{exit} {print}' "$file" | sed 's://.*::' \
      | grep -En "vt_audio|vt_crypto|SessionKey|decrypt|audio|pcm|\.wav" >/dev/null; then
    fail "${file#"$ROOT_DIR/"} 提到了音频或音频密钥;同步引擎只搬文档字节"
  fi
done < <(find "$SYNC_CRATE/src" -type f -name '*.rs' | sort)

# 同步的编排层(vt-ffi/src/library_sync.rs 与它的子模块 nearby_share.rs ——
# 附近递稿、附近直播)同样碰不到音频:它只搬事实与文档字节。密钥库只用来存取
# 设备身份(一把与音频无关的签名密钥)。
for LIBRARY_SYNC in "$ROOT_DIR/crates/vt-ffi/src/library_sync.rs" "$ROOT_DIR/crates/vt-ffi/src/nearby_share.rs"; do
  NAME="${LIBRARY_SYNC##*/}"
  [[ -f "$LIBRARY_SYNC" ]] || fail "缺少 $LIBRARY_SYNC"
  SYNC_STRIPPED="$(mktemp)"
  awk '/^#\[cfg\(test\)\]$/{exit} {print}' "$LIBRARY_SYNC" | sed 's://.*::' >"$SYNC_STRIPPED"
  if grep -En "vt_audio|decrypt|DecryptReader|encrypted_path|audio_path|audio_key_ref|audio_journal|\.wav|export_session_zip|include_audio" \
      "$SYNC_STRIPPED" >/dev/null; then
    rm -f "$SYNC_STRIPPED"
    fail "$NAME 碰了音频或音频的密钥;同步只搬文字事实"
  fi
  KEY_REFS="$(tr '\n' ' ' <"$SYNC_STRIPPED" \
    | grep -Eo "key_store[[:space:]]*\.[a-z_]+\([[:space:]]*[A-Z_a-z]+" | sed 's/.*(//' | tr -d ' ' | sort -u || true)"
  rm -f "$SYNC_STRIPPED"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ "$ref" == "IDENTITY_KEY_REF" ]] || fail "$NAME 从密钥库取了设备身份以外的东西: $ref"
  done <<<"$KEY_REFS"
done

# 加密备份(vt-ffi/src/backup_share.rs,library_sync 的子模块)要加解密备份文件,
# 所以单列一层:照样碰不到音频;密钥库只取它自己那把现生成的备份密钥
# (BACKUP_KEY_REF),不取任何音频密钥;不走音频的解密读取。
BACKUP_SHARE="$ROOT_DIR/crates/vt-ffi/src/backup_share.rs"
[[ -f "$BACKUP_SHARE" ]] || fail "缺少 $BACKUP_SHARE"
BACKUP_STRIPPED="$(mktemp)"
awk '/^#\[cfg\(test\)\]$/{exit} {print}' "$BACKUP_SHARE" | sed 's://.*::' >"$BACKUP_STRIPPED"
if grep -En "vt_audio|DecryptReader|decrypt_range|encrypted_path|audio_path|audio_key_ref|audio_journal|\.wav|export_session_zip|include_audio" \
    "$BACKUP_STRIPPED" >/dev/null; then
  rm -f "$BACKUP_STRIPPED"
  fail "backup_share.rs 碰了音频或音频的解密;备份只存文字"
fi
# rustfmt 会把 `key_store` 与 `.load_key(…)` 拆成两行:先并成一行再找。
BACKUP_KEY_REFS="$(tr '\n' ' ' <"$BACKUP_STRIPPED" \
  | grep -Eo "key_store[[:space:]]*\.[a-z_]+\([[:space:]]*[A-Z_a-z]+" | sed 's/.*(//' | tr -d ' ' | sort -u || true)"
rm -f "$BACKUP_STRIPPED"
[[ -n "$BACKUP_KEY_REFS" ]] || fail "没能从 backup_share.rs 解析出密钥库的调用"
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  [[ "$ref" == "BACKUP_KEY_REF" ]] || fail "backup_share.rs 从密钥库取了备份密钥以外的东西: $ref"
done <<<"$BACKUP_KEY_REFS"

# ── 第六层:交到城的档案馆 —— 音频只走一道闸 ───────────────────────────────
# docs/architecture/city-archive.md 第 6 节。2026-11-14 起这条路可以带音频
# (见文件头)。守的不再是「没有音频」,而是三件事:协议库和编排层仍然碰不到
# 录音在这台 Mac 上的样子(密文、钥匙、采样);音频只从一个函数出去,而那个
# 函数前面有一道查四个条件的闸;别的出口够不到这个函数。

# 取出一个函数的全文:从 `fn 名字(` 那一行到同一缩进的 `}`。源码是 rustfmt 排过的。
rust_fn() {
  awk -v name="$2" '
    !inside && $0 ~ "^[[:space:]]*(pub(\\([a-z]+\\))? )?fn " name "\\(" {
      inside = 1; indent = $0; sub(/[^[:space:]].*$/, "", indent)
    }
    inside { print }
    inside && $0 == indent "}" { exit }
  ' "$1"
}

# 6a. 协议库够不到音频解密与 PCM。
CITY_CRATE="$ROOT_DIR/crates/vt-city"
CITY_MANIFEST="$CITY_CRATE/Cargo.toml"
[[ -f "$CITY_MANIFEST" ]] || fail "缺少 $CITY_MANIFEST"
for forbidden in "${FORBIDDEN_CRATES[@]}"; do
  if grep -Eq "^[[:space:]]*${forbidden}[[:space:]]*=" "$CITY_MANIFEST"; then
    fail "vt-city 直接依赖了 $forbidden;交到档案馆的协议库必须够不到音频解密与 PCM"
  fi
done
if command -v cargo >/dev/null 2>&1; then
  CITY_TREE="$(cargo tree --quiet --offline --package vt-city --edges normal --prefix none 2>/dev/null \
    | awk '{print $1}')" || fail "cargo tree 没能列出 vt-city 的依赖"
  [[ -n "$CITY_TREE" ]] || fail "cargo tree 没能列出 vt-city 的依赖"
  for forbidden in "${FORBIDDEN_CRATES[@]}"; do
    if grep -Fxq "$forbidden" <<<"$CITY_TREE"; then
      fail "vt-city 通过传递依赖引入了 $forbidden;检查中间 crate"
    fi
  done
else
  echo "  ! 跳过 cargo tree 传递依赖检查(环境无 cargo)" >&2
fi
# 源码里同样不提录音的密文、钥匙、采样(link.rs 解的是连设备时那只封好的盒子,
# 用的是它自己协商出来的钥匙,所以这里不拦 `.decrypt(` 这个词本身)。协议的两个
# 字面量各只许出现在一个文件里:分段的记录在 publish.rs,文件的地址在 hub.rs。
# 6e. 标记:没有签 `tape/mark` 的代码。
CITY_SOURCES=0
while IFS= read -r file; do
  CITY_SOURCES=$((CITY_SOURCES + 1))
  SOURCE="$(awk '/^#\[cfg\(test\)\]$/{exit} {print}' "$file" | sed 's://.*::')"
  NAME="${file##*/}"
  if grep -En "vt_audio|vt_crypto|SessionKey|DecryptReader|decrypt_range|decrypt_session_audio|audio_journal|audio_key_ref|encrypted_path|AudioFrame|AudioChunk|\[i16\]|Vec<i16>|\[f32\]|Vec<f32>|\.wav|[Pp]cm" \
      <<<"$SOURCE" >/dev/null; then
    fail "crates/vt-city/src/$NAME 提到了音频的密文、钥匙或采样;协议库只经手编好码的文件"
  fi
  if grep -Fq "tape/mark" <<<"$SOURCE"; then
    fail "crates/vt-city/src/$NAME 签了标记(tape/mark);标记不交档案馆"
  fi
  if [[ "$NAME" != "publish.rs" ]] && grep -Fq "tape/part" <<<"$SOURCE"; then
    fail "crates/vt-city/src/$NAME 签了音频分段;那只许在 publish.rs 的 build_part 里"
  fi
  if [[ "$NAME" != "hub.rs" ]] && grep -Fq "/files/" <<<"$SOURCE"; then
    fail "crates/vt-city/src/$NAME 碰了文件服务器的地址;那只许在 hub.rs 里"
  fi
done < <(find "$CITY_CRATE/src" -type f -name '*.rs' | sort)
[[ "$CITY_SOURCES" -gt 0 ]] || fail "没找到 vt-city 的源文件"

# 6b. 编排层不引用解密、PCM 类型;协议的字面量不在这里手写;不读标记(6e)。
CITY_API="$ROOT_DIR/crates/vt-ffi/src/city_api.rs"
[[ -f "$CITY_API" ]] || fail "缺少 $CITY_API"
CITY_STRIPPED="$(mktemp)"
trap 'rm -f "$STRIPPED" "$CITY_STRIPPED"' EXIT
awk '/^#\[cfg\(test\)\]$/{exit} {print}' "$CITY_API" | sed 's://.*::' >"$CITY_STRIPPED"
[[ -s "$CITY_STRIPPED" ]] || fail "没能从 city_api.rs 取出非测试代码"
if grep -En "vt_audio|decrypt|DecryptReader|encrypted_path|audio_path|audio_key_ref|audio_journal|\.wav|export_session_zip|include_audio|AudioFrame|AudioChunk|\[i16\]|Vec<i16>|\[f32\]|Vec<f32>|[Pp]cm" \
    "$CITY_STRIPPED" >/dev/null; then
  fail "city_api.rs 碰了音频的解密、密钥或 PCM;它只收 App 编好码的文件"
fi
if grep -En "tape/part|/files/" "$CITY_STRIPPED" >/dev/null; then
  fail "city_api.rs 手写了音频分段的记录或文件的地址;那是 vt-city 的事"
fi
if grep -En "tape/mark|session_marks|marks_ms" "$CITY_STRIPPED" >/dev/null; then
  fail "city_api.rs 读了标记或签了 tape/mark;标记不交档案馆"
fi
CITY_KEY_REFS="$(tr '\n' ' ' <"$CITY_STRIPPED" \
  | grep -Eo "key_store[[:space:]]*\.[a-z_]+\([[:space:]]*[A-Z_a-z]+" | sed 's/.*(//' | tr -d ' ' | sort -u || true)"
[[ -n "$CITY_KEY_REFS" ]] || fail "没能从 city_api.rs 解析出密钥库的调用"
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  [[ "$ref" == "CITY_IDENTITY_KEY_REF" ]] || fail "city_api.rs 从密钥库取了登录钥匙以外的东西: $ref"
done <<<"$CITY_KEY_REFS"

# 6c. 那道闸。
# 闸本身:四个条件一条不少。
CLEARANCE="$(rust_fn "$CITY_STRIPPED" audio_clearance)"
[[ -n "$CLEARANCE" ]] || fail "city_api.rs 里没有 audio_clearance:音频发不发得有一处说了算"
grep -Fq "code::SIGNED_OUT" <<<"$CLEARANCE" \
  || fail "audio_clearance 没有查「登录着」"
grep -Fq "FilingState::Filed" <<<"$CLEARANCE" \
  || fail "audio_clearance 没有查「这一场的文字稿已经交上去」"
grep -Eq "if[[:space:]]+![[:space:]]*options\.audio[[:space:]]*\{" <<<"$CLEARANCE" \
  || fail "audio_clearance 没有查设置里的「连音频一起交」"
grep -Eq "if[[:space:]]+filing\.audio_withheld[[:space:]]*\{" <<<"$CLEARANCE" \
  || fail "audio_clearance 没有查「这一场单独关掉了音频」"
# 凭据只有闸造得出来:除了类型定义,`AudioClearance {` 只出现一次,在闸里。
[[ "$(grep -c "AudioClearance {" "$CITY_STRIPPED")" == "2" ]] \
  || fail "AudioClearance 在 audio_clearance 之外也被造了出来"
grep -Fq "struct AudioClearance {" "$CITY_STRIPPED" || fail "没找到 AudioClearance 的定义"
grep -Fq "Ok(AudioClearance {" <<<"$CLEARANCE" || fail "AudioClearance 不是 audio_clearance 造的"
grep -Fq "audio_clearance(" <<<"$(rust_fn "$CITY_STRIPPED" city_audio_clearance)" \
  || fail "city_audio_clearance 没有走 audio_clearance"

# 闸后面那一个函数:签分段、传文件只在它里面,它要凭据才调得动。
SEND_PART="$(rust_fn "$CITY_STRIPPED" city_send_part)"
[[ -n "$SEND_PART" ]] || fail "city_api.rs 里没有 city_send_part"
grep -Fq "clearance: &AudioClearance" <<<"$SEND_PART" \
  || fail "city_send_part 不要凭据就调得动"
for call in "build_part(" ".file_put("; do
  [[ "$(grep -Fc -- "$call" "$CITY_STRIPPED")" == "1" && "$(grep -Fc -- "$call" <<<"$SEND_PART")" == "1" ]] \
    || fail "city_api.rs 在 city_send_part 之外调了 $call(或者调了不止一次)"
done

# 调它的只有一处,而且先过闸。
FILE_PART="$(rust_fn "$CITY_STRIPPED" city_file_part)"
[[ -n "$FILE_PART" ]] || fail "city_api.rs 里没有 city_file_part"
[[ "$(grep -Fc "city_send_part(" "$CITY_STRIPPED")" == "2" ]] \
  || fail "city_send_part 在 city_file_part 之外也被调了"
GATE_AT="$(grep -Fn "self.city_audio_clearance(" <<<"$FILE_PART" | head -1 | cut -d: -f1 || true)"
SEND_AT="$(grep -Fn "self.city_send_part(" <<<"$FILE_PART" | head -1 | cut -d: -f1 || true)"
[[ -n "$GATE_AT" && -n "$SEND_AT" && "$GATE_AT" -lt "$SEND_AT" ]] \
  || fail "city_file_part 没有先过 city_audio_clearance 再发"
[[ "$(grep -Fc "city_file_part(" "$CITY_STRIPPED")" == "2" ]] \
  || fail "city_file_part 应当只被导出的 city_file_audio_part 调"
grep -Fq "self.city_file_part(" <<<"$(rust_fn "$CITY_STRIPPED" city_file_audio_part)" \
  || fail "city_file_audio_part 没有走 city_file_part"

# 6d. 别的出口够不到。vt-city 只有 vt-ffi 依赖,vt-ffi 里只有 city_api.rs 用它;
# 传文件、签分段的函数名在别处一次也不出现。
while IFS= read -r manifest; do
  case "$manifest" in
    */vt-ffi/Cargo.toml | */vt-city/Cargo.toml) continue ;;
  esac
  if grep -Eq "^[[:space:]]*vt-city[[:space:]]*=" "$manifest"; then
    fail "${manifest#"$ROOT_DIR/"} 依赖了 vt-city;能往城里传文件的只许是 vt-ffi 的 city_api.rs"
  fi
done < <(find "$ROOT_DIR/crates" -mindepth 2 -maxdepth 2 -name Cargo.toml | sort)
while IFS= read -r file; do
  if awk '/^#\[cfg\(test\)\]$/{exit} {print}' "$file" | sed 's://.*::' \
      | grep -En "vt_city|file_put\(|build_part\(|city_send_part\(|city_file_part\(|city_file_audio_part\(" >/dev/null; then
    fail "${file#"$ROOT_DIR/"} 够到了交音频的函数;音频只许经 city_api.rs 交到档案馆"
  fi
done < <(find "$ROOT_DIR/crates" -type f -name '*.rs' -path '*/src/*' \
  ! -path "$CITY_CRATE/*" ! -path "$CITY_API" | sort)

# 6f. App 这一头。为档案馆导出音频(把一段录音编成 AAC 文件)只许在
# CityAudioExport*.swift 里做,而且要先问 core 的计划(cityAudioPlan 说不交就
# 不导出);它不走会连别的东西一起打包的 zip 导出。别的 City*.swift 照旧不碰
# 音频。交音频的入口(cityFileAudioPart)只许 City*.swift 调 —— 链接、同步、
# 附近的界面调不到。
while IFS= read -r file; do
  NAME="${file##*/}"
  CODE="$(sed 's://.*::' "$file")"
  if [[ "$NAME" == CityAudioExport*.swift ]]; then
    if grep -En "exportSessionZip|includeAudio|audio\.wav" <<<"$CODE" >/dev/null; then
      fail "${file#"$ROOT_DIR/"} 走了 zip 导出;给档案馆的音频只导出编好码的分段"
    fi
    grep -Fq "cityAudioPlan" <<<"$CODE" \
      || fail "${file#"$ROOT_DIR/"} 没有先问 cityAudioPlan 就导出音频"
    continue
  fi
  if grep -En "exportSessionZip|includeAudio|audio\.wav|\"wav\"|AVAudioFile|decryptSessionAudio|getAudioSegment|AVAssetWriter|AVAssetExportSession|ExtAudioFile|AudioConverter" <<<"$CODE" >/dev/null; then
    fail "${file#"$ROOT_DIR/"} 碰了音频导出;档案馆的音频导出只许在 CityAudioExport*.swift 里"
  fi
done < <(find "$SWIFT_DIR" -type f -name 'City*.swift' | sort)
while IFS= read -r file; do
  if sed 's://.*::' "$file" | grep -En "cityFileAudioPart" >/dev/null; then
    fail "${file#"$ROOT_DIR/"} 调了交音频的入口;那只许 City*.swift 调"
  fi
done < <(find "$SWIFT_DIR" -type f -name '*.swift' ! -name 'City*.swift' ! -path '*/Bridge/Generated/*' | sort)

echo "✓ [share] 音频不可共享、不可同步;交档案馆的音频只走那一道闸;标记不交 —— 六层约束成立"
