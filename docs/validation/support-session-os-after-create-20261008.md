# 支持会话创建后选择被控机系统：生产部署记录

- 部署时间：2026-10-08 01:46 UTC
- 功能提交：`06a1702ef090e6482fef2f93b7dff100aa8f63f7`
- 部署目标：控制机 `adam@192.168.2.52` 与 Edge `ubuntu@edge.trinfo.net`
- 发布包：`/srv/tsuite-deploy/releases/support-session-os-after-create-20261008T014400Z-06a1702/source.tar.gz`
- 发布包 SHA-256：`1f0c35202ddc69236ce1f306feb139176942fb5e62628b9e7ecbf0b0742e6820`

## 更新内容

- Edge 会话管理器支持将尚未接入的会话从 `pending` 设置为 Linux 或 Windows，并拒绝在客户接入后修改。
- Edge bridge 与控制机 broker 转发 `set-platform` 操作。
- 控制页面创建会话时只选择支持机系统；会话命令页面再选择被控机系统，并据此生成对应接入命令与 AI 指令。
- Edge 与控制机 sudoers 均增加最小范围的 `set-platform` 授权。

## 备份与回滚

- Edge 更新前备份：`/var/backups/tsuite-support-session/20261008T014504Z-pre-06a1702/`
- 控制机更新前备份：`/var/backups/tsuite-support-console/20261008T014607Z-pre-06a1702/`
- 回滚时分别从备份恢复 Edge 的 `edge-manager`、`edge-bridge`、`edge-sudoers`，以及控制机的 `console`、`broker`、`sudoers`；恢复 sudoers 后执行 `visudo -c`。控制机恢复后重启 `tsuite-support-console.service`。

## 验证

- 两侧 Python 文件均在安装前通过 `py_compile`；两侧 sudoers 均通过 `visudo` 校验。
- Edge 与控制机的 `set-platform` sudo 授权均可见。
- 控制机 `nginx` 配置通过 `nginx -t`；`nginx`、`tsuite-frpc`、`tsuite-support-console`、`tsuite-github-egress` 均为 active。
- 公网 `/_tsuite-control-health` 返回 HTTP 200，未登录 `/support/` 返回预期 HTTP 401。
- `/support/operator-client` 与 `/support/operator-client.ps1` 分别返回 HTTP 200。
- Edge 服务保持 active；会话记录仍为 70 条，active 会话为 0。部署过程中未创建或关闭生产会话。
- 本次部署前，功能提交的 96 项 Python 测试、`py_compile`、`bash -n` 和 `git diff --check` 均已通过。
