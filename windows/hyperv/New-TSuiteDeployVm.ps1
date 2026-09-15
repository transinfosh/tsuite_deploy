Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 本文件使用 GBK（Windows 代码页 936）保存，以兼容 Windows PowerShell 5.1。
$consoleEncoding = [Text.Encoding]::GetEncoding(936)
[Console]::InputEncoding = $consoleEncoding
[Console]::OutputEncoding = $consoleEncoding
$OutputEncoding = $consoleEncoding

function Require-Administrator {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = [Security.Principal.WindowsPrincipal]::new($identity)
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		throw '请使用“以管理员身份运行”的 Windows PowerShell 执行此脚本。'
	}
}

function Require-Command([string]$CommandName) {
	if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
		throw "缺少命令: $CommandName"
	}
}

function Read-Default([string]$Prompt, [string]$DefaultValue) {
	$value = Read-Host "$Prompt [$DefaultValue]"
	if ([string]::IsNullOrWhiteSpace($value)) {
		return $DefaultValue
	}
	return $value.Trim()
}

function Read-Integer([string]$Prompt, [int]$DefaultValue, [int]$Minimum, [int]$Maximum) {
	$value = Read-Default -Prompt $Prompt -DefaultValue $DefaultValue
	$parsedValue = 0
	if (-not [int]::TryParse($value, [ref]$parsedValue) -or $parsedValue -lt $Minimum -or $parsedValue -gt $Maximum) {
		throw "$Prompt 必须是 $Minimum 到 $Maximum 之间的整数。"
	}
	return $parsedValue
}

function Read-IpAddress([string]$Prompt, [string]$DefaultValue) {
	$value = Read-Default -Prompt $Prompt -DefaultValue $DefaultValue
	$ipAddress = $null
	if (-not [IPAddress]::TryParse($value, [ref]$ipAddress) -or $ipAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
		throw "$Prompt 必须是有效的 IPv4 地址。"
	}
	return $ipAddress
}

function Select-CloudInitFile([string]$CloudInitDirectory) {
	$files = @(
		Get-ChildItem -LiteralPath $CloudInitDirectory -File -ErrorAction SilentlyContinue |
			Where-Object { $_.Extension -in '.yaml', '.yml' } |
			Sort-Object Name
	)
	if ($files.Count -gt 0) {
		Write-Host ''
		Write-Host "可用 cloud-init 文件（$CloudInitDirectory）："
		for ($index = 0; $index -lt $files.Count; $index++) {
			Write-Host "  [$($index + 1)] $($files[$index].Name)"
		}
		Write-Host '直接回车将手工输入文件路径。'
		$selection = Read-Host '请选择 cloud-init 文件编号'
		if (-not [string]::IsNullOrWhiteSpace($selection)) {
			if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $files.Count) {
				throw 'cloud-init 文件编号无效。'
			}
			return $files[[int]$selection - 1].FullName
		}
	}
	return Read-Default -Prompt 'cloud-init 文件路径' -DefaultValue ''
}

function Select-VmSwitch {
	$switches = @(Get-VMSwitch | Sort-Object Name)
	if ($switches.Count -eq 0) {
		throw '未找到 Hyper-V 虚拟交换机。'
	}
	Write-Host ''
	Write-Host '可用 Hyper-V 交换机：'
	for ($index = 0; $index -lt $switches.Count; $index++) {
		Write-Host "  [$($index + 1)] $($switches[$index].Name) ($($switches[$index].SwitchType))"
	}
	$selection = Read-Host '请选择交换机编号'
	if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $switches.Count) {
		throw '交换机编号无效。'
	}
	return $switches[[int]$selection - 1].Name
}

