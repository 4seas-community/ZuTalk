#!/usr/bin/env bash
# caption-web 跨层冒烟:真实 Rust 链接共享 → 本地 Python 服务 → SSE → 用链接
# 里的密钥解开。
#
# 防的是两边契约漂移:Rust 侧 serde 字段名、信封格式与服务端/观看页读的分家时,
# 单元测试两边各自全绿,链路却是断的。Rust 那条测试自己在本机起一份
# services/caption-web/server.py;这里只是把「本机没有 python3 就跳过」变成失败。
set -euo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null || { echo "FAIL: 需要 python3 起本地 caption-web"; exit 1; }

OUTPUT=$(cargo test -p vt-ffi --lib \
    link_share::tests::a_link_round_trip_against_the_caption_service \
    -- --exact --nocapture 2>&1)
echo "$OUTPUT" | grep -q "跳过" && { echo "$OUTPUT" | tail -5; echo "FAIL: 本地服务没起来"; exit 1; }
echo "$OUTPUT" | grep -q "test result: ok. 1 passed" || {
    echo "$OUTPUT" | tail -30
    echo "FAIL: Rust 链路冒烟未通过"
    exit 1
}

# 观看页本身:脚本语法、解密入口。
(cd services/caption-web && python3 -m unittest \
    test_server.CaptionWebTests.test_viewer_page_script_parses \
    test_server.CaptionWebTests.test_viewer_page_serves_inline_html 2>&1 | tail -1) \
    | grep -q "^OK" || { echo "FAIL: 观看页检查未通过"; exit 1; }

echo "✓ [caption-web] Rust→服务→SSE→解密 链路冒烟通过"
