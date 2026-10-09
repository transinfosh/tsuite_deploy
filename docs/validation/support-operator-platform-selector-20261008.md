# 支持会话命令页切换支持机系统：生产部署记录

- 部署时间：2026-10-08 01:51 UTC
- 功能提交：`927cb6721af41a36e9f4c3074eaf3476b59f5ace`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-os-selector-927cb67/source.tar.gz`
- 发布包 SHA-256：`4e4d3e41081a1ec3409481ac0fc4119226051a16a7b2603f25bfa917c5eaaecf`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T015143Z-pre-927cb67/`

## 更新内容

会话命令页现在同时提供支持机和被控机系统选择。更改支持机系统会重新生成对应的 Linux 或 PowerShell 支持命令及 AI 操作说明；被控机系统仍由 Edge 更新，并在客户接入后锁定。

## 验证

- `support-session/tests` 的 96 项测试通过；目标 Python 文件通过 `py_compile`，`git diff --check` 通过。
- 控制机 `nginx`、`tsuite-frpc`、`tsuite-support-console`、`tsuite-github-egress` 均为 active，`nginx -t` 通过。
- 稳定后公网 `/_tsuite-control-health` 返回 HTTP 200，未登录 `/support/` 返回 HTTP 401；Linux 与 PowerShell 客户端下载路由均返回 HTTP 200。
- 会话列表为 71 条，未接入活动通道为 0；本次仅重启控制页面服务，没有变更 Edge 会话数据。
- 服务重启后的首次公网探测遇到短暂 502；数秒后重测恢复上述预期状态。

