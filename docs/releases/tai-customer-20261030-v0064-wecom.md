# 2.183 企业微信统一入口及 Ask AI 发布（2026-10-30）

部署完成，站点 `tai.trinfo.net` 已恢复访问。北京时间 2026-10-30 13:28:15 完成验收：8 个应用容器运行 Customer 0.0.64，维护模式 0、调度器启用，short/long/tai_runtime worker 正常，活动 Run 和排队任务均为 0。Engine 容器身份保持，外部数据库仍为 2.185 的 PostgreSQL 18。

## 版本及兼容

| 组件 | 版本 | 源码 |
| --- | --- | --- |
| TAI / Customer | v0.0.64 | b1d17f23b75bbd6353a0f51fa8124f4f81fb2238 |
| TBI | v0.0.25 | 3b02d33b1fa6a6b8ac949a1b658b91b6a4da062d |
| frappe_ext | v0.0.13 | dba3533b31134f9ceb0cbf0a2f0d2097eaf600e9 |
| tai-chat | v0.2.46 | f10a111947fbcfde2b8f4579df55e54e4bba33a4 |

Frappe 保持 16.53.0（v16.53.0-ts.12），transinfo-ui 保持 v0.1.8，Engine 保持 0.1.18。所有业务源码均已推送并由不可变标签固定。基础镜像及业务镜像的构建和同步均成功：[基础镜像 41002697085](https://github.com/transinfosh/frappe_ext/actions/runs/41002697085)、[Customer 41005135888](https://github.com/transinfosh/tai/actions/runs/41005135888)。

- Customer：`registry.trinfo.net/transinfosh/tai-customer@sha256:7aff1b52479c46a6ca571b06194fb4c0ce686167a3ef10758f613e66a3b05433`。
- 基础镜像：`registry.trinfo.net/transinfosh/tsuite-base@sha256:a814beede4e1424932150e328dc1a0164cae113de9bb945ab437937399f48f98`。
- Engine：`registry.trinfo.net/transinfosh/tbi-engine@sha256:8b4cfe84aec472ad0315470c601d3a504f227ad9b5a27e1648fb03a12f3309c2`，未重启。

公共登录入口位于 frappe_ext 的 `/wecom/login`，使用已有应用配置的默认回跳路径，支持本次受校验的站内回跳。2.183 先复用 `tai` 企业微信应用进入 TBI，企业微信后台可填写以下应用首页：

```text
https://tai.trinfo.net/wecom/login?app_key=tai&redirect_path=%2Fdesk%2Ftbi%2Ftbi-home
```

tAI 旧入口保留兼容，迁移只将该应用已知旧默认登录地址改为 `/app/tai-chat`；自定义首页、凭据和权限保持。未新增 DocType/字段，OAuth 白名单 Interface 的签名及回调地址保持。TBI 的 Ask AI 进入 `/desk/tai-chat/<workspace>/new`，跳过当前及记忆会话；首次发问再创建 Thread。所有 TBI 入口资源版本统一刷新为 `20261030.ask-ai.1`。

## 备份及升级

沿用控制机 2.52、多节点 inventory、2.183 原 Compose/volume/Secret、frappe_docker 提交 `1400040089cef563d1307ad26202f683a381c4a8` 和原三组队列，不启用 delivery watcher。只部署客户应用栈，未升级其他节点。

停写前确认无在途问答和队列任务，停写后备份并复制至：

`192.168.2.52:/srv/tsuite-deploy/backups/tai-customer-01/20261030-v0064-wecom/`

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| customer-tai.dump | 44,303,274 | 9816edf88025bd2d65df8c1585b58ebdf648108231f2424b4974263b43c72e8d |
| site-config-and-files.tgz | 1,464,397 | cc4ca7a152e8afcf47f9447503bb92dc5f4f30cd290b0150f859d5ffcbce7503 |
| stack-config.tgz | 2,033 | 101eb07c299cd265c72141d7101da4095a36e2a7faf2edfd52c943513582e2e4 |

原件与异地摘要一致；数据库已在无网络、无端口的隔离 PG18.6 中完整恢复，364 张 public 表可读。客户数据库及含密钥文件均未传至开发机。备份 playbook 无失败；应用切换及两次 migrate 成功，35 项升级任务通过、8 项变更。8 个应用容器均核对目标镜像，Engine 容器 ID 保持。恢复原维护及调度开关后再次通过查询部署检查器。

## 验证与限制

隔离站点 frappe_ext 227、tAI 登录/迁移 7、通用恢复 JavaScript 3、TBI 前端 393、TAI 前端 125、共享聊天 170 项测试通过；生产构建、翻译检查、隔离及开发站迁移通过。TBI 的资源一致性测试先发现两个共享页遗漏，补齐后重新全量通过；未部署候选 0.0.23/0.0.24 和 TAI 0.0.63 保留标签并标为预发布，未覆盖标签。

生产 HTTP 验证访客授权地址及 state Cookie、英文/中文错误页、已登录回跳到 TBI、tAI 旧入口兼容、默认首页迁移和新对话资源通过。公网 ping、普通登录页和企业微信中文错误页均返回 200。

本地及 Gateway 各保持“仪表板 + 单图”并发，分别连续 3 轮，合计 42 个仪表板结果和 6 个单图请求成功。首次将三组验收会话同时用同一 Administrator 创建，发生 User 元数据的序列化竞争；最终改为顺序创建/清理各组会话，组内查询并发保持，全部通过。会话已自动清理。队列按 Frappe 实际 Redis 前缀核对逻辑名称，三类 worker 空闲，业务对象数量与停写前一致。

企业微信客户端的真人授权尚需实际点击验收；本任务未发送真实模型请求，不将模拟 OAuth 或导航测试称为真实企业微信/模型端到端验收。

## 发布恢复及清理

公网同步曾中断一个 310,140,881 字节的基础层。按上游摘要核对后，使用已有 GHCR 读取授权与可续传工具补齐，经控制机 loopback Registry 官方 API 导入；凭据未传到控制机。业务仓库通过官方 blob mount 复用 6 个基础对象，316,440,063 字节，再补齐剩余对象。两类镜像均保留源索引与平台清单、摘要完全一致，之后只重跑同步 job，构建不重做。没有直接写 Registry 存储文件或覆盖不同摘要的标签。

受限证据目录为 `/srv/tsuite-deploy/files/releases/tai-customer-20261030-v0064-wecom/`，包含原始及最终验收、镜像清单、运行状态、备份和恢复记录。临时 OCI 缓存、隔离恢复容器/卷及临时密码文件已清理；正式备份、旧镜像和旧发布目录保留。本次使用内网固定 identity，未创建临时支持会话。

回退点为原 Customer 0.0.62 的 `sha256:d70911633a203668a5d5145f9d0ce777bb88fec3a7b166fa5e33b39ddbac49ac` 及本次正式备份。回退前仍按运行手册评估配置/迁移兼容，不自动恢复数据库。执行人为 Codex，经用户授权使用控制机 adam 账号。
