# 支持会话命令区内的系统选择器：生产部署记录

- 部署时间：2026-10-08 02:03 UTC
- 功能提交：`c795fcf4656f38276d85e374ee2120ffb6f0247d`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-command-local-selectors-c795fcf/source.tar.gz`
- 发布包 SHA-256：`789b1a8132e4778edbacd429b51401d1035a0b656850337e5bd958a07e35475d`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T020317Z-pre-c795fcf/`

## 更新内容

被控机系统选择器现在放在客户执行命令下方，支持机系统选择器放在支持机执行命令下方；各自标题和标签明确说明对应关系。更改选择会自动更新相应命令。无 JavaScript 时每个选择器下仍显示对应的手动更新按钮。

## 验证

- `support-session/tests` 的 97 项测试通过，包含检查两个选择器各自位于对应命令之后的断言。
- 控制台文件部署后 SHA-256 与提交内容一致。
- 控制机相关服务均为 active，`nginx -t` 通过；公网健康检查 HTTP 200，未登录支持页 HTTP 401，Linux/PowerShell 工具路由 HTTP 200。
- 会话记录为 74 条，active 会话为 0；本次未更新 Edge 或会话数据。

