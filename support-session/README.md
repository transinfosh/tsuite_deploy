# 临时远程支持会话

`support-session` 用于客户服务器无法被公司网络直接访问时，建立短时、可审计边界清晰的
SSH 反向隧道。客户只需执行一条由公司 CLI 生成的命令并输入一次性会话码，后续操作由
公司运维人员通过堡垒机完成。

该模块独立于 `single-node` 和 `multi-node`，不会接管或修改现有 FRP 服务。FRP 与本模块可以
在同一堡垒机共存；两者不共用端口、Token、用户或配置文件。

## 安全边界

- 客户入口通过 Caddy HTTPS 提供 15 分钟随机地址，enrollment 仍由专用 SSH
  用户的每会话强制命令完成；
- 一次性会话码默认 15 分钟失效，服务端只保存 SHA-256 摘要；
- 每个会话使用独立的 enrollment key、隧道 Unix 用户、隧道 key、operator key 和回环端口；
- 反向端口固定为堡垒机的 `127.0.0.1:<port>`，不会暴露到公网；
- 客户和堡垒机的 SSH Host Key 均严格固定，禁止首次连接自动信任；
- 客户端会创建临时运维用户，并显式授予临时免密 root 权限；默认两小时后自动删除；
- 关闭或过期时，堡垒机会终止隧道连接、删除隧道用户和私钥，客户机会删除临时用户、
  sudoers、密钥、systemd unit 与本地会话配置。

这是一条临时的完整 root 运维通道。创建会话前应获得客户授权，并在工单中记录客户、用途、
创建人和会话 ID。不要把会话码、私钥或 enrollment 响应写入聊天记录或普通日志。

## 前置条件

堡垒机需要 Ubuntu、OpenSSH Server、Python 3 和 systemd。另需准备：

1. 一个解析到堡垒机的长期独立域名，例如 `bastion-support.example.com`；
2. 客户网络能够访问该域名的 HTTPS 和 SSH 端口；
3. 公司电脑到堡垒机的密钥 SSH 登录。安装器会为该用户配置仅能管理支持会话的限定 sudo。

堡垒机需已安装 Caddy。安装器会为独立域名增加受管的 `/tsuite-support/`
静态下载路由，不改动现有 FRP 配置。以后切换堡垒机 IP 时只需更新 DNS；若服务器
SSH Host Key 也改变，新会话脚本会固定新的 Host Key。

## 安装堡垒机模块

从固定版本检出仓库后执行：

```bash
cd support-session/bastion
sudo ./install.sh \
  --bastion-host bastion-support.example.com \
  --operator-user tunnel-user
```

安装器会先校验 sshd 的语法和 `tsuite-enroll` 用户的有效策略，再 reload SSH，并安装过期回收
timer。它不会开放 22000–22999 到公网，这些端口只能通过堡垒机本机回环地址访问；现有 FRP、
FRP 和 FRP Token 均不会被修改或复用。Caddy 只会增加一个独立的受管 import，并在校验或
reload 失败时自动恢复旧配置。

## GitHub 支持管理页面

支持页面是可选模块，使用 GitHub OAuth 登录并限制到指定 GitHub 组织（默认
`transinfosh`），可选择进一步限制到某个团队。页面只提供创建、查看和关闭会话；服务账户通过
固定参数的受限桥接程序调用会话管理器，不能执行任意 Shell 或 SSH 命令。

先在 GitHub 中创建一个 OAuth App：Homepage URL 为 `https://edge.trinfo.net/support/`，
Authorization callback URL 为 `https://edge.trinfo.net/support/auth/github/callback`。应用需要
请求 `read:org` scope。Client Secret 只在部署控制机安装时通过隐藏输入或 root-only 文件提供，绝不
提交到仓库、粘贴到聊天或放入命令行参数。

生产环境中页面安装在内网部署控制机，堡垒机只安装 forced-command 桥接程序。控制机通过固定
Host Key 和专用 bridge key 调用堡垒机，bridge key 不能获得普通 Shell。具体安装方式见
[control-node](../control-node/README.md)。同机试用场景仍可使用：

```bash
cd support-session/bastion
sudo ./install-console.sh \
  --bastion-host edge.example.com \
  --github-client-id YOUR_GITHUB_CLIENT_ID \
  --github-allowed-org transinfosh
```

安装器会隐藏提示 Client Secret，然后页面可从
`https://edge.example.com/support/` 访问。浏览器中创建会话后，页面仅显示一次客户执行命令和
一次性会话码；二者仍应通过独立安全渠道发送给客户。该页面不替代客户发起的出站连接，也不提供
浏览器终端；客户仍只需执行页面给出的那一条命令。

## 安装公司端 CLI

```bash
cd support-session/operator
sudo ./install.sh
tsuite-support configure --bastion company-bastion
```

`company-bastion` 建议配置在公司电脑的 `~/.ssh/config` 中，并固定堡垒机 Host Key。公司端
生成的会话私钥只保存在 `~/.config/tsuite-support/sessions/`，关闭会话时删除。

## 日常流程

公司运维创建会话：

```bash
tsuite-support create customer-code
```

命令会输出一条 `curl ... | sudo bash` 客户执行语句，并在标准错误中单独显示
一次性会话码。URL 使用 256-bit 随机标识，不包含会话码，下载文件禁止缓存，并在登记、
关闭或最迟 15 分钟到期时回收。脚本内的 enrollment key 仅限本次会话且只能调用强制
enrollment 命令，同时固定堡垒机 Host Key。客户执行后在终端提示中输入会话码；
会话码不会出现在命令历史或进程参数中。

客户完成 enrollment 后，公司端可执行：

```bash
tsuite-support status SESSION_ID
tsuite-support ssh SESSION_ID
tsuite-support run SESSION_ID -- sudo tsuite-deploy
```

完成工作后立即关闭，不必等待自动过期：

```bash
tsuite-support close SESSION_ID
```

关闭命令只有在客户机确认清理任务已经调度后，才撤销堡垒机通道并删除公司本地 key；当前 SSH
连接随后中断属于预期行为。客户不可达时可用 `--force` 只撤销堡垒机端，但命令会明确警告客户
残留尚未确认，双方的原生 key 过期时间和 timer/GC 仍会兜底。堡垒机可用
`sudo tsuite-support-session list` 核对是否仍有活动会话。

## 首次客户实测顺序

首次接入客户生产环境时，先只读检查时间、系统、Docker、Compose、站点 volume、部署状态与
PostgreSQL 版本。确认备份能够由与服务端同主版本的 `pg_dump` 完成后，再执行升级。删除旧
Compose 容器和旧 volume 必须放在新部署健康检查、站点登录与后台任务验证之后。
