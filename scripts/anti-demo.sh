#!/bin/bash
# 静态守门：检查示例数据、硬编码密钥和未完成代码。
#
# 设计目标:
# - 1 秒内跑完 (CI 友好 + pre-commit hook 友好)
# - 失败时给清晰的文件路径 + 行号
# - 对常见的「已知漏洞模式」做防御性 grep
#
# 用法:
#   bash scripts/anti-demo.sh           # 单独跑
#   just lint                            # 通过 just 运行

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXIT_CODE=0
TOTAL_CHECKS=0
FAILED_CHECKS=0

# 颜色 (CI 也支持)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_check() {
    local name="$1"
    local pattern="$2"
    local include="$3"
    local exclude_pattern="${4:-}"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    local find_args=(-type f)
    IFS=',' read -ra inc_arr <<< "$include"
    if [ ${#inc_arr[@]} -gt 0 ]; then
        find_args+=( \( )
        local first=true
        for ext in "${inc_arr[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                find_args+=( -o )
            fi
            find_args+=( -name "*.$ext" )
        done
        find_args+=( \) )
    fi

    # 排除常见目录
    find_args+=(
        -not -path '*/target/*'
        -not -path '*/.git/*'
        -not -path '*/DerivedData/*'
        -not -path '*/build/*'
        -not -path '*/dist/*'
    )

    if [ -n "$exclude_pattern" ]; then
        find_args+=( -not -path "$exclude_pattern" )
    fi

    local results
    results=$(find "$ROOT" "${find_args[@]}" 2>/dev/null | xargs grep -nH -E "$pattern" 2>/dev/null || true)

    if [ -n "$results" ]; then
        echo -e "${RED}✗${NC} $name"
        echo "$results" | sed 's/^/    /'
        echo
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        EXIT_CODE=1
    else
        echo -e "${GREEN}✓${NC} $name"
    fi
}

echo "=== anti-demo.sh — Zulangue 静态守门 ==="
echo "ROOT: $ROOT"
echo

# 示例数据标记不能进入生产源码。
run_check \
    "[examples] no demo markers in production" \
    "DEMO_DATA|FAKE_DATA|demoLines|hardcodedDemo" \
    "swift,rs" \
    "*Tests*"

# 硬编码 API key
run_check \
    "[security] no hardcoded API keys (sk-XXX...)" \
    "sk-(or-)?[a-zA-Z0-9]{20,}" \
    "swift,rs,toml,yaml,json,sh,rb" \
    "*test*"

# Public source must not expose prior product identities or machine-local paths.
# Keep the blocked identity fragments separated so the public source does not
# reproduce those names while the guard can still reject regressions.
prior_identity_pattern='4[[:space:]_-]*S''EAS|Four''Seas|Voice''Tool|hpe''Xt'
run_check \
    "[public] no prior product or service identities" \
    "$prior_identity_pattern" \
    "swift,rs,md,sh,rb,toml,yaml,yml,json,pbxproj,strings" \
    "*/scripts/anti-demo.sh"

run_check \
    "[public] no private absolute user paths" \
    "/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/" \
    "swift,rs,md,sh,rb,toml,yaml,yml,json,pbxproj,strings"

public_email_pattern='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
run_check \
    "[public] no personal email addresses" \
    "$public_email_pattern" \
    "swift,rs,md,sh,rb,toml,yaml,yml,json,pbxproj,strings" \
    "*/scripts/anti-demo.sh"

# Internal issue labels and unreleased product claims are not public documentation.
internal_record_pattern='Ph''ase[[:space:]_-]*[A-Z]-?[0-9]+|B''UG-[0-9]+|[[:space:]#(/]C-[0-9]+|暂''未实现|计划''中的|未来''设备|future device sh''aring'
run_check \
    "[public] no internal development records" \
    "$internal_record_pattern" \
    "swift,rs,md,sh,rb,toml,yaml,yml,json,pbxproj,strings" \
    "*/scripts/anti-demo.sh"

TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
tracked_private_trees=$(git ls-files -- 'archive/**' 'fuzz/target/**' 'target/**')
if [ -n "$tracked_private_trees" ]; then
    echo -e "${RED}✗${NC} [public] archive or build output is tracked:"
    echo "$tracked_private_trees" | sed 's/^/    /'
    echo
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    EXIT_CODE=1
else
    echo -e "${GREEN}✓${NC} [public] no archive or build output is tracked"
fi

# todo!() / unimplemented!() 不能进入 production Rust。
# (排除 tests/ 目录 + inline #[cfg(test)] mod 块, 那些是 mock impl 用的)
echo "─ Production todo!()/unimplemented!() check ─"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
deadcode_results=$(find "$ROOT" -name "*.rs" \
    -not -path '*/target/*' \
    -not -path '*/tests/*' \
    -not -path '*/Bridge/Generated/*' \
    -not -path '*/build/*' 2>/dev/null | while read -r file; do
    awk '
        /^#\[cfg\(test\)\]/ { in_test = 1 }
        in_test == 0 && /unimplemented!\(\)|todo!\(\)/ {
            print FILENAME ":" NR ": " $0
        }
    ' "$file"
done)

if [ -n "$deadcode_results" ]; then
    echo -e "${RED}✗${NC} [deadcode] todo!()/unimplemented!() in production Rust:"
    echo "$deadcode_results" | sed 's/^/    /'
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    EXIT_CODE=1
else
    echo -e "${GREEN}✓${NC} [deadcode] no production todo!()/unimplemented!()"
fi
echo

# FIXME / XXX 警告
echo -e "${YELLOW}─ FIXME/XXX scan (informational) ─${NC}"
fixme_results=$(find "$ROOT" \( -name "*.swift" -o -name "*.rs" \) \
    -not -path '*/target/*' \
    -not -path '*/Bridge/Generated/*' \
    -not -path '*/build/*' \
    2>/dev/null | xargs grep -nH -E "FIXME|XXX:" 2>/dev/null || true)
if [ -n "$fixme_results" ]; then
    fixme_count=$(echo "$fixme_results" | wc -l | tr -d ' ')
    echo "  $fixme_count FIXME/XXX markers found (not blocking)"
else
    echo "  0 FIXME/XXX markers"
fi
echo

# notification post 必须有 listener。
# 关闭 pipefail/exit-on-error 因为 grep 找不到匹配会返回 1
set +e
set +o pipefail

echo "─ Notification wiring check ─"
notif_names=$(grep -rEoh "zulangue[A-Z][a-zA-Z]*" \
    "$ROOT/macos/Zulangue/Zulangue" \
    --include='*.swift' 2>/dev/null | sort -u)

if [ -z "$notif_names" ]; then
    echo -e "${YELLOW}  no zulangue notifications found (skipped)${NC}"
else
    notif_failed=false
    for name in $notif_names; do
        post_count=$(grep -rE "post\\(name: \\.${name}|object: \\.${name}" \
            "$ROOT/macos/Zulangue/Zulangue" \
            --include='*.swift' \
            --exclude-dir='Bridge' 2>/dev/null | wc -l | tr -d ' ')

        observe_count=$(grep -rE "publisher\\(for: \\.${name}|name: \\.${name}|forName: \\.${name}|selector\\(for: \\.${name}" \
            "$ROOT/macos/Zulangue/Zulangue" \
            --include='*.swift' \
            --exclude-dir='Bridge' 2>/dev/null | wc -l | tr -d ' ')

        if [ "$post_count" -gt 0 ] && [ "$observe_count" -eq 0 ]; then
            if [ "$notif_failed" = false ]; then
                echo -e "${RED}✗${NC} [notification] posted but no observer:"
                notif_failed=true
                FAILED_CHECKS=$((FAILED_CHECKS + 1))
                EXIT_CODE=1
            fi
            echo "    .$name (posted ${post_count}x, observed 0x)"
        fi
    done
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [ "$notif_failed" = false ]; then
        notif_count=$(echo "$notif_names" | wc -l | tr -d ' ')
        echo -e "${GREEN}✓${NC} [notification] all $notif_count zulangue notifications have listeners"
    fi
fi

set -e
set -o pipefail

echo
echo "=== Summary ==="
PASSED=$((TOTAL_CHECKS - FAILED_CHECKS))
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ ALL CHECKS PASSED${NC}: $PASSED/$TOTAL_CHECKS"
else
    echo -e "${RED}✗ FAILURES${NC}: $FAILED_CHECKS/$TOTAL_CHECKS checks failed"
fi

exit $EXIT_CODE
