# Run the generated script in elevated, 64-bit Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$configuration = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__TSUITE_CONFIG_BASE64__')) | ConvertFrom-Json
$clientText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__TSUITE_CLIENT_BASE64__'))
. ([scriptblock]::Create($clientText)) -Mode Library

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
    -not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run in elevated 64-bit Windows PowerShell 5.1 (powershell.exe).'
}
foreach ($command in @('New-LocalUser', 'Register-ScheduledTask', 'Get-CimInstance')) {
    Get-Command $command -ErrorAction Stop | Out-Null
}

function Assert-SupportedWindowsHost {
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $build = [int]$operatingSystem.BuildNumber
    if ($operatingSystem.ProductType -eq 3) {
        if (([version]$operatingSystem.Version) -lt ([version]'10.0') -or $build -lt 14393) {
            throw 'TSuite support requires Windows Server 2016 or later; older Windows Server releases are not supported.'
        }
    } elseif ($operatingSystem.ProductType -eq 1) {
        if (([version]$operatingSystem.Version) -lt ([version]'10.0') -or $build -lt 17763) {
            throw 'TSuite support requires Windows 10 build 1809 or later, or Windows 11.'
        }
    } else {
        throw 'TSuite support does not run on Windows domain controllers.'
    }
    if ($computerSystem.DomainRole -in @(4, 5)) {
        throw 'TSuite support does not create temporary local administrators on a domain controller.'
    }
    return @{
        operating_system = $operatingSystem
        use_compatibility_openssh = ($operatingSystem.ProductType -eq 3 -and $build -lt 17763)
    }
}

$windowsHost = Assert-SupportedWindowsHost
Assert-SessionId $configuration.session_id
if ($configuration.bastion_host -cnotmatch '^[a-zA-Z0-9.-]+$' -or
    $configuration.bastion_port -lt 1 -or $configuration.bastion_port -gt 65535) {
    throw 'Invalid bastion configuration.'
}

function Get-OpenSshServicePath {
    $service = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    if (-not $service -or $service.PathName -notmatch '^\s*(?:"([^"]+)"|(\S+))') { return $null }
    if ($Matches[1]) { return $Matches[1] }
    return $Matches[2]
}

function Install-OpenSshCapability([string]$Name) {
    $capability = Get-WindowsCapability -Online -Name $Name -ErrorAction Stop
    if ($capability.State -ne 'Installed') {
        Write-Host "Installing $Name from Windows Features on Demand..."
        Add-WindowsCapability -Online -Name $Name -ErrorAction Stop | Out-Null
    }
}

function Disable-NewOpenSshFirewallRule([bool]$RuleExistedBeforeInstall) {
    if ($RuleExistedBeforeInstall) { return }
    # Adding the Windows OpenSSH Server capability creates and enables this
    # port-22 rule. This support channel starts its own sshd only on loopback,
    # so it must not leave a new public SSH listener path behind.
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($rule) { Disable-NetFirewallRule -InputObject $rule -ErrorAction Stop | Out-Null }
}

function Assert-OpenSshBinaries([string]$Directory) {
    $binaries = @{
        sshd = Join-Path $Directory 'sshd.exe'
        ssh = Join-Path $Directory 'ssh.exe'
        keygen = Join-Path $Directory 'ssh-keygen.exe'
        sftp = Join-Path $Directory 'sftp-server.exe'
    }
    foreach ($name in $binaries.Keys) {
        if (-not (Test-Path -LiteralPath $binaries[$name] -PathType Leaf)) {
            throw "OpenSSH installation is incomplete; missing $name executable: $($binaries[$name])"
        }
    }
    return $binaries
}

