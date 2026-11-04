# 2026-11-04 仪表板专用图表与搜索发布至 2.183

已完成部署与验收，目标为 `192.168.2.183` / `tai.trinfo.net`。沿用控制机 2.52、多节点 Ansible、2.185 外部 PostgreSQL 18、原 sites volume、Secret 和三类队列。执行人为 Codex，经用户授权；使用固定内网 identity，没有创建临时支持会话。

## 更新内容

- 新增 Dashboard Only（仪表板专用）图表分类，提供标准复选框筛选；普通列表、首页搜索/最近更新及 AI 独立资产目录默认排除专用图表。
- 仪表板编辑页直接弹框创建完整图表，默认设为专用；保存图表后加入当前仪表板草稿。
- 首页搜索覆盖仪表板、图表、语义模型及其表、视图、分析模型和连接；显示细分类型、图标与统一语义配色。
- 完整结果页按独立卡片展示，支持类型筛选和每页 24 条分页；移动端单列。
- 搜索框 AI 入口按空词/有词切换状态，有词时在当前工作区新对话自动发送一次；保留输入防抖、IME 和迟到响应保护。
- 修复页签误保存、非标准提示、弹窗下拉遮挡、菜单图标/分隔线、筛选重复及首次渲染闪现；主页“查看全部”不再追加 workspace 筛选。

开发站点批量设置专用图表属于独立数据操作，本次镜像没有自动改写生产图表分类。业务记录数量在迁移后、恢复访问前与停写备份基线一致。

## 版本与镜像

| 仓库 | 标签 | 源码提交 |
| --- | --- | --- |
| tBI | v0.0.29 | e008bd0e9da20c37f49702ebaee84e76e048e974 |
| tAI / Customer | v0.0.67 | fbb8e01ddb0e241ae35aa4c16c6a9f41a7d2ba0f |
| Frappe | v16.53.0-ts.13 | da5b296eab3426534911c71856030f3c4084f797 |
| frappe_ext | v0.0.14 | 763282061aca4d07ae07faeb559f2be933a09e3d |
| tai-chat | v0.2.46 | f10a111947fbcfde2b8f4579df55e54e4bba33a4 |
| transinfo-ui | v0.1.8 | 0a2de9b180f7c348688c5c4205e8020c972a5cd9 |

共享组件为已核对的最新正式不可变标签。代码、标签和相关功能文档均已推送。Customer 构建、站点安装、运行时检查与最终镜像同步：[41746647583](https://github.com/transinfosh/tai/actions/runs/41746647583)，最终成功。tBI 契约检查：[41746635793](https://github.com/transinfosh/tbi/actions/runs/41746635793)。

- 目标镜像：`registry.trinfo.net/transinfosh/tai-customer@sha256:e37024a06aaa433c199f8196cae7b4e0596151625911a71de02bef4ee4100472`。
- 原镜像恢复点：`registry.trinfo.net/transinfosh/tai-customer@sha256:110fb18972c3b37e9d8c3453201a36e4483606996e857bc3afb23f454271c8e0`。
- Engine 保持 0.1.18，容器 ID 未改变。
- 部署工具基线 `ae13acaf2abb9a94bad14dc1dab35af8050606c0`，vendor 固定 `1400040089cef563d1307ad26202f683a381c4a8`；本次工具快照保存在受限证据目录。

## 备份与升级

确认无在途 Run 和忙碌 worker 后进入维护、暂停调度并停写。备份均已复制到控制机 `/srv/tsuite-deploy/backups/tai-customer-01/20261104-v0067-search/`，源文件与异地 SHA256 一致。

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| customer-tai.dump | 46,746,044 | 8c5e78c305fef758602f9c03cb3a6f2d520ce963f4733a4af64ca1ccafe08419 |
| site-config-and-files.tgz | 4,305,397 | 8bd2885284682fb2f125b102f8b856a2f9379ed47a7c42c89320ccc67414e5be |
| stack-config.tgz | 2,035 | 56f209ab74cafe7ba99d1b7ad903d79623147d1f498f8cebcfd5243b6dff7d8a |

数据库在独立、无网络及无端口的 PostgreSQL 18.6 容器恢复成功，364 张表可读；恢复容器、卷和临时密码文件已清理。没有将生产备份下载到开发机。升级 35 项任务通过、9 项变更，migrate 成功；维护和暂停调度标志均恢复为 0。

8 个应用容器均使用目标摘要、全部运行且重启计数为 0。三类 worker 队列保留 short/default、long/default/short、tai_runtime；独立查询服务、26 条精确路由及 Engine 普通 backend 回调检查通过。

## 验证与兼容

发布前 tBI 452 项、tAI 127 项前端测试通过；隔离站点迁移、专用图表 3 项、工作区门户 12 项、仪表板发布 16 项通过，两个应用构建及翻译检查通过。开发阶段中英文、手机、筛选首次渲染、完整搜索和 AI 交接浏览器回归已通过；生产不是以模拟接口代替实际查询验证。

部署后公网 ping、登录、认证首页及搜索接口均返回 200；搜索两页各 24 条且无重叠。新增 Check 字段及标准筛选元数据已迁移，专用图表排除逻辑核对通过。本地和 Gateway 各进行三轮并发“仪表板+单图”验证，合计 48 个真实图表结果成功。最小真实问答由 tai_runtime worker 完成，状态 succeeded、调用模型一次，验收 Thread 已归档；这次验收在业务数量核对后新增了一个 Thread 和 Run。

兼容影响：图表增加 dashboard_only 字段，搜索接口增量接受 offset 参数，保留既有参数、记录身份、权限及发布版本语义。未迁移或重新发布语义模型，没有改变线上业务资产分类。回退前评估 schema 兼容，不自动恢复数据库。

## 镜像传输与收尾

公网镜像同步耗时过长并超时取消。CI 以只读包权限导出同一不可变 OCI 图，补充支持省略目标已存在层的恢复工作流（tAI develop 提交 7b02e25）。完整制品经分段传输取回，归档 SHA256 为 `39e9a07d32c1d47b909e232e7056b62186d8165a19a1428d0c930a1d15c43394`；在控制机核对全部 OCI blob、描述符和最终摘要后，通过 Registry 官方 loopback API 补齐。随后只重跑同步作业并成功，没有重建业务镜像或移动发布标签。

正式升级前已确认补丁台账只有 rolled_back 历史记录，没有活跃补丁。vendor 使用现场同一固定提交的只读本地 Git 镜像，升级后 origin 恢复 GitHub 地址；本次沿用已验证的本地 vendor 取码路径，没有调整生产网络。临时制品和缓存已清理，正式备份、旧镜像及受限证据保留。

受限证据：`192.168.2.52:/srv/tsuite-deploy/files/releases/tai-customer-20261104-v0067-search/`。