function New-AvailableStaticMacAddress([System.Collections.Generic.HashSet[string]]$ExistingMacAddresses) {
	$vmHost = Get-VMHost
	$minimum = [Convert]::ToInt64(($vmHost.MacAddressMinimum -replace '[^0-9A-Fa-f]', ''), 16)
	$maximum = [Convert]::ToInt64(($vmHost.MacAddressMaximum -replace '[^0-9A-Fa-f]', ''), 16)
	if ($maximum -lt $minimum -or ($maximum - $minimum) -ge [int]::MaxValue) {
		throw 'Hyper-V 主机的 MAC 地址范围无效或过大。'
	}
	do {
		$address = '{0:X12}' -f ($minimum + (Get-Random -Minimum 0 -Maximum ([int]($maximum - $minimum + 1))))
	}
	while ($ExistingMacAddresses.Contains($address))
	return $address
}

function Expand-UbuntuImage([string]$ArchivePath, [string]$ExpectedImagePath) {
	$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
	if (-not $tar) {
		throw '缺少 tar.exe，无法解压 Ubuntu 官方 .tar.gz 云镜像。请安装 Windows 的 tar 工具后重试。'
	}
	& $tar.Source -xzf $ArchivePath -C (Split-Path -Parent $ExpectedImagePath)
	if ($LASTEXITCODE -ne 0) {
		throw '解压 Ubuntu 云镜像失败。'
	}
	if (-not (Test-Path -LiteralPath $ExpectedImagePath -PathType Leaf)) {
		throw "压缩包中未找到预期的 .vhd 文件: $ExpectedImagePath"
	}
	return $ExpectedImagePath
}

function Download-FileWithProgress([string]$Uri, [string]$Destination) {
	$temporaryPath = "$Destination.part"
	if (Test-Path -LiteralPath $temporaryPath) {
		Remove-Item -LiteralPath $temporaryPath -Force
	}

	$response = $null
	$inputStream = $null
	$outputStream = $null
	$downloadError = $null
	try {
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		$request = [Net.WebRequest]::Create($Uri)
		$response = $request.GetResponse()
		$totalBytes = $response.ContentLength
		$inputStream = $response.GetResponseStream()
		$outputStream = [IO.File]::Open($temporaryPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
		$buffer = New-Object byte[] 1048576
		$downloadedBytes = [int64]0
		while (($readBytes = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
			$outputStream.Write($buffer, 0, $readBytes)
			$downloadedBytes += $readBytes
			$downloadedMegabytes = [Math]::Round($downloadedBytes / 1MB, 1)
			if ($totalBytes -gt 0) {
				$percentComplete = [Math]::Min(100, [Math]::Floor(($downloadedBytes * 100) / $totalBytes))
				$totalMegabytes = [Math]::Round($totalBytes / 1MB, 1)
				Write-Progress -Activity '正在下载 Ubuntu 云镜像' -Status "$downloadedMegabytes MB / $totalMegabytes MB" -PercentComplete $percentComplete
			}
			else {
				Write-Progress -Activity '正在下载 Ubuntu 云镜像' -Status "已下载 $downloadedMegabytes MB" -PercentComplete 0
			}
		}
		Write-Progress -Activity '正在下载 Ubuntu 云镜像' -Completed
	}
	catch {
		$downloadError = $_
	}
	finally {
		if ($outputStream) {
			$outputStream.Dispose()
		}
		if ($inputStream) {
			$inputStream.Dispose()
		}
		if ($response) {
			$response.Dispose()
		}
	}
	if ($downloadError) {
		if (Test-Path -LiteralPath $temporaryPath) {
			Remove-Item -LiteralPath $temporaryPath -Force
		}
		throw $downloadError
	}
	Move-Item -LiteralPath $temporaryPath -Destination $Destination
}

function Select-CachedImage([string]$ImageDirectory) {
	$images = @(
		Get-ChildItem -LiteralPath $ImageDirectory -Filter '*.vhd' -File -ErrorAction SilentlyContinue |
			ForEach-Object {
				try {
					$vhd = Get-VHD -Path $_.FullName -ErrorAction Stop
					if ($vhd.VhdType -in 'Fixed', 'Dynamic') {
						[PSCustomObject]@{
							Path = $_.FullName
							Name = $_.Name
							VhdType = $vhd.VhdType
							SizeGB = [Math]::Round($vhd.Size / 1GB, 1)
						}
					}
					else {
						Write-Warning "已忽略无法作为父盘的缓存 VHD: $($_.Name)（类型: $($vhd.VhdType)）"
					}
				}
				catch {
					Write-Warning "已忽略无法作为父盘的缓存 VHD: $($_.Name)"
				}
			} |
			Sort-Object Name
	)
	if ($images.Count -eq 0) {
		return $null
	}

	Write-Host ''
	Write-Host '可复用的本地 Ubuntu 云镜像：'
	for ($index = 0; $index -lt $images.Count; $index++) {
		Write-Host "  [$($index + 1)] $($images[$index].Name) [$($images[$index].VhdType), $($images[$index].SizeGB) GB]"
	}
	Write-Host '直接回车将下载或选择新的 Ubuntu 版本。'
	$selection = Read-Host '请选择镜像编号'
	if ([string]::IsNullOrWhiteSpace($selection)) {
		return $null
	}
	if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $images.Count) {
		throw '镜像编号无效。'
	}
	return $images[[int]$selection - 1].Path
}

function Get-UbuntuImageInfo([string]$Version) {
	$knownImages = @{
		'24.04' = [PSCustomObject]@{
			Url = 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-azure.vhd.tar.gz'
			ChecksumsUrl = 'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS'
		}
		'22.04' = [PSCustomObject]@{
			Url = 'https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-azure.vhd.tar.gz'
			ChecksumsUrl = 'https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS'
		}
	}
	return $knownImages[$Version]
}

function Get-ExpectedSha256([string]$ChecksumsUrl, [string]$FileName) {
	$checksums = (New-Object Net.WebClient).DownloadString($ChecksumsUrl)
	$match = [regex]::Match($checksums, '(?m)^(?<checksum>[A-Fa-f0-9]{64})\s+\*?' + [regex]::Escape($FileName) + '$')
	if (-not $match.Success) {
		throw "官方 SHA256SUMS 中未找到镜像: $FileName"
	}
	return $match.Groups['checksum'].Value.ToLowerInvariant()
}

function Assert-FileSha256([string]$Path, [string]$ExpectedSha256) {
	$actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
		throw "镜像 SHA-256 校验失败。期望: $ExpectedSha256；实际: $actualSha256"
	}
}

