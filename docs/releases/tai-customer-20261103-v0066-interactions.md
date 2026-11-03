# 2026-11-03 交互分组与配置刷新发布至 2.183

已部署并恢复访问，2026-11-03 北京时间 12:10 完成业务与容器验收。目标仅为 `192.168.2.183` / `tai.trinfo.net`，沿用控制机 2.52、多节点 Ansible、2.185 外部 PostgreSQL 18、原 sites volume、Secret 与队列配置；Engine 0.1.18 保持原镜像及容器 ID。执行人为 Codex，经用户授权；使用内网固定 identity，未创建临时支持会话。

## 发布版本与源码

| 仓库 | 发布标签 | 源码提交 |
| --- | --- | --- |
| frappe | v16.53.0-ts.13 | da5b296eab3426534911c71856030f3c4084f797 |
| frappe_ext | v0.0.14 | 763282061aca4d07ae07faeb559f2be933a09e3d |
| tbi | v0.0.28 | 66b608fdf6cf6a65f300be31a6949f21ec2822ae |
| tai / Customer | v0.0.66 | 16650d3ffe1cf342ffd98b0e0e4355c5f0457cac |
| tai-chat | v0.2.46 | f10a111947fbcfde2b8f4579df55e54e4bba33a4 |
| transinfo-ui | v0.1.8 | 0a2de9b180f7c348688c5c4205e8020c972a5cd9 |

共享组件使用已核对的最新正式不可变标签。Frappe 代码推送至 `codex/release-frappe-v16.53.0-ts.13`，应用代码与发布锁推送至各自 develop。tBI 0.0.27 保留为被 0.0.28 替代的预发布候选；未移动任何已发布标签。0.0.28 合入现场热补丁的提交历史，解决相同修复代码来自不同提交时升级门禁拒绝的问题。

