#!/usr/bin/env bash
# 更新可达性:这一版的 app 必须仍然被上一版**找得到**。
#
# Sparkle 解包之后要在更新目录里挑出「要装的那个 bundle」,判据写死在
# Sparkle 2.9.4 的 Autoupdate/SUInstaller.m 里,用的全是**已装的那一份**手
# 里的名字:
#
#   1. 新 bundle 的文件名 == 已装 app 的文件名(ZuTalk.app)
#   2. 新 bundle 的文件名 == 已装 app 的显示名 + ".app"
#   3. 新 bundle 的 CFBundleIdentifier == 已装 app 的 CFBundleIdentifier
#
# 三条全不中,Sparkle 报 "No suitable install is found in the update",而这
# 个错误(SUValidationError)在 SPUInstallerDriver 里被统一翻译成「此更新未
# 正确签名,无法验证其真实性」。签名其实是好的——0.4.1 的 DMG、delta 与
# appcast 三个 Ed25519 签名都能用 App 内置公钥验过——但用户看到的是签名出
# 了问题,开发者也会照着签名去查。
#
# 0.4.0 同时改掉了文件名(Zulangue.app → ZuTalk.app)与 bundle ID
# (xyz.voice.zulangue → xyz.voice.zutalk),三条匹配一条不剩,于是每一份
# 0.3.x 安装从那一版起就再也更新不动了,只能手动重装一次。那批安装已经追
# 不回来:它们编译进去的判据就是那两个旧名字。
#
# 所以这道门禁守的不是签名,是「新版本还在不在老版本的视野里」。
# packaging/update-identity.json 记着已经发出去的那份身份;要改它,等于宣布
# 放弃现存的全部安装,必须是一次明写在提交里的决定,不能是改名时的顺手连带。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RECORD="$ROOT_DIR/packaging/update-identity.json"
APP_PATH="${1:-$ROOT_DIR/build/app/ZuTalk.app}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$RECORD" ]] \
  || fail "packaging/update-identity.json is missing — 没有它就无从判断新版本是否还被老版本找得到"
[[ -d "$APP_PATH" ]] \
  || fail "$APP_PATH does not exist — 先构建 app 再跑这道门禁"

PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$PLIST" ]] || fail "$PLIST is missing"

read_record() {
  python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    record = json.load(handle)
value = record.get(sys.argv[2], "")
if not isinstance(value, str) or not value.strip():
    raise SystemExit(1)
print(value.strip())
' "$RECORD" "$1"
}

SHIPPED_FILE_NAME="$(read_record bundle_file_name)" \
  || fail "packaging/update-identity.json is missing bundle_file_name"
SHIPPED_DISPLAY_NAME="$(read_record display_name)" \
  || fail "packaging/update-identity.json is missing display_name"
SHIPPED_BUNDLE_ID="$(read_record bundle_id)" \
  || fail "packaging/update-identity.json is missing bundle_id"

NEW_FILE_NAME="$(basename "$APP_PATH")"
NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[[ -n "$NEW_BUNDLE_ID" ]] || fail "$PLIST has no CFBundleIdentifier"

# 与 SUInstaller.m 的三条判据一一对应,顺序也一致。
if [[ "$NEW_FILE_NAME" == "$SHIPPED_FILE_NAME" ]]; then
  MATCHED="bundle 文件名 $NEW_FILE_NAME"
elif [[ "$NEW_FILE_NAME" == "$SHIPPED_DISPLAY_NAME.app" ]]; then
  MATCHED="bundle 文件名 $NEW_FILE_NAME == 已装 app 的显示名 $SHIPPED_DISPLAY_NAME"
elif [[ "$NEW_BUNDLE_ID" == "$SHIPPED_BUNDLE_ID" ]]; then
  MATCHED="bundle ID $NEW_BUNDLE_ID"
else
  cat >&2 <<EOF
FAIL: 已发布的 $SHIPPED_FILE_NAME($SHIPPED_BUNDLE_ID)在这份更新里找不到要装的 app。

  已装的那一份会去找:  $SHIPPED_FILE_NAME / $SHIPPED_DISPLAY_NAME.app / $SHIPPED_BUNDLE_ID
  这份更新里实际是:    $NEW_FILE_NAME / $NEW_BUNDLE_ID

  发出去的话,每一份已装副本都会拒收这次以及此后的每一次更新,弹出的是
  「此更新未正确签名,无法验证其真实性」——签名没问题,这句话会把用户和你
  自己都带到错误的方向去查。已装的副本改不了,只能让用户手动重装一次,而
  能通知到他们的渠道只有更新提示里的发布说明。

  确实要放弃现存安装,就在同一个提交里更新 packaging/update-identity.json,
  并在 packaging/release-notes.md 里替这批用户写清楚该怎么做。
  背景见 docs/service-rename.md 第 1.5 节。
EOF
  exit 1
fi

echo "✓ 已发布的 $SHIPPED_FILE_NAME 仍能在更新包里找到这一版:$MATCHED"