function New-NoCloudSeedDisk(
	[string]$Path,
	[string]$UserDataPath,
	[string]$InstanceName,
	[string]$MacAddress,
	[IPAddress]$IpAddress,
	[int]$NetworkPrefixLength,
	[IPAddress]$DefaultGateway,
	[IPAddress[]]$NameServers
) {
	$macSegments = for ($index = 0; $index -lt $MacAddress.Length; $index += 2) {
		$MacAddress.Substring($index, 2)
	}
	$netplanMac = ($macSegments -join ':').ToLowerInvariant()
	$dnsYaml = ($NameServers | ForEach-Object { "                - $_" }) -join "`n"
	$networkConfig = @"
version: 2
ethernets:
  external0:
    match:
      macaddress: "$netplanMac"
    set-name: external0
    dhcp4: false
    addresses:
      - $IpAddress/$NetworkPrefixLength
    routes:
      - to: default
        via: $DefaultGateway
    nameservers:
      addresses:
$dnsYaml
"@

	New-VHD -Path $Path -Dynamic -SizeBytes 64MB | Out-Null
	$mounted = Mount-VHD -Path $Path -Passthru
	try {
		$disk = $mounted | Get-Disk
		$partition = $disk |
			Initialize-Disk -PartitionStyle GPT -PassThru |
			New-Partition -UseMaximumSize -AssignDriveLetter
		$volume = $partition |
			Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'CIDATA' -Confirm:$false
		$drive = "$($volume.DriveLetter):"
		Copy-Item -LiteralPath $UserDataPath -Destination (Join-Path $drive 'user-data')
		@(
			"instance-id: $InstanceName"
			"local-hostname: $InstanceName"
		) | Set-Content -LiteralPath (Join-Path $drive 'meta-data') -Encoding ascii
		$networkConfig | Set-Content -LiteralPath (Join-Path $drive 'network-config') -Encoding ascii
	}
	finally {
		Dismount-VHD -Path $Path
	}
}

