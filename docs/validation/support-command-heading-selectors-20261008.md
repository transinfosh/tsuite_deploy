# 命令标题旁的系统选择器：生产部署记录

- 部署时间：2026-10-08 02:06 UTC
- 功能提交：`30855a4382b1caadc57808e89c0967926c598a55`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-command-heading-selectors-30855a4/source.tar.gz`
- 发布包 SHA-256：`b18d8cb57e88eb526566fb103fa005a2132c84ee62212018b89195b00f774704`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T020632Z-pre-30855a4/`

## 更新内容

被控机系统选择器移动到“客户执行命令”标题行；支持机系统选择器移动到“支持机执行命令”标题行。两个选择器均保留清楚的标签、自动更新行为和复制按钮；窄屏下标题行会换行。

## 验证

- `support-session/tests` 的 97 项测试通过，包含选择器与对应命令的顺序断言；Python 编译和 `git diff --check` 通过。
- 控制台文件部署后 SHA-256 与提交内容一致。
- 控制机相关服务均为 active，`nginx -t` 通过；公网健康检查 HTTP 200，未登录支持页 HTTP 401，Linux/PowerShell 客户端路由 HTTP 200。
- 会话记录为 75 条，active 会话为 0；本次没有修改会话或 Edge 数据。

