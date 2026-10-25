# 多节点部署

## 镜像来源

默认使用 `registry.trinfo.net`，应用与运行依赖共用只读登录。将 `vault_registry_username`、
`vault_registry_password` 写入目标加密 Vault；不要将 CI 发布密码用于部署。每次部署在备份、
迁移和重建前校验所需镜像存在。完整约定见[镜像来源契约](../shared/contracts/README.md#镜像来源)。
Registry 加入 `NO_PROXY`；Git、apt 等其他下载仍可按需使用原代理。仅换源时保留原版本与现场拓扑。

## 发布前数据库备份

`customer.yml`、`control.yml` 和 `runtime.yml` 在修改服务前都会执行强制数据库备份。
已有数据库备份失败、文件为空或 SHA-256 校验失败时，发布立即中止；首次安装尚无内置数据库
容器时会记录 `not_installed` 后继续。

备份默认保存在数据库所在主机的
`/opt/tsuite-deploy/backups/releases/<UTC 时间>/`。每个组件同时写入一份 JSON 清单，记录
目标环境、部署节点、数据库、备份文件、校验值、发布前运行镜像及本次目标版本；全局历史追加到
`/opt/tsuite-deploy/backups/releases/history.jsonl`，用于定位可回退的数据库与镜像组合。

`ansible/` 是多节点部署 Adapter，按 Control、Runtime、Customer 角色编排，并可配置独立 PostgreSQL 与入口节点。

从旧目录布局升级时，Git 不会自动移动未跟踪的 Inventory、Vault 或源码归档。先复制到新位置，确认可用后再自行处理旧副本；命令使用 `-n`，不会覆盖已有文件：

```bash
mkdir -p multi-node/ansible/inventories/internal-demo multi-node/ansible/artifacts
cp -an ansible/inventories/internal-demo/{hosts.yml,vault.yml,control_private.yml} \
  multi-node/ansible/inventories/internal-demo/ 2>/dev/null || true
cp -an ansible/artifacts/* multi-node/ansible/artifacts/ 2>/dev/null || true
```

从该目录运行 Ansible，以使用本目录的 `ansible.cfg` 和相对路径：

```bash
cd multi-node/ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/preflight.yml --ask-vault-pass
ansible-playbook playbooks/deploy-all.yml --ask-vault-pass
```

本地源码快照仅用于 `local_bundle` 故障恢复模式：

```bash
multi-node/tools/create-source-bundle.sh
```

## TBI 独立查询服务与部署检查

安装 `tbi` 的 Frappe Stack 必须配套独立 `tbi-query` 服务。普通后端处理元数据和 Engine
网关桥接，图表／仪表板等长查询走独立 ASGI 服务；两者共用原站点、Secret 文件和同一不可变
应用镜像。查询端口仅在 Compose 网络内开放，不发布到宿主机。

`frappe_stack` 从目标镜像读取查询入口清单和原始 Nginx 模板，生成精确路由；不手工复制接口
列表，不把 `/api/` 整段转发给查询服务，也不把 Engine 桥接接口转入查询服务。Frontend 等待查询
容器健康后启动。配置生成保留原 Nginx 的 HTTPS 转发信息、静态资源和 WebSocket 路由。

上线前检查镜像的查询模块及依赖、Compose 中的服务／镜像／站点与 Secret 挂载、健康检查、
前端依赖和完整查询路由；缺项立即中止。部署后检查实际运行镜像、容器健康、Nginx 生效路由和
容器间可达性。`playbooks/verify.yml` 额外检查 Engine 回调仍指向普通后端。

已有部署可单独执行只读检查：

```bash
sudo python3 /opt/tsuite-deploy/frappe-customer/tbi_query_config.py verify \
  --root /opt/tsuite-deploy/frappe-customer --stack customer --site tai.trinfo.net \
  --engine-container tai-tbi-engine-service-1
```

兼容影响：本部署工具要求带 `tbi.query_service` 的应用镜像（TAI 0.0.49 / TBI 0.0.17 已验证）；
不改变业务 API、数据库 schema 或权限。旧镜像缺少该能力会在启动前拒绝，不能通过关闭检查上线。
回退旧业务版本需使用与该版本相配套的部署工具，并同时评估 Engine 的兼容性。

2026-10-17，2.183 因查询和桥接共用普通 Frappe 线程出现随机 `gateway_bridge_unavailable`。
在不更换应用镜像、不迁移数据库的情况下补齐服务和 25 条精确路由；7 张图的仪表板连续 3 次加载
共 21 个结果全部成功。部署前配置备份与修复过程保存在控制机
`/srv/tsuite-deploy/files/releases/tai-query-20261017/`。

2026-10-22：查询路由检查同时接受镜像声明的精确路径和唯一受限的 `^/tbi/shared/chart/[^/\r\n]+/?$` 共享图表规则。配置及实际 Nginx 必须完整匹配两类路由；宽泛 API 前缀、未知正则、未锚定规则和重复项仍拒绝。TAI 0.0.58 / TBI 0.0.19 需要此版本检查器。

实际验证还通过 frontend 请求匿名仪表板方法，要求返回 Frappe 的 401/403；这可发现容器重启后 Nginx 仍缓存旧查询 IP、但 DNS/healthz/路由文本均正常的情况。重启 backend 或 tbi-query 后，应待服务健康再重新加载 frontend 上游，并复验真实 HTTP 请求。

升级维护窗口内，验证器读取有效站点维护开关；只有明确开启维护时接受 Frappe 的 503。恢复服务后仍要求 401/403，502 始终失败，不能为通过检查而关闭维护。
