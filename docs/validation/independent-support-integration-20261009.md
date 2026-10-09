# 独立支持工具集成验证（2026-10-09）

> 后续调整：按使用现有服务的要求，已移除本记录所述的固定版本安装入口、版本文件及其专属测试。
> 当前业务部署直接使用 192.168.2.52 上的支持服务，支持服务由独立仓库维护。以下为首次拆分的历史验证记录。

## 变更边界

支持工具从 `ef5933994f319f372fe65836def0900da83fe115` 提取到
[transinfosh/tsuite-support](https://github.com/transinfosh/tsuite-support)，保留相关历史。
32 个原 support-session 文件均已迁入；14 份支持工具历史验证记录逐字节保留。
13 个运行时源文件与提取前逐字节一致。原仓库历史不重写。

本仓库仅保留混合部署路由、运维流程和固定版本安装集成。
`control-node/support-release.env` 固定 `v0.1.0` 与归档 SHA-256：
`6b2003ea32db9facfd445d9fa2236ad4f6b78a69ba26eafa912454f7f5bf5d66`。
原两个控制服务入口的参数边界、代理与精确重启授权保持兼容。

## 验证

- 独立仓库：101 项 Python 测试、ShellCheck、Python/Shell 语法检查通过。
- 本机真实双 sshd 验证：证书登录、Edge forced proxy、跨会话拒绝、Shell 拒绝、错误私钥、原生到期和撤销通过。
- [Linux CI](https://github.com/transinfosh/tsuite-support/actions/runs/37908830988) 完整通过。
- [Windows CI](https://github.com/transinfosh/tsuite-support/actions/runs/37908830984) 完整通过：PowerShell 5.1、ACL、生命周期、原生转发及 OpenSSH 8.1/9.8.3 认证。
- 本仓库：4 项安装边界测试通过，包括正确归档与参数转发、摘要不匹配拒绝执行、安装失败退出码、固定 Release URL。
- `tests/test_static.sh` 通过，包含既有 17 项补丁部署测试和单机部署隔离验证。
- 真实 Release 归档通过两个兼容安装入口的 `--help` 验证；安装器未实际写入系统。

## 部署边界

这是源码与发布边界拆分，没有修改线上配置、会话状态、已安装命令或 systemd 服务。
本次未执行新机器完整安装，也未重启生产服务；不能将 CI 或 `--help` 检查视为完整安装验证。
