#!/usr/bin/env bash
# 验收对账的上下文生成器 —— 脚本算能算准的，语义交给模型。
#
# 它从 PR 正文的「## 验证方式」与它 Closes 的 issue 的「### 验收」抽条目，
# 给出机械信号（同值 / 同量纲异值 / 同名对象 / 词面），不判定真伪。
# 判据唯一源是 docs/work/ai-review-rubric.md C 节。
#
# 两个模式：
#   --pr <N>       取 GitHub 数据（要 gh 且已登录；联网）+ 本地渲染
#   --from-dir <D> 只渲染（离线），回归测试走这条
#
# 产物（写进 --out，默认 /tmp/caelestia-pr-acceptance）：
#   facts.md     判据清单 + 机械信号 + 计数（评论的前半段）
#   context.md   喂给模型的上下文（两侧全文 + 其它关闭同一 issue 的 PR）
#
# 不需要 root。退出码：0 = 正常；1 = 用法错误、读不到输入或 gh 失败。

set -euo pipefail
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)

MODE=""; PR=""; FROM_DIR=""
OUT_DIR=${CAELESTIA_PR_ACCEPTANCE_OUT:-/tmp/caelestia-pr-acceptance}

usage() {
  cat <<'EOF'
用法：
  pr-acceptance-context.sh --pr <N> [--out <DIR>]
  pr-acceptance-context.sh --from-dir <DIR> [--out <DIR>]

  --pr        从 GitHub 取 PR 数据并渲染
  --from-dir  只渲染离线夹具目录（meta.tsv / pr-body.md / issues.tsv 等）
  --out       输出目录（默认 /tmp/caelestia-pr-acceptance）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)       [ $# -ge 2 ] || { echo "错误：--pr 需要一个编号" >&2; exit 1; }; MODE=collect; PR=$2; shift 2 ;;
    --from-dir) [ $# -ge 2 ] || { echo "错误：--from-dir 需要一个目录" >&2; exit 1; }; MODE=render; FROM_DIR=$2; shift 2 ;;
    --out)      [ $# -ge 2 ] || { echo "错误：--out 需要一个目录" >&2; exit 1; }; OUT_DIR=$2; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "错误：不认识参数 $1（见 --help）" >&2; exit 1 ;;
  esac
done
[ -n "$MODE" ] || { usage; exit 1; }

mkdir -p "$OUT_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO_SLUG=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null \
  | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##' || true)

ref() { # $1=#N（或 N）  $2=issues|pull
  local n kind text
  n=${1#\#}
  kind=${2:-issues}
  text="#$n"
  if [ "$kind" = pull ]; then text="PR #$n"; fi
  if [ -n "$REPO_SLUG" ]; then
    printf '[%s](https://github.com/%s/%s/%s)' "$text" "$REPO_SLUG" "$kind" "$n"
  else
    printf '%s' "$text"
  fi
}

# ── collect ───────────────────────────────────────────────────────────────────
collect() {
  local n=$1 dir=$2
  echo "── 取 GitHub 数据：PR #$n"
  mkdir -p "$dir/issues" "$dir/other-prs"

  local assoc
  assoc=$(gh api "repos/{owner}/{repo}/pulls/$n" -q .author_association 2>/dev/null || true)
  gh pr view "$n" --json number,title,headRefOid,state \
      -q '[.number, .title, .headRefOid, .state] | @tsv' \
    | awk -F'\t' -v a="$assoc" '{printf "number\t%s\ntitle\t%s\nhead\t%s\nstate\t%s\nauthor_association\t%s\n", $1, $2, $3, $4, a}' \
    >"$dir/meta.tsv"
  gh pr view "$n" --json body -q .body >"$dir/pr-body.md"

  grep -Eio '(close[sd]?|fixe[sd]?|resolves?)[[:space:]]+(#[0-9]+[[:space:],]*)+' "$dir/pr-body.md" \
    | grep -Eo '[0-9]+' | sort -un >"$dir/issue-numbers.txt" || true
  : >"$dir/issues.tsv"
  local inum
  while IFS= read -r inum; do
    [ -n "$inum" ] || continue
    gh issue view "$inum" --json number,title -q '[.number, .title] | @tsv' >>"$dir/issues.tsv"
    gh issue view "$inum" --json body -q .body >"$dir/issues/$inum.md"
  done <"$dir/issue-numbers.txt"

  : >"$dir/other-prs.tsv"
  while IFS=$'\t' read -r inum _; do
    [ -n "$inum" ] || continue
    local cand
    cand=$(gh pr list --state all --limit 20 --search "#$inum in:body" --json number,title \
             -q '.[] | [.number, .title] | @tsv' 2>/dev/null || true)
    [ -n "$cand" ] || continue
    while IFS=$'\t' read -r pnum ptitle; do
      [ -n "$pnum" ] || continue
      gh pr view "$pnum" --json body -q .body 2>/dev/null \
        | grep -Eqi "close[sd]?[[:space:]]+#$inum([^0-9]|$)|fixe[sd]?[[:space:]]+#$inum([^0-9]|$)|resolves?[[:space:]]+#$inum([^0-9]|$)" \
        && printf '%s\t%s\n' "$pnum" "$ptitle" >>"$dir/other-prs.tsv" || true
    done <<<"$cand"
  done <"$dir/issues.tsv"
  sort -u -o "$dir/other-prs.tsv" "$dir/other-prs.tsv"
  while IFS=$'\t' read -r pnum _; do
    [ -n "$pnum" ] || continue
    [ "$pnum" = "$n" ] && continue
    gh pr view "$pnum" --json body -q .body >"$dir/other-prs/$pnum.md" || true
  done <"$dir/other-prs.tsv"

  echo "   关联 issue：$(cut -f1 "$dir/issues.tsv" 2>/dev/null | tr '\n' ' ')"
  echo "   其它相关 PR：$(cut -f1 "$dir/other-prs.tsv" 2>/dev/null | tr '\n' ' ')"
}

# ── 切段：`## <名>` / `### <名>` 到下一个同级或更高级的标题 ───────────────────────
section_of() { # $1=文件 $2=段名
  awk -v want="$2" '
    /^#+[[:space:]]/ {
      n = 0; tmp = $0
      while (substr(tmp, n + 1, 1) == "#") n++
      line = $0; sub(/^#+[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
      if (f && n <= lvl) f = 0
      if (!f && line == want) { f = 1; lvl = n; next }
    }
    f { print }
  ' "$1"
}

blocks_of() { # $1=文件
  awk '{ if ($0 ~ /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/) print ""; print }' "$1" \
    | awk 'BEGIN{RS="";ORS="\n"} {gsub(/^[[:space:]]+|[[:space:]]+$/,""); if (length($0)) print $0"\n"}'
}

type_of() { # $1=条目
  local t=$1 h
  h=$(printf '%s' "$t" | head -1 | tr -d '*[:space:]')
  case "$h" in 现状*|口径*) printf 'STATUS'; return 0 ;; esac
  if printf '%s' "$t" | grep -Eqi '要[[:space:]]*root|需[[:space:]]*root|由维护者|需维护者|真机|需要图形|图形会话|需要[[:space:]]*hyprland|requires?[[:space:]]+(root|a[[:space:]]+graphical|hyprland|wayland)|manual[[:space:]]+test'; then
    printf 'DEFERRED'; return 0
  fi
  if printf '%s' "$t" | grep -q '`'; then printf 'CMD'; return 0; fi
  printf 'NARRATIVE'
}

# ── 数字与量纲（R1 / R5 的判据）────────────────────────────────────────────────
numbers_of() { # $1=文本 → `<值>\t<量纲>`
  printf '%s' "$1" \
    | grep -oiE '[0-9]{2,}/[0-9]{2,}|[0-9]{2,}(\.[0-9]+)?[[:space:]]*(项|组|键|条|张|个|次|轮|字节|MiB|KiB|GiB|%|tests?|passed|failed|files?|lines?|cases?)' \
    | awk '{
        if ($0 ~ /^[0-9]+\/[0-9]+$/) { print $0"\t比例"; next }
        v=$0; u=""
        if (match($0, /[^0-9.[:space:]]+$/)) { u=substr($0, RSTART); v=substr($0, 1, RSTART-1) }
        gsub(/[[:space:]]/,"",v); gsub(/[[:space:]]/,"",u)
        u=tolower(u)
        if (v != "") print v"\t" u
      }' | sort -u || true
}

