#!/usr/bin/env bash
# ai-review-context.sh 的回归测试：造夹具，验证该抓的抓得住、该抑制的抑制得住。
#
# 夹具全部在临时目录里，不联网、不写真实仓库（render 模式只读文本，另从 git remote 推仓库地址）。
# 不需要 root。用法：./scripts/workflow/tests/ai-review-context.test.sh

set -uo pipefail
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SELF_DIR/../ai-review-context.sh"

FAIL=0
pass() { printf '✅ %s\n' "$1"; }
bad()  { printf '❌ %s\n' "$1"; FAIL=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

[ -f "$SCRIPT" ] || { echo "错误：读不到 $SCRIPT" >&2; exit 1; }

fixture_tree() {
  cat <<'EOF'
docs/work/tech/01-构建.md
modules/bar/Bar.qml
modules/bar/Other.qml
components/controls/Button.qml
components/controls/Other.qml
plugin/src/Caelestia/Config/config.cpp
scripts/trs.fish
services/Audio.qml
docs/a/note.md
docs/b/note.md
CMakeLists.txt
shell.qml
EOF
}

mk_case_full() {
  local d=$1
  mkdir -p "$d"
  printf 'number\t901\ntitle\t夹具：解析形态\nlabels\ttask\nauthor_association\tMEMBER\n' >"$d/meta.tsv"
  cat >"$d/body.md" <<'EOF'
### 目标

夹具。

### 实现

- 改 `modules/bar/Bar.qml`，同一件事另写 `Bar.qml`（两种写法 → 必须去重成 1 条）
- 改 `docs/work/tech/01-构建.md`（中文名必须解析得出来）
- 见 `note.md`（同名两处 → 歧义，必须判不了、不许瞎猜）
- `plugin/src/Caelestia/Config/config.cpp` 要动（这条会被下面的 `plugin/src/Caelestia/Config/**` 削掉）
- 键盘选择落进 `/etc/vconsole.conf`（系统绝对路径，不许回退到仓库内同名文件）
- 文案走 `scripts/trs.fish raw`（命令 + 参数，剥掉参数后是真路径）
- 记录 `1a221bd` 与产物 `build/caelestia-shell`（都不是所有权）
- 见 `Plan.keymap` 与 `keymap.try`（属性名 / i18n 键，不是路径）
- 明确**不**做：不动 `plugin/src/Caelestia/Config/config.cpp`、不改 `services/**`
- ⑥ 善后：`components/controls/Button.qml` §7 的「明确不做」按实改（段首不是「不做」→ 仍算正向）

### 验收

- `true` → 期望退出码 0。
EOF
  fixture_tree >"$d/tree.txt"
  printf '900\t另一个 open task\n' >"$d/open-tasks.tsv"
  mkdir -p "$d/open-tasks"
  cat >"$d/open-tasks/900.md" <<'EOF'
### 实现

- 改 `modules/bar/Bar.qml`（硬撞：同一个文件）
- 改 `components/controls/Other.qml`（软邻近：同目录、不同文件）
EOF
  printf '901\tOPEN\t夹具：解析形态\n' >"$d/recent.tsv"
}

mk_case_nontask() {
  local d=$1
  mkdir -p "$d"
  printf 'number\t902\ntitle\t夹具：bug\nlabels\tbug\nauthor_association\tMEMBER\n' >"$d/meta.tsv"
  printf '### 问题描述\n\n坏了。\n' >"$d/body.md"
  fixture_tree >"$d/tree.txt"
}

mk_case_empty() {
  local d=$1
  mkdir -p "$d"
  printf 'number\t903\ntitle\t夹具：空实现\nlabels\ttask\nauthor_association\tMEMBER\n' >"$d/meta.tsv"
  printf '### 目标\n\n夹具。\n\n### 实现\n\n\n\n### 验收\n\n- `true` → 期望退出码 0。\n' >"$d/body.md"
  fixture_tree >"$d/tree.txt"
}

mk_case_title_only() {
  local d=$1
  mkdir -p "$d"
  printf 'number\t904\ntitle\t[工作] 夹具：只有标题前缀\nlabels\t\nauthor_association\tMEMBER\n' >"$d/meta.tsv"
  printf '### 目标\n\n夹具。\n\n### 实现\n\n- 改 `modules/bar/Bar.qml`\n\n### 验收\n\n- `true` → 期望退出码 0。\n' >"$d/body.md"
  fixture_tree >"$d/tree.txt"
}

own_block() { sed -n '/我认领了这/,/<\/details>/p' "$1"; }
ign_block() { sed -n '/未计入所有权/,/<\/details>/p' "$1"; }
exc_block() { sed -n '/段排除的/,/<\/details>/p' "$1"; }

D="$T/full"; mk_case_full "$D"
if "$SCRIPT" --from-dir "$D" --out "$D/out" >"$D/log" 2>&1; then pass "夹具 1 渲染退出码 0"; else bad "夹具 1 渲染失败：$(tail -2 "$D/log")"; fi
F="$D/out/facts.md"

[ -f "$F" ] && pass "facts.md 已生成" || bad "facts.md 没生成"

grep -q '01-构建.md' <<<"$(own_block "$F")" && pass "A9 中文名路径进了所有权" || bad "A9 中文名路径没进所有权"
grep -q 'scripts/trs.fish' <<<"$(own_block "$F")" && pass "命令剥参数后解析出真路径" || bad "命令里的路径没解析出来"

if grep -q 'etc/vconsole.conf' <<<"$(own_block "$F")"; then
  bad "A2 绝对路径被错误回退成了仓库内同名文件"
else
  pass "A2 绝对路径未被回退（静默错配拦住了）"
fi
grep -q '/etc/vconsole.conf.*系统绝对路径' <<<"$(ign_block "$F")" && pass "A2 绝对路径被标成「系统绝对路径」" || bad "A2 绝对路径没被标注"

if grep -q 'note.md' <<<"$(own_block "$F")"; then bad "歧义 basename 被瞎猜成了所有权"; else pass "歧义 basename 没有进所有权"; fi

if grep -q 'plugin/src/Caelestia/Config/config.cpp' <<<"$(own_block "$F")"; then
  bad "A5「不做」段里的全路径漏进了所有权"
else
  pass "A5「不做」段里的全路径被排除"
fi
grep -q 'plugin/src/Caelestia/Config/config.cpp' <<<"$(exc_block "$F")" && pass "被「不做」排除的项有回显" || bad "被排除的项没有回显"

grep -q 'components/controls/Button.qml' <<<"$(own_block "$F")" && pass "A5 反面：引用了「明确不做」的段落仍算正向" || bad "A5 反面：正向段被误判成排除段"

n_bar=$(grep -c 'modules/bar/Bar.qml' <<<"$(own_block "$F")")
[ "$n_bar" -eq 1 ] && pass "同一文件两种写法去重成 1 条" || bad "去重失败（Bar.qml 出现 $n_bar 次）"

if grep -Eq '1a221bd|build/caelestia-shell|Plan\.keymap|keymap\.try' <<<"$(own_block "$F")"; then
  bad "A10 非所有权的东西进了所有权（hash / 产物 / 属性名 / 键）"
else
  pass "A10 hash、产物、属性名、i18n 键都没进所有权"
fi

grep -q '硬撞 1' "$F" && pass "硬撞被判出 1 处" || bad "硬撞没判出来"
grep -q '软邻近 1' "$F" && pass "软邻近被判出 1 处（硬撞所在的目录不重复报）" || bad "软邻近计数不对（期望 1）"
grep -q 'components/controls/' <<<"$(sed -n '/软邻近/,/details/p' "$F")" && pass "软邻近报的是目录级" || bad "软邻近没报到目录级"

grep -qE '\[#900\]\(https://github\.com/[^/]+/[^/]+/issues/900\)' "$F" \
  && pass "撞车引用带 markdown 链接" || bad "撞车引用没带链接"

D2="$T/nontask"; mk_case_nontask "$D2"
"$SCRIPT" --from-dir "$D2" --out "$D2/out" >/dev/null 2>&1
grep -q '跳过' "$D2/out/facts.md" && pass "非 task label 跳过所有权雷达（按 label 分流）" || bad "非 task label 没跳过"
grep -q '我认领了这' "$D2/out/facts.md" && bad "非 task label 仍然输出了认领清单" || pass "非 task label 没有输出认领清单"

D3="$T/empty"; mk_case_empty "$D3"
"$SCRIPT" --from-dir "$D3" --out "$D3/out" >/dev/null 2>&1
grep -q '无法判定' "$D3/out/facts.md" && pass "空「实现」判成「无法判定」（不是「无重叠」）" || bad "空「实现」没判成「无法判定」"
grep -q '认领 0 个文件' "$D3/out/facts.md" && bad "空「实现」被说成了「认领 0 个文件」" || pass "空「实现」没被说成「认领 0 个文件」"

D4="$T/titleonly"; mk_case_title_only "$D4"
"$SCRIPT" --from-dir "$D4" --out "$D4/out" >/dev/null 2>&1
grep -q '我认领了这' "$D4/out/facts.md" && pass "[工作] 标题前缀在没有 task label 时仍触发所有权雷达" || bad "[工作] 标题前缀没有触发所有权雷达"
grep -q '跳过' "$D4/out/facts.md" && bad "[工作] 标题前缀被当成非 task" || pass "[工作] 标题前缀没有被当成非 task"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结论：该抓的抓得住，该抑制的抑制得住。"
  exit 0
fi
echo "结论：有失败项。"
exit 1
