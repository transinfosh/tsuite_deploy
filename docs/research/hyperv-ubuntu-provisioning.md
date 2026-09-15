# Windows Server Hyper-V：批量创建 Ubuntu 的方案调研

调研日期：2026-08-27。范围是 Windows Server 上已有 Hyper-V 主机、需要反复创建 Ubuntu，且每台机器要能注入 cloud-init、使用固定网络、复用基础镜像的场景。下文链接均为厂商或项目维护方的一手资料；Terraform 的 Hyper-V Provider 是社区 Provider，已明确标注。

## 结论

对于当前这台独立的 Windows Server Hyper-V 宿主机，**继续采用「官方 Ubuntu Cloud Image + cloud-init NoCloud seed + Hyper-V PowerShell + 差分 VHDX」是最合适的主方案**。它没有新增控制平面，云镜像只下载一次，针对单台机器建机可以保留交互式体验；同一套底层逻辑也可以在以后改为配置文件/非交互模式。

若以后变成“统一部署机管理多台 Hyper-V 主机、需要声明式变更审计”，再选择 Terraform；若需求升级为模板库、配额、多租户和主机集群管理，才值得引入 System Center VMM。Packer 的定位是“构建和固化黄金镜像”，应作为现有方案的上游补充，而不是每次创建 Ubuntu 的交互工具。Vagrant 更偏开发者本机环境，且官方文档列出的兼容性只承诺 Windows 8.1 及更高版本，未把 Windows Server 列为支持目标，因此不建议作为这台生产 Hyper-V Server 的标准。

## 需求与技术映射

