# 临时 Python / 提示词补丁

在 52 控制机执行，复用已获授权的 SSH identity，不复制开发机私钥。不需要重建或下载应用镜像。
此入口不会修改镜像、Compose、站点配置、依赖或数据库，不运行 `bench update`、`pip install`、构建或迁移。

## 第一版边界

- 只接受已推送到 origin 分支、可由基础 commit 向前追溯的提交。
- 只修改已有普通文件：`<app>/.../*.py`，或 `<app>/.../prompts/.../*.md|*.txt`。
- 拒绝文件增加、删除、重命名、符号链接、可执行文件，以及 DocType、patches、migrations、hooks、安装、配置、前端和依赖文件。
- 2 MiB 补丁容量上限。Python 内的提示字符串也适用。
- 这些文件限制不能判定 Python 的行为语义：操作者仍需确认变更没有在普通 Python 文件中引入依赖、DDL、安装逻辑或迁移要求。
- 同一 Compose 项目只允许一个活跃补丁；第二个修复应先撤回现有补丁，再以原基础 commit 生成包含两次修复的累计补丁。
- 必须安排维护窗口，暂停新问答及其他任务入口。程序检查 RQ worker 是否 busy，但不提供全站请求排空或调度器互斥，检查后仍可能有新任务进入。
- 项目中的 backend、frontend、websocket、scheduler 和 `queue-*` 容器必须运行同一镜像。容器源码必须逐文件与基础 commit 相同，否则拒绝覆盖。
- 切换期间会停止上述应用容器；数据库、Redis 和外部引擎保持运行。使用 Docker stop/start，而非 Compose recreate，避免丢失容器可写层。

## 使用

在控制机 clone/fetch 目标应用仓库。`--base` 必须来自该服务器实际基础镜像的发布记录，不能凭工作区版本猜测。
`--commit` 为修复提交，不是持续变化的分支。Git 工作区的未提交内容不会参与补丁。

```bash
cd /srv/tsuite-deploy/repositories/tsuite_deploy

# 只核对，不修改应用文件或停止容器。
python3 patch-deploy/patch.py check \
  --host ubuntu@123.60.56.169 --identity /home/adam/.ssh/tsuite_deploy_ed25519 \
  --repo /srv/tsuite-deploy/repositories/tai --app tai \
  --base <基础镜像源码commit> --commit <修复commit> --site tai.ruisu.cn

# 应用；先复制备份到控制机，成功后才允许写入目标容器。
python3 patch-deploy/patch.py apply \
  --host ubuntu@123.60.56.169 --identity /home/adam/.ssh/tsuite_deploy_ed25519 \
  --repo /srv/tsuite-deploy/repositories/tai --app tai \
  --base <基础镜像源码commit> --commit <修复commit> --site tai.ruisu.cn

python3 patch-deploy/patch.py status \
  --host ubuntu@123.60.56.169 --identity /home/adam/.ssh/tsuite_deploy_ed25519

python3 patch-deploy/patch.py rollback \
  --host ubuntu@123.60.56.169 --identity /home/adam/.ssh/tsuite_deploy_ed25519 \
  --id <返回的补丁ID>
```

`--project` 默认 `frappe-customer`，其他项目须显式指定。183 使用 `adam@192.168.2.183` 和站点 `tai.trinfo.net`。

## 备份、验证与恢复

目标宿主机台账：`/opt/tsuite-deploy/patches/<project>/<id>.json`，0700 目录、0600 文件。
控制机备份：`/srv/tsuite-deploy/backups/patches/<host>/<project>/<id>.json`。
保存原文件内容、权限、UID/GID、容器身份、镜像身份以及提交，不保存 Docker 环境变量或 SSH 凭据。

执行顺序：核对全部容器与文件 → 语法检查与 idle 检查 → 宿主机备份 → 控制机备份 → 再次核对 → 停止应用容器 → 同步补丁 → 启动 → 验证。
备份失败不会写入容器。验证包括全部文件内容、容器状态、实际站点数据库连接和 app 导入，不替代具体业务功能验证。
不把数据库或模型查询结果写进普通日志。

写入或验证失败会尝试恢复所有原文件。成功记录 `rolled_back`；失败记录 `rollback_failed`，命令返回非零。
恢复失败时保留备份和现场，先恢复 Docker/容器运行条件，再使用同一个 `rollback` 命令。
容器已被删除或重建则拒绝恢复旧备份到新容器；应按正式部署修复，不能修改台账绕过身份检查。
`prepared` 表示仅完成备份，尚未改文件；备份写入失败后可以使用新的 `--id` 重新准备。

## 正式升级

容器重建会丢失临时补丁。台账不会因为重建而自动消失，也不会自动把临时修改混入正式镜像。

在正式升级前，用最新 fetch 的源码执行：

```bash
python3 patch-deploy/patch.py verify-upgrade \
  --host ubuntu@123.60.56.169 --identity /home/adam/.ssh/tsuite_deploy_ed25519 \
  --repo /srv/tsuite-deploy/repositories/tai --app tai --commit <正式镜像源码commit>
```

它检查正式提交包含活跃修复，拒绝未完成或回滚失败的补丁。该命令是运行手册的显式步骤，第一版不自动钩入全部单机脚本或 Ansible 角色。
检查通过并预下载正式镜像后，在同一维护窗口先 `rollback` 补丁，再执行现有正式升级、迁移及验证。
撤回后到正式升级完成之前运行的是基础版本；不要在这段时间恢复请求入口。
如果正式升级失败，优先按升级回退规范处理；数据库迁移后不能直接重新应用旧补丁。

## 验证

```bash
python3 -m unittest discover -s patch-deploy/tests -v
python3 -m py_compile patch-deploy/patch.py patch-deploy/remote.py
```

事务测试使用隔离的临时仓库和 Docker 替身，覆盖部分失败、恢复失败、版本不一致以及身份变化。
2026-09-18 已在获授权的 183 演示环境完成真实 Docker / Frappe 演练：修改已有 Python 进度文案，检查 7 个应用容器，应用补丁，提交真实物料查询，撤回补丁并再次查询。检查约 3.5 秒、应用约 18.8 秒、撤回约 14.8 秒；应用和撤回均验证文件内容及站点连接。测试不涉及镜像重建、依赖或数据库迁移。

演练台账 ID：`drill-183-20260918-label`，状态 `rolled_back`；测试源码仅在独立测试分支提交并随后撤回，未合入应用发布分支。该演练不替代每次补丁的业务验证，也未覆盖真实环境中的故障注入。
