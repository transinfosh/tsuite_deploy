# Native support operator: Windows PowerShell 5.1 / PowerShell 7 + OpenSSH Client.
[CmdletBinding()]
param(
    [ValidateSet('Library', 'Claim', 'Resume', 'Watch')]
    [string]$Mode = 'Claim',
    [string]$GrantJson,
    [string]$Command
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSCommandPath -and -not (Get-Variable -Name ClientSource -Scope Script -ErrorAction SilentlyContinue)) {
    $script:ClientSource = [IO.File]::ReadAllText($PSCommandPath)
    $script:RelaySource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tsuite_support_windows_relay.cs'))
}

function Assert-OperatorId([string]$Value) {
    if ($Value -cnotmatch '\A[a-f0-9]{12}\z') { throw 'Invalid session ID.' }
}

function Get-OperatorProperty($Object, [string]$Name) {
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.$Name
}

function Test-OperatorInteger($Value) { return ($Value -is [int] -or $Value -is [long]) }

function Get-OperatorTime { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Get-OperatorUserSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Get-OperatorParent {
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TSuiteSupport/portable')
}

function Assert-OperatorPath([string]$Path) {
    # ProxyCommand is executed by Win32 OpenSSH's command shell; do not permit expansion.
    if ($Path.IndexOfAny([char[]]"%!`"`r`n") -ge 0) { throw 'Unsupported characters in the support directory path.' }
    $item = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $item) {
        if ($item.Exists -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Support directories must not traverse a reparse point.'
        }
        $item = $item.Parent
    }
}

function Set-OperatorDirectoryPermissions([string]$Path) {
    Assert-OperatorPath $Path
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($user)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $user, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-OperatorDirectoryPermissions([string]$Path) {
    Assert-OperatorPath $Path
    $user = Get-OperatorUserSid
    foreach ($item in @((Get-Item -LiteralPath $Path)) + @(Get-ChildItem -LiteralPath $Path -Force -Recurse)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected support reparse point.' }
        $acl = Get-Acl -LiteralPath $item.FullName
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $user) {
            throw 'Support credentials have an unexpected owner.'
        }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -ne $user) {
                throw 'Support credentials are accessible by another identity.'
            }
        }
    }
}

function Set-OperatorFilePermissions([string]$Path) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner($user)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-OperatorFile([string]$Path, [string]$Value) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        # The BOM lets Windows PowerShell 5.1 read saved non-ASCII source correctly.
        $encoding = New-Object Text.UTF8Encoding($Path.EndsWith('.ps1'))
        $writer = New-Object IO.StreamWriter($stream, $encoding)
        try { $writer.Write($Value) } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
    # Elevated tokens may default new files to Administrators ownership even
    # inside our user-only directory. Normalize metadata as well as keygen files.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Set-OperatorFilePermissions $Path
    }
}

