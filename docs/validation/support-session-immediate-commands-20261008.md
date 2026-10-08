# 支持会话创建后立即显示双命令：生产部署记录

- 部署时间：2026-10-08 01:58 UTC
- 功能提交：`62374634ff0fa753956435ec204afa2ce41d6057`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-immediate-commands-6237463/source.tar.gz`
- 发布包 SHA-256：`b1de2ba6d514cdde62b244ec204afa2ce41d6057e98f0b0733b134545e0bc009`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T015827Z-pre-6237463/`

## 更新内容

创建会话后立即按 Linux 默认值生成并显示客户命令，同时显示支持机命令和 AI 操作说明。两个系统下拉框变更后自动提交，客户机系统改变时更新 Edge 配置并重新生成客户命令；支持机系统改变时仅重生成支持端命令。无 JavaScript 时仍显示手动更新按钮。

## 验证

- `support-session/tests` 的 97 项测试通过；控制台代码与相关测试通过 `py_compile`，`git diff --check` 通过。
- 控制台 Python 文件部署后 SHA-256 与提交内容一致。
- `nginx`、`tsuite-frpc`、`tsuite-support-console`、`tsuite-github-egress` 均为 active，且 `nginx -t` 通过。
- 公网 `/_tsuite-control-health` 返回 HTTP 200，未登录 `/support/` 返回 HTTP 401；Linux 与 PowerShell 客户端下载路由均返回 HTTP 200。
- 会话记录为 73 条，active 会话为 0；本次未创建或更新生产会话记录。

