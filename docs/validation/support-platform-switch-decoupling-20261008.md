# 支持机与被控机系统切换解耦：生产部署记录

- 部署时间：2026-10-08 01:54 UTC
- 功能提交：`700a3a9fbb0586ab03efaca0263e26d4ad45ac0b`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-os-decouple-700a3a9/source.tar.gz`
- 发布包 SHA-256：`fb439f8c713abf0abebaf75055e452331955803abb9a513b62a893da71010da6`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T015434Z-pre-700a3a9/`

## 更新内容

命令页先查询 Edge 当前被控机系统。仅当被控机系统真的发生变化时才调用 Edge 的 `set-platform`；只切换支持机系统时保留当前客户命令，在控制机本地重新生成支持命令和 AI 说明。因此被控机接入后的系统锁定不会阻止支持机系统切换。

## 验证

- `support-session/tests` 的 97 项测试通过，包含客户已接入后仅更改支持机系统的用例；Python 编译与 `git diff --check` 通过。
- 部署文件 SHA-256 与提交中的 `support-session/console/tsuite_support_console.py` 一致。
- 控制机 `nginx`、`tsuite-frpc`、`tsuite-support-console`、`tsuite-github-egress` 均为 active，`nginx -t` 通过。
- 公网 `/_tsuite-control-health` 返回 HTTP 200，未登录 `/support/` 返回 HTTP 401；Linux 与 PowerShell 客户端下载路由均返回 HTTP 200。
- Edge 未修改；会话记录仍为 71 条，active 会话为 0。

