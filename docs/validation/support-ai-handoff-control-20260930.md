# 会话命令页面 AI 操作说明上线记录

2026-09-30，在 `192.168.2.52` 更新支持管理页面和 Linux portable 客户端。
新建会话结果页新增“交给 AI 的操作说明”及复制按钮。说明根据 Linux/Windows 支持机与
Linux/Windows 客户机的四种组合生成，包含客户环境、会话 ID、支持用途、首次命令检查、再次连接
方式、远端 Shell 示例、结果判断与会话结束提示。未填写用途时保留任务占位符。

Linux 首次命令新增可选 `--command 'hostname'`，避免 AI 进入交互终端；Windows 支持机沿用
`-Command 'hostname'`。Linux 控制端连接 Windows 客户机时，单条远端命令自动编码为 PowerShell。
原交互接入、Linux `--resume`、Windows `-Mode Resume` 和领取接口保持兼容。
复制说明包含一次性授权，仅保存在创建响应中，响应保持 `Cache-Control: no-store`。

## 版本与运行状态

- 已推送代码提交：`dab3366bdbd4d6053c6d6a34ea333ab9d5821677`。
- 分支：`codex/native-windows-support-operator`。
- 发布目录：`/srv/tsuite-deploy/releases/support-ai-handoff-20260930T071644Z-dab3366b/`。
- 精确替换 `/usr/local/lib/tsuite-support-console/tsuite-support-console` 和
  `/usr/local/lib/tsuite-support-console/tsuite_support_portable.py`。
- console 新进程于 `2026-09-30 07:17:57 UTC` 启动。
- nginx、FRPC、console、GitHub egress 均为 active。

发布前核对运行文件与上次部署 SHA-256；按已推送提交归档传送，验证源码清单后备份和原子替换，
仅重启 console。保留控制机原仓库检出、配置、密钥、broker、Windows 客户端文件与 Edge 配置。
部署前后均有 69 条支持会话记录、2 条活动会话；未创建或关闭客户支持会话。

## 验证

- 开发机与控制机发布源码各通过全部 95 项 Python 支持会话测试。
- 新增测试覆盖四种组合、任务及授权复制、HTML 转义、不持久化说明、首次 Linux 命令模式、
  Linux 命令原样传递与 Windows 命令 UTF-16LE 编码。
- 在实际安装的 console 模块上，用隔离临时状态和模拟 broker 验证四种创建页面；未向生产 broker
  创建验证用会话。
- 公网 Linux 下载地址返回 200，其内嵌客户端 SHA-256 与清单一致，包含新的首次命令与编码逻辑。
- Windows 下载地址与公网健康检查返回 200，未登录支持页面返回 401。

## 回退与边界

备份目录：`/srv/tsuite-deploy/backups/support-console/support-ai-handoff-20260930T071644Z-dab3366b/`。
控制机回退命令：

```bash
sudo python3 /srv/tsuite-deploy/backups/support-console/support-ai-handoff-20260930T071644Z-dab3366b/rollback.py
```

新说明仅出现在新建会话的一次性命令页面。现有支持机已经保存的旧脚本不会远程改写；新领取的
Linux 客户端才包含此次增强。Windows 原生 ACL/ConPTY 实机验收边界仍沿用上一份上线记录，
本次未变更 Windows 原生终端实现。控制面备份与告警等长期待办沿用统一部署运行手册。
