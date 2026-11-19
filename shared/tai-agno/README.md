# 部署共享 Agno 服务

一个 Frappe Compose 项目使用一个独立的 Agno 容器和一个服务进程。各站点从现有聊天页面发出同源请求，Frappe frontend 沿用站点匹配规则，将 `/tai-agno/` 转给内部 `/sites/<site>/`。Frappe 服务端调用直接使用这个内部入口。未配置的站点返回 404，请求中的 Frappe 站点 Header 不能覆盖入口选定的站点。

Agno 按站点选择应用、签名校验、PG 连接和模型配置。Frappe 用当前站点的密钥签发用户 JWT，Agno 校验签名、签发站点、受众、有效期及权限。业务回调携带原用户身份和专用回调 scope，Frappe 重新校验用户和业务权限。前端继续使用原有路径和 API。

会话、运行、记忆、轨迹和用量存在一个 PG 数据库的独立 schema 中，每站点一个 DB 账号；Frappe 的业务数据库和业务快照继续单独维护。容器重启会影响该部署所有站点的活动任务。当前依赖进程内 SSE 和会话接纳锁，保持单进程、单副本。

## 镜像

`transinfosh/tai-agno` 的同名 Git Tag `v<version>` 对应服务 `pyproject.toml` 的版本。使用 `tsuite_deploy` 的 **Build one GHCR image** 工作流选择 `tai-agno`，并复用现有 GHCR 到 Registry 的同步。按[镜像来源契约](../contracts/README.md#镜像来源)验证已发布镜像的摘要，部署时使用固定版本或摘要。Frappe 镜像需包含 tAI Agno bridge 和使用该 bridge 的聊天前端。

## PostgreSQL 与站点配置

使用 PG 16 或更新版本。首次由数据库管理员创建 Agno 数据库。按站点分别创建运行账号和 schema，运行账号只拥有自己的 schema。下面示例在 `psql` 中执行，站点密码通过 `\password` 交互设置。

```sql
CREATE DATABASE tai_agno;
REVOKE ALL ON DATABASE tai_agno FROM PUBLIC;
\connect tai_agno
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE ROLE agno_a LOGIN;
\password agno_a
GRANT CONNECT ON DATABASE tai_agno TO agno_a;
CREATE SCHEMA agno_a AUTHORIZATION agno_a;
COMMENT ON SCHEMA agno_a IS 'tai-agno:a.example.com';
```

为其他启用站点重复账号、授权、schema 和注释部分。站点名使用 Frappe 的站点目录名。Agno 启动时核验 schema 绑定、账号所有权以及登录后可以继承或切换取得的角色权限。能够读写其他站点 schema 或获得数据库管理特权的运行账号会被拒绝。Agno 使用原生 `PostgresDb` 在选中的 schema 初始化表，数据库管理员保留独立的备份和维护权限。

从 [sites.example.json](sites.example.json) 准备生产 `sites.json`，替换所有示例值。每站点配置实际的 `FRAPPE_URL`、公开地址、默认工作区、模型、数据库账号和签名密钥。`FRAPPE_URL=http://backend:8000` 适用于默认 Compose 网络；Agno 回调将 Frappe 站点名作为 Host。DSN 内密码按 URL 编码，已有原生 UI 客户端依赖 `TAI_AGNO_DB_ID` 时维持其值。已有站点保留原密钥，以便验证历史材料。

密钥文件仅由运维和容器账号读取。示例使用宿主 root 所有、GID `10001`、模式 `0440` 的 `sites.json`，以只读方式挂载给镜像内 UID/GID `10001`。使用用户命名空间时按实际映射调整权限。配置目录、数据库凭据、模型密钥和历史导出均纳入受限备份，避免写入源码、Compose 插值、命令参数或日志。

## 启动和接入

从 [compose.env.example](compose.env.example) 准备部署环境文件。`TAI_AGNO_FRAPPE_NETWORK` 指向对应 Frappe 项目已存在的网络。Agno 使用内部别名 `tai-agno:7777`，Compose 无宿主机端口；每个 Frappe 网络只运行一份此服务。

```bash
agno_compose=(docker compose -p frappe-tai-agno --env-file /opt/tsuite-deploy/tai-agno/compose.env -f shared/tai-agno/compose.yaml)
set -o pipefail
"${agno_compose[@]}" config --images | python3 tools/check-registry-images.py
"${agno_compose[@]}" up -d --wait
```

接入 Frappe frontend 时保留该项目已有的查询路由，并让反代空闲超时覆盖 SSE 保活间隔。

- 多节点 Ansible 部署设置 `frappe_enable_tai_agno_proxy: true`。`frappe_stack` 在同一模板内生成 TBI 查询路由和 Agno 入口，由既有 frontend 部署流程加载。
- 单机或现场自有 Compose 使用 [tai_agno_nginx.py](../../multi-node/ansible/roles/frappe_stack/files/tai_agno_nginx.py) 从目标镜像的 Nginx 模板生成带 Agno 入口的模板。现有项目含自定义路由或独立 TBI 查询时，以合并后的有效模板为输入。将 [frontend 覆盖示例](compose.frappe.yaml.example) 加在现有 Compose 文件之后。单机安装器自动加载部署根目录中的 `compose.tai-agno.yaml`。升级 Frappe 镜像时用目标版本的模板重新生成并检查现有路由。

逐站点写入原本的 `site_config.json`。`tai_agno_url` 为 `/tai-agno`，`tai_agno_internal_url` 为 `http://tai-agno:7777/sites/<站点名>`，`tai_agno_signing_key` 与对应 `sites.json` 中的密钥一致。只在各站点配置其自己的密钥。根据现场的部署方式刷新配置和 frontend，在入口开放前运行 `nginx -t`，然后验证每个启用站点。开发用 `uvicorn tai_agno.server:app` 的单站点入口继续使用自己的开发环境变量。

## 已有记录迁移与回退

停止接纳，等待当前 AI 任务退出，并分别备份 Frappe 站点和 Agno PG。按实际历史来源选择迁移路径。

- 旧 Frappe Runtime 用 `bench --site <站点> execute tai.agno_migration.export_records --args '["<私有导出路径>"]'` 导出。把导出及校验文件放到受限迁移目录。运行下面的预演，核对站点、记录数和冲突后追加 `--apply`。已迁记录可校验重跑。
- 旧 Agno SQLite 在源端用 `snapshot-sqlite` 从原站点配置生成一致快照和签名清单。迁移端把这两个文件挂载到 `/migration`，执行 `--site <站点> -- python /app/tools/migrate_sqlite.py /migration/backup.db`。导入前核对源站点、摘要和目标 schema。
- 旧 Agno PostgreSQL 在源端用 `snapshot-postgres` 从原站点的连接生成带签名清单的 schema 备份。源端需要兼容版本的 `pg_dump`。在恢复前先用下方命令验证签名、站点和摘要，再在隔离的临时 PG 库恢复该已验证的备份。需要调整 schema 名时只在临时库操作，随后将数据事务恢复到同版本目标 schema，核对行数、权限、会话和证据。恢复到已有数据的 schema 前先检查冲突。

在 Agno 服务源码目录使用原站点配置生成 SQLite 或 PostgreSQL 备份，选择与来源一致的命令。备份及其相邻的 `*.manifest.json` 保存在同一个受限目录，目标使用原站点的签名密钥。只有未签名的历史备份时，先在隔离源环境确认其所属站点并重新生成签名备份；来源不明确的文件不能导入。

```bash
uv run --env-file /private/source.env python -m tai_agno.backup_manifest snapshot-sqlite /private/backup.db
# PostgreSQL 来源改用以下命令
uv run --env-file /private/source.env python -m tai_agno.backup_manifest snapshot-postgres /private/backup.dump
```

```bash
"${agno_compose[@]}" run --rm --no-deps \
  -v /opt/tsuite-deploy/tai-agno/import-a:/migration:ro \
  tai-agno --site a.example.com -- python -m tai_agno.backup_manifest verify-postgres /migration/backup.dump
```

旧 Frappe Runtime 导入预演命令如下。

```bash
"${agno_compose[@]}" run --rm --no-deps \
  -v /opt/tsuite-deploy/tai-agno/import-a:/migration:ro \
  tai-agno --site a.example.com -- python /app/tools/migrate_frappe.py /migration/source.jsonl.gz
```

验收时逐站点检查容器健康、登录后发起问题、SSE 续接、取消任务、历史显示和管理员审计。同名用户的会话及审计只能看到本 schema 的数据，A 站令牌访问 B 站应拒绝。升级后继续使用原 project、网络、签名密钥和 schema。回退先停止新接纳，按旧版本的 schema 兼容性恢复服务配置并保留新库和旧库备份。退回旧 Runtime 要评估切换后产生的 Agno 会话，不能用旧备份覆盖。