| 需求 | 推荐实现 | 依据 |
| --- | --- | --- |
| 官方 Ubuntu 基础系统 | Ubuntu 官方 Cloud Image 的 `*-azure.vhd.tar.gz` | Ubuntu 官方当前目录直接发布 VHD 包和 `SHA256SUMS`。[Ubuntu 24.04 Cloud Images](https://cloud-images.ubuntu.com/noble/current/) |
| 首次启动配置（用户、SSH 公钥、包、主机名） | cloud-init NoCloud 的 `user-data` / `meta-data` | NoCloud 能离线提供用户、元数据和网络配置，不需要额外网络服务。[cloud-init NoCloud 文档](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html) |
| 固定 IP、网关、DNS | 同一个 NoCloud seed 中的 `network-config`；Hyper-V 侧只负责接入正确 vSwitch/VLAN | NoCloud 支持通过 seed 提供网络配置；Ubuntu 24.04/22.04 也被微软列为支持静态 IP 注入的 Hyper-V 客体。[NoCloud](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html)、[Ubuntu on Hyper-V](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-ubuntu-virtual-machines-on-hyper-v) |
| 不重复下载/占用完整系统盘 | 本地只读父 VHD + 每台 VM 一个差分 VHDX | Hyper-V 官方 PowerShell 模块提供 VHD/VM 管理命令；VMM 的官方文档也明确支持差分磁盘。[Hyper-V PowerShell 模块](https://learn.microsoft.com/en-us/powershell/module/hyper-v/)、[New-SCVirtualMachine](https://learn.microsoft.com/en-us/powershell/module/virtualmachinemanager/new-scvirtualmachine?view=systemcenter-ps-2025) |
| Ubuntu Gen 2 安全启动 | `Set-VMFirmware` 配合 Linux 的 UEFI CA 模板 | Microsoft 的 Ubuntu 支持矩阵列出 24.04/22.04 在 Windows Server 2016–2025 上支持 Gen 2 UEFI 与 Secure Boot；固件 cmdlet 可设置相应模板。[支持矩阵](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-ubuntu-virtual-machines-on-hyper-v)、[Set-VMFirmware](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmfirmware?view=windowsserver2025-ps) |

## 方案比较

| 方案 | Windows Server Hyper-V | 云镜像 / NoCloud | 可复用镜像 | 适合度 | 判断 |
| --- | --- | --- | --- | --- | --- |
| 原生 Hyper-V PowerShell + cloud-init | Microsoft 官方 Hyper-V 模块适用于 Windows Server；Ubuntu 24.04、22.04 已在支持矩阵中列出 | 原生可行：挂载 `CIDATA` NoCloud seed | 直接用父 VHD + 差分 VHDX | **最高（当前）** | 没有新平台依赖，最贴合“在这台宿主机上点选创建”。 |
| Packer Hyper-V | Packer 官方 Hyper-V 插件可构建并导出 Hyper-V VM；会调用本机 Hyper-V | 可以用 HTTP、额外 ISO/ISO 文件等无人值守机制；不是 NoCloud 的专用封装 | Packer 有缓存，产物是可版本化的镜像 | **高（构建黄金镜像）** | 适合作为镜像工厂：周期性生成已打补丁、预装基础工具的 Ubuntu VHDX；不适合替代日常“一台一台建机”。 |
| Terraform Hyper-V Provider | 没有 HashiCorp 官方 Hyper-V Provider；现有 Provider 为社区维护，部分文档声明支持 Windows Server 2016+ | 可以声明 VM、VHD、网卡和运行远程 PowerShell；NoCloud 仍需自行生成 seed | 可以引用本地 VHD/差分盘 | **中（多主机 IaC 时）** | 可以纳入 Git、Plan、状态管理，但会引入 Provider 版本、状态文件与远程 WinRM/SSH 凭据维护。 |
| Vagrant Hyper-V | Vagrant 内置 Hyper-V Provider，但官方页仅表述 Windows 8.1+，未承诺 Windows Server | 常用 box/provisioner；不是直接消费 Ubuntu 官方 VHD + NoCloud 的模型 | box 缓存 | **低** | 优点是开发者体验；与现有企业 Hyper-V 宿主机、静态网络和标准 cloud-init 的需求不贴合。 |
| System Center Virtual Machine Manager (VMM) | Microsoft 官方企业级管理平台，管理 Hyper-V 主机、库和模板 | 可通过 Linux 自定义模板/SSH key 配置；不以 NoCloud 为中心 | VMM Library/VM Template，可从 VHD 创建模板 | **低到高（取决于规模）** | 适用于多主机、模板库、自助服务、委派和治理；对单台宿主机和少量 Ubuntu 机器明显过重。 |

### 1. 原生 Hyper-V PowerShell + cloud-init（建议保留并完善）

这是当前脚本的技术路线，而且不是“临时拼凑”：Hyper-V 的 `New-VM`、VHD、网络和固件配置均是微软随 Windows Server 提供的模块能力。Microsoft 也明确列出了 Windows Server 2016、2019、2022、2025 上 Ubuntu 22.04 / 24.04 的支持项，包括 Gen 2、Secure Boot、VHDX resize、VLAN 和静态 IP 注入。[Ubuntu 支持矩阵](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-ubuntu-virtual-machines-on-hyper-v)

cloud-init NoCloud 的标准输入由 `user-data`、`meta-data` 以及可选的 `network-config` 组成；在标签为 `CIDATA` 的 ISO 或 VFAT 卷上提供这些文件即可离线启动配置。[NoCloud 格式](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html) 这正好对应“每个 VM 独有小 seed 盘 + 可共享基础 VHD”的模型。

建议演进方向：

1. 交互式 PowerShell 工具保留为一线运维入口，cloud-init 文件在同级目录中列出供选择。
2. 给镜像下载加官方 `SHA256SUMS` 校验，并将镜像文件名、版本、校验值写入清单；不要把不断变化的 `current` 当作不可变发布物。
3. 将交互收集到的变量输出为一个不含密码的“VM 定义 YAML/JSON”，以便日后审计和非交互重建。
4. 固定 IP 之外保留 DHCP 选项；若网络团队按 MAC 做地址保留，再允许用户显式固定 MAC。

### 2. Packer Hyper-V（适合做镜像工厂）

HashiCorp 官方 Hyper-V 插件提供 `hyperv-iso`（从安装 ISO 创建新 VM 后导出）和 `hyperv-vmcx`（克隆既有 VM 后导出）两个 Builder。[插件概览](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv) `hyperv-iso` 支持校验下载、缓存路径、输出目录、vSwitch、VLAN、MAC、Gen 2、安全启动等设置；其文档也说明可用额外 ISO 或内建 HTTP server 做无人值守安装。[hyperv-iso 参数](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv/latest/components/builder/iso)

建议只在下面情况下引入：需要每月生成统一的“Ubuntu 24.04 + 安全补丁 + Docker/常用工具”的黄金镜像，并希望镜像构建定义由 Git 版本化。Packer 生成并验收父 VHDX 后，日常建机仍让当前 PowerShell 工具为每台 VM 建差分盘和 NoCloud seed；两者职责清晰。

注意：Packer 文档提示 Linux 客体的 IP 检测依赖 Hyper-V KVP daemon；若缺失，Packer 可能一直等待 SSH 可用。因此将 Packer 用于构建时，应先在目标 Ubuntu 版本上验证 `hv_kvp_daemon`/相关 cloud tools 是否正常，而不是直接用于生产批量创建。[Packer Hyper-V Linux 说明](https://developer.hashicorp.com/packer/integrations/hashicorp/hyperv/latest/components/builder/iso)

### 3. Terraform Hyper-V Provider（以后需要声明式管理再考虑）

截至调研日期，Terraform Registry 中的 Hyper-V Provider 并非 HashiCorp 官方 Provider。以 `taliesins/hyperv` 为例，源码 README 自称 beta，并要求通过 WinRM/凭据在 Windows Hyper-V 主机上执行 PowerShell；它声称支持 Windows Server 2016 或更新版本。[Provider 源码](https://github.com/taliesins/terraform-provider-hyperv)、[Registry 页面](https://registry.terraform.io/providers/taliesins/hyperv/latest)

另一个较新的 `windsorcli/hyperv` Provider 声称在 Windows Server 2022 上验证，并提供 local/SSH/WinRM 后端；这仍是社区项目，不能把其兼容性表述成 Terraform 官方支持。[Provider 文档](https://registry.terraform.io/providers/windsorcli/hyperv/latest/docs)

它适合“部署机从代码库创建/变更多台宿主机上的 VM，且团队愿意维护 state、Provider pin、远程访问和密钥轮换”的阶段。对当前单台 Windows Server，Terraform 不能免除 cloud-init seed、镜像缓存、网络地址管理这些问题，反而增加状态漂移和远程管理面的复杂度，因此暂不建议替换现有脚本。

### 4. Vagrant Hyper-V（不建议作为服务器标准）

Vagrant 自带 Hyper-V Provider，但官方文档写的是兼容 Windows 8.1 及以后版本，重点是桌面系统的 Hyper-V 启用和开发环境使用，并未将 Windows Server 作为正式兼容目标。[Vagrant Hyper-V Provider](https://developer.hashicorp.com/vagrant/docs/providers/hyperv) 它的 box 模型与 Ubuntu 官方 Azure VHD + NoCloud seed 并不直接衔接；固定外网、企业 VLAN、长期运行的服务 VM 还需要额外脚本。

因此可供开发人员在个人 Windows 笔记本复现环境，但不应成为这台承载许多现有虚拟机的 Windows Server 的生产建机通道。

### 5. System Center VMM（规模化后再上）

VMM 是 Microsoft 的正式企业虚拟化管理方案。其模板可从 VHD、既有 VM 或模板建立，并保存硬件和客户机配置以反复创建 VM；`New-SCVMTemplate` 的参数包含 Linux SSH key，且官方示例说明可创建可自定义 Linux 模板。[New-SCVMTemplate](https://learn.microsoft.com/en-us/powershell/module/virtualmachinemanager/new-scvmtemplate?view=systemcenter-ps-2025) `New-SCVirtualMachine` 也支持以包含第三方 OS（如 Linux）的既有 VHD 创建 VM，并支持差分磁盘。[New-SCVirtualMachine](https://learn.microsoft.com/en-us/powershell/module/virtualmachinemanager/new-scvirtualmachine?view=systemcenter-ps-2025)

若将来有多台宿主机、集群、共享模板库、委派给不同运维人员、配额和审批需求，VMM 才有明显收益。它需要额外的 VMM Server、SQL Server、库与运维体系；当前只为反复创建几台 Ubuntu 而部署，成本不成比例。

## 推荐落地路线

```text
现在：Ubuntu 官方 VHD + NoCloud + 原生 Hyper-V PowerShell + 差分 VHDX
  │
  ├─ 需要统一、可审计的基础镜像：在上游增加 Packer 生成并签名/校验父镜像
  │
  ├─ 需要从部署机统一声明式管理多台宿主机：评估并试点社区 Terraform Provider
  │
  └─ 需要企业级多主机模板库/自助服务/集群治理：评估 System Center VMM
```

当前脚本最值得投入的不是换一个“大工具”，而是把交互流程、镜像校验、日志和错误提示做好：这些正是该场景下减少人工试错的关键。随后用 Packer 固化父镜像即可兼顾成熟度与复杂度。

## 不建议项

- **不要把 Multipass 作为这台 Windows Server 的标准建机工具。** 它更适合开发机；当前环境已经出现其服务端/Hyper-V 兼容性问题，且它不解决企业 vSwitch、固定网络和可审计模板的核心诉求。
- **不要只依赖随机 MAC 来避免 IP 冲突。** 静态 IP 应在网络地址规划或 DHCP reservation 中登记；MAC 只是一种绑定标识。
- **不要共享一个可写 VHD 给多台 VM。** 父镜像必须保持只读，每台 VM 应有自己的差分盘或完整副本。
