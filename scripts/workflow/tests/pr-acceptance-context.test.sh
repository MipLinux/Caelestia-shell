#!/usr/bin/env bash
# pr-acceptance-context.sh 的回归测试：夹具取自 Caelestia 风格的验收条目，
# 断言「该抑制的抑制住、该报的报得出」。
#
# 夹具全部在临时目录里，不联网、不写真实仓库。
# 不需要 root。用法：./scripts/workflow/tests/pr-acceptance-context.test.sh

set -uo pipefail
export LC_ALL=C

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$SELF_DIR/../pr-acceptance-context.sh"

FAIL=0
pass() { printf '✅ %s\n' "$1"; }
bad()  { printf '❌ %s\n' "$1"; FAIL=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
[ -f "$SCRIPT" ] || { echo "错误：读不到 $SCRIPT" >&2; exit 1; }

mk_case_main() {
  local d=$1
  mkdir -p "$d/issues"
  printf 'number\t96\ntitle\tbar：修复多显示器下的布局\nhead\t3064e79cafe\nstate\tMERGED\n' >"$d/meta.tsv"
  cat >"$d/pr-body.md" <<'EOF'
## 改了什么

修复多显示器下的 bar 布局。

## 验证方式

| 项 | 结果 |
|---|---|
| CMake | `cmake --build build` → 单测 30/30 通过 |
| 翻译 | `./scripts/trs-check.py` → 138 键 × 2 语言 |
| 静态检查 | 品牌色板三方一致 · 对比度 46 组全过 · 单测 56 项 · probe 84 项断言全过 |

**仍未实测**：Hyprland 图形会话下的实际观感。
EOF
  printf '92\tbar 多显示器布局\n' >"$d/issues.tsv"
  cat >"$d/issues/92.md" <<'EOF'
### 目标

夹具。

### 实现

改 `modules/bar/Bar.qml`。

### 验收

- `ctest --test-dir build` → **30/30 通过**。
- `./scripts/trs-check.py` → **138 键 × 2 语言**与源一致。
- `gen-tokens.py --check` / `gen-icons.py --check` → 生成物与源一致。
- `check-tokens.py` → 品牌色板三方一致。
- `check-contrast.py` → **46 组全过**。
- `ctest -R unit` → 51 项通过。
- `probe-render` → **42 项断言全过**。
- **未实测**：需要 Hyprland 图形会话，由维护者手动验证。

### 回报

无
EOF
  : >"$d/other-prs.tsv"
}

mk_case_multi() {
  local d=$1
  mkdir -p "$d/issues" "$d/other-prs"
  printf 'number\t83\ntitle\t补回 Live 入口\nhead\tfe3a867aaaa\nstate\tMERGED\n' >"$d/meta.tsv"
  printf '## 验证方式\n\n| 项 | 结果 |\n|---|---|\n| 静态检查 | `./scripts/qml-lint-conventions.py` → 0 |\n' >"$d/pr-body.md"
  printf '79\tbar 阶段 0\n' >"$d/issues.tsv"
  cat >"$d/issues/79.md" <<'EOF'
### 验收

- `./scripts/workflow/check-contrast.py` → 期望 28 组全过、0 组不合格。
- `sudo ./scripts/... build` → 期望构建成功（需要 root，由维护者执行）。

### 回报

无
EOF
  printf '80\tfeat(bar)：阶段 0\n' >"$d/other-prs.tsv"
  printf '## 验证方式\n\n| 项 | 结果 |\n|---|---|\n| 对比度 | `check-contrast.py` → exit 0，**28 组全过** |\n' >"$d/other-prs/80.md"
}

run() { "$SCRIPT" --from-dir "$1" --out "$2" >"$1/log" 2>&1; }
counts() { grep -o '判据 [0-9]* 条（机械信号）：.*' "$1" | head -1; }

D="$T/c96"; mk_case_main "$D"
if run "$D" "$D/out"; then pass "夹具 1 退出码 0"; else bad "夹具 1 失败：$(tail -2 "$D/log")"; fi
F="$D/out/facts.md"
[ -f "$F" ] && pass "facts.md 已生成" || bad "facts.md 没生成"

grep -q '判据 8 条' "$F" && pass "判据条数 = 8" || bad "判据条数不对：$(counts "$F")"

grep -E '^\| 7 ' "$F" | grep -q '❓' && pass "R5：42 项 vs 84 项判成 ❓" || bad "R5：42/84 那条判错了"
grep -E '^\| 6 ' "$F" | grep -q '❓' && pass "R5：51 项 vs 56 项判成 ❓" || bad "R5：51/56 那条判错了"
grep -E '^\| 1 ' "$F" | grep -q '✅.*30/30' && pass "同值 30/30 命中 ✅" || bad "同值信号没生效"
grep -E '^\| 2 ' "$F" | grep -q '✅.*138' && pass "同值 138 命中 ✅" || bad "138 键没命中"
grep -E '^\| 4 ' "$F" | grep -q '✅' && pass "词面信号：品牌色板三方一致 ↔ 色板三方一致" || bad "词面信号没生效"
grep -E '^\| 8 ' "$F" | grep -q '➖' && pass "R3：自带「需要图形会话」的判据被抑制成 ➖" || bad "R3 抑制没生效"
grep -E '^\| 3 ' "$F" | grep -q '⚠️' && pass "真缺口（gen-tokens / gen-icons 没写进 PR）报成 ⚠️" || bad "真缺口没报出来"

D2="$T/c96b"; cp -r "$D" "$D2"; rm -rf "$D2/out" "$D2/log"
sed -i 's/单测 30\/30 通过/构建成功/' "$D2/pr-body.md"
run "$D2" "$D2/out"
grep -E '^\| 1 ' "$D2/out/facts.md" | grep -q '⚠️' && pass "反例：删掉声称后对应判据从 ✅ 翻成 ⚠️" || bad "反例失败：删掉声称也没翻成 ⚠️"

D3="$T/cmulti"; mk_case_multi "$D3"
run "$D3" "$D3/out"
grep -q 'PR #80' "$D3/out/facts.md" && pass "R7：证据在另一个 PR 里时被认到（点名 PR #80）" || bad "R7：没认到另一个 PR 里的证据"
grep -qE '\[PR #80\]\(https://github\.com/[^/]+/[^/]+/pull/80\)' "$D3/out/facts.md" \
  && pass "跨 PR 引用带 markdown 链接" || bad "跨 PR 引用没带链接"
grep -E '^\| 2 ' "$D3/out/facts.md" | grep -q '➖' && pass "R7 + R3：自带「需要 root」的那条仍被抑制" || bad "R3 在多 PR 夹具里失效"

D4="$T/cnolink"; mkdir -p "$D4"
printf 'number\t900\ntitle\t没有关联的 PR\nhead\tdeadbeef000\nstate\tOPEN\n' >"$D4/meta.tsv"
printf '## 验证方式\n\n| 项 | 结果 |\n|---|---|\n| 静态检查 | 全过 |\n' >"$D4/pr-body.md"
: >"$D4/issues.tsv"
run "$D4" "$D4/out"
grep -q '无法判定' "$D4/out/facts.md" && pass "没关联 issue 的 PR 判成「无法判定」" || bad "没关联 issue 时没说「无法判定」"
grep -q '判据 0 条' "$D4/out/facts.md" && bad "0 条判据被说成了「判据 0 条」" || pass "0 条判据没被报成「判据 0 条」"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结论：该抑制的抑制得住，该报的报得出。"
  exit 0
fi
echo "结论：有失败项。"
exit 1
