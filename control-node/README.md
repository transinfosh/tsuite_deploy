# 部署控制机

`control-node` 把发布、Ansible、客户部署文件和 GitHub 支持管理页面集中到一台稳定的内网
Linux 服务器。公网堡垒机只保留 Caddy、FRPS 和 SSH 反向隧道入口；控制机通过 FRPC 主动连接
堡垒机，不需要公网 IP 或入站端口。

生产拓扑：

```text
GitHub / 运维人员
        |
        v
部署控制机（代码、Ansible、制品、支持页面、FRPC）
        |
        | TLS FRP :7000
        v
edge.trinfo.net（Caddy、FRPS、SSH enrollment/tunnel）
        |
        v
客户服务器
```

## 目录

- `/srv/tsuite-deploy/repositories/`：部署仓库；
- `/srv/tsuite-deploy/files/`：通过随机或不可猜测路径提供给客户的部署文件；
- `/srv/tsuite-deploy/logs/`：部署日志；
- `/srv/tsuite-deploy/backups/`：控制面配置备份；
- `/etc/frp/frpc.toml`：FRPC Token，权限 `0640 root:tsuite-deploy`；
- `/etc/tsuite-support-console/`：支持页面 OAuth 配置；
- `/etc/tsuite-support-control/`：broker 的固定 Host Key 与受限 SSH 配置；
- `/var/lib/tsuite-support-operator/`：每会话独立私钥和最小会话索引。
- `/etc/tsuite-support-control/*_ed25519`：固定桥接私钥，仅
  `tsuite-support-operator` 可读，权限为 `0600`。

控制面备份应加密保存 `/etc/tsuite-support-control/`，但必须排除
`/var/lib/tsuite-support-operator/sessions/`；短期会话私钥不能进入长期备份。

## 基础安装

从受信任的现有 FRP Server 取得同版本 `frpc` 和 Token 文件后执行：

```bash
sudo ./install.sh \
  --frpc-binary /secure/path/frpc \
  --frp-token-file /secure/path/frp-token \
  --operator-user adam
```

安装器创建专用 `tsuite-deploy` 服务账户、部署目录、仅回环监听的 Nginx、FRPC systemd 服务，
并验证 `127.0.0.1:8081/_tsuite-control-health`。公网堡垒机使用
[edge-support.caddy](edge-support.caddy) 仅转发 `/support/*`、`/deploy-files/*` 和健康检查路径；
原 `/tsuite-support/*` enrollment 文件仍由堡垒机本地提供。

## 支持管理页面

支持工具已迁至独立仓库 [tsuite-support](https://github.com/transinfosh/tsuite-support)。
源码、客户端、权限规则、测试、CI 和工具说明统一在该仓库维护。本仓库保留部署机的
FRP、Nginx/Caddy 路由与两个兼容安装入口。

`support-release.env` 固定 Release 版本和归档 SHA-256；安装入口下载并校验归档后调用
独立安装器，不保存运行时代码副本。显式升级时同时更新版本与摘要。
离线安装可使用 `sudo env TSUITE_SUPPORT_ARCHIVE=/绝对路径/源码归档 ./安装入口.sh ...`，
归档仍须匹配固定摘要。

控制机依赖和首次安装顺序见[独立安装说明](https://github.com/transinfosh/tsuite-support/blob/main/control/README.md)。
在现有部署机上继续使用本目录入口，它们保留原代理及精确服务维护权限：

```bash
sudo ./prepare-support-access.sh \
  --bastion-host edge.trinfo.net \
  --bastion-host-key-file /secure/path/edge-known-hosts \
  --operator-user adam
```

将输出的两个公钥传到 edge，在独立 `tsuite-support` 的固定版本源码中运行
`bastion/install-console-bridge.sh`，参数见独立安装说明；然后回到部署机执行：

```bash
sudo ./install-support-console.sh \
  --github-client-id YOUR_CLIENT_ID \
  --github-client-secret-file /secure/path/github-client-secret \
  --github-allowed-org transinfosh
```

升级可省略 Secret 文件以沿用现有 OAuth 配置；本地管理员初始化参数由入口原样传递。
控制台默认通过既有 `http://127.0.0.1:18080` 代理访问 GitHub；可显式传入 `--https-proxy` 覆盖。
支持工具安装器直接检查本机 8765，部署集成还应验证 Nginx 的
`http://127.0.0.1:8081/support/` 与公网 `https://edge.trinfo.net/support/` 均返回未登录 401。

本次源码拆分保持 installed commands、HTTP 路径、配置和会话状态不变，不需重启服务。
升级操作和安全边界以[工具运维手册](https://github.com/transinfosh/tsuite-support/blob/main/docs/operations.md)为准；
便携 Linux/Windows 支持端及 AI 操作说明见[工具 README](https://github.com/transinfosh/tsuite-support)。

## 安全约束

- 不把 GitHub Token、OAuth Secret、FRP Token、Vault 密码或客户私钥提交到 Git；
- 不把开发机的 SSH 私钥复制到控制机，为控制机单独生成部署 identity；
- 客户下载目录禁止目录索引，发布文件应使用不可猜测路径并提供 SHA-256；
- 镜像构建继续使用 GitHub Actions，控制机只负责发布编排，避免本机资源耗尽；
- 控制机 SSH 只允许公钥，禁止 root 与密码登录。
