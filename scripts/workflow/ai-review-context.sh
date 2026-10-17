#!/usr/bin/env bash
# 受理前质检的上下文生成器 —— 脚本只算集合，语义判断交给模型。
#
# 它把 issue 正文里「哪些反引号项真的是仓库文件路径」抠出来，算出：
#   - 本条 issue 认领了哪些文件；
#   - 与其它 open task 的硬撞 / 软邻近；
#   - 解析不了、被排除、被当成产物的项。
# 判据质量 / 查重 / 引用有效性交给模型，判据唯一源是 docs/work/ai-review-rubric.md。
#
# 两个模式：
#   --issue <N>      取 GitHub 数据（要 gh 且已登录；联网）+ 本地渲染
#   --from-dir <D>   只渲染（离线），D 里放 collect 写下的文本；回归测试走这条
#
# 产物（写进 --out，默认 /tmp/caelestia-ai-review）：
#   facts.md     确定性事实：所有权 / 未计入 / 硬撞 / 软邻近 —— 直接进评论
#   context.md   喂给模型的上下文：事实 + 正文 + 仓库树 + 其它 open task 的「实现」
#
# 不需要 root。退出码：0 = 正常；1 = 用法错误、读不到输入或 gh 失败。

set -euo pipefail
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)

MODE=""
ISSUE=""
FROM_DIR=""
OUT_DIR=${CAELESTIA_AI_REVIEW_OUT:-/tmp/caelestia-ai-review}

usage() {
  cat <<'EOF'
用法：
  ai-review-context.sh --issue <N> [--out <DIR>]
  ai-review-context.sh --from-dir <DIR> [--out <DIR>]

  --issue     从 GitHub 取 issue 数据并渲染
  --from-dir  只渲染离线夹具目录（meta.tsv / body.md / tree.txt 等）
  --out       输出目录（默认 /tmp/caelestia-ai-review）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)    [ $# -ge 2 ] || { echo "错误：--issue 需要一个编号" >&2; exit 1; }; MODE=collect; ISSUE=$2; shift 2 ;;
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

# ── collect：把 GitHub 上的数据落成纯文本 ──────────────────────────────────────
collect() {
  local n=$1 dir=$2
  echo "── 取 GitHub 数据：issue #$n"
  mkdir -p "$dir/open-tasks"

  local assoc
  assoc=$(gh api "repos/{owner}/{repo}/issues/$n" -q .author_association 2>/dev/null || true)
  gh issue view "$n" --json number,title,labels \
      -q '[.number, .title, ([.labels[].name] | join(","))] | @tsv' \
    | awk -F'\t' -v a="$assoc" '{printf "number\t%s\ntitle\t%s\nlabels\t%s\nauthor_association\t%s\n", $1, $2, $3, a}' \
    >"$dir/meta.tsv"
  gh issue view "$n" --json body -q .body >"$dir/body.md"

  # 撞车集合只与 open 的 task 比。label 不存在时 gh 会报错，按空处理。
  if ! gh issue list --label task --state open --limit 50 --json number,title \
      -q '.[] | [.number, .title] | @tsv' >"$dir/open-tasks.tsv" 2>/dev/null; then
    : >"$dir/open-tasks.tsv"
  fi
  while IFS=$'\t' read -r num _; do
    [ -n "$num" ] || continue
    [ "$num" = "$n" ] && continue
    gh issue view "$num" --json body -q .body >"$dir/open-tasks/$num.md" || true
  done <"$dir/open-tasks.tsv"

  # 查重与引用有效性要看历史（含已关闭），但只需要标题级别。
  if ! gh issue list --state all --limit 200 --json number,state,title \
      -q '.[] | [.number, .state, .title] | @tsv' >"$dir/recent.tsv" 2>/dev/null; then
    : >"$dir/recent.tsv"
  fi

  # 用 HEAD 的提交树，不用索引：索引会被暂存的删除 / 改名带脏。
  git -C "$PROJECT_ROOT" -c core.quotePath=false ls-tree -r --name-only HEAD >"$dir/tree.txt"
  echo "   meta.tsv / body.md / open-tasks.tsv / recent.tsv / tree.txt 已就位"
}

# ── 从正文里切出「实现」段，再把它分成正向陈述与「不做」段 ────────────────────
split_impl() { # $1=正文文件 $2=正向 $3=排除
  local body=$1 pos=$2 neg=$3
  : >"$pos"; : >"$neg"
  awk '/^###[[:space:]]*实现/{f=1;next} /^###/{f=0} f' "$body" >"$TMP/impl.md"
  awk '{ if ($0 ~ /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/) print ""; print }' \
    "$TMP/impl.md" >"$TMP/impl.blocks.md"
  awk -v p="$pos" -v n="$neg" 'BEGIN{RS="";ORS="\n"} {
      h=$0; sub(/\n.*/,"",h); gsub(/[-*+0-9.[:space:]]/,"",h)
      if (h ~ /^(明确)?不(做|碰|动)/) print >> n; else print >> p
    }' "$TMP/impl.blocks.md"
}

