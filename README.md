# Frappe Deploy

面向 Ubuntu 单机服务器的交互式 Frappe Docker 部署工具。脚本会自动下载
`frappe_docker`，安装缺失的软件，生成部署配置，并完成站点创建、应用安装和迁移。
本仓库不复制或跟踪 `frappe_docker` 的文件，两者可以独立升级。

## 功能

- 检测并通过 Docker 官方 apt 仓库安装 Docker Engine、Buildx 和 Compose 插件；
- PostgreSQL 可选择容器部署或安装在 Ubuntu 本机；
- 支持任意包含 Frappe 应用的自定义镜像；
- 私有 GHCR 镜像拉取失败时，安全提示输入用户名和只读 Token；
- 在修改系统前确认代理设置，并可同时应用到 APT、Docker daemon 和 Frappe 容器；
- 自动部署 Redis、后端、前端、WebSocket、队列和调度器；
- 新站点自动创建并安装指定应用，已有站点升级前自动备份；
- 重复运行时安装缺失应用、执行 `bench migrate` 并重启服务；
- 重复运行默认保留原数据库密码和 `frappe_docker` commit，只需修改镜像标签即可升级；
- 升级前保存配置快照，失败时输出恢复旧配置的方法；
- 默认仅监听 `127.0.0.1:8080`，避免未配置 HTTPS 时直接暴露公网；
- 支持 `--dry-run`，用于预览系统操作和检查生成的配置。

## 快速使用

不需要克隆 Git 仓库，一条命令即可安装并启动部署：

```bash
curl -fsSL https://raw.githubusercontent.com/transinfosh/frappe_deploy/main/install.sh | sudo bash && sudo frappe-deploy
```

安装器会检查下载结果的 Bash 语法，然后把部署脚本安装到
`/usr/local/sbin/frappe-deploy`。

默认镜像为：

```text
ghcr.io/transinfosh/project_management:0.0.2
```

脚本会逐项询问镜像、应用名、站点名、数据库模式、端口、代理和密码。密码输入
不会回显；直接回车会使用随机生成的强密码。

数据库密码不设置最低长度，`postgres` 这类普通密码也可以使用。为了能够安全写入
Compose 的 `.env` 文件，密码应使用字母、数字以及
`._~!@%^+=-`；输入为空或包含不兼容字符时，脚本会原地提示重新输入，不会退出部署。

检测到已有部署时，脚本会读取 `deployment.state` 和 `.env`：

- 应用镜像默认使用当前已部署版本，输入新标签即执行镜像升级；
- 数据库密码默认保持不变；
- `frappe_docker` 默认固定到上次部署的准确 commit，不会自动跟随 `main`；
- 已有站点不再询问未使用的 Administrator 初始密码。

部署前可先预览：

```bash
frappe-deploy --dry-run
```

`--dry-run` 会把生成结果留在 `/tmp/frappe-deploy-dry-run.*` 中供检查，不会改动
目标部署目录、安装软件或启动容器。

## 更新部署工具

服务器不需要执行 `git pull`。重新下载安装器即可把
`/usr/local/sbin/frappe-deploy` 更新到最新的 `main`：

```bash
curl -fsSL https://raw.githubusercontent.com/transinfosh/frappe_deploy/main/install.sh | sudo bash
```

更新部署工具不会自动升级正在运行的应用。更新完成后再执行：

```bash
sudo frappe-deploy
```

脚本会读取 `/opt/frappe-deploy` 中的现有状态；输入新的应用镜像标签才会执行镜像
升级。如果需要固定部署工具版本，可以把 `FRAPPE_DEPLOY_REF` 设置为仓库中实际存在
的 Tag 或 commit。也可以通过 `FRAPPE_DEPLOY_INSTALL_PATH` 修改安装位置。

## 数据库模式

### PostgreSQL 容器

推荐用于单机部署。数据库数据保存在 Docker volume 中，部署目录中的 `.env`
保存数据库管理密码，文件权限为 `600`。

### Ubuntu 本机 PostgreSQL

脚本安装 Ubuntu 提供的 PostgreSQL，创建独立管理角色，并只允许部署专用 Docker
子网连接。容器通过 `host.docker.internal` 访问宿主机数据库。

