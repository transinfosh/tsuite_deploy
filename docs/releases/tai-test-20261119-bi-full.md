# 2026-11-19 2.183 测试站升级 tBI 工作区初始化与交互配置

[test.tai.trinfo.net](https://test.tai.trinfo.net/desk/tai/tai-chat/AHRD) 已升级至 tAI 0.0.73、tBI 0.0.34、tai-chat 0.2.49，独立的 Agno 容器继续运行 0.1.1。正式站容器 ID、镜像和启动时间逐一核对一致。

| 组件 | 发布标签 | 提交 |
| --- | --- | --- |
| tAI | `v0.0.73` | `cea66bd9cea5dafef2935727d93120fb04d94634` |
| tBI | `v0.0.34` | `a3af9df8bb116b9425a09c744e1b4f3bf4f010f7` |
| tai-chat | `v0.2.49` | `3efe55c2797171a455725c44c7f8e839f2eebd3c` |
| tai-agno | `v0.1.1` | `f2c8b84d9942d6efc11be5eadb60aa749ddca93c` |

- Frappe 镜像为 `registry.trinfo.net/transinfosh/tai-customer@sha256:1230f1a8309d9b1a0faa099b229fc44eff0f02e2e43e24b099af4447b9f78086`。
- Agno 镜像为 `registry.trinfo.net/transinfosh/tai-agno@sha256:5d61ffdf603a9343620c94472e7090254762c767be98cba8aa5880dd2c377d52`。
- GitHub Actions 使用锁定版本构建，前端构建与新站安装通过。常规镜像同步较慢，通过 OCI 导出流程补同步，验证了根摘要和全部 27 个 blob。[构建记录](https://github.com/transinfosh/tai/actions/runs/44509419728) · [OCI 导出](https://github.com/transinfosh/tai/actions/runs/44511224084)
- 封版后调整了向导的「返回」按钮位置。该补丁已提交到 tBI `develop` 的 `9950d78`，后续发布时纳入镜像。

## 备份、迁移与回退

暂停测试站新问答并停写。两套 PostgreSQL 备份均在隔离数据库完整恢复并对照行数，现场文件与配置的异机备份已校验。备份目录为 `192.168.2.52:/srv/tsuite-deploy/backups/tai-test-20261119-bi-full/`。

| 文件 | SHA-256 |
| --- | --- |
| `tai_test.dump` | `884f9c62f55da4073e6c20d54712e82484a63b622999d36cf0b1f84e19ed70cb` |
| `tai_test_agno.dump` | `456341cedcf139006838848f710d823ef74c1b93f08959975ace047a0c4ca32f` |
| `site-files.tar.gz` | `61a2a2bf73591055c9ef1f851e738b43433afc9936e2f8d96639d694f4172f97` |
| `configuration.tar.gz` | `12e989a932d918e9a35730bc50084092208536258cb5ad704004611e78e75eb6` |

`bench migrate` 成功。tBI 将旧交互配置归档并迁到图表和仪表板配置，移除旧的交互表与字段。升级前后的 393 个图表版本和 167 个仪表板版本的发布快照逐项对照一致。八个目标容器健康检查、26 条查询路由和 Agno 回调鉴权通过，已恢复测试站问答。

现场旧配置和核对记录位于 `192.168.2.183:/opt/tsuite-deploy/frappe-test/upgrades/20261119-bi-full/`。回退须先暂停新任务、备份升级后新增或修改的数据，再使用已验证的备份恢复旧 tBI 表结构和数据，核对兼容后切换旧镜像和配置。保留当前 Agno 数据库及升级后会话，在恢复前核对业务引用。

## 验收结果

- 隔离站使用上一发布版本建立真实关联和发布快照，验证升级后保留原关联及快照。新建空白工作区及同请求重试通过，且没有自动创建业务资产；旧 Git 模板路径回归通过。
- 2.183 已验证匿名访问拒绝、历史会话可读、原图表可查询、四个已发布仪表板可读。已有工作区继续通过原入口使用。
- 2.183 已验证管理端初始化页面及 SAP Business One 模板 ZIP 上传预览，识别出 6 张图表、1 个仪表板和 3 条知识。该项验收止于预览，没有连接 SAP 业务库执行实际导入。[模板源码](https://github.com/transinfosh/tbi-semantic-template-sap-b1/commit/6125120280a082360ef9b70ae6281dbc2c4779dd)
- tBI、tAI 和 tai-chat 精确发布源码的前端测试分别通过 557、150 和 177 项；契约 CI、受影响的隔离站用例及静态检查通过。
- 真实问答重新查询 2026 年 8 月销售数据，生成两个绑定不同指标的卡片。SSE 断开后成功续接，管理员审计可读查询工具输入和输出，测试会话已归档。该次验收耗时 11.618 秒。
- HTTPS 验收记录位于 `192.168.2.52:/srv/tsuite-deploy/release-work/tai-test-20261119-bi-full/verification-http.json`。