Require-Administrator
Require-Command 'Get-VM'
Require-Command 'New-VM'
Require-Command 'New-VHD'
Require-Command 'Get-VHD'
Require-Command 'Get-VMHost'
Require-Command 'Convert-VHD'
Require-Command 'Resize-VHD'
Require-Command 'Mount-VHD'
Require-Command 'Add-VMHardDiskDrive'
Require-Command 'Start-VM'

Write-Host ''
Write-Host '=== 创建 Ubuntu Hyper-V 虚拟机 ==='
$Name = Read-Default -Prompt '虚拟机和计算机名称' -DefaultValue 'ubuntu-vm'
if ($Name -notmatch '^[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
	throw '计算机名称必须以字母开头和结尾，仅可包含字母、数字和连字符，且不超过 63 个字符。'
}
$CloudInitPath = Select-CloudInitFile -CloudInitDirectory (Join-Path $PSScriptRoot 'cloud-init')
$SshUser = Read-Default -Prompt 'SSH 登录用户' -DefaultValue 'deployer'
if ($SshUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
	throw 'SSH 登录用户名必须以小写字母或下划线开头，只能包含小写字母、数字、下划线和连字符。'
}
$SwitchName = Select-VmSwitch
$VmRoot = Read-Default -Prompt '虚拟机系统根目录（会自动创建机器名子目录）' -DefaultValue (Join-Path (Split-Path -Parent $PSScriptRoot) 'vms')
$CpuCount = Read-Integer -Prompt 'CPU 核数' -DefaultValue 2 -Minimum 1 -Maximum 64
$MemoryGB = Read-Integer -Prompt '内存（GB）' -DefaultValue 4 -Minimum 1 -Maximum 256
$DiskGB = Read-Integer -Prompt '系统磁盘（GB）' -DefaultValue 80 -Minimum 20 -Maximum 2048
$StaticIpAddress = Read-IpAddress -Prompt '固定 IPv4 地址' -DefaultValue '192.168.2.52'
$PrefixLength = Read-Integer -Prompt '子网前缀长度' -DefaultValue 24 -Minimum 1 -Maximum 32
$Gateway = Read-IpAddress -Prompt '默认网关' -DefaultValue '192.168.2.253'
$ipBytes = $StaticIpAddress.GetAddressBytes()
$gatewayBytes = $Gateway.GetAddressBytes()
if ([BitConverter]::ToString($ipBytes) -eq [BitConverter]::ToString($gatewayBytes)) {
	throw '固定 IPv4 地址不能与默认网关相同。'
}
$dnsInput = Read-Default -Prompt 'DNS 服务器（多个用逗号分隔）' -DefaultValue '114.114.114.114,8.8.8.8'
try {
	$DnsServers = @($dnsInput.Split(',') | ForEach-Object {
		$address = $_.Trim()
		if (-not $address) {
			throw 'DNS 服务器列表中存在空值。'
		}
		[IPAddress]$address
	})
}
catch {
	throw 'DNS 服务器必须是有效的 IP 地址，多个地址请用英文逗号分隔。'
}

Write-Host '[1/6] 正在生成随机网卡 MAC，并检查是否与现有虚拟机冲突。'
$existingMacAddresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
Get-VMNetworkAdapter -All | ForEach-Object { [void]$existingMacAddresses.Add($_.MacAddress) }
$StaticMacAddress = New-AvailableStaticMacAddress -ExistingMacAddresses $existingMacAddresses
$ImageCachePath = Join-Path $PSScriptRoot 'images'
$UbuntuVersion = '24.04'
$UbuntuImageUrl = $null
$checksumsUrl = $null
$expectedSha256 = $null

