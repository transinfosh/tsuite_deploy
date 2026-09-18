# 便携 Linux 支持端发布验证（2026-09-18）

网页创建会话同时显示客户命令和 Linux 支持机命令。会话 ID 自动绑定，支持机生成本机密钥，
通过 Edge HTTPS 单次领取会话专属 SSH 证书，终端流量经 Edge 直接到客户；支持机不需 GitHub
再次登录或到 192.168.2.52 的 SSH 权限。

实现位于独立 tsuite_deploy 仓库；本地检出路径为 `/home/adam/development/tsuite_deploy`，基线为
`7c319b5d4fd43110961ddb10c962b056cb111093`。本次改动没有发布 Git Tag 或覆盖 GitHub main。
控制机仓库存在其他未提交变更，未 reset、覆盖或修改；线上只更新已经确认与基线完全一致的
支持 runtime 文件和新增客户端。新增独立 sudoers 仅允许页面调用无参数 `claim`，不增加
页面读取私钥、ssh/run/force-close 的权限。

## 发布与回退

- Edge 原程序备份：`/var/backups/support-portable-20260918T043302Z/`。
- 控制机原程序备份：`/srv/tsuite-deploy/backups/support-portable-20260918T043306Z/`。
- 原始发布快照：`/srv/tsuite-deploy/releases/support-portable-20260918T043306Z/`。
- 最终快照：`/srv/tsuite-deploy/releases/support-portable-20260918-final/`，包含最终源码、
  manifest 和 source.patch；不含会话凭据、OAuth Secret 或 SSH 私钥。
- 原备份的 manifest 记录修改目标和新增目标。回退应先确认没有活动新会话，恢复原程序、删除
  本次新增客户端文件及 `/etc/sudoers.d/tsuite-support-portable`，校验 sudoers 后重启支持页面。
  Edge manager 的受管 `/usr/local/sbin` 软链接保持不变，无需变更系统 SSH 配置或长期身份。

## 验证结果

- 支持模块 81 项 Python 测试通过，包括两条网页命令、错误/过期/重复/并发领取、跨会话隔离、
  本机撤销清理、网络故障按最后确认租约清理和旧会话兼容。
- 真实回环 OpenSSH 验证通过：证书登录、Edge forced proxy、show、跨会话拒绝、Shell 拒绝、
  错误密钥拒绝、原生到期及 CA 撤销。测试使用独立 sshd，严格主机密钥校验，没有更改系统账号。
- 新文件 Ruff F 检查通过，相关 Shell 语法检查和 git diff --check 通过。
- 完整 static 脚本中的 Python 编译、17 项 patch 测试、81 项支持测试、单机接管及 SSH 限制检查
  均通过；随后被既有 build-images.yml 的 `github.workflow_sha` 文本断言阻止，该断言与基线
  文件内容不符，未为本任务改动无关镜像工作流。
- 公网实际会话 `3f6abedb818f`：先运行支持机命令并领取授权，再执行 Linux 客户命令，成功等待
  接入和连接；交互 SSH、root 操作、再次连接执行 root 命令、重复 HTTPS 领取拒绝均通过。
  Linux 原 operator key 和 CA 两条记录跟随客户监控同步原生到期时间，普通关闭成功。
- 公网实际会话 `7c7fc93450dc`：先客户后支持机，成功连接；普通关闭中断正在连接的终端，删除
  客户临时账号及配置、撤销 Edge 信任，本机后台清理删除支持目录。最终无活动支持会话。
- 本机 WSL 回环 :22 返回的主机密钥与 `/etc/ssh` 不同，严格校验正确阻止连接。实测使用独立
  sshd 和只作用于临时支持隧道的 runtime override，未修改原系统 SSH；全部测试资源已清理。

## 兼容与剩余验证

只对升级后网页新建会话发放支持凭据，不迁移或补发既有会话。旧公司 CLI 会话保持原行为。
客户 Linux/Windows 同步增加会话 CA 信任及双记录续期，原公钥仍供控制机普通关闭使用。
Windows 代码和现有 Python 测试已经同步，但本次没有可丢弃 Windows Server 或 pwsh 环境，
尚未完成真实 Windows 证书登录、续期和关闭验收，不能把 Linux 实测等同于 Windows 验证。

支持命令是可转交的临时密码，领取前泄露可能被抢领。其安全边界是 256-bit 独立随机凭据、
15 分钟领取窗口、文件锁单次消费、绑定本机公钥、会话专属 CA/principal、原生闲置期限及关闭
撤销；完整命令仍可能留在执行者 Shell 历史中，需由执行者妥善保管。休眠或后台进程退出可
延迟本机凭据文件删除，服务端到期/撤销不依赖支持机清理。
