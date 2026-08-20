# frappe_deploy 代理执行说明

## 适用范围

本文档适用于 `frappe_deploy` 部署仓库。

## 共享组件版本

- 本地应用可以通过 `file:` 引用同一工作区内的共享组件库，便于开发和联调。
- GitHub Actions 与 Docker 发布构建必须通过不可变 Git Tag 检出 `tai-chat`、`transinfo-ui` 等共享组件库。
- 发布构建不得使用 `file:`、分支名或裸提交 SHA 作为共享组件版本。
- Tag 必须与组件库 `package.json` 版本一致，格式为 `v<version>`；修改构建默认版本前应确认对应远端 Tag 已存在。
- 已用于发布的 Tag 不得移动或覆盖；组件内容变化时应先发布新组件版本，再更新构建输入。

## 发布验证

- 修改共享组件 Tag 后，至少执行工作流静态检查，并通过一次相关镜像构建验证组件检出与前端编译。
- 不要在工作流或文档中写入源码 Token、GHCR Token 或其他密钥值。
