#!/usr/bin/env bash
# 工作 issue 草案守卫：检查 out/issue-drafts/*.md 是否符合 docs/work/README.md 的规范。
#
# 它只做本地能确定的事：字段齐备且顺序正确、实现里有文件路径、验收含命令与期望、
# 行数上限、骨架与网页表单没有漂移。
#
# 不需要 root，只读，不联网。
#
# 用法：
#   ./scripts/workflow/check-work-issue.sh
#   ./scripts/workflow/check-work-issue.sh out/issue-drafts/x.md
#   CAELESTIA_WORK_DRAFTS=/tmp/drafts ./scripts/workflow/check-work-issue.sh
#
# 退出码：0 = 全部合规；1 = 有不合规项。

set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)

DRAFT_DIR=${CAELESTIA_WORK_DRAFTS:-$PROJECT_ROOT/out/issue-drafts}
TEMPLATE=${CAELESTIA_WORK_TEMPLATE:-$PROJECT_ROOT/docs/work/TEMPLATE.md}
FORM=${CAELESTIA_WORK_FORM:-$PROJECT_ROOT/.github/ISSUE_TEMPLATE/task.yml}

FIELDS=(目标 实现 验收 回报 依赖)
MAX_LINES=60
problems=0

fail() { printf '❌ %s\n' "$1"; problems=$((problems + 1)); }
ok()   { printf '✅ %s\n' "$1"; }
note() { printf '   %s\n' "$1"; }

section() { # $1=文件 $2=字段
  awk -v want="$2" '
    $0 == "### " want { inside = 1; next }
    /^### / { inside = 0 }
    inside { print }
  ' "$1"
}

nonempty() { [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

check_draft() { # $1=草案文件
  local f="$1" rel
  case "$f" in
    "$PROJECT_ROOT"/*) rel=${f#"$PROJECT_ROOT"/} ;;
    *) rel=$f ;;
  esac
  echo "── $rel"

  if ! nonempty "$(cat "$f")"; then
    fail "$rel 是空的"
    return
  fi

  if [ "$(head -1 "$f")" = "---" ]; then
    fail "$rel 首行是 ---（YAML frontmatter）—— issue 正文不接受 frontmatter"
  fi
  if grep -q '<!--' "$f"; then
    fail "$rel 含 HTML 注释 —— 抄模板时把用法说明一起抄进来了"
  fi

  local want_seq got_seq n_got
  want_seq=$(printf '%s\n' "${FIELDS[@]}")
  got_seq=$(grep -oE '^### .+$' "$f" | sed 's/^### //' || true)
  n_got=$(printf '%s\n' "$got_seq" | grep -c . || true)
  if [ "$got_seq" = "$want_seq" ]; then
    ok "字段齐备且顺序正确（${#FIELDS[@]} 个）"
  else
    fail "$rel 的字段与规范不符 —— 应为「${FIELDS[*]}」各一次、顺序不变，实际是「$(printf '%s ' $got_seq)」（共 $n_got 个 ### 小节）"
  fi

  nonempty "$(section "$f" 目标)" || fail "$rel 的「目标」是空的"

  if section "$f" 实现 | grep -qE '(^|[^[:alnum:]_])((modules|components|services|utils|plugin|extras|nix|scripts|docs|assets|\.github)/|CMakeLists\.txt|shell\.qml|flake\.(nix|lock)|README\.md|NOTICE\.md|LICENSE|AGENTS\.md)'; then
    ok "实现里写了文件路径"
  else
    fail "$rel 的「实现」里没有一条文件路径 —— 所有权按文件切，路径写出来才拦得住撞车"
  fi

  local accept
  accept=$(section "$f" 验收)
  if printf '%s' "$accept" | grep -q '`' && printf '%s' "$accept" | grep -qE '期望|→|->'; then
    ok "验收含命令与期望结果"
  else
    fail "$rel 的「验收」要写成命令 + 期望结果（含反引号包住的命令，并写出期望）——「跑起来了」不是判据"
  fi

  local field
  for field in 回报 依赖; do
    nonempty "$(section "$f" "$field")" || fail "$rel 的「$field」是空的"
  done

  grep -q 'AI 起草' "$f" || fail "$rel 缺「本 issue 由 AI 起草」声明"
  grep -q 'git switch main' "$f" || fail "$rel 缺「开工前请执行」里的 git switch main"

  local lines
  lines=$(wc -l <"$f")
  if [ "$lines" -gt "$MAX_LINES" ]; then
    fail "$rel 有 $lines 行，超过 $MAX_LINES 行上限 —— 过程和实测输出请进 issue 评论或 PR 正文"
  else
    ok "$lines 行（上限 $MAX_LINES）"
  fi
}

check_templates() {
  echo "── 骨架 ↔ 表单"
  local skeleton labels want_seq
  skeleton=$(grep -oE '^### .+$' "$TEMPLATE" | sed 's/^### //' || true)
  labels=$(grep -oE '^[[:space:]]*label: .+$' "$FORM" | sed 's/^[[:space:]]*label: //' || true)

  want_seq=$(printf '%s\n' "${FIELDS[@]}")
  if [ "$skeleton" = "$want_seq" ]; then
    ok "TEMPLATE.md 的字段与规范一致"
  else
    fail "TEMPLATE.md 的字段应为「${FIELDS[*]}」，实际是「$(printf '%s ' $skeleton)」"
  fi
  if [ "$labels" = "$want_seq" ]; then
    ok "task.yml 的字段与规范一致"
  else
    fail "task.yml 的 label 应为「${FIELDS[*]}」，实际是「$(printf '%s ' $labels)」—— 骨架改了表单没改？"
  fi

  grep -q '^title: "\[工作\] "' "$FORM" || fail "task.yml 的标题前缀不是「[工作] 」"
  grep -q '^labels: \["task"\]' "$FORM" || fail "task.yml 没有 labels: [\"task\"]"
  [ "$(grep -c 'required: true' "$FORM" || true)" -eq "${#FIELDS[@]}" ] \
    || fail "task.yml 的必填字段数不等于 ${#FIELDS[@]} —— 每个字段都要 required: true"
}

echo "── 草案目录：${DRAFT_DIR#"$PROJECT_ROOT"/}"
if [ $# -gt 0 ]; then
  for f in "$@"; do
    [ -f "$f" ] || { echo "错误：读不到 $f" >&2; exit 1; }
    check_draft "$(cd -- "$(dirname -- "$f")" && pwd)/$(basename -- "$f")"
  done
elif [ -d "$DRAFT_DIR" ]; then
  found=0
  for f in "$DRAFT_DIR"/*.md; do
    [ -e "$f" ] || continue
    found=$((found + 1))
    check_draft "$f"
  done
  [ "$found" -gt 0 ] || note "没有草案（$DRAFT_DIR 是空的）—— 只比对骨架与表单"
else
  note "没有草案目录（$DRAFT_DIR 不存在）—— 只比对骨架与表单"
fi

echo
for t in "$TEMPLATE" "$FORM"; do
  [ -f "$t" ] || { echo "错误：读不到 $t" >&2; exit 1; }
done
check_templates

echo
if [ "$problems" -eq 0 ]; then
  echo "结论：草案符合规范，骨架与表单没有漂移。"
  exit 0
fi
printf '结论：发现 %d 处不合规。规范见 docs/work/README.md。\n' "$problems"
exit 1
