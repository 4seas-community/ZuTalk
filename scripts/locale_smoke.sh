#!/usr/bin/env bash
# locale_smoke.sh — 给 Zulangue.app 单独覆盖 AppleLanguages,不改系统语言.
#
# 用法:
#   ./scripts/locale_smoke.sh en       # 英文启动
#   ./scripts/locale_smoke.sh zh-Hans  # 简中启动
#   ./scripts/locale_smoke.sh ja       # 日文启动
#   ./scripts/locale_smoke.sh reset    # 清空覆盖,恢复跟随系统
#
# 需已 `just xcode-build` 完成. App 必须未运行(脚本会 killall).

set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="xyz.voice.zulangue"
APP_PATH="$ROOT_DIR/build/app/Zulangue.app"

usage() { echo "usage: $0 {en|zh-Hans|ja|reset}" >&2; exit 2; }

[ $# -eq 1 ] || usage
lang="$1"

# 杀掉在运行的实例,保证下次读到新的 AppleLanguages
killall Zulangue 2>/dev/null || true
sleep 0.4

case "$lang" in
  en|zh-Hans|ja)
    echo "设 AppleLanguages = ($lang) for $BUNDLE_ID"
    defaults write "$BUNDLE_ID" AppleLanguages -array "$lang"
    ;;
  reset)
    echo "清空 AppleLanguages (恢复跟随系统) for $BUNDLE_ID"
    defaults delete "$BUNDLE_ID" AppleLanguages 2>/dev/null || true
    ;;
  *)
    usage
    ;;
esac

if [ "$lang" != "reset" ]; then
  echo "启动 $APP_PATH"
  open -a "$APP_PATH"
fi