cjk_phrases() { # $1=文本 → 每行一个 ≥12 字节的中文片段
  printf '%s' "$1" \
    | sed 's/[]A-Za-z0-9_ ./`*(){}<>:;,!?+=|"#@$%^~[-]/\n/g' \
    | awk 'length($0) >= 12 { print }' || true
}

windows_of() { # $1=中文片段 → 12 字节滑窗
  local s=$1
  local n=${#s} i
  for ((i = 0; i + 12 <= n; i += 3)); do printf '%s\n' "${s:i:12}"; done
}

STOP_WINDOWS='期望结果 命令输出 退出码 全部通过 全部一致 逐字一致 期望全绿 以上都是'

window_hit() { # $1=窗口 $2=声称文件 → 命中则打印命中的行号
  case " $STOP_WINDOWS " in *" $1 "*) return 0 ;; esac
  grep -nF -- "$1" "$2" | head -1 || true
}

tokens_of() { # $1=文本 → 每行一个有辨识度的 token
  grep -o '`[^`]*`' <<<"$1" 2>/dev/null | tr -d '`' | tr ' ' '\n' \
    | sed -e "s/^[\"']*//" -e "s/[\"']*\$//" \
    | grep -Ei '/|\.(py|sh|fish|md|json|yml|yaml|toml|nix|qml|cpp|hpp|js|mjs|ts|css|conf|ini|txt|po|pot)$' \
    | awk 'length($0) >= 6' | sort -u || true
}

