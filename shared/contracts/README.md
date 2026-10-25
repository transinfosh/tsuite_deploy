# 共享部署契约

本目录定义单机和多节点部署共同遵循的运维契约，而不是共享执行脚本。

- 发布：镜像必须使用可追溯的版本；正式发布使用不可变 Tag 或 digest，并记录来源提交。
- 备份：迁移前必须生成数据库、站点配置和公私有文件备份；备份保留在站点之外才具备灾难恢复价值。
- 健康检查：完成迁移后必须验证目标服务可用，失败时停止继续发布并保留诊断信息。

单机 Compose 与多节点 Ansible 是两个 Adapter：它们分别实现上述契约，但网络、密钥、数据库和回退实现各自独立。

## 镜像来源

新部署、升级、回退与 AI 直接维护 Compose 均默认从 `registry.trinfo.net` 拉取。
将 `ghcr.io/transinfosh/<镜像>:<版本>` 改为同路径的自建地址；Docker Hub 官方依赖使用
`registry.trinfo.net/library/<镜像>:<版本>`，其他上游保留 namespace，例如 `pgvector/pgvector`。
使用固定版本或 digest，换源保持原 tag/digest，不能把不存在的旧版本换成 `latest`。

部署前确认以下条件：

1. 用客户只读账号登录自建 Registry；密码由受限文件或 Vault 注入，不放在命令参数、Git 或 Compose 中；
2. GitHub 构建与后置同步均成功，目标 manifest 可读取，复制版本与源 digest 相同；
3. 展开所有 Compose、环境变量与覆盖文件，检查本次全部镜像；缺少版本或发现其他仓库时先停止；
4. 自建仓库域名加入 Docker daemon 和命令环境的 `NO_PROXY`，其余源码/包下载按需保留现有代理。

对现场 Compose 可执行（命令中的 Compose 参数沿用现场）：

```bash
set -o pipefail
sudo docker compose -f /现场/compose.yml config --images |
  sudo python3 tools/check-registry-images.py
```

检查器只读取 manifest，不启动容器。多节点 `registry_images` 自动检查本次角色所需镜像。
单机脚本生成数据库与 Redis 的自建地址覆盖，继续维护全部 Frappe 应用服务的统一镜像。
Registry 不是自动回源缓存；缺失版本由运维补同步，不自动切换 GHCR。确需其他仓库时由操作者
显式修改仓库和完整镜像引用，并记录原因。

已有站点沿用现场 Compose 也能遵守此契约，不强制接管。AI 应先按运行手册盘点，再选择单机、
多节点或保留现场 Compose 的操作方式，并记录镜像、源码、备份、健康检查与回退点。