function Get-CompatibilityOpenSshBinaries {
    if ($configuration.windows_openssh_url -cnotmatch '^https://[a-zA-Z0-9.-]+(?:/[A-Za-z0-9._~!$&''()*+,;=:@%/-]+)+$' -or
        $configuration.windows_openssh_sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $configuration.windows_openssh_version -cnotmatch '^[A-Za-z0-9._-]{1,40}$') {
        throw 'Windows Server 2016 requires a configured, pinned OpenSSH compatibility package.'
    }
    $runtimeRoot = Join-Path $env:ProgramData 'TSuiteSupportRuntime'
    if (-not (Test-Path -LiteralPath $runtimeRoot)) { New-PrivateDirectory $runtimeRoot }
    Assert-PrivateDirectory $runtimeRoot
    $version = [string]$configuration.windows_openssh_version
    $target = Join-Path $runtimeRoot ("OpenSSH-" + $version)
    $marker = Join-Path $target 'package.sha256'
    if (Test-Path -LiteralPath $target) {
        Assert-PrivateDirectory $target
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
            (Get-Content -LiteralPath $marker -Raw).Trim() -cne $configuration.windows_openssh_sha256) {
            throw "Existing OpenSSH compatibility runtime failed integrity metadata validation: $target"
        }
        return Assert-OpenSshBinaries $target
    }

    $runtimeMutex = New-Object Threading.Mutex($false, 'Global\TSuiteSupport-OpenSSHRuntime')
    $runtimeLockAcquired = $false
    try {
        try { $runtimeLockAcquired = $runtimeMutex.WaitOne(300000) }
        catch [Threading.AbandonedMutexException] { $runtimeLockAcquired = $true }
        if (-not $runtimeLockAcquired) { throw 'Timed out waiting for another OpenSSH compatibility installation.' }
        if (Test-Path -LiteralPath $target) {
            Assert-PrivateDirectory $target
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
                (Get-Content -LiteralPath $marker -Raw).Trim() -cne $configuration.windows_openssh_sha256) {
                throw "Existing OpenSSH compatibility runtime failed integrity metadata validation: $target"
            }
            return Assert-OpenSshBinaries $target
        }

        $staging = Join-Path $runtimeRoot ('install-' + [guid]::NewGuid().ToString('N'))
        $archive = Join-Path $runtimeRoot ('download-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-PrivateDirectory $staging
        try {
            Write-Host "Installing pinned OpenSSH $version compatibility runtime for Windows Server 2016..."
            $web = New-Object Net.WebClient
            try { $web.DownloadFile([string]$configuration.windows_openssh_url, $archive) }
            finally { $web.Dispose() }
            $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -cne $configuration.windows_openssh_sha256) {
                throw 'Downloaded OpenSSH compatibility package failed SHA-256 validation.'
            }
            Expand-Archive -LiteralPath $archive -DestinationPath $staging
            $servers = @(Get-ChildItem -LiteralPath $staging -Filter 'sshd.exe' -File -Recurse)
            if ($servers.Count -ne 1) { throw 'OpenSSH compatibility package layout is invalid.' }
            $source = $servers[0].Directory.FullName
            [void](Assert-OpenSshBinaries $source)
            New-PrivateDirectory $target
            try {
                Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
                }
                [void](Assert-OpenSshBinaries $target)
                Write-Utf8 $marker ([string]$configuration.windows_openssh_sha256)
                Set-ServiceFilePermissions $marker
                Assert-PrivateDirectory $target
            } catch {
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
                throw
            }
        } finally {
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        }
    } finally {
        if ($runtimeLockAcquired) { $runtimeMutex.ReleaseMutex() }
        $runtimeMutex.Dispose()
    }
    return Assert-OpenSshBinaries $target
}

