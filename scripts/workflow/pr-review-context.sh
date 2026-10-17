#!/usr/bin/env bash
# PR 代码审查上下文生成器 —— 提取 git diff、计算机械信号、组装模型输入。
#
# 用法：
#   ./scripts/workflow/pr-review-context.sh --pr <N> [--out <DIR>]
#   ./scripts/workflow/pr-review-context.sh --dry-run [--out <DIR>]
#
# 产物（写入 --out，默认 /tmp/caelestia-pr-review）：
#   meta.tsv       PR 基础元数据
#   context.md     组装好、喂给模型的完整上下文（含带行号的 diff 与机械告警）
#
# 不需要 root。退出码：0 = 正常；1 = 参数错误或执行失败。

set -euo pipefail
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=${CAELESTIA_PROJECT_ROOT:-$(cd -- "$SELF_DIR/../.." && pwd)}

MODE=""
PR=""
OUT_DIR=${CAELESTIA_PR_REVIEW_OUT:-/tmp/caelestia-pr-review}
MAX_DIFF_BYTES=${CAELESTIA_REVIEW_MAX_DIFF_BYTES:-200000}

usage() {
  cat <<'EOF'
用法：
  pr-review-context.sh --pr <N> [--out <DIR>]
  pr-review-context.sh --dry-run [--out <DIR>]

  --pr       取 GitHub PR 数据与 diff
  --dry-run  离线比对本地分支与 main 的 diff（自检 / 回归测试）
  --out      输出目录（默认 /tmp/caelestia-pr-review）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      [ $# -ge 2 ] || { echo "错误：--pr 需要一个编号" >&2; exit 1; }
      MODE=pr; PR=$2
      case "$PR" in ''|*[!0-9]*) echo "错误：--pr 必须是纯数字" >&2; exit 1 ;; esac
      shift 2 ;;
    --dry-run) MODE=dryrun; shift ;;
    --out) [ $# -ge 2 ] || { echo "错误：--out 需要一个目录" >&2; exit 1; }; OUT_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：不认识参数 $1（见 --help）" >&2; exit 1 ;;
  esac
done
[ -n "$MODE" ] || { usage; exit 1; }

mkdir -p "$OUT_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 给 unified diff 加 [L行号] 标记；新增行用新文件行号，删除行不编号。
annotate_diff() {
  local diff_file=$1
  awk '
    /^diff --git / { in_hunk = 0; next }
    /^\+\+\+ b\// {
      file = substr($0, 7);
      print "\n========================================================";
      print "文件: " file;
      print "========================================================";
      next;
    }
    /^@@ / {
      split($3, arr, ",");
      new_line = substr(arr[1], 2) + 0;
      in_hunk = 1;
      print $0;
      next;
    }
    in_hunk {
      if ($0 ~ /^\\/) {
        print $0;
      } else if ($0 ~ /^\+/) {
        printf "[L%d] %s\n", new_line, $0;
        new_line++;
      } else if ($0 ~ /^-/) {
        print $0;
      } else {
        printf "[L%d] %s\n", new_line, $0;
        new_line++;
      }
    }
  ' "$diff_file"
}

