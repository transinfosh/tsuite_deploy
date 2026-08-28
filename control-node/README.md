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
- `/etc/tsuite-support-console/`：支持页面 OAuth 与受限 SSH 桥配置。

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

先安装堡垒机受限桥接 key，再将 OAuth Client Secret 写入仅 root 可读文件，执行：

```bash
sudo ./install-support-console.sh \
  --github-client-id YOUR_CLIENT_ID \
  --github-client-secret-file /secure/path/github-client-secret \
  --github-allowed-org transinfosh
```

OAuth App 的 Homepage URL 为 `https://edge.trinfo.net/support/`，Callback URL 为
`https://edge.trinfo.net/support/auth/github/callback`。页面进程不能运行任意 Shell；它只能使用
固定 Host Key、固定 SSH identity 和 forced command 调用堡垒机的 create/show/list/close 动作。

## 安全约束

- 不把 GitHub Token、OAuth Secret、FRP Token、Vault 密码或客户私钥提交到 Git；
- 不把开发机的 SSH 私钥复制到控制机，为控制机单独生成部署 identity；
- 客户下载目录禁止目录索引，发布文件应使用不可猜测路径并提供 SHA-256；
- 镜像构建继续使用 GitHub Actions，控制机只负责发布编排，避免本机资源耗尽；
- 控制机 SSH 只允许公钥，禁止 root 与密码登录。
