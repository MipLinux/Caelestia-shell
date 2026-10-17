#!/usr/bin/env bash
# render-pr-review.py 的回归测试：合法 JSON、代码围栏、越界行号、坏 JSON。
#
# 不需要 root。用法：./scripts/workflow/tests/render-pr-review.test.sh

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SELF_DIR/../render-pr-review.py"

FAIL=0
pass() { printf '✅ %s\n' "$1"; }
bad()  { printf '❌ %s\n' "$1"; FAIL=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
[ -f "$SCRIPT" ] || { echo "错误：读不到 $SCRIPT" >&2; exit 1; }

cat >"$T/context.md" <<'EOF'
文件: modules/bar/Bar.qml
========================================================
[L4] Item {
[L5]     property string label: qsTr("hello")
[L6] }
EOF

run_case() { # $1=名字 $2=响应内容 $3=期望行级批注数 $4=期望正文包含
  local name=$1 response=$2 want_comments=$3 want_body=$4 out="$T/$1"
  printf '%s' "$response" >"$out.response"
  python3 "$SCRIPT" --response "$out.response" --context "$T/context.md" \
    --head 0123456789abcdef --output "$out.payload.json" >"$out.log" 2>&1 || {
      bad "$name（脚本退出码非 0）"; cat "$out.log" | sed 's/^/     /'; return;
    }
  local got
  got=$(jq '.comments | length' "$out.payload.json")
  if [ "$got" -ne "$want_comments" ]; then
    bad "$name（行级批注 $got，期望 $want_comments）"
    return
  fi
  if [ -n "$want_body" ] && ! jq -r '.body' "$out.payload.json" | grep -qF -- "$want_body"; then
    bad "$name（正文里没有「$want_body」）"
    return
  fi
  pass "$name"
}

run_case valid '{"summary":"ok","verdict":"PASS","comments":[{"path":"modules/bar/Bar.qml","line":5,"category":"ENGINEERING","severity":"WARNING","message":"test"}]}' 1 "PASS"
run_case fenced '```json
{"summary":"ok","verdict":"NEEDS_ATTENTION","comments":[{"path":"modules/bar/Bar.qml","line":5,"category":"REDLINE","severity":"ERROR","message":"test"}]}
```' 1 "NEEDS_ATTENTION"
run_case line-outside '{"summary":"ok","verdict":"NEEDS_ATTENTION","comments":[{"path":"modules/bar/Bar.qml","line":99,"category":"ENGINEERING","severity":"WARNING","message":"outside"}]}' 0 "无法贴到具体行"
run_case bad-json 'not json at all' 0 "解析异常"
run_case empty '' 0 "审查结果为空"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结论：Review payload 整形符合预期。"
  exit 0
fi
echo "结论：有失败项。"
exit 1
