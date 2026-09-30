# Windows 原生支持机控制端上线记录

2026-09-30，原生 PowerShell/OpenSSH 支持机客户端已部署到 `adam@192.168.2.52`。
线上入口为 `https://edge.trinfo.net/support/`。创建页独立选择客户机与支持机系统；支持机选择
Windows 后生成 PowerShell 命令，客户机仍可选择 Linux 或 Windows。

## 部署版本与范围

- 代码提交：`2b5c59af45416768a6177706cf9754784e2ae8dc`。
- 已推送分支：`codex/native-windows-support-operator`。
- 发布目录：`/srv/tsuite-deploy/releases/support-windows-operator-20260930T064843Z-2b5c59af/`。
- 发布目录保留 Git 源码归档、SHA-256 清单、安装脚本和 `deployment.json`。
- 运行文件：`/usr/local/lib/tsuite-support-console/tsuite-support-console`、
  `tsuite_support_windows.ps1`、`tsuite_support_windows_relay.cs`。
- 仅重启 `tsuite-support-console.service`；新进程于 `2026-09-30 06:51:57 UTC` 启动。

控制机现有 GitHub 代理无法连接。本次从开发机传送已推送提交的源码归档，校验归档与三个运行文件
的 SHA-256 后精确安装；未改变控制机原仓库检出及其内容。安装前运行中的 console 与本地基础版本
一致。Edge、broker、客户 bootstrap、现有 Linux 客户端和会话数据均未更新，无需数据迁移。

## 验证结果

- 开发机和控制机发布目录各通过全部 91 项 Python 支持会话测试。
- 开发机 pwsh 通过 PowerShell/C# 语法、真实 keygen、带空格路径、SSH 配置、远端命令编码、
  二进制输入输出、退出码、超时及租约清理测试。
- 两个隔离 sshd 验证 PowerShell/C# 构造的证书登录、Edge 代理和固定主机密钥拒绝。
- 实际运行服务的登录后网页包含独立 Windows 支持机选项。验证使用临时 Web session，验证后已删除，
  未创建客户支持会话。
- 公网 `/support/operator-client.ps1` 返回 200、`Cache-Control: no-store`；其中 PowerShell 与 C#
  源码的 SHA-256 与发布清单一致。
- 原 `/support/operator-client` 返回 200，嵌入 Linux 客户端可编译。
- 公网控制机健康检查返回 200；未登录 `/support/` 返回 401，登录保护保持有效。
- nginx、FRPC、console、GitHub egress 均为 active，console 上线后 error 级别日志为 0 行。
- 部署前后均为 68 条支持会话记录、1 条活动会话；未关闭、替换或创建客户支持会话。

## 备份、回退与验证边界

原运行文件及原文件存在状态保存在：
`/srv/tsuite-deploy/backups/support-console/support-windows-operator-20260930T064843Z-2b5c59af/`。
如需回退，在控制机执行：

```bash
sudo python3 /srv/tsuite-deploy/backups/support-console/support-windows-operator-20260930T064843Z-2b5c59af/rollback.py
```

该脚本恢复原 console、移除本次新增文件并重启 console。配置、密钥、现有会话不在此次回退范围内。
服务端上线及公网下载已验证；Windows 真实系统上的 ACL、ConPTY 交互、经公网 Edge 登录、连续输入续期
与本地清理仍需 Windows 端验收，不能用 Linux pwsh 测试代替。既有控制面异机备份恢复演练、告警和
历史保留待办见统一部署运行手册，本次仅保存此次代码更新的备份与回退材料。