function Get-OpenSshBinaries([bool]$UseCompatibilityRuntime) {
    if ($UseCompatibilityRuntime) { return Get-CompatibilityOpenSshBinaries }
    $sshd = Get-OpenSshServicePath
    $directory = if ($sshd) { Split-Path -Parent $sshd } else { $null }
    $needsClient = -not $directory -or -not (Test-Path -LiteralPath (Join-Path $directory 'ssh.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $directory 'ssh-keygen.exe') -PathType Leaf)
    $firewallRuleExisted = [bool](Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)
    $installedServer = $false
    if (-not $sshd -or $needsClient) {
        # Supported modern Windows releases distribute OpenSSH as Features on
        # Demand. Use the OS-serviced package rather than replacing it.
        try {
            if (-not $sshd) {
                Install-OpenSshCapability 'OpenSSH.Server~~~~0.0.1.0'
                $installedServer = $true
            }
            if ($needsClient) { Install-OpenSshCapability 'OpenSSH.Client~~~~0.0.1.0' }
            if ($installedServer) { Disable-NewOpenSshFirewallRule $firewallRuleExisted }
        } catch {
            throw "Could not install Windows OpenSSH automatically. Configure Windows Update/WSUS Features on Demand, then retry: $($_.Exception.Message)"
        }
        $sshd = Get-OpenSshServicePath
    }
    if (-not $sshd) { throw 'OpenSSH Server was installed but the sshd service was not registered.' }

    return Assert-OpenSshBinaries (Split-Path -Parent $sshd)
}

function New-OpenSshTestKey([string]$KeygenPath, [string]$Path) {
    $process = Start-Process -FilePath $KeygenPath -ArgumentList (
        '-q -t ed25519 -N "" -f "{0}"' -f $Path) -PassThru -Wait -NoNewWindow
    try {
        if ($process.ExitCode -ne 0) { throw 'Could not generate a local OpenSSH authentication test key.' }
    } finally { $process.Dispose() }
}

function Test-LocalSshAuthentication(
    [string]$SshPath, [string]$KeygenPath, [string]$Directory,
    [string]$User, [int]$Port, [string]$SessionId
) {
    $authorizedKeysPath = Join-Path $Directory 'authorized_keys'
    $realAuthorizedKeys = [IO.File]::ReadAllText($authorizedKeysPath)
    $plainKey = Join-Path $Directory 'selftest_plain'
    $caKey = Join-Path $Directory 'selftest_ca'
    $certificateKey = Join-Path $Directory 'selftest_certificate'
    $knownHostsPath = Join-Path $Directory 'selftest_known_hosts'
    try {
        New-OpenSshTestKey $KeygenPath $plainKey
        New-OpenSshTestKey $KeygenPath $caKey
        New-OpenSshTestKey $KeygenPath $certificateKey
        $sign = Start-Process -FilePath $KeygenPath -ArgumentList (
            '-q -s "{0}" -I tsuite-selftest -n "{1}" -V -1m:+5m "{2}.pub"' -f `
                $caKey, $SessionId, $certificateKey) -PassThru -Wait -NoNewWindow
        try {
            if ($sign.ExitCode -ne 0) { throw 'Could not generate a local OpenSSH authentication test certificate.' }
        } finally { $sign.Dispose() }

        $plainPublic = ((Get-Content -LiteralPath "$plainKey.pub" -Raw).Trim() -split '\s+')[0..1] -join ' '
        $caPublic = ((Get-Content -LiteralPath "$caKey.pub" -Raw).Trim() -split '\s+')[0..1] -join ' '
        $testExpiry = [DateTimeOffset]::UtcNow.AddMinutes(10).UtcDateTime.ToString('yyyyMMddHHmmssZ')
        $testKeys = (
            'expiry-time="{0}",from="127.0.0.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc {1}' -f `
                $testExpiry, $plainPublic) + "`n" + (
            'cert-authority,principals="{0}",expiry-time="{1}",from="127.0.0.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc {2}' -f `
                $SessionId, $testExpiry, $caPublic)
        Write-Utf8 $authorizedKeysPath $testKeys
        Set-ServiceFilePermissions $authorizedKeysPath
        $hostPublic = ((Get-Content -LiteralPath (Join-Path $Directory 'ssh_host_ed25519_key.pub') -Raw).Trim() -split '\s+')[0..1] -join ' '
        Write-Utf8 $knownHostsPath ("[127.0.0.1]:$Port $hostPublic`n")

        foreach ($identity in @($plainKey, $certificateKey)) {
            $output = & $SshPath -F none -T -i $identity -o IdentitiesOnly=yes -o BatchMode=yes `
                -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$knownHostsPath" `
                -o ClearAllForwardings=yes -o ConnectTimeout=10 -p $Port "$User@127.0.0.1" `
                'cmd.exe /d /c exit 0' 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Local OpenSSH public-key/certificate authentication self-test failed: $($output -join ' ')"
            }
        }
    } finally {
        Write-Utf8 $authorizedKeysPath $realAuthorizedKeys
        Set-ServiceFilePermissions $authorizedKeysPath
        foreach ($path in @(
            $plainKey, "$plainKey.pub", $caKey, "$caKey.pub", $certificateKey,
            "$certificateKey.pub", "$certificateKey-cert.pub", $knownHostsPath
        )) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

function Stop-SessionSshdForDiagnostics([string]$Id, [string]$SshdPath, [string]$ConfigPath) {
    Stop-ScheduledTask -TaskName "TSuiteSupport-$Id-Sshd" -ErrorAction SilentlyContinue
    foreach ($process in Get-CimInstance Win32_Process) {
        if ($process.Name -ine 'sshd.exe' -or -not $process.CommandLine -or
            $process.ExecutablePath -ine $SshdPath -or -not $process.CommandLine.Contains($ConfigPath)) { continue }
        & "$env:SystemRoot\System32\taskkill.exe" /PID $process.ProcessId /T /F | Out-Null
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $running = @(Get-CimInstance Win32_Process | Where-Object {
            $_.Name -ieq 'sshd.exe' -and $_.ExecutablePath -ieq $SshdPath -and
            $_.CommandLine -and $_.CommandLine.Contains($ConfigPath)
        })
        if ($running.Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    }
    throw 'Could not stop the session SSH listener before collecting diagnostics.'
}

$openSsh = Get-OpenSshBinaries ([bool]$windowsHost.use_compatibility_openssh)
$sshdPath = $openSsh.sshd
$sshPath = $openSsh.ssh
$keygenPath = $openSsh.keygen
$sftpPath = $openSsh.sftp

function Invoke-Enrollment([string]$Action, $Request) {
    $json = $Request | ConvertTo-Json -Compress
    $result = $json | & $sshPath -F none -T -i (Join-Path $temporary 'enrollment_key') `
        -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes `
        -o "UserKnownHostsFile=$temporary\known_hosts" -o ClearAllForwardings=yes `
        -o ConnectTimeout=15 -p $configuration.bastion_port "tsuite-enroll@$($configuration.bastion_host)" $Action
    if ($LASTEXITCODE -ne 0) { throw 'Session enrollment failed; create a new session if its code was consumed.' }
    return ($result -join "`n" | ConvertFrom-Json)
}

$root = Get-SupportRoot
$id = $configuration.session_id
$directory = Join-Path $root $id
$opsUser = "tsuite-ops-$($id.Substring(0, 8))"
$mutex = Enter-SupportLock $id
try {
    if ((Test-Path -LiteralPath $directory) -or (Get-LocalUser -Name $opsUser -ErrorAction SilentlyContinue)) {
        throw 'This session already has local resources. Close/clean it before retrying; nothing was overwritten.'
    }
    foreach ($mode in @('Sshd', 'Tunnel', 'Monitor', 'Cleanup')) {
        if (Get-ScheduledTask -TaskName "TSuiteSupport-$id-$mode" -ErrorAction SilentlyContinue) {
            throw 'A task with this session ID already exists. Clean up the previous installation first.'
        }
    }
    $temporary = Join-Path $root ('enroll-' + [guid]::NewGuid().ToString('N'))
    New-PrivateDirectory $temporary
    $installed = $false
    $stateWritten = $false
    $directoryCreated = $false
    try {
        $knownHost = $configuration.bastion_host
        if ($configuration.bastion_port -ne 22) { $knownHost = '[{0}]:{1}' -f $knownHost, $configuration.bastion_port }
        $knownHosts = "$knownHost $($configuration.bastion_host_key)`n"
        Write-Utf8 (Join-Path $temporary 'known_hosts') $knownHosts
        Write-Utf8 (Join-Path $temporary 'enrollment_key') $configuration.enrollment_private_key
        $hostKeyPath = Join-Path $temporary 'ssh_host_ed25519_key'
        $keygen = Start-Process -FilePath $keygenPath -ArgumentList (
            '-q -t ed25519 -N "" -f "{0}"' -f $hostKeyPath) -PassThru -Wait -NoNewWindow
        if ($keygen.ExitCode -ne 0) { throw 'Could not generate the session SSH host key.' }
        $keygen.Dispose()
        $hostKey = ((Get-Content -LiteralPath "$hostKeyPath.pub" -Raw).Trim() -split '\s+')[0..1] -join ' '
        # Possession of this session's forced-command enrollment key authenticates enrollment.
        $payload = Invoke-Enrollment 'enroll' @{
            nonce = [guid]::NewGuid().ToString('N'); customer_host_key = $hostKey
        }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($payload.schema_version -ne 2 -or $payload.platform -cne 'windows' -or $payload.session_id -cne $id -or
            $payload.bastion_host -cne $configuration.bastion_host -or $payload.bastion_port -ne $configuration.bastion_port -or
            $payload.bastion_host_key -cne $configuration.bastion_host_key -or
            $payload.tunnel_user -cne "tsuite-tunnel-$($id.Substring(0, 8))" -or
            $payload.remote_port -lt 1024 -or $payload.remote_port -gt 65535 -or
            $payload.expires_at -le $now -or $payload.expires_at -gt ($now + 28800) -or
            $payload.operator_public_key -cnotmatch '^(ssh-ed25519|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+$' -or
            $payload.idle_timeout_seconds -lt 300 -or $payload.idle_timeout_seconds -gt 28800 -or
            -not $payload.lease_private_key.StartsWith("-----BEGIN OPENSSH PRIVATE KEY-----`n") -or
            -not $payload.tunnel_private_key.StartsWith("-----BEGIN OPENSSH PRIVATE KEY-----`n")) {
            throw 'Invalid enrollment response.'
        }
        New-PrivateDirectory $directory
        $directoryCreated = $true
        # Reserve an OS-assigned loopback port; sshd will fail closed if another process takes it meanwhile.
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $localPort = $listener.LocalEndpoint.Port
        $listener.Stop()
        $state = @{
            session_id = $id; ops_user = $opsUser; expires_at = $payload.expires_at
            portable_operator = ($payload.portable_operator -eq $true)
            idle_timeout_seconds = $payload.idle_timeout_seconds
            bastion_host = $payload.bastion_host; bastion_port = $payload.bastion_port
            remote_port = $payload.remote_port; local_port = $localPort; tunnel_user = $payload.tunnel_user
            ssh_path = $sshPath; sshd_path = $sshdPath; sftp_path = $sftpPath
        }
        Write-Utf8 (Join-Path $directory 'session.json') ($state | ConvertTo-Json -Compress)
        $stateWritten = $true
        Write-Utf8 (Join-Path $directory 'client.ps1') $clientText
        Write-Utf8 (Join-Path $directory 'known_hosts') $knownHosts
        Write-Utf8 (Join-Path $directory 'tunnel_ed25519') $payload.tunnel_private_key
        Write-Utf8 (Join-Path $directory 'lease_ed25519') $payload.lease_private_key
        Move-Item -LiteralPath $hostKeyPath -Destination $directory
        $expiry = [DateTimeOffset]::FromUnixTimeSeconds([long]$payload.expires_at)
        $keyExpiry = $expiry.UtcDateTime.ToString('yyyyMMddHHmmssZ')
        Write-Utf8 (Join-Path $directory 'authorized_keys') (
            'expiry-time="{0}",from="127.0.0.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc {1}' -f `
                $keyExpiry, $payload.operator_public_key)
        if ($payload.portable_operator -eq $true) {
            $keysPath = Join-Path $directory 'authorized_keys'
            $keys = [IO.File]::ReadAllText($keysPath)
            $keys += "`n" + ('cert-authority,principals="{0}",expiry-time="{1}",from="127.0.0.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc {2}' -f $id, $keyExpiry, $payload.operator_public_key)
            Write-Utf8 $keysPath $keys
        }
        # Isolated sshd: no shared administrators_authorized_keys or changes to the existing sshd service.
        $sshDirectoryPath = $directory.Replace('\', '/')
        $sshdConfiguration = @"
    ListenAddress 127.0.0.1
    Port $localPort
    HostKey "$sshDirectoryPath/ssh_host_ed25519_key"
    AuthorizedKeysFile "$sshDirectoryPath/authorized_keys"
    AllowUsers $opsUser
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    PermitEmptyPasswords no
    AllowTcpForwarding no
    AllowAgentForwarding no
    LogLevel VERBOSE
    Subsystem sftp "$($sftpPath.Replace('\', '/'))"
"@
        Write-Utf8 (Join-Path $directory 'sshd_config') $sshdConfiguration
        foreach ($serviceFile in @('ssh_host_ed25519_key', 'tunnel_ed25519', 'lease_ed25519', 'authorized_keys', 'sshd_config')) {
            Set-ServiceFilePermissions (Join-Path $directory $serviceFile)
        }
        & $sshdPath -t -f (Join-Path $directory 'sshd_config')
        if ($LASTEXITCODE -ne 0) { throw 'Session sshd configuration validation failed.' }
        # Install expiry cleanup before granting privileges; account and key also expire natively.
        Register-SupportTask $id 'Cleanup' $expiry.LocalDateTime
        $random = New-Object byte[] 48
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($random)
        $rng.Dispose()
        $password = ConvertTo-SecureString ('Aa1!' + [Convert]::ToBase64String($random)) -AsPlainText -Force
        $user = New-LocalUser -Name $opsUser -Password $password -AccountExpires $expiry.LocalDateTime `
            -UserMayNotChangePassword -Description "TSuite temporary support $id"
        $password.Dispose()
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $user
        Register-SupportTask $id 'Sshd' $expiry.LocalDateTime
        Register-SupportTask $id 'Tunnel' $expiry.LocalDateTime
        Register-SupportTask $id 'Monitor' $expiry.LocalDateTime
        Start-ScheduledTask -TaskName "TSuiteSupport-$id-Sshd"
        $ready = $false
        for ($attempt = 0; $attempt -lt 15; $attempt++) {
            $connection = New-Object Net.Sockets.TcpClient
            try { $connection.Connect('127.0.0.1', $localPort); $ready = $true; break }
            catch { Start-Sleep -Seconds 1 }
            finally { $connection.Dispose() }
        }
        if (-not $ready) {
            try { Save-StartupDiagnostics $id }
            catch { Write-Warning ('Could not save startup diagnostics: ' + $_.Exception.Message) }
            throw 'The temporary SSH listener failed to start. See the startup diagnostics above.'
        }
        try {
            Test-LocalSshAuthentication $sshPath $keygenPath $directory $opsUser $localPort $id
        } catch {
            $authenticationError = $_
            try { Stop-SessionSshdForDiagnostics $id $sshdPath (Join-Path $directory 'sshd_config') }
            catch { Write-Warning ('Could not stop the SSH listener for diagnostics: ' + $_.Exception.Message) }
            try { Save-StartupDiagnostics $id }
            catch { Write-Warning ('Could not save authentication diagnostics: ' + $_.Exception.Message) }
            throw $authenticationError
        }
        Start-ScheduledTask -TaskName "TSuiteSupport-$id-Tunnel"
        Start-ScheduledTask -TaskName "TSuiteSupport-$id-Monitor"
        if ([DateTimeOffset]::UtcNow -ge $expiry) { throw 'Session expired during installation.' }
        $installed = $true
        Write-Host "Support session $id started; idle expiry $($expiry.LocalDateTime), extended during activity. Check the support page for connectivity."
    } finally {
        $configuration = $null
        $payload = $null
        Complete-SupportBootstrap $temporary $directory $id $installed $stateWritten $directoryCreated
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