Write-Host '[2/6] 正在校验 cloud-init、虚拟交换机和目标虚拟机名称。'
if ([string]::IsNullOrWhiteSpace($CloudInitPath)) {
	throw '未选择 cloud-init 文件，已取消创建。'
}
$CloudInitPath = [IO.Path]::GetFullPath($CloudInitPath)
if (-not (Test-Path -LiteralPath $CloudInitPath -PathType Leaf)) {
	throw "cloud-init 文件不存在: $CloudInitPath"
}
if (-not ((Get-Content -LiteralPath $CloudInitPath -TotalCount 1) -eq '#cloud-config')) {
	throw 'cloud-init 文件第一行必须是 #cloud-config。'
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
	throw "Hyper-V 交换机不存在: $SwitchName"
}
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
	throw "Hyper-V 虚拟机已存在: $Name"
}
if ($existingMacAddresses.Contains($StaticMacAddress)) {
	throw "Hyper-V 中已有网卡使用 MAC 地址: $StaticMacAddress"
}

$vmDirectory = Join-Path $VmRoot $Name
if (Test-Path -LiteralPath $vmDirectory) {
	throw "目标目录已存在，为避免覆盖已停止: $vmDirectory"
}
if ([string]::IsNullOrWhiteSpace($ImageCachePath)) {
	$ImageCachePath = Join-Path $PSScriptRoot 'images'
}
$ImageCachePath = [IO.Path]::GetFullPath($ImageCachePath)
$osDisk = Join-Path $vmDirectory "$Name-os.vhdx"
$seedDisk = Join-Path $vmDirectory "$Name-seed.vhdx"

Write-Host '[3/6] 正在准备虚拟机目录和镜像缓存目录。'
New-Item -ItemType Directory -Force -Path $vmDirectory, $ImageCachePath | Out-Null