## 私有镜像和私有源码

部署脚本只需要拉取已经构建完成的镜像。私有 GHCR 镜像需要 fine-grained Token
或 classic PAT，至少具有 `read:packages` 权限。Token 只传给 `docker login`，
不会写入部署配置。

## 代理

脚本会在任何安装操作之前询问是否启用代理，并显示最终配置供确认。启用后会写入：

- `/etc/apt/apt.conf.d/90-frappe-deploy-proxy`
- `/etc/systemd/system/docker.service.d/frappe-deploy-proxy.conf`
- 部署目录中的 `compose.proxy.yaml`

脚本顶部的 `DEFAULT_HTTP_PROXY`、`DEFAULT_HTTPS_PROXY` 和 `DEFAULT_NO_PROXY`
可作为团队默认值，也可在交互过程中修改。

脚本只管理以上带有 `frappe-deploy` 名称的代理配置；后续选择不使用代理时会移除
这些配置。变更 Docker daemon 代理需要重启 Docker 服务，执行前请确认服务器上
其他容器可以承受这次重启。

## 生产环境建议

- 使用域名作为 Frappe 站点名；
- 保持默认的 `127.0.0.1` 监听，并在前面配置 Nginx、Caddy 或云负载均衡；
- 为反向代理启用 HTTPS；
- 定期把站点备份复制到服务器之外；
- 监控磁盘、PostgreSQL、Redis、队列和调度器；
- 升级镜像前先在测试环境验证；
- Docker 发布端口可能绕过 UFW，公网访问控制应使用云防火墙或
  `DOCKER-USER` iptables 链。

## 文件结构

脚本默认将运行环境写入 `/opt/frappe-deploy`：

```text
/opt/frappe-deploy/
├── .env
├── compose.generated.yaml
├── compose.proxy.yaml
├── deployment.state
└── frappe_docker/
```

`frappe_docker` 会按照交互中选择的分支、标签或提交检出，并在
`deployment.state` 中记录实际提交 SHA。

## 镜像升级与回退

重新运行脚本，把应用镜像从例如 `:0.0.2` 改为 `:0.0.3`，脚本会依次：

1. 备份现有站点及文件；
2. 保存 `.env`、Compose 覆盖文件和部署状态；
3. 拉取并验证新镜像；
4. 启动新容器、安装缺失应用并执行 `bench migrate`；
5. 健康检查通过后记录新镜像版本。

配置快照保存在部署目录的 `rollback/<UTC 时间>/`。如果升级失败，脚本会显示
恢复旧配置的命令。由于数据库迁移不一定支持向后兼容，脚本不会自动恢复数据库；
需要先评估迁移影响，再决定是否使用站点备份恢复。

## 限制

- 当前面向单台 Ubuntu 服务器，不替代 Kubernetes、Swarm 或多节点高可用方案；
- 不自动申请域名或 TLS 证书；
- 自动备份仍保存在站点 volume 内，应另行配置异地备份；
- 数据库从容器迁移到本机或反向迁移不属于自动升级范围。

## tAI 三节点部署工程

`ansible/` 提供内部准生产环境的三节点部署骨架，与上面的单机交互式工具相互独立：

```text
customer_nodes  Frappe + frappe_ext/tbi/tai + tbi-engine + 客户数据库
runtime_nodes   tai-service + Runtime PostgreSQL + 在线 Embedding 调用
control_nodes   Frappe + tai_control + PostgreSQL/pgvector + Redis + Phoenix
```

Frappe、数据库、Redis、tbi-engine、tai-service 和 Phoenix 都以 Docker/Compose 运行；
`cloudflared` 或 `frpc` 由宿主机 Systemd 守护。业务域名不随入口实现改变，因此后续可以把
`ingress_provider` 从 `cloudflare` 改为 `frp`，而不修改 tai/tai-service/tai_control 的外部地址。

### GHCR 镜像发布

三节点部署默认不再在目标服务器构建 Node 资产或 Docker 镜像。应用仓库推送 `v*` Tag 后，
由各仓库的 GitHub Actions 调用本仓库
`.github/workflows/build-images.yml`，通过 Buildx 构建并发布到 GHCR：