trunc_bytes() { # $1=文本 $2=字节上限
  printf '%s' "$1" | head -c "$2" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true
}

claims_of() { # $1=PR 正文文件
  section_of "$1" 验证方式 \
    | grep -vE '^[[:space:]]*\|?[[:space:]]*-{2,}' \
    | grep -vE '^[[:space:]]*\|[[:space:]]*项[[:space:]]*\|' \
    | while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*|[[:space:]]*//; s/[[:space:]]*|[[:space:]]*$//; s/^[[:space:]]*[-*][[:space:]]*//')
        [ -n "$line" ] || continue
        printf '%s\n' "$line"
      done || true
}

# ── render ────────────────────────────────────────────────────────────────────
render() {
  local dir=$1 out=$2
  [ -f "$dir/meta.tsv" ] || { echo "错误：读不到 $dir/meta.tsv" >&2; exit 1; }
  [ -f "$dir/pr-body.md" ] || { echo "错误：读不到 $dir/pr-body.md" >&2; exit 1; }

  local pr title head
  pr=$(awk -F'\t' '$1=="number"{print $2}' "$dir/meta.tsv")
  title=$(awk -F'\t' '$1=="title"{print $2}' "$dir/meta.tsv")
  head=$(awk -F'\t' '$1=="head"{print $2}' "$dir/meta.tsv")

  : >"$TMP/criteria.tsv"; : >"$TMP/claims.tsv"
  local inum
  while IFS=$'\t' read -r inum _; do
    [ -n "$inum" ] || continue
    [ -f "$dir/issues/$inum.md" ] || continue
    section_of "$dir/issues/$inum.md" 验收 >"$TMP/acc.md"
    blocks_of "$TMP/acc.md" | while IFS= read -r blk; do
      [ -n "$blk" ] || continue
      printf '%s\t%s\t%s\n' "$inum" "$(type_of "$blk")" "$(trunc_bytes "$(printf '%s' "$blk" | tr '\n' ' ')" 200)" >>"$TMP/criteria.tsv"
    done
  done <"$dir/issues.tsv"

  claims_of "$dir/pr-body.md" >"$TMP/claims.md"
  cp "$TMP/claims.md" "$TMP/claims_all.md"
  if [ -f "$dir/other-prs.tsv" ]; then
    local op
    while IFS=$'\t' read -r op _; do
      [ -n "$op" ] || continue
      [ -f "$dir/other-prs/$op.md" ] || continue
      claims_of "$dir/other-prs/$op.md" | sed "s|^|[PR #$op] |" >>"$TMP/claims_all.md"
    done <"$dir/other-prs.tsv"
  fi

  : >"$TMP/other.md"
  if [ -f "$dir/other-prs.tsv" ]; then
    local pnum
    while IFS=$'\t' read -r pnum _; do
      [ -n "$pnum" ] || continue
      [ -f "$dir/other-prs/$pnum.md" ] || continue
      printf '### PR #%s\n%s\n\n' "$pnum" "$(section_of "$dir/other-prs/$pnum.md" 验证方式)" >>"$TMP/other.md"
    done <"$dir/other-prs.tsv"
  fi

  : >"$TMP/table.tsv"
  local n_total=0 n_ok=0 n_na=0 n_q=0 n_warn=0
  local i=0
  while IFS=$'\t' read -r inum ctype text; do
    [ -n "$text" ] || continue
    i=$((i + 1)); n_total=$((n_total + 1))
    local hint note
    if [ "$ctype" = "STATUS" ]; then
      hint="➖"; note="口径行（现状 / 口径），不参与对账"; n_na=$((n_na + 1))
    elif [ "$ctype" = "DEFERRED" ]; then
      hint="➖"; note="按 R3 抑制：判据自带「要 root / 需要图形会话 / 真机」"; n_na=$((n_na + 1))
    else
      local hit="" vals v
      vals=$(numbers_of "$text" | cut -f1 | sort -u || true)
      for v in $vals; do
        case "$v" in
          */*) grep -qF -- "$v" "$TMP/claims_all.md" && { hit="$v"; break; } ;;
          *)   grep -qE "(^|[^0-9])$(printf '%s' "$v" | sed 's/\./\\./g')([^0-9]|$)" "$TMP/claims_all.md" && { hit="$v"; break; } ;;
        esac
      done
      local dif=""
      if [ -z "$hit" ]; then
        local dv du cand
        while IFS=$'\t' read -r dv du; do
          [ -n "$du" ] || continue
          cand=$(grep -nF -- "$du" "$TMP/claims_all.md" | head -1 || true)
          [ -n "$cand" ] && { dif="${dv}${du} → $(sed -n "${cand%%:*}p" "$TMP/claims_all.md" | cut -c1-30)"; break; }
        done < <(numbers_of "$text" || true)
      fi
      local tok=""
      if [ -z "$hit" ] && [ -z "$dif" ]; then
        while IFS= read -r t; do
          [ -n "$t" ] || continue
          grep -qF -- "$t" "$TMP/claims_all.md" && { tok="$t"; break; }
        done < <(tokens_of "$text")
      fi
      local phrase=""
      if [ -z "$hit" ] && [ -z "$dif" ] && [ -z "$tok" ]; then
        local p w
        while IFS= read -r p; do
          while IFS= read -r w; do
            [ -n "$w" ] || continue
            if window_hit "$w" "$TMP/claims_all.md" | grep -q .; then phrase="$w"; break; fi
          done < <(windows_of "$p")
          [ -n "$phrase" ] && break
        done < <(cjk_phrases "$text")
      fi
      local where=""
      [ -n "$hit" ] && where=$(grep -nF -- "$hit" "$TMP/claims_all.md" | head -1 | cut -d: -f1)
      [ -n "$tok" ] && [ -z "$where" ] && where=$(grep -nF -- "$tok" "$TMP/claims_all.md" | head -1 | cut -d: -f1)
      [ -n "$phrase" ] && [ -z "$where" ] && where=$(grep -nF -- "$phrase" "$TMP/claims_all.md" | head -1 | cut -d: -f1)
      if [ -n "$where" ]; then
        local line; line=$(sed -n "${where}p" "$TMP/claims_all.md")
        case "$line" in
          "[PR #"*)
            local prn
            prn=$(printf '%s' "$line" | sed -n 's/^\[PR #\([0-9]*\)\].*/\1/p')
            note="证据在 $(ref "$prn" pull) 的声称里：$(printf '%s' "$line" | sed 's/^\[PR #[0-9]*\] //' | cut -c1-40)" ;;
          *)        note="命中本 PR 的声称：$(printf '%s' "$line" | cut -c1-40)" ;;
        esac
      fi
      if [ -n "$hit" ]; then
        note="同值 $hit —— $note"; hint="✅"; n_ok=$((n_ok + 1))
      elif [ -n "$dif" ]; then
        note="同量纲异值：${dif}"; hint="❓"; n_q=$((n_q + 1))
      elif [ -n "$tok" ]; then
        note="同名对象 \`$tok\` —— $note"; hint="✅"; n_ok=$((n_ok + 1))
      elif [ -n "$phrase" ]; then
        note="词面「$phrase」—— $note"; hint="✅"; n_ok=$((n_ok + 1))
      else
        note="机械层面没有找到对应声称"; hint="⚠️"; n_warn=$((n_warn + 1))
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$ctype" "$hint" "$note" "$(trunc_bytes "$text" 60)" >>"$TMP/table.tsv"
  done <"$TMP/criteria.tsv"

  {
    local label
    label=$(cut -f1 "$dir/issues.tsv" 2>/dev/null | grep -v '^$' \
              | while read -r n; do printf '%s ' "$(ref "#$n")"; done | sed 's/ $//' || true)
    if [ -n "$label" ]; then
      echo "## 验收对账（机器 · $(ref "$pr" pull) · head ${head:0:7} · 判据来自 $label）"
    else
      echo "## 验收对账（机器 · $(ref "$pr" pull) · head ${head:0:7}）"
    fi
    echo
    if [ "$n_total" -eq 0 ]; then
      echo "⚠️ 无法判定：没有可对账的判据（PR 正文没写 \`Closes #N\`，或关联 issue 没有「验收」段）。"
    else
      echo "判据 $n_total 条（机械信号）：✅ $n_ok · ➖ $n_na · ❓ $n_q · ⚠️ $n_warn"
      echo
      echo "| # | 型 | 建议档 | 机械信号（不是判决） | 判据（截断） |"
      echo "|---|---|---|---|---|"
      while IFS=$'\t' read -r idx ctype hint note txt; do
        printf '| %s | %s | %s | %s | `%s` |\n' "$idx" "$ctype" "$hint" "$note" "$txt"
      done <"$TMP/table.tsv"
    fi
  } >"$out/facts.md"

  {
    echo "# 验收对账的上下文"
    echo
    echo "**本次任务：C（验收对账）** —— 按 docs/work/ai-review-rubric.md C 节的输出契约回答。"
    echo
    if [ -n "$REPO_SLUG" ]; then
      echo "- 仓库：\`$REPO_SLUG\`；引用写成 \`[#N](https://github.com/$REPO_SLUG/issues/N)\`（PR 用 \`[PR #N](https://github.com/$REPO_SLUG/pull/N)\`），不抄标题（rubric A-0）。"
    else
      echo "- 仓库：未取到远端地址；引用只写 \`#N\` / \`PR #N\`（GitHub 会自动链接），不抄标题（rubric A-0）。"
    fi
    echo
    echo "## PR #$pr $title"
    echo
    echo '### PR 正文'
    echo '```markdown'; cat "$dir/pr-body.md"; echo '```'
    echo
    echo "## 脚本抽出的判据与机械信号（不要重算；可以推翻并说明理由）"
    echo '```markdown'; cat "$out/facts.md"; echo '```'
    echo
    echo "## PR 侧的声称（逐行，编号即上面信号里引用的行号）"
    echo '```'; nl -ba "$TMP/claims_all.md"; echo '```'
    echo
    local inum2
    while IFS=$'\t' read -r inum2 it; do
      [ -n "$inum2" ] || continue
      [ -f "$dir/issues/$inum2.md" ] || continue
      echo "## 关联 issue #$inum2 $it（全文）"
      echo '```markdown'; cat "$dir/issues/$inum2.md"; echo '```'
      echo
    done <"$dir/issues.tsv"
    if [ -s "$TMP/other.md" ]; then
      echo "## 其它 PR 也提到同一批 issue —— 判据的证据可能在它们里面（rubric R7）"
      echo '```markdown'; cat "$TMP/other.md"; echo '```'
    fi
  } >"$out/context.md"

  printf '判据 %s 条：✅ %s · ➖ %s · ❓ %s · ⚠️ %s\n' "$n_total" "$n_ok" "$n_na" "$n_q" "$n_warn"
  printf '产物：%s\n      %s\n' "$out/facts.md" "$out/context.md"
}

if [ "$MODE" = collect ]; then
  collect "$PR" "$OUT_DIR"
  render "$OUT_DIR" "$OUT_DIR"
else
  render "$FROM_DIR" "$OUT_DIR"
fi
