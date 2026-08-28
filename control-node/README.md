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

## GitHub 支持页面

控制机先创建专用 broker、每会话私钥目录、bridge key、edge 会话代理 key、固定 Host Key 和最小
sudoers。Host Key 文件必须通过独立渠道核验，不能直接信任 `ssh-keyscan`：

```bash
sudo ./prepare-support-access.sh \
  --bastion-host edge.trinfo.net \
  --bastion-host-key-file /secure/path/edge-known-hosts \
  --operator-user adam
```

把命令输出的两个公钥复制到 edge，在 edge 的固定版本仓库中执行：

```bash
sudo support-session/bastion/install-console-bridge.sh \
  --bridge-public-key /secure/path/bridge_ed25519.pub \
  --edge-operator-public-key /secure/path/edge_operator_ed25519.pub \
  --operator-user tsuite-operator
```

最后将 OAuth Client Secret 写入仅 root 可读文件，在控制机执行：

```bash
sudo ./install-support-console.sh \
  --github-client-id YOUR_CLIENT_ID \
  --github-client-secret-file /secure/path/github-client-secret \
  --github-allowed-org transinfosh
```

已有控制机原地升级时，可以省略 `--github-client-secret-file`，安装器会以 root 身份沿用现有 OAuth
配置中的 Secret；首次安装仍必须显式提供 Secret 文件。

从旧版固定 operator key 升级时，先确认 edge 上没有 `issued`、`enrolled` 或 `revoking` 会话，再按上述
顺序更新。控制机安装器只有在新 broker 自检通过后，才会删除旧 `/etc/tsuite-support-console/` 中的共享
私钥副本；未结束的旧会话不能自动迁移到每会话独立 key。

OAuth App 的 Homepage URL 为 `https://edge.trinfo.net/support/`，Callback URL 为
`https://edge.trinfo.net/support/auth/github/callback`。页面进程不能运行任意 Shell；它只能使用
限定 sudo 调用 broker 的 create/show/list/close。broker 为每个会话生成独立 operator key，并且只有
运维账号可以通过 broker 调用 ssh/run/force-close；页面进程不能读取 bridge、edge 或会话私钥。
edge 上的 `tsuite-operator` 使用专用受限 Shell：只允许 sshd 已绑定的 bridge/proxy forced-command，
不能进入交互式 Shell，也不能执行任意命令。

安装器会同时验证 forced-command bridge 和 edge forced proxy 通道。代理 key 不能取得 edge Shell，也
不能转发任意回环端口；edge 会根据会话 ID 只代理已接入会话登记的端口。日常命令：

```bash
sudo -n -u tsuite-support-operator tsuite-support-console-action list
sudo -n -u tsuite-support-operator tsuite-support-console-action show SESSION_ID
sudo -n -u tsuite-support-operator tsuite-support-console-action ssh SESSION_ID
sudo -n -u tsuite-support-operator tsuite-support-console-action run SESSION_ID -- sudo tsuite-deploy
sudo -n -u tsuite-support-operator tsuite-support-console-action close SESSION_ID --closed-by adam
sudo -n -u tsuite-support-operator tsuite-support-console-action force-close SESSION_ID \
  --closed-by adam --reason "客户服务器已离线；工单记录了待到期回收的本地残留"
```

普通 `close` 会先确认客户侧清理已经调度，再撤销堡垒机，并记录关闭人。只有客户不可达且已记录残留
风险时，运维人员才能显式使用带 `--reason` 的 `force-close`；Web 页面没有该权限。关闭方式、关闭人和
原因会保留在 edge 会话历史中。

## 安全约束

- 不把 GitHub Token、OAuth Secret、FRP Token、Vault 密码或客户私钥提交到 Git；
- 不把开发机的 SSH 私钥复制到控制机，为控制机单独生成部署 identity；
- 客户下载目录禁止目录索引，发布文件应使用不可猜测路径并提供 SHA-256；
- 镜像构建继续使用 GitHub Actions，控制机只负责发布编排，避免本机资源耗尽；
- 控制机 SSH 只允许公钥，禁止 root 与密码登录。