| Tag 所在仓库 | 发布镜像 |
| --- | --- |
| `tai` | `ghcr.io/transinfosh/tai-customer:<tag>` |
| `tai_control` | `ghcr.io/transinfosh/tai-control:<tag>` |
| `tai-service` | `ghcr.io/transinfosh/tai-service:<tag>` |
| `tbi-engine` | `ghcr.io/transinfosh/tbi-engine:<tag>` |
| `tai-auth` | `ghcr.io/transinfosh/tai-auth:<tag>` |

工作流使用 `type=gha,mode=max` 保存 BuildKit layer cache。服务器仍使用 inventory 中现有的
Docker daemon 代理拉取 GHCR 镜像；部署时只执行 `docker pull`、迁移和容器重建。

组织需要完成一次性配置：

1. 允许上述私有仓库调用 `frappe_deploy` 的 reusable workflow；
2. 统一使用名为 `APP_SOURCE_TOKEN` 的专用 fine-grained Token，只授予构建涉及的私有源码仓库
   `Contents: read`，不要复用个人管理 Token。GitHub Team 及以上套餐可以把它配置为组织级 Secret，
   并将 Repository access 限定为 `tai`、`tai_control`、`tai-service`、`tbi-engine` 和 `tai-auth`。
   当前 `transinfosh` 为 GitHub Free，组织级 Secret 无法提供给私有仓库，因此需要把同一个值保存到
   五个仓库；可以在本地一次输入后批量设置，无需逐个打开网页：

   ```bash
   read -rsp "APP_SOURCE_TOKEN: " app_source_token_value
   printf '\n'
   for repo in tai tai_control tai-service tbi-engine tai-auth; do
     printf '%s' "$app_source_token_value" |
       gh secret set APP_SOURCE_TOKEN --repo "transinfosh/$repo"
   done
   unset app_source_token_value
   ```
3. 确认 Actions 的 `GITHUB_TOKEN` 具有 `packages: write`，服务器 Vault 中的 GHCR Token 具有
   `read:packages`。如果容器包保持私有，还需在 GHCR 包设置中授予对应仓库 Actions 写入权限；
4. 如果标准 GitHub Runner 的磁盘不足，在仓库变量 `TAI_BUILD_RUNNER` 中填写大磁盘或
   self-hosted runner 标签。

`tai` 与 `tai_control` 是聚合镜像。创建发布 Tag 前，必须先在 `frappe_ext`、`tbi`、`tai`
（控制镜像还包括 `tai_control`）创建同名 Tag；工作流会用这个 Tag 检出所有业务应用，缺少
任一 Tag 会直接失败。共享包固定使用 `tai-chat@v0.2.30` 与 `transinfo-ui@v0.1.3`，升级共享包时
先修改 reusable workflow 的默认输入，再创建新的业务发布 Tag。

镜像构建完成后，把 inventory 的 `deployment_image_tag` 改为同一个 Tag，再执行部署：

```bash
cd ansible
ansible-playbook playbooks/preflight.yml --vault-password-file ../.vault-pass
ansible-playbook playbooks/deploy-all.yml --vault-password-file ../.vault-pass
```

`build-images.yml` 也保留 `workflow_dispatch`，用于重试某一个镜像；正式发布仍应使用不可变 Tag，
不要覆盖已经部署过的镜像标签。

#### 发布与部署演练清单

以下示例使用预发布 Tag `v0.1.0-internal-demo.1`。开始前应确认所有待发布改动已经提交并推送，
尤其是 `tai`、`tbi` 和 `tai-service` 的跨应用接口改动；不要给仍有未提交改动的旧 commit 打 Tag。

1. 开发阶段先把 `frappe_deploy` 的 reusable workflow 推送到 `develop`，再把五个发布仓库各自的
   `publish-image.yml` 推送到 `develop`。调用方固定引用 `frappe_deploy@develop`，因此这一步必须
   先完成；正式发布前再把 reusable workflow 改为固定 commit 或正式 Tag。
