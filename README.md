# TSUIE Deploy

TSUIE 平台部署仓库；其中包含面向 Ubuntu 单机服务器的交互式 Frappe Docker 部署工具。脚本会自动下载
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
curl -fsSL https://raw.githubusercontent.com/transinfosh/tsuie_deploy/main/install.sh | sudo bash && sudo frappe-deploy
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
curl -fsSL https://raw.githubusercontent.com/transinfosh/tsuie_deploy/main/install.sh | sudo bash
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
