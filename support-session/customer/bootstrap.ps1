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
    if ($operatingSystem.ProductType -ne 3 -or
        ([version]$operatingSystem.Version) -lt ([version]'10.0.17763')) {
        throw 'TSuite support requires Windows Server 2019 or later.'
    }
    if ($computerSystem.DomainRole -in @(4, 5)) {
        throw 'TSuite support does not create temporary local administrators on a domain controller.'
    }
}

Assert-SupportedWindowsHost
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

function Get-OpenSshBinaries {
    $sshd = Get-OpenSshServicePath
    $directory = if ($sshd) { Split-Path -Parent $sshd } else { $null }
    $needsClient = -not $directory -or -not (Test-Path -LiteralPath (Join-Path $directory 'ssh.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $directory 'ssh-keygen.exe') -PathType Leaf)
    $firewallRuleExisted = [bool](Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)
    $installedServer = $false
    if (-not $sshd -or $needsClient) {
        # Windows Server 2019+ distributes OpenSSH as Features on Demand.  Use the
        # OS package rather than downloading an unpinned third-party archive.
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

    $directory = Split-Path -Parent $sshd
    $binaries = @{
        sshd = $sshd
        ssh = Join-Path $directory 'ssh.exe'
        keygen = Join-Path $directory 'ssh-keygen.exe'
        sftp = Join-Path $directory 'sftp-server.exe'
    }
    foreach ($name in $binaries.Keys) {
        if (-not (Test-Path -LiteralPath $binaries[$name] -PathType Leaf)) {
            throw "OpenSSH installation is incomplete; missing $name executable: $($binaries[$name])"
        }
    }
    return $binaries
}

$openSsh = Get-OpenSshBinaries
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