2. 配置并核验五个发布仓库都能读取统一的 `APP_SOURCE_TOKEN`，同时检查 GHCR 包权限和服务器
   Vault 中的 `vault_ghcr_username`、`vault_ghcr_token`。服务器拉取 Token 应单独创建并只授予
   `read:packages`，不要与源码读取 Token 共用。可以先手动运行一个发布仓库的
   `Publish GHCR image` workflow，使用临时演练标签验证权限；手动运行不会代替正式 Tag 发布。
3. 在 `frappe_ext`、`tbi`、`tai` 和 `tai_control` 的目标 commit 上创建完全相同的 Tag。
   先推送依赖仓库 `frappe_ext`、`tbi` 的 Tag，确认远端可见后，再推送 `tai`、`tai_control`
   的 Tag 触发两个聚合镜像，避免工作流启动时找不到依赖 Tag。
4. 在 `tai-service`、`tbi-engine` 和 `tai-auth` 的目标 commit 上创建并推送同名 Tag，触发其余
   三个镜像。五个仓库的 `Publish GHCR image` workflow 都成功后，再进入部署阶段。
5. 确认 GHCR 中存在以下五个不可变镜像，并记录构建对应的 commit：

   ```text
   ghcr.io/transinfosh/tai-customer:v0.1.0-internal-demo.1
   ghcr.io/transinfosh/tai-control:v0.1.0-internal-demo.1
   ghcr.io/transinfosh/tai-service:v0.1.0-internal-demo.1
   ghcr.io/transinfosh/tbi-engine:v0.1.0-internal-demo.1
   ghcr.io/transinfosh/tai-auth:v0.1.0-internal-demo.1
   ```

6. 把 `inventories/internal-demo/group_vars/all.yml` 的 `deployment_image_tag` 更新为该 Tag，先执行
   `preflight.yml`，通过后执行 `deploy-all.yml` 和 `verify.yml`：

   ```bash
   cd ansible
   ansible-playbook playbooks/preflight.yml --vault-password-file ../.vault-pass
   ansible-playbook playbooks/deploy-all.yml --vault-password-file ../.vault-pass
   ansible-playbook playbooks/verify.yml --vault-password-file ../.vault-pass
   ```

7. 验证失败时停止继续发布，不覆盖原 Tag。修复代码后递增预发布序号并重新构建；需要回退时，
   把 `deployment_image_tag` 改回上一组已验证镜像，再重新执行部署。数据库迁移是否可逆仍需单独评估。

内部演示环境通过阿里云百炼在线 `text-embedding-v4` 为 tai-service 生成 1024 维向量，向量仍
保存在控制节点的 pgvector。在线 Endpoint、模型和回填批次由 inventory 配置，API Key 只保存在
Ansible Vault，并以只读 Secret 文件挂载到 tai-service；运行节点不再部署本地 Embedding 模型。

运行节点到控制面和 Phoenix 的服务间调用使用局域网地址，不经过 Cloudflare Tunnel；JWT 的
`issuer` 仍保持公网 HTTPS 域名。容器通过 `extra_hosts` 把控制面域名解析到控制节点，并保留
正确的 Frappe `Host`，避免同一局域网内的请求绕行公网代理。正式环境应把这组内部 HTTP 地址
替换为私网 TLS 或服务网格地址。
控制面 Frappe 和 Phoenix 仅额外绑定控制节点指定的局域网地址，不使用 `0.0.0.0`；公网访问
仍由 Cloudflare Tunnel 提供。
部署时还会通过只读 Secret 文件幂等同步控制面的 Runtime Store HMAC 密钥，确保控制面与
tai-service 使用同一个 Vault 值；密钥不会出现在命令参数或任务日志中。
控制站点创建后，部署角色会以数据库管理员身份启用 `vector` 扩展，再由应用身份初始化派生
向量索引，避免仅使用 pgvector 镜像却未对站点数据库启用扩展。

### 当前版本策略

内部演示阶段使用：

```yaml
release_lock_state: unlocked-internal-demo
allow_unlocked_revisions: true
```

