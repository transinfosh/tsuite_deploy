# 系统切换按钮显示 Linux / Windows 标签：生产部署记录

- 部署时间：2026-10-08 02:17 UTC
- 功能提交：`6073f5f8216a505d26ce5f82f695c5947ec0327a`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-os-labeled-buttons-6073f5f/source.tar.gz`
- 发布包 SHA-256：`61f86b6b3d403c5ee773e5636c80254c9cf1db27c77191620f73dcaa0e7e594d`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T021711Z-pre-6073f5f/`

## 更新内容

Linux 和 Windows 系统按钮现在同时显示图标与系统名称，继续在命令标题右侧与复制按钮并排；当前选择保持高亮，并保留 tooltip 与 ARIA 标签。

## 验证

- `support-session/tests` 的 97 项测试通过，包含两个按钮的可见系统名称断言；Python 编译和 `git diff --check` 通过。
- 部署文件 SHA-256 与提交内容一致。
- 控制机相关服务均为 active，`nginx -t` 通过；公网健康检查 HTTP 200，未登录支持页 HTTP 401，Linux/PowerShell 客户端路由 HTTP 200。
- 会话记录为 77 条，active 会话为 0；本次未修改会话或 Edge 数据。

