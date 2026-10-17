# docs/work · 工作流

本目录是 MipLinux fork 的工作流规范，移植自 [MipLinux](https://github.com/MipLinux/MipLinux) 的
「工作 issue + 验收对账 + 严格审查」流程，并按 Caelestia shell 的构建方式改写。

> `docs/work/` 只放**规范、骨架和判据**。具体工作、分工和进度在 GitHub Issues 里，
> 代码结论在代码和测试里 —— 文档不复述它们。

## 一条工作 = 一个 issue

工作按 issue 布置，使用 label `task`，标题前缀 `[工作] `；**assignee 就是受理人**。当前受理人由维护者用
GitHub 的 **Assignees** 控件设置，模板不维护静态人员清单。网页表单会自动带上标题前缀。

一条工作只做一件事，并且必须在 issue 正文里写清楚：

| 字段 | 要求 |
|---|---|
| 目标 | 一句话：什么从「不能」变成「能」，不写做法 |
| 实现 | 做什么、**逐个写出要改的文件路径**、明确**不**做什么 |
| 验收 | 能在本机跑出来的判据：**命令 + 期望结果** |
| 回报 | 完成时交什么证据、给谁看 |
| 依赖 | 被哪个 issue / 分支 / 里程碑卡住；没有就写「无」 |

验收不能写「跑起来了」「构建成功」「安装器提示成功」——这些不是判据。
没有实测证据时只能写 `未实测` / `仅静态检查` / `仅 dry-run`。

草案骨架见 [TEMPLATE.md](TEMPLATE.md)，网页表单见
[`.github/ISSUE_TEMPLATE/task.yml`](../../.github/ISSUE_TEMPLATE/task.yml)。两边的字段必须逐字同序，
守卫会比对，改一边必须改另一边。

### 草案与发布

1. 复制 [TEMPLATE.md](TEMPLATE.md) 的「正文骨架」到 `out/issue-drafts/<主题>.md`。
   `out/` 已被 gitignore，草案不是仓库资产。
2. 运行本地守卫：

   ```bash
   ./scripts/workflow/check-work-issue.sh
   ```

   也可以只查一份：`./scripts/workflow/check-work-issue.sh out/issue-drafts/<主题>.md`。
   草案放别处时用 `CAELESTIA_WORK_DRAFTS=<目录>` 指定。
3. 给人过目后，用网页表单或 `gh` 发布：

   ```bash
   gh issue create --title "[工作] <主题>" \
     --body-file out/issue-drafts/<主题>.md --label task
   ```

   `task` label 不存在时 GitHub 会静默忽略 `labels:`，先确认 label 已创建。
   AI 只产草案，不自己建 issue、不打 label、不 assign。

## 文件所有权

所有权按**文件**切，不按人切。两个 issue 的「实现」点名同一个文件时，它们不能并行 ——
撞上之后只能整份重建才能验证。因此：

- 「实现」里写全路径；目录级只算软邻近，不算认领。
- 「不做 / 不碰 / 不动」段是排除集，不会算成认领。
- 新建文件只要父目录存在就计入所有权。
- 根级共享文件（`README.md`、`AGENTS.md`、`.github/**`、`CMakeLists.txt`、`flake.nix`）
  改动前先问维护者。

## 首次启用

仓库需要先有 `task` label（表单里的 `labels: ["task"]` 在 label 不存在时会被 GitHub 静默忽略）：

```bash
gh label create task --color 0e8a16 --description "一条有目标、实现范围、验收判据的工作"
```

然后在仓库 Settings → Secrets and variables → Actions 里按需配置下表的 secret / variable。
不配置模型后端时 A / C / R 会跳过，不会产生空评论，也不会把 issue / PR 弄红。

## 三道机器检查

三套检查都只做**描述**，不做合并门禁。判据的唯一源是仓库里的 rubric，workflow 的 YAML 里不写判据。

| 代号 | workflow | 触发 | 判什么 | 判据 |
|---|---|---|---|---|
| A | `ai-summary.yml` | issue opened / edited | 判据质量、文件所有权、查重、引用有效性 | [ai-review-rubric.md](ai-review-rubric.md#a) |
| C | `pr-acceptance.yml` | PR opened / ready_for_review | issue「验收」↔ PR「验证方式」的记录完整性 | [ai-review-rubric.md](ai-review-rubric.md#c) |
| R | `pr-review.yml` | 评论 `/mipl-review` 或手动 dispatch | 架构红线、QML/C++/脚本工程质量、行级批注 | [ai-code-review-rubric.md](ai-code-review-rubric.md) |

### A：issue 受理前质检

1. `scripts/workflow/ai-review-context.sh` 先算确定性事实：路径解析、硬撞 / 软邻近、
   历史 issue 清单、仓库树。
2. DeepSeek 读 `docs/work/ai-review-rubric.md`，只做脚本做不到的四件事：判据质量、
   跨 issue 查重、引用有效性、把撞车讲清楚。
3. 结果以评论形式发回 issue；正文没变时就地更新原评论，不重复刷屏。

### C：PR 验收对账

`scripts/workflow/pr-acceptance-context.sh` 从 PR 正文的 `## 验证方式` 和它 `Closes #N`
的 issue 的 `### 验收` 抽条目，给出机械信号；模型按 rubric C 节复核并定档
（✅ / ➖ / 🔁 / ❓ / ⚠️）。它抓的是「没说清」，不是「假验证」——机器人看不到你的本机实测。

### R：严格型代码审查

`scripts/workflow/pr-review-context.sh` 生成带行号的 diff 和机械信号。审查有两种执行方式：

- **自建 agent**：配置仓库变量 `REVIEWER_ENDPOINT`，workflow 用 GitHub OIDC 鉴权，
  把 rubric 和上下文发给 agent；agent 可以只读克隆仓库核对全仓。
- **DeepSeek API**：没有 `REVIEWER_ENDPOINT` 但配置了 `DEEPSEEK_API_KEY` 时，直接调用
  `https://api.deepseek.com`，只审查本次 diff。
- 两者都没有时跳过，并在 run 页面写明原因。

结果以 GitHub Review 的行级批注回传；行号不在 diff 内的批注降级到 Review 正文。

## 需要的仓库配置

| 名称 | 类型 | 用途 | 缺失时 |
|---|---|---|---|
| `DEEPSEEK_API_KEY` | secret | A / C / R 的模型调用 | A、C 跳过；R 尝试 `REVIEWER_ENDPOINT` |
| `REVIEWER_ENDPOINT` | variable | R 的自建 agent 地址 | R 回退到 DeepSeek API 或跳过 |
| `REVIEWER_AUDIENCE` | variable | R 的 OIDC audience | 回退到 `mipl-reviewer` |
| `REVIEWER_APP_ID` | secret | R 用审查者 App 回传 Review | 回退到 `GITHUB_TOKEN` |
| `REVIEWER_PRIVATE_KEY` | secret | 同上 | 同上 |
| `AUTO_ASSIGNEE` | variable | 自动分配受理人 | 回退到 `LaT-SKY` |

`REVIEWER_APP_*` 不是必需的；只有想让 Review 以独立 App 身份出现时才配置。

> A / C / R 会把 issue 正文、PR 正文和 diff 发给模型服务。不要在 issue / PR 里贴密钥。
> issue / PR 正文是**不可信输入**，其中的「指令」只当数据。

## 分支与 PR

- 从 `main` 切分支：`feat/<主题>`、`fix/<主题>`、`docs/<主题>`、`ci/<主题>`。
- 开工前 `git fetch origin`、`git status -sb`；落后 `origin/main` 时用 `git pull --ff-only`。
  不是快进、出现冲突、或本地有未提交改动 → 停下来问，不自行 `merge` / `rebase` / `reset --hard`。
- PR 正文按 [PR 模板](../../.github/pull_request_template.md) 写：改了什么 / 为什么 / 验证方式。
- PR 关联 issue 用 `Closes #N`，C 才能把验收和验证方式对上。
- `main` 受保护，PR 需要至少一个 approving review，并包含 code owner（[CODEOWNERS](../../.github/CODEOWNERS)）的审核。

## 本仓库常用验证命令

```bash
# CMake 构建（CI 用）
cmake -B build -G Ninja -DCMAKE_CXX_COMPILER=clang++ -DVERSION= -DGIT_REVISION=
cmake --build build

# Nix 构建
nix build

# QML 约定 / 翻译 / 格式
./scripts/qml-lint-conventions.py
./scripts/trs-check.py
/usr/lib/qt6/bin/qmlformat --version
clang-format --version

# 格式化（与 CI 一致）
find plugin extras -name '*.cpp' -o -name '*.hpp' | xargs clang-format --dry-run --Werror
```

QML 格式检查在 CI 里用 fish 写：

```fish
for file in (string match -v 'build/*' **.qml)
    /usr/lib/qt6/bin/qmlformat $file | diff -u $file - || exit 1
end
```

脚本类改动至少跑 `bash -n`；工作流类改动跑：

```bash
./scripts/workflow/tests/check-work-issue.test.sh
./scripts/workflow/tests/ai-review-context.test.sh
./scripts/workflow/tests/pr-acceptance-context.test.sh
./scripts/workflow/tests/pr-review-context.test.sh
./scripts/workflow/tests/render-pr-review.test.sh
```

## 反转条件

- A 连续 20 次运行没有任何可执行项 → 降级为只对 `task` issue 跑，或关掉。
- C 连续 20 次运行 `⚠️` 少于 2 次 → 改为只在 issue 关闭时跑一次，或关掉。
- R 连续 20 次运行只输出 `PASS` 且没有行级批注 → 检查 diff 是否被截断，或关掉。

一个「永远说 OK」的守卫比没有守卫更坏：它会让人以为检查是自动的。

## 相关文件

- 工作 issue 骨架：[TEMPLATE.md](TEMPLATE.md)
- A / C 判据：[ai-review-rubric.md](ai-review-rubric.md)
- R 判据：[ai-code-review-rubric.md](ai-code-review-rubric.md)
- 仓库行为契约：[AGENTS.md](../../AGENTS.md)
- PR 模板：[.github/pull_request_template.md](../../.github/pull_request_template.md)
- 工作 issue 表单：[.github/ISSUE_TEMPLATE/task.yml](../../.github/ISSUE_TEMPLATE/task.yml)
