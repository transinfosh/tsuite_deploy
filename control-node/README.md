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
- `/etc/tsuite-connect-console/`：支持页面 OAuth 配置；
- `/etc/tsuite-connect-control/`：broker 的固定 Host Key 与受限 SSH 配置；
- `/var/lib/tsuite-connect-operator/`：每会话独立私钥和最小会话索引。
- `/etc/tsuite-connect-control/*_ed25519`：固定桥接私钥，仅
  `tsuite-connect-operator` 可读，权限为 `0600`。

控制面备份应加密保存 `/etc/tsuite-connect-control/`，但必须排除
`/var/lib/tsuite-connect-operator/sessions/`；短期会话私钥不能进入长期备份。

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
[edge-support.caddy](edge-support.caddy) 转发 `/connect/*`、兼容 `/support/*`、`/deploy-files/*` 和健康检查路径；
原 `/tsuite-support/*` enrollment 文件仍由堡垒机本地提供。

## 使用现有支持服务

业务部署统一使用已部署在 `192.168.2.52` 的 TSuite Connect，管理入口为
[支持管理页面](https://edge.trinfo.net/connect/)。登录后创建会话，将客户命令交给客户，
在支持机执行页面生成的支持端命令，连接后进行业务部署；完成后关闭会话。
具体操作见 [AI Agent 部署运行手册](../docs/AI_AGENT_DEPLOYMENT_RUNBOOK.md)。

`tsuite_deploy` 只消费现有支持服务，不下载支持工具源码、不锁定其版本，也不负责安装或升级支持服务。
支持服务独立维护，更新后业务部署使用服务当前生成的接入命令即可。
支持服务安装、升级、备份和权限维护统一由
[tsuite-support](https://github.com/transinfosh/tsuite-connect) 仓库负责。

本仓库仍维护现有控制机的 FRP、Nginx/Caddy 混合路由，因为它们同时承载部署文件与支持页面。
安装新的业务部署节点无需部署支持服务；维护上述共享路由时应确保现有 `/connect/`、`/support/*` 与
`/tsuite-support/` 路由可用。

## 安全约束

- 不把 GitHub Token、OAuth Secret、FRP Token、Vault 密码或客户私钥提交到 Git；
- 不把开发机的 SSH 私钥复制到控制机，为控制机单独生成部署 identity；
- 客户下载目录禁止目录索引，发布文件应使用不可猜测路径并提供 SHA-256；
- 镜像构建继续使用 GitHub Actions，控制机只负责发布编排，避免本机资源耗尽；
- 控制机 SSH 只允许公钥，禁止 root 与密码登录。

`/support/` 与 `/connect/` 均直接代理至控制台，不做入口地址跳转。
既有 operator-client 下载、授权 POST 和 GitHub OAuth 回调继续兼容。
