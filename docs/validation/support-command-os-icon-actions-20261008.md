# 命令标题旁的系统图标按钮：生产部署记录

- 部署时间：2026-10-08 02:09 UTC
- 功能提交：`ab883130ac88b5b48642854daa155e3e650fa317`
- 部署目标：控制机 `adam@192.168.2.52`
- 发布包：`/srv/tsuite-deploy/releases/support-console-os-icon-actions-ab88313/source.tar.gz`
- 发布包 SHA-256：`14c911e597cac4d8b7f010e74d893719df2a152683ee226bba0fbc1b2c53024a`
- 更新前备份：`/var/backups/tsuite-support-console/20261008T020955Z-pre-ab88313/`

## 更新内容

用 Linux 终端和 Windows 标志图标按钮替代系统下拉框。各自的 Linux/Windows 按钮与命令标题及复制按钮并排，当前系统带选中态；图标带 tooltip、ARIA 标签和屏幕阅读器文本。

## 验证

- `support-session/tests` 的 97 项测试通过，覆盖两组图标按钮、可访问名称与命令区归属；Python 编译和 `git diff --check` 通过。
- 部署文件 SHA-256 与提交内容一致。
- 控制机服务均为 active，`nginx -t` 通过；公网健康检查 HTTP 200，未登录支持页 HTTP 401，Linux/PowerShell 客户端路由 HTTP 200。
- 会话记录为 76 条，active 会话为 0；本次未修改会话或 Edge 数据。