try {
	Write-Host '[4/6] 正在扫描本地 Ubuntu 镜像缓存。'
	$parentVhd = $null
	$parentVhd = Select-CachedImage -ImageDirectory $ImageCachePath
	if (-not $parentVhd) {
		$enteredVersion = Read-Host "Ubuntu 版本 [$UbuntuVersion]"
		if (-not [string]::IsNullOrWhiteSpace($enteredVersion)) {
			$UbuntuVersion = $enteredVersion.Trim()
		}
	}

	if (-not $parentVhd) {
		Write-Host '[5/6] 正在准备 Ubuntu 系统镜像。'
		$imageInfo = Get-UbuntuImageInfo -Version $UbuntuVersion
		if ($imageInfo) {
			$UbuntuImageUrl = $imageInfo.Url
			$checksumsUrl = $imageInfo.ChecksumsUrl
		}
		else {
			$UbuntuImageUrl = Read-Host "未内置 Ubuntu $UbuntuVersion 的下载地址，请输入官方 .vhd.tar.gz URL"
			$expectedSha256 = Read-Host '请输入该镜像的 SHA-256 校验值'
		}
		if ([string]::IsNullOrWhiteSpace($UbuntuImageUrl)) {
			throw '未提供 Ubuntu 云镜像下载地址。'
		}
		$uri = [Uri]$UbuntuImageUrl
		if ($uri.Scheme -ne 'https') {
			throw 'Ubuntu 镜像地址必须使用 HTTPS。'
		}
		$archiveName = [IO.Path]::GetFileName($uri.AbsolutePath)
		if (-not $archiveName.EndsWith('.tar.gz', [StringComparison]::OrdinalIgnoreCase)) {
			throw 'Ubuntu 镜像地址必须指向 .tar.gz 文件。'
		}
		if ([string]::IsNullOrWhiteSpace($expectedSha256) -and $checksumsUrl) {
			Write-Host '正在获取 Ubuntu 官方 SHA-256 校验值。'
			$expectedSha256 = Get-ExpectedSha256 -ChecksumsUrl $checksumsUrl -FileName $archiveName
		}
		if ($expectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
			throw '镜像 SHA-256 校验值无效。'
		}
		$archivePath = Join-Path $ImageCachePath $archiveName
		$expectedParentVhd = Join-Path $ImageCachePath ($archiveName.Substring(0, $archiveName.Length - '.tar.gz'.Length))
		if (Test-Path -LiteralPath $expectedParentVhd -PathType Leaf) {
			$parentVhd = $expectedParentVhd
		}
	}

	if (-not $parentVhd) {
		if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
			try {
				Assert-FileSha256 -Path $archivePath -ExpectedSha256 $expectedSha256
			}
			catch {
				Write-Warning '缓存的镜像压缩包校验失败，将删除后重新下载。'
				Remove-Item -LiteralPath $archivePath -Force
			}
		}
		if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
			Write-Host "正在下载 Ubuntu $UbuntuVersion 官方 Hyper-V 云镜像，首次执行约需 600 MB。"
			Download-FileWithProgress -Uri $UbuntuImageUrl -Destination $archivePath
		}
		Write-Host '正在校验 Ubuntu 云镜像 SHA-256。'
		Assert-FileSha256 -Path $archivePath -ExpectedSha256 $expectedSha256
		Write-Host '正在解压 Ubuntu 云镜像。'
		$parentVhd = Expand-UbuntuImage -ArchivePath $archivePath -ExpectedImagePath $expectedParentVhd
		(Get-Item -LiteralPath $parentVhd).IsReadOnly = $true
	}
	if (-not (Get-Item -LiteralPath $parentVhd).IsReadOnly) {
		Write-Host '正在将父镜像标记为只读。'
		(Get-Item -LiteralPath $parentVhd).IsReadOnly = $true
	}

	Write-Host '[6/6] 正在创建系统差分磁盘、cloud-init 启动盘并启动虚拟机。'
	$parentVhdInfo = Get-VHD -Path $parentVhd
	if ($parentVhdInfo.VhdType -notin 'Fixed', 'Dynamic') {
		throw "所选父盘类型不支持克隆: $($parentVhdInfo.VhdType)。请选择 Fixed 或 Dynamic 类型的 Ubuntu 云镜像。"
	}
	if (($DiskGB * 1GB) -le $parentVhdInfo.Size) {
		Write-Host '正在创建系统差分磁盘。'
		New-VHD -Path $osDisk -ParentPath $parentVhd -Differencing | Out-Null
	}
	else {
		Write-Host '目标磁盘容量大于父镜像，正在创建可扩容的动态克隆磁盘。'
		Convert-VHD -Path $parentVhd -DestinationPath $osDisk -VHDType Dynamic
		Resize-VHD -Path $osDisk -SizeBytes ($DiskGB * 1GB)
	}
	Write-Host '正在创建 cloud-init 启动盘。'
	New-NoCloudSeedDisk -Path $seedDisk -UserDataPath $CloudInitPath -InstanceName $Name `
		-MacAddress $StaticMacAddress -IpAddress $StaticIpAddress -NetworkPrefixLength $PrefixLength `
		-DefaultGateway $Gateway -NameServers $DnsServers

	Write-Host '正在创建并启动 Hyper-V 虚拟机。'
	New-VM -Name $Name -Generation 2 -Path $vmDirectory -MemoryStartupBytes ($MemoryGB * 1GB) `
		-VHDPath $osDisk -SwitchName $SwitchName | Out-Null
	Set-VMProcessor -VMName $Name -Count $CpuCount
	Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
	Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
	Set-VMNetworkAdapter -VMName $Name -StaticMacAddress $StaticMacAddress
	Add-VMHardDiskDrive -VMName $Name -Path $seedDisk
	Start-VM -Name $Name
}
catch {
	Write-Warning "创建失败；为避免误删其他任务的资源，失败现场已保留在: $vmDirectory"
	throw
}

Write-Host ''
Write-Host "虚拟机已启动: $Name"
Write-Host "External MAC: $StaticMacAddress"
Write-Host "cloud-init 完成后，请通过固定地址连接：ssh $SshUser@$StaticIpAddress"
Write-Host "查看启动状态：Get-VM -Name $Name"
