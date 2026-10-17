#!/usr/bin/env bash
# pr-review-context.sh 的回归测试：造一个临时 git 仓库，验证 diff 行号、机械信号与截断提示。
#
# 不需要 root。用法：./scripts/workflow/tests/pr-review-context.test.sh

set -uo pipefail
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SELF_DIR/../pr-review-context.sh"

FAIL=0
pass() { printf '✅ %s\n' "$1"; }
bad()  { printf '❌ %s\n' "$1"; FAIL=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
[ -f "$SCRIPT" ] || { echo "错误：读不到 $SCRIPT" >&2; exit 1; }

R="$T/repo"
mkdir -p "$R/modules/bar"
git -C "$R" init -q
git -C "$R" checkout -q -B main
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

cat >"$R/modules/bar/Bar.qml" <<'EOF'
import QtQuick

Item {
    id: root
}
EOF
git -C "$R" add .
git -C "$R" commit -q -m "init"

cat >"$R/modules/bar/Bar.qml" <<'EOF'
import QtQuick

Item {
    id: root

    property string label: qsTr("hello")
    // 中文注释

    Component.onCompleted: {
        sudo rm -rf /tmp/example
    }
}
EOF

if CAELESTIA_PROJECT_ROOT="$R" "$SCRIPT" --dry-run --out "$R/out" >"$R/log" 2>&1; then
  pass "dry-run 退出码 0"
else
  bad "dry-run 失败：$(tail -2 "$R/log")"
fi

C="$R/out/context.md"
[ -f "$C" ] && pass "context.md 已生成" || bad "context.md 没生成"
grep -q '文件: modules/bar/Bar.qml' "$C" && pass "diff 文件头正确" || bad "diff 文件头缺失"
grep -q '\[L5\]' "$C" && pass "新增行带 [L行号] 标记" || bad "新增行没有行号标记"
grep -q 'qsTr' "$C" && pass "qsTr 机械信号被检出" || bad "qsTr 机械信号没检出"
grep -q 'sudo' "$C" && pass "sudo 机械信号被检出" || bad "sudo 机械信号没检出"
grep -q '中文注释' "$C" && pass "中文内容未被截断破坏" || bad "中文内容缺失"

if CAELESTIA_PROJECT_ROOT="$R" CAELESTIA_REVIEW_MAX_DIFF_BYTES=40 "$SCRIPT" --dry-run --out "$R/out-small" >"$R/log-small" 2>&1; then
  pass "截断模式退出码 0"
else
  bad "截断模式失败：$(tail -2 "$R/log-small")"
fi
grep -q 'diff 已截断' "$R/out-small/context.md" && pass "超限 diff 给出截断提示" || bad "超限 diff 没有截断提示"

if "$SCRIPT" --pr abc >"$R/log-badpr" 2>&1; then
  bad "非数字 --pr 没有被拒绝"
else
  pass "非数字 --pr 被拒绝"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结论：diff 上下文与机械信号符合预期。"
  exit 0
fi
echo "结论：有失败项。"
exit 1
