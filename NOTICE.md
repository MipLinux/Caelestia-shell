# 版权与许可声明

本仓库是 [Caelestia shell](https://github.com/caelestia-dots/shell) 的 MipLinux fork。

- **本仓库**：<https://github.com/MipLinux/Caelestia-shell>
- **上游**：<https://github.com/caelestia-dots/shell>
- **上游许可**：GPL-3.0（按上游 LICENSE；本 fork 以 GPL-3.0-only 分发）
- **本 fork 的修改**：Copyright (C) 2026 MipLinux contributors，同样按 **GPL-3.0-only** 发布。
- **完整许可全文**：[LICENSE](LICENSE)

## MipLinux fork 结构

| 仓库 | 内容 | 关系 |
|---|---|---|
| [Caelestia-dotfiles](https://github.com/MipLinux/Caelestia-dotfiles) | Hyprland / Wayland 配置与主题 | fork |
| [Caelestia-shell](https://github.com/MipLinux/Caelestia-shell) | 本仓库：顶栏、面板、启动器等 shell 本体 | fork |
| [Caelestia-cli](https://github.com/MipLinux/Caelestia-cli) | `caelestia` 安装 / 更新命令 | fork |

三个 fork 的 `main` 跟踪上游，只保留最小的 MipLinux 文档 / 许可声明；功能改动放 `mip` 分支 / tag，发布时记录上游 base commit。
dots / shell / cli 与 Quickshell 的 pin 一起对齐，不单独升级其中一个。

## 相关组件

| 组件 | 许可 | 仓库 |
|---|---|---|
| Caelestia CLI | GPL-3.0-only | <https://github.com/MipLinux/Caelestia-cli>（上游 <https://github.com/caelestia-dots/cli>） |
| Quickshell | LGPL-3.0 | <https://github.com/quickshell-mirror/quickshell> |
| Qt6 | LGPL-3.0（部分 GPL-3.0） | <https://www.qt.io/licensing> |

本仓库不包含 Quickshell、Qt6 或 NVIDIA 驱动。运行时依赖各自保留许可；发行版中的
NVIDIA 用户态组件（`nvidia-utils`）是独立专有组件，不属于本仓库的 GPL 许可范围。

## 修改与再分发

- 修改本仓库的文件时，保留原版权声明，并标明 MipLinux 的改动。
- 再分发本仓库或其修改版时，按 GPL-3.0-only 提供对应源码与许可全文。
- `Caelestia` 名称与标识的权利不随 GPL 授予；对外产品名使用 MipLinux，并保留
  “based on Caelestia” 的来源说明。