items_of() { grep -o '`[^`]*`' "$1" 2>/dev/null | tr -d '`' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u || true; }

# ── 分类：一条反引号项到底是「所有权」还是别的什么 ────────────────────────────
# 输出 <kind>\t<值>；kind ∈ exact / basename / from-command / new / ignored / unresolved
classify() { # $1=item  $2=tree  $3=basename 索引  $4=目录集合
  local it=$1 tree=$2 bybase=$3 dirs=$4 base cnt tok pdir
  case "$it" in
    '') return 0 ;;
    *'{{'*|*'<'*'>'*) printf 'ignored\t模板占位\n'; return 0 ;;
  esac
  if printf '%s' "$it" | grep -Eq '^[0-9a-f]{7,64}$'; then printf 'ignored\tcommit / sha256\n'; return 0; fi
  if printf '%s' "$it" | grep -Eq '^#[0-9]+$'; then printf 'ignored\tissue 引用\n'; return 0; fi
  if printf '%s' "$it" | grep -Eq '^/'; then printf 'ignored\t系统绝对路径\n'; return 0; fi
  if printf '%s' "$it" | grep -Eq '[*?]'; then printf 'ignored\t通配 / 目录范围\n'; return 0; fi
  case "$it" in
    build/*|result|result/*|.direnv/*|.cache/*|logs/*|out/*|*.iso|*.qcow2|*.fd|*.mo)
      printf 'ignored\t生成物 / 构建产物\n'; return 0 ;;
    */) printf 'ignored\t目录范围\n'; return 0 ;;
  esac
  if grep -Fxq -- "$it" "$tree"; then printf 'exact\t%s\n' "$it"; return 0; fi
  base=${it##*/}
  cnt=$(awk -F'\t' -v b="$base" '$1==b{c++} END{print c+0}' "$bybase")
  if [ "$cnt" -eq 1 ]; then printf 'basename\t%s\n' "$(awk -F'\t' -v b="$base" '$1==b{print $2; exit}' "$bybase")"; return 0; fi
  if printf '%s' "$it" | grep -q ' '; then
    tok=${it%% *}
    if grep -Fxq -- "$tok" "$tree"; then printf 'from-command\t%s\n' "$tok"; return 0; fi
    base=${tok##*/}
    cnt=$(awk -F'\t' -v b="$base" '$1==b{c++} END{print c+0}' "$bybase")
    if [ "$cnt" -eq 1 ]; then printf 'from-command\t%s\n' "$(awk -F'\t' -v b="$base" '$1==b{print $2; exit}' "$bybase")"; return 0; fi
    printf 'ignored\t命令 / 散文\n'; return 0
  fi
  if printf '%s' "$it" | grep -q '/'; then
    pdir=${it%/*}
    if grep -qxF -- "$pdir" "$dirs"; then printf 'new\t%s\n' "$it"; return 0; fi
  fi
  printf 'unresolved\t%s\n' "$it"
}

# ── 一条 issue 的所有权集合 ────────────────────────────────────────────────────
ownership_of() { # $1=正文 $2=out.tsv $3=ignored.tsv $4=excluded.tsv $5=tree $6=bybase $7=dirs
  local body=$1 out=$2 ign=$3 exc=$4 tree=$5 bybase=$6 dirs=$7
  : >"$out"; : >"$ign"; : >"$exc"
  split_impl "$body" "$TMP/pos.md" "$TMP/neg.md"
  local it kind val
  while IFS= read -r it; do
    [ -n "$it" ] || continue
    IFS=$'\t' read -r kind val < <(classify "$it" "$tree" "$bybase" "$dirs") || true
    case "$kind" in
      exact|basename|from-command) printf '%s\t%s\n' "$val" "$kind" >>"$out" ;;
      new) printf '%s\t新建\n' "$val" >>"$out" ;;
      unresolved) printf '%s\t未解析\n' "$it" >>"$ign" ;;
      *) printf '%s\t%s\n' "$it" "$val" >>"$ign" ;;
    esac
  done < <(items_of "$TMP/pos.md")
  while IFS= read -r it; do
    [ -n "$it" ] || continue
    IFS=$'\t' read -r kind val < <(classify "$it" "$tree" "$bybase" "$dirs") || true
    case "$kind" in
      exact|basename|from-command|new) printf '%s\n' "$val" >>"$exc" ;;
      *) printf '%s\n' "$it" >>"$exc" ;;
    esac
  done < <(items_of "$TMP/neg.md")
  sort -u -o "$exc" "$exc"
  if [ -s "$exc" ]; then
    awk -F'\t' -v OFS='\t' '
      NR==FNR { if ($0 ~ /\*\*$/) { p=$0; sub(/\*\*$/,"",p); pre[++n]=p } else exact[$0]=1; next }
      { drop=0
        if (exact[$1]) drop=1
        for (i=1;i<=n;i++) if (index($1, pre[i])==1) drop=1
        if (!drop) print }
    ' "$exc" "$out" >"$TMP/kept.tsv"
    mv "$TMP/kept.tsv" "$out"
  fi
  sort -u -o "$out" "$out"
  awk -F'\t' '{ r = ($2=="exact" ? 1 : ($2=="from-command" ? 2 : ($2=="basename" ? 3 : 4)))
                if (!($1 in best) || r < best[$1]) { best[$1] = r; line[$1] = $0 } }
              END { for (p in line) print line[p] }' "$out" | LC_ALL=C sort >"$TMP/dedup.tsv"
  mv "$TMP/dedup.tsv" "$out"
  sort -u -o "$ign" "$ign"
}

# ── render：把事实写成两份 markdown ────────────────────────────────────────────
render() {
  local dir=$1 out=$2
  local tree="$dir/tree.txt" bybase="$TMP/bybase.tsv"
  for f in meta.tsv body.md tree.txt; do
    [ -f "$dir/$f" ] || { echo "错误：读不到 $dir/$f（先用 --issue <N> 取数据，或检查 --from-dir）" >&2; exit 1; }
  done
  awk -F/ 'NF>1{print $NF"\t"$0}' "$tree" | LC_ALL=C sort >"$bybase"
  awk -F/ 'NF>1 { s=""; for (i=1;i<NF;i++) s = (i==1 ? $i : s"/"$i); print s }' "$tree" \
    | LC_ALL=C sort -u >"$TMP/dirs.txt"

  local number title labels assoc
  number=$(awk -F'\t' '$1=="number"{print $2}' "$dir/meta.tsv")
  title=$(awk -F'\t' '$1=="title"{print $2}' "$dir/meta.tsv")
  labels=$(awk -F'\t' '$1=="labels"{print $2}' "$dir/meta.tsv")
  assoc=$(awk -F'\t' '$1=="author_association"{print $2}' "$dir/meta.tsv")

  local is_task=0
  case ",$labels," in *,task,*) is_task=1 ;; esac
  case "$title" in "[工作]"*) is_task=1 ;; esac

  ownership_of "$dir/body.md" "$TMP/own.tsv" "$TMP/ign.tsv" "$TMP/exc.tsv" "$tree" "$bybase" "$TMP/dirs.txt"
  local n_own n_ign n_new
  n_own=$(wc -l <"$TMP/own.tsv")
  n_ign=$(wc -l <"$TMP/ign.tsv")
  n_new=$(awk -F'\t' '$2=="新建"{c++} END{print c+0}' "$TMP/own.tsv")

  : >"$TMP/hard.tsv"; : >"$TMP/soft.tsv"
  if [ "$is_task" = 1 ] && [ -f "$dir/open-tasks.tsv" ] && [ -d "$dir/open-tasks" ]; then
    local num other_own other_ign other_exc
    while IFS=$'\t' read -r num _; do
      [ -n "$num" ] || continue
      [ "$num" = "$number" ] && continue
      [ -f "$dir/open-tasks/$num.md" ] || continue
      ownership_of "$dir/open-tasks/$num.md" "$TMP/o.tsv" "$TMP/oi.tsv" "$TMP/oe.tsv" "$tree" "$bybase" "$TMP/dirs.txt"
      comm -12 <(cut -f1 "$TMP/own.tsv" | LC_ALL=C sort -u) <(cut -f1 "$TMP/o.tsv" | LC_ALL=C sort -u) \
        | sed "s/$/\t#$num/" >>"$TMP/hard.tsv"
      comm -12 \
        <(awk -F'\t' '$1 ~ /\//{p=$1; sub(/\/[^\/]*$/,"",p); print p}' "$TMP/own.tsv" | LC_ALL=C sort -u) \
        <(awk -F'\t' '$1 ~ /\//{p=$1; sub(/\/[^\/]*$/,"",p); print p}' "$TMP/o.tsv"  | LC_ALL=C sort -u) \
        >"$TMP/dirs.tsv" || true
      cut -f1 "$TMP/hard.tsv" | sed 's|/[^/]*$||' | LC_ALL=C sort -u >"$TMP/harddirs.tsv" || true
      if [ -s "$TMP/dirs.tsv" ]; then
        if [ -s "$TMP/harddirs.tsv" ]; then
          grep -vxF -f "$TMP/harddirs.tsv" "$TMP/dirs.tsv" >"$TMP/dirs.soft.tsv" || true
        else
          cp "$TMP/dirs.tsv" "$TMP/dirs.soft.tsv"
        fi
        sed "s|\$|\t#$num|" "$TMP/dirs.soft.tsv" >>"$TMP/soft.tsv"
      fi
    done <"$dir/open-tasks.tsv"
    sort -u -o "$TMP/hard.tsv" "$TMP/hard.tsv"
    sort -u -o "$TMP/soft.tsv" "$TMP/soft.tsv"
  fi
  local n_hard n_soft
  n_hard=$(wc -l <"$TMP/hard.tsv"); n_soft=$(wc -l <"$TMP/soft.tsv")

  {
    echo "## 受理前质检（机器 · issue $(ref "#$number") · 正文 $(sha256sum "$dir/body.md" | cut -c1-8)）"
    echo
    if [ "$is_task" != 1 ]; then
      echo "**所有权雷达** ➖ 跳过：本 issue 的 label 是「${labels:-无}」，没有「实现」段（rubric A-2 按 label 分流）。"
    else
      if [ "$n_own" -eq 0 ]; then
        echo "**所有权雷达** ⚠️ 无法判定：「实现」段里没有解析出任何仓库文件路径。"
      else
        if [ "$n_new" -gt 0 ]; then
          echo "**所有权雷达** 认领 $n_own 个文件（其中 $n_new 个是新建）· 硬撞 $n_hard · 软邻近 $n_soft"
        else
          echo "**所有权雷达** 认领 $n_own 个文件 · 硬撞 $n_hard · 软邻近 $n_soft"
        fi
      fi
      if [ "$n_hard" -gt 0 ]; then
        echo "🔴 **硬撞**（同一文件被两条 open task 点名）："
        while IFS=$'\t' read -r p who; do echo "- \`$p\` —— $(ref "$who") 的「实现」里也点了它"; done <"$TMP/hard.tsv"
        echo
      fi
      if [ "$n_soft" -gt 0 ]; then
        echo "🟡 软邻近（同一目录，未撞同一文件）："
        while IFS=$'\t' read -r d who; do echo "- \`$d/\` —— $(ref "$who") 也在改这个目录"; done <"$TMP/soft.tsv"
        echo
      fi
      if [ "$n_ign" -gt 0 ]; then
        echo "<details><summary>另有 $n_ign 项未计入所有权</summary>"
        echo
        while IFS=$'\t' read -r it why; do echo "- \`$it\` —— $why"; done <"$TMP/ign.tsv"
        echo
        echo "</details>"
      fi
      if [ "$n_own" -gt 0 ]; then
        echo "<details><summary>我认领了这 $n_own 个文件（点开看解析来源）</summary>"
        echo
        while IFS=$'\t' read -r p kind; do echo "- \`$p\` —— $kind"; done <"$TMP/own.tsv"
        echo
        echo "</details>"
      fi
      if [ -s "$TMP/exc.tsv" ]; then
        echo "<details><summary>按「不做 / 不碰 / 不动」段排除的 $(wc -l <"$TMP/exc.tsv") 项</summary>"
        echo
        while IFS= read -r x; do echo "- \`$x\`"; done <"$TMP/exc.tsv"
        echo
        echo "</details>"
      fi
    fi
  } >"$out/facts.md"

  {
    echo "# 受理前质检的上下文"
    echo
    echo "**本次任务：A（受理前质检）** —— 按 docs/work/ai-review-rubric.md 的输出契约回答。"
    echo
    if [ -n "$REPO_SLUG" ]; then
      echo "- 仓库：\`$REPO_SLUG\`；引用写成 \`[#N](https://github.com/$REPO_SLUG/issues/N)\`（PR 用 \`[PR #N](https://github.com/$REPO_SLUG/pull/N)\`），不抄标题（rubric A-0）。"
    else
      echo "- 仓库：未取到远端地址；引用只写 \`#N\`（GitHub 会自动链接），不抄标题（rubric A-0）。"
    fi
    echo
    echo "## 主体 issue #$number"
    echo "- 标题：$title"
    echo "- labels：${labels:-（无）}"
    echo "- author_association：${assoc:-未知}"
    echo
    echo '### 正文'
    echo '```markdown'
    cat "$dir/body.md"
    echo '```'
    echo
    echo "## 脚本已经算好的确定性事实（不要重算，也不要推翻）"
    echo '```markdown'
    cat "$out/facts.md"
    echo '```'
    echo
    echo "## 仓库树（git ls-tree，$(( $(wc -l <"$tree") )) 条）"
    echo '```'
    cat "$tree"
    echo '```'
    echo
    if [ "$is_task" = 1 ] && [ -f "$dir/open-tasks.tsv" ]; then
      echo "## 其它 open task issue 的「实现 / 不做」段（撞车集合的来源）"
      while IFS=$'\t' read -r num t; do
        [ -n "$num" ] || continue
        [ "$num" = "$number" ] && continue
        [ -f "$dir/open-tasks/$num.md" ] || continue
        echo "### #$num $t"
        split_impl "$dir/open-tasks/$num.md" "$TMP/p.md" "$TMP/n.md"
        echo '```markdown'
        echo '[实现 · 正向]'; cat "$TMP/p.md"
        echo '[实现 · 不做]'; cat "$TMP/n.md"
        echo '```'
      done <"$dir/open-tasks.tsv"
      echo
    fi
    if [ -f "$dir/recent.tsv" ]; then
      echo "## 历史 issue（含已关闭，最新在前；查重用）"
      echo '```'
      cat "$dir/recent.tsv"
      echo '```'
    fi
  } >"$out/context.md"

  printf '所有权 %s 条 · 未计入 %s 条 · 硬撞 %s · 软邻近 %s\n' "$n_own" "$n_ign" "$n_hard" "$n_soft"
  printf '产物：%s\n' "$out/facts.md"
  printf '      %s\n' "$out/context.md"
}

if [ "$MODE" = collect ]; then
  collect "$ISSUE" "$OUT_DIR"
  render "$OUT_DIR" "$OUT_DIR"
else
  render "$FROM_DIR" "$OUT_DIR"
fi
