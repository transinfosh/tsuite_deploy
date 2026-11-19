# 2026-11-19 2.183 测试站启用 Agno

[test.tai.trinfo.net](https://test.tai.trinfo.net/desk/tai/tai-chat/AHRD) 已切换至独立 Agno 服务。Frappe 聊天和管理员会话审计仍从原 Desk 入口打开。现场使用 `frappe-test` 和 `frappe-test-agno` 两个 Compose 项目，共用测试 Docker 网络。Agno 只有一个服务实例，监听内部网络上的 `tai-agno:7777`。

2.185 上的 `tai_test_agno` 保存会话、运行、记忆、轨迹和用量。测试站用独立的 `agno_test` schema、数据库账号和站点签名密钥。Frappe 的业务数据库仍是 `tai_test`。入口按 Frappe 站点配置转发，Agno 校验当前站点签发的短期令牌，Frappe 在业务回调时校验身份及业务权限。运行模型为既有官方 DeepSeek `deepseek-v4-flash`，默认关闭思考。

2.183 的 `tai.trinfo.net`（`frappe-customer`）及正式 Engine 共 12 个容器，升级前后的 ID、镜像和启动时间一致。

## 发布镜像

| 组件 | 固定标签 | 源码提交 |
|---|---|---|
| tAI Customer | `v0.0.71` | `f6f538d88cfd5ceb50396e31f02a5450ba5200c1` |
| tai-agno | `v0.1.0` | `38adc10a3a86c32662c10609a72258b3824e235f` |
| tai-chat | `v0.2.48` | `f03fdf1d1969c2507c33242cdbae4412f3d93e46` |
| tBI | `v0.0.32` | `e867a26610e77eadbaa2de71af16f47b34571135` |

Agno 服务源码在[独立私有仓库](https://github.com/transinfosh/tai-agno)，tAI 仓库包含 Frappe 接入。测试站使用以下固定镜像，Engine 和 Redis 继续运行原有版本。

- `registry.trinfo.net/transinfosh/tai-customer@sha256:b11761eece6cf92d698ef4ad2029a981fe058dcdae56d67149b63569d1b7b2c7`
- `registry.trinfo.net/transinfosh/tai-agno@sha256:3096cf91771f1ab451382af4a6dc15c2d05d990dbfc5887ec7dfd60e84472beb`

[tAI 镜像流水线](https://github.com/transinfosh/tai/actions/runs/44439123248)通过 ODBC、前端编译及全新站点安装检查，[Agno 流水线](https://github.com/transinfosh/tai-agno/actions/runs/44439438715)构建成功。因常规 Registry 同步超时，从 Actions 导出[同摘要 tAI 镜像](https://github.com/transinfosh/tai/actions/runs/44442158263)和[同摘要 Agno 镜像](https://github.com/transinfosh/tai-agno/actions/runs/44442103605)，核对归档并在 2.52 补同步。两个镜像分别验证 27 和 11 个 blob，内网 Registry 与 GHCR 根 manifest 摘要一致。重跑常规镜像同步后，两条流水线均成功。2.183 使用既有只读账号拉取固定镜像。

## 备份和切换

停写并排空旧运行。数据库备份在隔离 PostgreSQL 库完整恢复，测试站文件和旧配置均异机校验。离线迁移预演和正式导入均得出 105 个会话、236 次运行、466 条消息和 109 批技术归档，无孤立运行。旧 Runtime worker 已停用，旧 Compose、站点配置和备份保留作为回退点。Frappe migrate 成功，维护模式已关闭。

| 切换前备份 | SHA-256 |
|---|---|
| `tai_test.dump` | `e2d4096b8b23d2c67e924ca9d6cd0b5532eda4657c83aac95185d65d70282bcd` |
| `site-files.tar.gz` | `96b6657b810ade96a9c69c9d15a1c6a1ec9941a96bd82e3a6921c695484ef24d` |
| `configuration-backup.tar.gz` | `c7b94c83a68e2fc2eb48c2b924b7ebc46f23f832ae930b906d62ace57e670a91` |
| 历史迁移归档 `legacy.jsonl.gz` | `bc8c2109a3f96057c01d10f1e12c3f740f8fb0bf774b0f6ebd6dd286287c8863` |

切换后的 Agno schema 和运行配置也已备份至控制机，备份对象清单和归档均可读取。

| 切换后备份 | SHA-256 |
|---|---|
| `tai_test_agno.dump` | `a8b648cd8871179894ca93f6ef46f95c221654c8cb3eb5972ee86fe11713248a` |
| `agno-configuration.tar.gz` | `3fe189bbe59b86aa5dcaf06ffbd8642a7c0020e567f201cb207e2e97ee49525b` |

受限备份在 `192.168.2.52:/srv/tsuite-deploy/backups/tai-test-agno-20261119/`。验收证据在同一控制机的 `/srv/tsuite-deploy/release-work/tai-test-agno-20261119/`。现场证据和旧镜像配置在 `192.168.2.183:/opt/tsuite-deploy/frappe-test/upgrades/20261119-agno/`。回退前暂停新问答及写入，评估旧 schema 的兼容性，保存切换后的 Agno 记录，再按旧 Compose 和受限备份恢复。

## 验收

- Frappe frontend 和 Agno 健康，26 条 TBI 查询路由核对通过。short、long 和 default worker 正在订阅，测试调度器和邮件继续暂停。
- 公网 HTTPS 登录和前端资源通过。隔离 Chromium 中聊天页成功加载 Agno 会话列表，管理员会话审计页成功加载，未捕获 JavaScript 异常。匿名请求 Agno 返回 401。
- 从管理员审计打开迁移会话。通过现有 Frappe 登录发起真实计量单位查询，核对查询工具成功、回答与结构化图表内容、SSE 断开后的续接及终态。管理员可读取模型用量和工具输入输出。首次验收耗时 27.65 秒，记录 12 次模型调用，总计 391,506 token，这是单次验收数据。
- 独立运行的取消操作到达 `cancelled` 状态，两次验收会话均已归档。
- 现有 BI 图表通过独立查询服务返回数据。AHRD 七图看板的四路并发查询全部成功。
- 两站使用同一个 Run ID 的 SSE 回放和取消隔离通过自动化回归，2.183 现场只启用了一个测试站点。本次未做并发压测。操作使用现有控制机 SSH，没有建立临时支持会话。