function Save-OperatorLease([string]$Root, $Settings) {
    $temporary = Join-Path $Root ('session-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-OperatorFile $temporary ($Settings | ConvertTo-Json -Compress)
        [TSuiteSupport.WindowsRelay]::ReplaceFile($temporary, (Join-Path $Root 'session.json'))
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Initialize-OperatorRelay {
    if ('TSuiteSupport.WindowsRelay' -as [type]) { return }
    if (Get-Variable -Name RelaySource -Scope Script -ErrorAction SilentlyContinue) {
        $source = $script:RelaySource
    } else {
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tsuite_support_windows_relay.cs'))
    }
    Add-Type -TypeDefinition $source
}

function Get-OperatorTools {
    $ssh = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $ssh) { throw 'Install the Windows OpenSSH Client optional feature first (ssh.exe and ssh-keygen.exe).' }
    $keygen = Join-Path (Split-Path -Parent $ssh.Source) 'ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $keygen)) { throw 'ssh-keygen.exe must be installed beside ssh.exe.' }
    Assert-OperatorPath (Split-Path -Parent $ssh.Source)
    return [pscustomobject]@{ Ssh = $ssh.Source; Keygen = $keygen }
}

function Request-OperatorClaim($Grant, [string]$PublicKey) {
    $uri = $null
    if (-not [uri]::TryCreate([string](Get-OperatorProperty $Grant 'url'), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -cne '/support') { throw 'Invalid authorization URL.' }
    $request = [Net.HttpWebRequest]::Create($uri.AbsoluteUri + '/operator-claim')
    $request.Method = 'POST'
    $request.ContentType = 'application/json'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{
        id = $Grant.id; token = $Grant.token; public_key = $PublicKey
    } | ConvertTo-Json -Compress))
    $request.ContentLength = $bytes.Length
    $response = $null
    try {
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { throw 'Authorization failed.' }
        $stream = $response.GetResponseStream()
        try {
            $buffer = New-Object byte[] 32769
            $length = 0
            do {
                $count = $stream.Read($buffer, $length, $buffer.Length - $length)
                $length += $count
            } while ($count -gt 0 -and $length -lt $buffer.Length)
            if ($length -gt 32768) { throw 'Authorization response too large.' }
            return ([Text.Encoding]::UTF8.GetString($buffer, 0, $length) | ConvertFrom-Json)
        } finally { $stream.Dispose() }
    } catch {
        # Never print HTTP bodies, URLs from errors, or the bearer grant.
        throw 'Unable to claim authorization. Check connectivity and whether the grant was already used or expired.'
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Assert-OperatorSettings($Settings, [string]$Id, [switch]$Claim) {
    $port = Get-OperatorProperty $Settings 'port'
    $expiry = Get-OperatorProperty $Settings 'expires_at'
    if ((Get-OperatorProperty $Settings 'id') -cne $Id -or
        (Get-OperatorProperty $Settings 'host') -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z' -or
        (Get-OperatorProperty $Settings 'user') -cne 'tsuite-operator' -or
        -not (Test-OperatorInteger $port) -or $port -lt 1 -or $port -gt 65535 -or
        -not (Test-OperatorInteger $expiry) -or $expiry -le 0) { throw 'Invalid authorization metadata.' }
    if ($Claim) {
        $hosts = Get-OperatorProperty $Settings 'known_hosts'
        if ((Get-OperatorProperty $Settings 'certificate') -cnotmatch '\Assh-ed25519-cert-v01@openssh.com [A-Za-z0-9+/=]+(?: [^\r\n]*)?\z' -or
            $hosts -isnot [string] -or -not $hosts.Trim() -or $hosts.Contains([char]0)) {
            throw 'Invalid authorization trust data.'
        }
    }
}

function Get-OperatorSshOptions([string]$Root) {
    # SSH's own config parser also needs quoted filenames, separately from CRT quoting.
    $path = $Root.Replace('\', '/')
    return @('-F', 'none', '-i', "$path/identity", '-o', "CertificateFile=`"$path/identity-cert.pub`"",
        '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'GlobalKnownHostsFile=none', '-o', 'ClearAllForwardings=yes', '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3')
}

function Get-OperatorEdgeArguments([string]$Root, $Settings) {
    $path = $Root.Replace('\', '/')
    # Keep nested SSH config quotes out of ProxyCommand's Windows shell command line.
    $config = @"
Host tsuite-edge
    HostName $($Settings.host)
    User $($Settings.user)
    Port $($Settings.port)
    IdentityFile "$path/identity"
    CertificateFile "$path/identity-cert.pub"
    UserKnownHostsFile "$path/edge_known_hosts"
    GlobalKnownHostsFile none
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking yes
    ClearAllForwardings yes
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 3
"@
    $file = Join-Path $Root 'edge_config'
    if (Test-Path -LiteralPath $file) {
        if ([IO.File]::ReadAllText($file) -cne $config) { throw 'Edge connection configuration changed.' }
    } else { Write-OperatorFile $file $config }
    return @('-F', "$path/edge_config", '-T', 'tsuite-edge')
}

function Get-OperatorStatus([string]$Root, $Settings, $Tools) {
    $arguments = @((Get-OperatorEdgeArguments $Root $Settings)) + @('show', $Settings.id)
    $result = [TSuiteSupport.WindowsRelay]::Capture($Tools.Ssh, [string[]]$arguments, 20000)
    if ($result.ExitCode -ne 0) {
        if ($result.Error.Contains('Permission denied (publickey')) {
            throw [UnauthorizedAccessException]::new('Session authorization was revoked or expired.')
        }
        throw 'Unable to connect to Edge. Check connectivity and the support page.'
    }
    $remote = $result.Output | ConvertFrom-Json
    if ((Get-OperatorProperty $remote 'id') -cne $Settings.id -or
        -not (Test-OperatorInteger (Get-OperatorProperty $remote 'expires_at'))) { throw 'Invalid session status.' }
    return $remote
}

function Wait-OperatorCustomer([string]$Root, $Settings, $Tools) {
    [Console]::Error.WriteLine('Waiting for the customer to connect...')
    while ($true) {
        $remote = Get-OperatorStatus $Root $Settings $Tools
        if ($remote.status -notin @('issued', 'enrolled') -or (Get-OperatorTime) -ge $remote.expires_at) {
            throw [UnauthorizedAccessException]::new('Session ended or expired.')
        }
        if ($remote.status -eq 'enrolled' -and (Get-OperatorProperty $remote 'tunnel_reachable') -eq $true) {
            $port = Get-OperatorProperty $remote 'remote_port'
            if ((Get-OperatorProperty $remote 'customer_host_key') -cnotmatch '\A(?:ssh-ed25519|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+\z' -or
                -not (Test-OperatorInteger $port) -or $port -lt 1024 -or $port -gt 65535 -or
                (Get-OperatorProperty $remote 'platform') -cnotin @('linux', 'windows')) { throw 'Invalid customer metadata.' }
            return $remote
        }
        Start-Sleep -Seconds 3
    }
}

function Get-OperatorCustomerArguments([string]$Root, $Settings, $Remote, $Tools) {
    $hostLine = "[127.0.0.1]:$($Remote.remote_port) $($Remote.customer_host_key)`n"
    $hosts = Join-Path $Root 'customer_known_hosts'
    if (Test-Path -LiteralPath $hosts) {
        if ([IO.File]::ReadAllText($hosts) -cne $hostLine) { throw 'Customer host key changed. Connection refused.' }
    } else { Write-OperatorFile $hosts $hostLine }
    $edge = @((Get-OperatorEdgeArguments $Root $Settings)) + @('proxy', $Settings.id)
    $proxy = [TSuiteSupport.WindowsRelay]::Quote($Tools.Ssh) + ' ' + [TSuiteSupport.WindowsRelay]::Arguments([string[]]$edge)
    $path = $hosts.Replace('\', '/')
    return @((Get-OperatorSshOptions $Root)) + @('-o', "UserKnownHostsFile=`"$path`"", '-o', "ProxyCommand=$proxy",
        '-p', [string]$Remote.remote_port, "tsuite-ops-$($Settings.id.Substring(0, 8))@127.0.0.1")
}

function ConvertTo-OperatorRemoteCommand([string]$Platform, [string]$Value) {
    if ($Platform -eq 'windows') {
        return 'powershell.exe -NoProfile -NonInteractive -EncodedCommand ' +
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Value))
    }
    return $Value
}

function Get-OperatorActivityCommand([string]$Platform, [string]$Id) {
    Assert-OperatorId $Id
    if ($Platform -eq 'windows') {
        return ConvertTo-OperatorRemoteCommand 'windows' (
            "& (Join-Path `$env:ProgramData 'TSuiteSupport/$Id/client.ps1') -Mode Activity -SessionId '$Id'")
    }
    return 'sudo -n /usr/local/sbin/tsuite-support-client activity'
}

function Remove-OperatorSession([string]$Root) {
    Assert-OperatorPath $Root
    if (Test-Path -LiteralPath $Root) {
        Assert-OperatorDirectoryPermissions $Root
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}

function Watch-OperatorSession([string]$Root, $Settings, $Tools) {
    $user = Get-OperatorUserSid
    $mutex = New-Object Threading.Mutex($false, "Local\TSuiteSupportOperatorWatch-$user-$($Settings.id)")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { return }
        $deadline = $Settings.expires_at
        while (Test-Path -LiteralPath $Root) {
            try {
                $remote = Get-OperatorStatus $Root $Settings $Tools
                if ($remote.status -notin @('issued', 'enrolled')) { Remove-OperatorSession $Root; return }
                $deadline = $remote.expires_at
                $Settings.expires_at = $deadline
                Save-OperatorLease $Root $Settings
            } catch [UnauthorizedAccessException] { Remove-OperatorSession $Root; return }
            catch { } # A network failure must never create a new local lease.
            if ((Get-OperatorTime) -ge $deadline) { Remove-OperatorSession $Root; return }
            Start-Sleep -Seconds ([Math]::Min(30, [Math]::Max(1, $deadline - (Get-OperatorTime))))
        }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Start-OperatorWatcher([string]$Root) {
    $executable = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'support.ps1'), '-Mode', 'Watch')
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = [TSuiteSupport.WindowsRelay]::Arguments([string[]]$arguments)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    $process.Dispose()
}

function New-OperatorSession([string]$Json, $Tools) {
    if ($Json.Length -gt 8192) { throw 'Invalid grant size.' }
    try { $grant = $Json | ConvertFrom-Json } catch { throw 'Invalid grant JSON.' }
    Assert-OperatorId (Get-OperatorProperty $grant 'id')
    if ((Get-OperatorProperty $grant 'token') -cnotmatch '\A[A-Za-z0-9_-]{43}\z') { throw 'Invalid authorization grant.' }
    $parent = Get-OperatorParent
    foreach ($directory in @((Split-Path -Parent $parent), $parent)) {
        Assert-OperatorPath $directory
        [void][IO.Directory]::CreateDirectory($directory)
        Set-OperatorDirectoryPermissions $directory
    }
    $root = Join-Path $parent $grant.id
    $user = Get-OperatorUserSid
    $mutex = New-Object Threading.Mutex($false, "Local\TSuiteSupportOperatorClaim-$user-$($grant.id)")
    $acquired = $false
    $created = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another process is claiming this session.' }
        Assert-OperatorPath $root
        if (Test-Path -LiteralPath $root) { throw 'This session directory already exists. Use its -Mode Resume command.' }
        [TSuiteSupport.WindowsRelay]::CreateSessionDirectory($root)
        $created = $true
        Set-OperatorDirectoryPermissions $root
        $result = [TSuiteSupport.WindowsRelay]::Capture($Tools.Keygen,
            [string[]]@('-q', '-t', 'ed25519', '-N', '', '-f', (Join-Path $root 'identity')), 20000)
        if ($result.ExitCode -ne 0) { throw 'Unable to generate the local SSH identity.' }
        # Win32 keygen may install explicit SYSTEM/Administrators grants; normalize them too.
        Set-OperatorFilePermissions (Join-Path $root 'identity')
        Set-OperatorFilePermissions (Join-Path $root 'identity.pub')
        $publicKey = (([IO.File]::ReadAllText((Join-Path $root 'identity.pub')) -split '\s+')[0..1] -join ' ')
        $settings = Request-OperatorClaim $grant $publicKey
        Assert-OperatorSettings $settings $grant.id -Claim
        Write-OperatorFile (Join-Path $root 'identity-cert.pub') ($settings.certificate + "`n")
        Write-OperatorFile (Join-Path $root 'edge_known_hosts') $settings.known_hosts
        $settings.PSObject.Properties.Remove('certificate')
        $settings.PSObject.Properties.Remove('known_hosts')
        Write-OperatorFile (Join-Path $root 'session.json') ($settings | ConvertTo-Json -Compress)
        $null = Get-OperatorEdgeArguments $root $settings
        if (Get-Variable -Name ClientSource -Scope Script -ErrorAction SilentlyContinue) {
            $source = $script:ClientSource
            $relay = $script:RelaySource
        } else {
            $source = [IO.File]::ReadAllText($PSCommandPath)
            $relay = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tsuite_support_windows_relay.cs'))
        }
        Write-OperatorFile (Join-Path $root 'support.ps1') $source
        Write-OperatorFile (Join-Path $root 'tsuite_support_windows_relay.cs') $relay
        Assert-OperatorDirectoryPermissions $root
        return [pscustomobject]@{ Root = $root; Settings = $settings }
    } catch {
        # Never remove another invocation's existing claimed identity.
        if ($created) { Remove-OperatorSession $root }
        throw
    } finally {
        $grant = $null
        $Json = $null
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-OperatorMain {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess -or
        [Environment]::OSVersion.Version.Build -lt 17763) {
        throw 'Use 64-bit PowerShell on Windows 10 1809+, Windows 11, or Windows Server 2019+.'
    }
    Initialize-OperatorRelay
    $tools = Get-OperatorTools
    $root = $null
    try {
        if ($Mode -eq 'Claim') {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            try { $session = New-OperatorSession $GrantJson $tools } finally { $script:GrantJson = $null }
            $root = $session.Root
            $settings = $session.Settings
            [Console]::Error.WriteLine("Authorization claimed. Reconnect using:`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File '" +
                (Join-Path $root 'support.ps1').Replace("'", "''") + "' -Mode Resume`nFor AI, append: -Command 'hostname'")
        } else {
            $root = $PSScriptRoot
            Assert-OperatorDirectoryPermissions $root
            $settings = [IO.File]::ReadAllText((Join-Path $root 'session.json')) | ConvertFrom-Json
            Assert-OperatorId $settings.id
            if ((Split-Path -Leaf $root) -cne $settings.id) { throw 'Session directory mismatch.' }
            Assert-OperatorSettings $settings $settings.id
        }
        if ($Mode -eq 'Watch') { Watch-OperatorSession $root $settings $tools; return 0 }
        Start-OperatorWatcher $root
        $remote = Wait-OperatorCustomer $root $settings $tools
        $base = [string[]](Get-OperatorCustomerArguments $root $settings $remote $tools)
        $activity = [string[]](@('-T') + $base + @(Get-OperatorActivityCommand $remote.platform $settings.id))
        if ($Command) {
            $arguments = [string[]](@('-T') + $base + @(ConvertTo-OperatorRemoteCommand $remote.platform $Command))
            return [TSuiteSupport.WindowsRelay]::RunCommand($tools.Ssh, $arguments, $activity,
                [Console]::OpenStandardInput(), [Console]::OpenStandardOutput(), [Console]::OpenStandardError())
        }
        return [TSuiteSupport.WindowsRelay]::RunTerminal($tools.Ssh, [string[]](@('-tt') + $base), $activity)
    } catch [UnauthorizedAccessException] {
        if ($root) { Remove-OperatorSession $root }
        throw
    }
}

if ($Mode -ne 'Library') {
    try {
        $result = Invoke-OperatorMain
        $global:LASTEXITCODE = $result
        if ($PSCommandPath) { exit $result }
    }
    catch {
        [Console]::Error.WriteLine('Support connection failed: ' + $_.Exception.Message)
        $global:LASTEXITCODE = 1
        if ($PSCommandPath) { exit 1 }
        throw 'Support connection failed. See the diagnostic above.'
    }
}