基础镜像构建及同步：[41569911773](https://github.com/transinfosh/frappe_ext/actions/runs/41569911773)。Customer 构建、运行时检查、站点安装及同步：[41570690044](https://github.com/transinfosh/tai/actions/runs/41570690044)。两条流水线最终均成功。

- 基础镜像：`registry.trinfo.net/transinfosh/tsuite-base@sha256:334b5b52341a5fae97b2a2cab6b01ceb9014b00726c5e7d86651edebbc94f842`。
- Customer：`registry.trinfo.net/transinfosh/tai-customer@sha256:110fb18972c3b37e9d8c3453201a36e4483606996e857bc3afb23f454271c8e0`。
- 原 Customer 恢复点：`registry.trinfo.net/transinfosh/tai-customer@sha256:7aff1b52479c46a6ca571b06194fb4c0ce686167a3ef10758f613e66a3b05433`。

本版包含报表多字段有序明细分组、汇总及列操作；仪表板关系卡片和独立编辑表单；有顺序的累积交互、上游保护与高亮置灰数据禁选；配置保存与仅展示变更取消不再重复查询，以及已提交的图表列表和工作区入口修复。规格与验证分别见[仪表板](https://github.com/transinfosh/tsuite/blob/main/docs/%E5%BA%94%E7%94%A8/tbi/%E4%BB%AA%E8%A1%A8%E6%9D%BF/%E4%BB%AA%E8%A1%A8%E6%9D%BF-%E8%A7%84%E6%A0%BC%E5%A5%91%E7%BA%A6.md)、[图表](https://github.com/transinfosh/tsuite/blob/main/docs/%E5%BA%94%E7%94%A8/tbi/%E5%9B%BE%E8%A1%A8/%E5%9B%BE%E8%A1%A8-%E8%A7%84%E6%A0%BC%E5%A5%91%E7%BA%A6.md)与[工作区](https://github.com/transinfosh/tsuite/blob/main/docs/%E5%BA%94%E7%94%A8/tbi/%E5%B7%A5%E4%BD%9C%E5%8C%BA/%E5%B7%A5%E4%BD%9C%E5%8C%BA-%E8%A7%84%E6%A0%BC%E5%A5%91%E7%BA%A6.md)。交互保存结构和公开接口保持，旧双向关系按新的上游保护规则解释；图表类型元数据标签通过 migrate 同步，稳定类型编码不变。

## 备份、迁移与恢复点

确认无在途问答和忙碌 worker 后进入维护、暂停调度和队列。停写数据库、站点文件与配置备份已复制到 `192.168.2.52:/srv/tsuite-deploy/backups/tai-customer-01/20261103-v0066-interactions/`，原件与异地 SHA256 一致。

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| customer-tai.dump | 46,636,407 | 45e28c587cbba28238334d803db6412bf1de434e77d81b716b7ed323c75b5329 |
| site-config-and-files.tgz | 4,302,928 | 69bd65c2e47ce43609778b0d41b70075a4aad5f2b66de8fc02c8d06297ae1ef3 |
| stack-config.tgz | 2,032 | 0f3aafe0e0b89f9c09dbb75c7e74a34ca969e253b81db75dfc56916724fb16b6 |

数据库在无网络、无端口的隔离 PG18.6 中恢复成功，364 张 public 表可读；恢复容器、卷和临时密码文件由脚本清理。客户数据库及含密钥文件没有传至开发机。正式备份及旧镜像保留，未自动恢复生产数据库。

现场 tBI 热补丁 `tbi-99ca61d32ad1` 已通过正式源码包含关系校验，并在维护窗口正常撤回。首次撤回使用的旧工具漏算独立 tbi-query，未通过身份检查且未修改文件；改用应用补丁时配套工具核实八个容器 ID 完全一致后撤回成功。本次同时为部署仓库修复服务选择遗漏，新增回归并通过18项工具测试。

部署工具执行基线为 `tsuite_deploy` 提交 `e8aab25c524eb9ac75c6743ce5d529be6cd1364a`，本次发布工具快照另保存在证据目录。升级沿用原 `frappe_docker` 提交 `1400040089cef563d1307ad26202f683a381c4a8`，35项升级任务通过，9项变更；迁移成功。原维护和调度开关恢复为0，八个应用容器使用目标摘要、全部运行且重启计数为0。独立查询容器、26条查询路由、Engine backend回调和三类队列均通过检查。升级后立即核对业务对象数量与停写基线一致；随后最小真实问答新增一个已归档验收会话及对应Run。

## 验证与传输处理

- 发布前：tBI 52个、tAI 29个前端测试文件通过；Frappe分组17项、tAI工作区发现9项隔离测试通过。tBI前端及基础/聚合镜像构建通过；隔离迁移和开发站点同步迁移通过。相关中英文图表/仪表板浏览器回归和翻译检查通过。报表已有邮件导出测试的旧环境失败记录仍见框架测试映射，本次不宣称框架全套测试通过。
- 部署后：公网ping和登录200；本地和Gateway分别进行三轮“仪表板+单图”并发验收，共48个真实图表结果成功。验收HTTP会话自动清理。
- 专用 tai_runtime worker完成一次真实模型问答，状态succeeded、模型调用1次，问题只要求解释同比增长率定义；验收会话已归档。不是用队列进程存在代替问答验收。
- 没有升级其他节点、数据库或Engine；没有进行模型发布范围或业务数据修复。

公网大层同步长时间未完成，按源描述符补齐已下载前缀的标准HTTP Range，整层核对SHA256后，经控制机loopback Registry官方API导入相同OCI对象与标签；没有直接写Registry存储。随后仅重跑同步job，保留原构建，摘要与源一致。全部Compose及目标镜像来源检查通过后才进入维护。

控制机及183的GitHub取码出口不可用：已推送业务提交通过Git bundle送达控制机并验证补丁祖先；部署vendor临时使用现场同一固定提交的本地只读Git镜像，已验证克隆和取码。升级后vendor origin已恢复原GitHub地址。本次没有更改网络出口；后续联网取码仍需解决该基础设施问题。

受限证据和工具目录为 `192.168.2.52:/srv/tsuite-deploy/files/releases/tai-customer-20261103-v0066-interactions/`。回退前仍需评估迁移兼容及已归档补丁状态，不直接把旧补丁备份写进新容器。永久版本锁在183专属host_vars中维护，不以旧全局版本回退现场。
