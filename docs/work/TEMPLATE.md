---
description: 工作 issue 的正文骨架：一条工作 = 一个 issue；复制到 out/issue-drafts/ 填好，给人过目后再发布。
tags: [work, template, issue]
---

<!--
  用法：只复制「正文骨架」那一节（从 `### 目标` 到文件末尾），存成
  `out/issue-drafts/<主题>.md`。`out/` 已 gitignore，草案不是仓库资产。

  填好之后先跑守卫：

      ./scripts/workflow/check-work-issue.sh out/issue-drafts/<主题>.md

  也可以把草案放到任何可写目录，用
  `CAELESTIA_WORK_DRAFTS=<目录> ./scripts/workflow/check-work-issue.sh` 校验整个目录。

  别把本文件的 frontmatter 与这段注释抄进草案：issue 不是仓库文档，不接受 YAML
  frontmatter 与 HTML 注释。骨架里的 `### <字段>` 标题不能改名 ——
  `.github/ISSUE_TEMPLATE/task.yml` 的 `label:` 与它们逐字相同，守卫会比对两边是否漂移。

  发布前先给维护者过目；AI 不自己建 issue：

      gh issue create --title "[工作] <主题>" \
        --body-file out/issue-drafts/<主题>.md --label task
-->

## 正文骨架（从下一行开始复制）

### 目标

<一句话：让什么从「不能」变成「能」，或从「错」变成「对」。不写做法。>

### 实现

<做什么、改哪些文件（逐个写路径）、明确**不**做什么。>

### 验收

<能在本机跑出来的判据：命令 + 期望结果。
没有实测证据不许写「已验证」，只能写 未实测 / 仅静态检查 / 仅 dry-run。>

### 回报

<交什么（命令输出 / 文件路径 / 截图 / PR 链接）、给谁。>

### 依赖

<被哪个 issue / 分支 / 里程碑卡住；没有就写「无」。>

---

**开工前请执行：**

```bash
git switch main && git pull --ff-only origin main
git switch -c feat/<主题>   # 只改文档用 docs/<主题>
```

> 本 issue 由 AI 起草，可能有错误；如有问题，请直接在本 issue 下回复。
> 分支不在 `main` 上、或拉取不是快进 → 停下来问维护者，**不要**自行 `merge` / `rebase` / `reset --hard`。
