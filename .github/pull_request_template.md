<!--
main 受保护：PR 需要至少 1 个 approving review，并包含 code owner（@LaT-SKY）的审核。
本文件里的 HTML 注释不会显示在渲染后的正文中，但下面的标题请保留。
填不出来的项请写「未验证」或「N/A」，不要留空。
关联 issue 写 Closes #N，验收对账（C）靠它取 issue。
-->

## 改了什么

<!-- 一两句话。一个 PR 只做一件事。 -->

## 为什么

<!-- 解决什么问题、依据哪条已有结论或哪个 issue。 -->

## 验证方式

<!-- 只写真实跑过的命令与结果。纯文档改动可整段写 N/A。 -->

| 项 | 结果 |
|---|---|
| CMake 构建 `cmake -B build -G Ninja ... && cmake --build build` | 产物 / 退出码： |
| Nix 构建 `nix build` | 产物： |
| 静态检查 | `./scripts/qml-lint-conventions.py`、`./scripts/trs-check.py`、`qmllint` / `clang-tidy`： |
| 运行时 | Hyprland 会话下验到的行为；未实测就写「未实测」： |

## 检查项

- [ ] 本次 PR 只做一件事（没有把「搬文件」和「改文件」混在一起）
- [ ] 已运行格式化：`qmlformat` / `clang-format`
- [ ] 没有提交 `build/`、`result`、`.direnv/`、`*.mo`、日志或任何密钥
- [ ] 改了行为或结论时，相关 issue / 文档已同步
- [ ] QML 用户可见字符串走 `Tr` 封装，没有新增 `qsTr` 或硬编码
- [ ] 如果引入了新依赖或改了 `flake.lock`，已在正文说明原因

Closes #