detect_mechanical_signals() {
  local diff_file=$1
  local signals=()

  local raw_sudo
  raw_sudo=$(grep -En '^\+[[:space:]]*sudo[[:space:]]+' "$diff_file" || true)
  if [ -n "$raw_sudo" ]; then
    signals+=("发现新增的 sudo 调用（CI / 脚本不应隐式提权）："$'\n'"$raw_sudo")
  fi

  local qstr
  qstr=$(grep -En '^\+.*\bqsTr\s*\(' "$diff_file" || true)
  if [ -n "$qstr" ]; then
    signals+=("发现 qsTr（应使用仓库的 Tr.tr / Tr.trCtx / Tr.trN 封装，见 docs/work/ai-code-review-rubric.md）："$'\n'"$qstr")
  fi

  local unquoted_vars
  unquoted_vars=$(grep -En '^\+[[:space:]]*(rm|cp|mv|cd|cat)[[:space:]]+[^"'\''#]*\$(TARGET|OUT_DIR|IMAGE|FILE|BUILD_DIR|ROOT)([[:space:]]|$)' "$diff_file" || true)
  if [ -n "$unquoted_vars" ]; then
    signals+=("发现文件操作命令中路径变量未加双引号保护："$'\n'"$unquoted_vars")
  fi

  local raw_secret
  raw_secret=$(grep -En '^\+.*(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY|(DEEPSEEK_API_KEY|REVIEWER_PRIVATE_KEY)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_./+-]{12,})' "$diff_file" || true)
  if [ -n "$raw_secret" ]; then
    signals+=("发现疑似密钥 / 凭据字面量（不要提交任何密钥）："$'\n'"$raw_secret")
  fi

  local backticks
  backticks=$(grep -En '^\+.*`[^`]*`' "$diff_file" | grep -E '^\+[[:space:]]*(echo|printf|local|export|[A-Z_]+=)' || true)
  if [ -n "$backticks" ]; then
    signals+=("发现新增行可能使用反引号命令替换（应使用 \$()）："$'\n'"$backticks")
  fi

  if [ ${#signals[@]} -eq 0 ]; then
    echo "未检测到明显的显式机械违规特征。"
  else
    local s
    for s in "${signals[@]}"; do
      printf -- '- ⚠️ %s\n' "$s"
    done
  fi
}

echo "── 运行模式：$MODE"

if [ "$MODE" = "pr" ]; then
  echo "正在获取 PR #$PR 数据..."
  gh pr view "$PR" --json number,title,headRefOid,baseRefName,body \
    -q '[.number, .title, .headRefOid, .baseRefName] | @tsv' \
    | awk -F'\t' '{printf "number\t%s\ntitle\t%s\nhead\t%s\nbase\t%s\n", $1, $2, $3, $4}' \
    >"$OUT_DIR/meta.tsv"

  gh pr view "$PR" --json body -q .body >"$TMP/pr-body.md"
  gh pr diff "$PR" >"$TMP/raw.diff"
else
  BASE_REF=$(git -C "$PROJECT_ROOT" merge-base HEAD origin/main 2>/dev/null || git -C "$PROJECT_ROOT" merge-base HEAD main 2>/dev/null || echo "HEAD~1")
  HEAD_OID=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
  BRANCH_NAME=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)

  printf "number\tdry-run\ntitle\t本地分支自检 (%s)\nhead\t%s\nbase\t%s\n" \
    "$BRANCH_NAME" "$HEAD_OID" "$BASE_REF" >"$OUT_DIR/meta.tsv"

  echo "本地测试 PR 描述（Dry-run 模式）" >"$TMP/pr-body.md"
  git -C "$PROJECT_ROOT" diff "$BASE_REF" >"$TMP/raw.diff"
fi

# 过滤生成物、依赖目录与二进制文件；审查只针对源码。
grep -vE '^diff --git a/(build/|result|out/|\.direnv/|node_modules/|\.cache/)' "$TMP/raw.diff" >"$TMP/filtered.diff" || true
grep -vE '^Binary files ' "$TMP/filtered.diff" >"$TMP/text.diff" || true

annotate_diff "$TMP/text.diff" >"$TMP/annotated.diff"

if [ "$(wc -c <"$TMP/annotated.diff")" -gt "$MAX_DIFF_BYTES" ]; then
  head -c "$MAX_DIFF_BYTES" "$TMP/annotated.diff" | iconv -f UTF-8 -t UTF-8 -c >"$TMP/truncated.diff" || true
  {
    cat "$TMP/truncated.diff"
    printf '\n\n[diff 已截断：原始 %s 字节，保留前 %s 字节]\n' \
      "$(wc -c <"$TMP/annotated.diff")" "$MAX_DIFF_BYTES"
  } >"$TMP/final.diff"
else
  cp "$TMP/annotated.diff" "$TMP/final.diff"
fi

SIGNALS=$(detect_mechanical_signals "$TMP/text.diff")

{
  echo "# PR 代码审查上下文"
  echo
  echo "## PR 基本信息"
  echo "- **PR**: $(awk -F'\t' '$1=="number"{print $2}' "$OUT_DIR/meta.tsv")"
  echo "- **标题**: $(awk -F'\t' '$1=="title"{print $2}' "$OUT_DIR/meta.tsv")"
  echo "- **Head SHA**: $(awk -F'\t' '$1=="head"{print $2}' "$OUT_DIR/meta.tsv")"
  echo "- **Base Ref**: $(awk -F'\t' '$1=="base"{print $2}' "$OUT_DIR/meta.tsv")"
  echo
  echo "## PR 正文"
  cat "$TMP/pr-body.md"
  echo
  echo "## 机械信号初筛"
  printf '%s\n' "$SIGNALS"
  echo
  echo "## 代码变更 Diff（含 [L行号] 标记）"
  cat "$TMP/final.diff"
} >"$OUT_DIR/context.md"

echo "✅ 上下文生成完成：$OUT_DIR/context.md"
