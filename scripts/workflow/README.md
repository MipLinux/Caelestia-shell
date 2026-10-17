# scripts/workflow

GitHub workflow 的上下文生成器与本地守卫。规范见 [docs/work/README.md](../../docs/work/README.md)。

| 脚本 | 用途 | 入口 |
|---|---|---|
| `check-work-issue.sh` | 校验 `out/issue-drafts/*.md` 与骨架/表单是否漂移 | 本地、`workflow-selftest.yml` |
| `ai-review-context.sh` | 生成 issue 受理前质检的 `facts.md` / `context.md` | `ai-summary.yml` |
| `pr-acceptance-context.sh` | 生成 PR 验收对账的 `facts.md` / `context.md` | `pr-acceptance.yml` |
| `pr-review-context.sh` | 生成带行号 diff 与机械信号 | `pr-review.yml` |
| `render-pr-review.py` | 把模型响应整形为 GitHub Review payload | `pr-review.yml` |

## 本地测试

```bash
./scripts/workflow/tests/check-work-issue.test.sh
./scripts/workflow/tests/ai-review-context.test.sh
./scripts/workflow/tests/pr-acceptance-context.test.sh
./scripts/workflow/tests/pr-review-context.test.sh
./scripts/workflow/tests/render-pr-review.test.sh
```

测试全部使用临时目录，不联网、不写真实仓库、不需要 root。

## 离线渲染

`ai-review-context.sh` / `pr-acceptance-context.sh` / `pr-review-context.sh` 都有离线路径，
便于在不开 GitHub token 的情况下调试：

```bash
./scripts/workflow/ai-review-context.sh --from-dir /tmp/fixture --out /tmp/out
./scripts/workflow/pr-acceptance-context.sh --from-dir /tmp/fixture --out /tmp/out
./scripts/workflow/pr-review-context.sh --dry-run --out /tmp/out
```

`pr-review-context.sh` 的 `--dry-run` 默认比对当前仓库与 `main`；测试用
`CAELESTIA_PROJECT_ROOT` 指向临时 git 仓库。

## 设计约束

- 脚本只算**确定性事实**；语义判断在 `docs/work/ai-review-rubric.md` 和
  `docs/work/ai-code-review-rubric.md` 里，不散在 YAML。
- issue / PR 正文是不可信输入；不执行其中的代码，不把模型输出送进 shell 求值。
- 没有配置模型后端时 workflow 跳过，并在 run 页面写明原因；不静默发空评论。