这表示内部演示暂时允许使用 Tag，而不强制锁定镜像 digest。默认的 `registry` 模式直接拉取
同一个 `deployment_image_tag` 对应的五个 GHCR 镜像；`local_bundle` 仅作为故障恢复路径，启用时
才需要运行 `tools/create-source-bundle.sh` 生成带 SHA256 的统一源码快照。
`production` inventory 会拒绝 `unlocked` 状态。

正式 Release 时只需更新 `ansible/versions.yml` 和 inventory 中的镜像引用，无需修改角色。

### 前置条件

- 三台 Ubuntu 24.04 x86_64 虚拟机，SSH 用户具有免交互 sudo 权限；
- 控制机安装 Ansible Core；
- 准备两个包含应用代码和前端资产的 Frappe 镜像：
  - 客户镜像：`frappe + frappe_ext + tbi + tai`；
  - 控制镜像：`frappe + frappe_ext + tbi + tai + tai_control`；
- 在 Cloudflare Zero Trust 创建三条 Tunnel，并把公网 hostname 分别指向本机服务；
- 准备业务模型 Key、阿里云百炼 Embedding Key 及各类数据库、服务 Token。

所有参与聚合构建的业务应用必须先推送同名发布 Tag。内部演示可按 Tag 部署；正式发布还应在
`ansible/versions.yml` 中记录构建后的镜像 digest。

### 初始化

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
cp inventories/internal-demo/hosts.example.yml inventories/internal-demo/hosts.yml
cp inventories/internal-demo/vault.example.yml inventories/internal-demo/vault.yml
cp inventories/internal-demo/control_private.example.yml inventories/internal-demo/control_private.yml
ansible-vault encrypt inventories/internal-demo/vault.yml
ansible-vault encrypt inventories/internal-demo/control_private.yml
```

然后修改主机地址、域名、镜像和 Vault Secret，执行：

```bash
ansible-playbook playbooks/preflight.yml --ask-vault-pass
ansible-playbook playbooks/deploy-all.yml --ask-vault-pass
```

内部演示 inventory 会从 Ansible Vault 的 Client ID/Secret 幂等初始化 `internal-demo` 租户与
客户端凭据。凭据仅通过容器内只读 Secret 文件进入控制面，数据库只保存 Secret 哈希。客户节点
部署会把 Client ID 写入站点配置，并把 Client Secret 作为只读文件挂载；Secret 不会写入
`site_config.json`。正式环境仍建议使用控制面生成一次性 Secret，再导入正式 Secret Manager。

### 入口切换

Cloudflare 阶段：

```yaml
ingress_provider: cloudflare
```

以后准备好公网 FRP 服务器后修改为：

```yaml
ingress_provider: frp
frp_server_addr: frp.example.net
```

FRP 模式需要在 inventory 中增加一台 `relay_nodes` 公网中转机。部署会在该机器上安装：

- `frps`：仅将 HTTP 虚拟主机端口绑定至 `127.0.0.1`，外部不能绕过 HTTPS；
- Caddy：监听公网 `80/443`，自动申请和续期证书，再将请求按 `Host` 转给 `frps`；
- `tai-frps.service`：使用 token 认证，并强制 `frpc` 通过 TLS 连接。

在 `group_vars/all.yml` 中补齐中转配置，并在 Vault 中设置一个至少 32 字符的随机 token：

```yaml
ingress_provider: frp
frp_server_addr: frp.example.net
frp_caddy_email: ops@example.net
frp_public_hostnames:
  - tai.example.net
  - api.example.net
  - control.example.net
  - phoenix.example.net
```

```yaml
vault_frp_auth_token: replace-with-a-long-random-token
```

`frp_server_addr` 必须能够从 customer、runtime、control 三个节点访问。所有
`frp_public_hostnames` 的 A/AAAA 记录必须指向 `relay_nodes` 的公网地址，并在云防火墙与
本机防火墙中放行 `80/tcp`、`443/tcp` 和 `7000/tcp`。运行 `deploy-all.yml` 时会先部署中转机，
再启动各节点的 `frpc`。

先用临时子域名验证 FRP 的 HTTPS、WebSocket、真实客户端 IP 和上传限制，再切换原业务域名
DNS，可以把停机窗口控制在 DNS 切换时间内。
