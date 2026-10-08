# Linux 企鹅图标：生产部署记录

- 部署时间：2026-10-08 02:19 UTC
- 功能提交：`0677f638c6b35ad58f0a6c6597245676d1ea0a5d`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-linux-penguin-icon-0677f63/source.tar.gz`
- 发布包 SHA-256：`4fe3062bc43dfce3ff8edce609521cf871c39ef9c621a89e13dee531ae11380a`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T021910Z-pre-0677f63/`

## 更新内容

Linux 系统按钮从终端图标改为企鹅图标；Linux/Windows 可见文字、当前选中态和 Windows 标志保持不变。

## 验证

- `support-session/tests` 的 97 项测试通过，覆盖 Linux 企鹅 SVG、Windows 标志及按钮标签；Python 编译和 `git diff --check` 通过。
- 部署文件 SHA-256 与提交内容一致。
- 控制机服务均为 active，`nginx -t` 通过；公网健康检查 HTTP 200，未登录支持页 HTTP 401，Linux/PowerShell 客户端路由 HTTP 200。
- 会话记录为 77 条，active 会话为 0；本次未修改会话或 Edge 数据。

