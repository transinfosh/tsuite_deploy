# GitHub 受限出口

当部署控制机无法稳定直连 GitHub Web 登录节点时，本模块通过一台可达的云主机提供受限 HTTPS 出口。

- 云主机的 Tinyproxy 仅监听 `127.0.0.1:8888`。
- SSH 用户只允许转发到该回环端口，不允许 shell、PTY、代理转发或其他目标。
- Tinyproxy 仅允许 GitHub、GHCR 与 GitHub 静态资源域名，其他域名默认拒绝。
- 控制机仅监听 `127.0.0.1:18080`，`gh` 包装器和 Git 配置自动使用该端口。
- 出口使用独立 Ed25519 密钥，不复用操作员个人私钥或部署目标主机密钥。

安装顺序：先在出口机运行 `install-bastion.sh`，再在控制机运行 `install-control.sh`。控制机安装时通过 `--egress-host` 指定已验证 Host Key 的出口主机。
