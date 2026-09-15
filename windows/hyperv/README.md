# Windows Server Hyper-V 创建 TSuite 部署机

`New-TSuiteDeployVm.ps1` 用 Windows Server 原生 Hyper-V 创建 Ubuntu 虚拟机，不依赖
Multipass。它是交互式脚本：运行后逐项询问所需配置，不需要在调用命令中填写参数。
每台机器使用独立的 differencing OS 磁盘，并创建带 `CIDATA` 标签的 NoCloud seed disk 注入
cloud-init 与启动早期网络配置。

## 前置条件

- 在运行 Hyper-V 的 Windows Server 上，以管理员 PowerShell 执行；
- 已创建至少一个 Hyper-V 虚拟交换机；
- 已准备 cloud-init 文件；
- 计划使用的固定 IP 未被占用，且与路由器 DHCP 范围/保留策略不冲突。

## 创建

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\New-TSuiteDeployVm.ps1
```

将多个 cloud-init 配置放在脚本同级的 `cloud-init` 目录中。脚本会先列出其中的 `.yaml` 和
`.yml` 文件供选择；目录为空或直接回车时，可手工输入配置文件路径。随后它会询问：计算机名、
SSH 登录用户、Hyper-V 交换机、虚拟机系统目录、CPU、内存、磁盘、固定 IP、子网前缀、网关和
DNS。网络项带默认值，通常直接按 Enter 即可；网卡 MAC 由脚本在 Hyper-V 主机分配范围内自动生成
并检查冲突。

镜像缓存目录固定为脚本所在目录的 `images` 子目录，例如
`F:\tsuite_deploy\windows\hyperv\images`。
首次运行会下载约 600 MB 云镜像；之后同一镜像作为只读父盘复用，重建部署机只会新建
differencing disk 和 seed disk，不会重复下载。若目标磁盘大于父镜像容量，脚本会改用动态克隆盘
再扩容，仍不会重新下载镜像。内置 Ubuntu 22.04/24.04 会从 Ubuntu 官方 `SHA256SUMS` 校验下载内容；
自定义版本必须提供 HTTPS 地址和 SHA-256 校验值。

默认以交互方式执行时，脚本会先列出该缓存目录中的 `.vhd` 镜像，可输入编号直接复用。直接
回车或缓存为空时，再输入 Ubuntu 版本；内置支持 `24.04` 和 `22.04`，其他版本可输入其官方
`.vhd.tar.gz` 下载地址。

不要移动、删除或手工修改 `images` 中已被虚拟机使用的父 `.vhd`；这会使依赖它的差分盘无法启动。
cloud-init 文件必须保存为 UTF-8；它与 PowerShell 脚本使用的 GBK/CP936 编码无关。创建失败时脚本
会保留现场而不自动删除任何 VM 或目录，防止误删其他任务资源。

## 验证

```powershell
Get-VM
ssh <cloud-init 中的用户名>@<刚才输入的固定 IP>
```

若 cloud-init 仍在运行，可使用 Hyper-V Manager 的控制台查看启动日志；它完成后会安装 Docker、
Git 和基础运维工具。
