# Exercise the Windows support client's real OpenSSH 8.1 authentication shape.
param(
    [Parameter(Mandatory=$true)][string]$OpenSshDirectory,
    [switch]$CompatibilityRuntime
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'customer/windows-client.ps1') -Mode Library

$sshd = Join-Path $OpenSshDirectory 'sshd.exe'
$ssh = Join-Path $OpenSshDirectory 'ssh.exe'
$keygen = Join-Path $OpenSshDirectory 'ssh-keygen.exe'
foreach ($path in @($sshd, $ssh, $keygen)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing OpenSSH test binary: $path" }
}

$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$userName = "tsuite-ci-$id"
$root = Join-Path $env:ProgramData "TSuiteSupportAuthTest-$id"
$hostKey = Join-Path $root 'ssh_host_ed25519_key'
$clientKey = Join-Path $root 'client_ed25519'
$authorizedKeys = Join-Path $root 'authorized_keys'
$config = Join-Path $root 'sshd_config'
$log = Join-Path $root 'sshd.log'
$process = $null
$user = $null
try {
    New-PrivateDirectory $root
    foreach ($path in @($hostKey, $clientKey)) {
        $keygenProcess = Start-Process -FilePath $keygen -ArgumentList (
            '-q -t ed25519 -N "" -f "{0}"' -f $path) -PassThru -Wait -NoNewWindow
        try {
            if ($keygenProcess.ExitCode -ne 0) { throw "Could not generate test key: $path" }
        } finally { $keygenProcess.Dispose() }
    }
    $publicKey = ((Get-Content -LiteralPath "$clientKey.pub" -Raw).Trim() -split '\s+')[0..1] -join ' '
    $expiry = Format-WindowsOpenSshExpiry ([DateTimeOffset]::UtcNow.AddMinutes(10))
    Write-Utf8 $authorizedKeys ('expiry-time="{0}",from="127.0.0.1",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc {1}' -f $expiry, $publicKey)

    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $rootForSsh = $root.Replace('\', '/')
    $runtimeOptions = Get-WindowsSshdRuntimeOptions ([bool]$CompatibilityRuntime) $rootForSsh
    Write-Utf8 $config @"
ListenAddress 127.0.0.1
Port $port
HostKey "$rootForSsh/ssh_host_ed25519_key"
AuthorizedKeysFile "$rootForSsh/authorized_keys"
AllowUsers $userName
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
AllowTcpForwarding no
AllowAgentForwarding no
StrictModes yes
$runtimeOptions
"@
    foreach ($path in @($hostKey, $authorizedKeys, $config)) { Set-ServiceFilePermissions $path }

    $random = New-Object byte[] 48
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
    $password = ConvertTo-SecureString ('Aa1!' + [Convert]::ToBase64String($random)) -AsPlainText -Force
    $user = New-LocalUser -Name $userName -Password $password -UserMayNotChangePassword
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $user

    & $sshd -t -f $config
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSH 8.1 rejected the support sshd configuration.' }
    $process = Start-Process -FilePath $sshd -ArgumentList ('-D -E "{0}" -f "{1}"' -f $log, $config) -PassThru -NoNewWindow
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $connection = New-Object Net.Sockets.TcpClient
        try { $connection.Connect('127.0.0.1', $port); break }
        catch { Start-Sleep -Milliseconds 200 }
        finally { $connection.Dispose() }
    }
    if ($CompatibilityRuntime) {
        # OpenSSH 9.8 counts bare readiness probes as no-auth penalties. Make
        # the production failure deterministic before testing authentication.
        foreach ($probe in 1..16) {
            $connection = New-Object Net.Sockets.TcpClient
            try { $connection.Connect('127.0.0.1', $port) }
            finally { $connection.Dispose() }
        }
    }
    & $ssh -F none -T -i $clientKey -o IdentitiesOnly=yes -o BatchMode=yes `
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 `
        -p $port "$userName@127.0.0.1" 'cmd.exe /d /c exit 0'
    $sshExitCode = $LASTEXITCODE
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $nativeLog = Get-Content -LiteralPath $log -Raw
    if ($nativeLog -match 'Couldn.t create pid file') {
        Write-Output $nativeLog
        throw 'Portable sshd fell back to an unusable package-default PID path.'
    }
    # A foreground sshd on CI is elevated but not SYSTEM, so Win32-OpenSSH
    # cannot create the user token after authentication. Production starts
    # sshd as SYSTEM; the regression signal here is key acceptance itself.
    if ($sshExitCode -ne 0 -and $nativeLog -notmatch 'Accepted publickey for ') {
        Write-Output $nativeLog
        throw 'OpenSSH 8.1 rejected the support client public key.'
    }
    $global:LASTEXITCODE = 0
    Write-Output 'OpenSSH 8.1 support authentication passed.'
} finally {
    if ($process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    if ($user) { Remove-LocalUser -SID $user.SID -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
