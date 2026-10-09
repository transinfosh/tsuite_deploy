# Isolated operator regressions. No support sessions, accounts or services are created.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$operator = Join-Path (Split-Path -Parent $PSScriptRoot) 'operator'
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $operator 'tsuite_support_windows.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
. (Join-Path $operator 'tsuite_support_windows.ps1') -Mode Library
Initialize-OperatorRelay
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-True $rejected $Message
}

foreach ($id in @('../escape', '012345ABCDEF', "012345abcdef`n")) {
    Assert-Rejected { Assert-OperatorId $id } 'Invalid session ID accepted.'
}
foreach ($path in @('C:/Users/%USERNAME%/support', 'C:/Users/test!/support', "C:/test`npath")) {
    Assert-Rejected { Assert-OperatorPath $path } 'Shell-expanding support path accepted.'
}
$settings = [pscustomobject]@{
    id = '012345abcdef'; host = 'edge.example.com'; user = 'tsuite-operator'; port = 22
    expires_at = [long]2000000000; certificate = 'ssh-ed25519-cert-v01@openssh.com AAAA'
    known_hosts = 'edge.example.com ssh-ed25519 AAAA'
}
Assert-OperatorSettings $settings $settings.id -Claim
Assert-Rejected { Assert-OperatorSettings $settings 'fedcba543210' -Claim } 'Cross-session certificate accepted.'
foreach ($badPort in @('22', 0, 65536)) {
    $bad = $settings | ConvertTo-Json | ConvertFrom-Json
    $bad.port = $badPort
    Assert-Rejected { Assert-OperatorSettings $bad $settings.id -Claim } 'Invalid SSH port accepted.'
}
foreach ($url in @('http://edge.example.com/support', 'https://user:password@edge.example.com/support',
    'https://edge.example.com/support?token=bad', 'https://edge.example.com/wrong')) {
    $grant = [pscustomobject]@{ id = $settings.id; token = 'test'; url = $url }
    Assert-Rejected { Request-OperatorClaim $grant 'ssh-ed25519 AAAA' } 'Invalid bearer destination accepted.'
}

$windowsCommand = "Write-Output 'Chinese text'; `$env:COMPUTERNAME"
$encoded = ConvertTo-OperatorRemoteCommand 'windows' $windowsCommand
$decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($encoded -split ' ')[-1]))
Assert-True ($decoded -ceq $windowsCommand) 'PowerShell command lost quoting or encoding.'
Assert-True ((ConvertTo-OperatorRemoteCommand 'linux' 'echo "$HOME"') -ceq 'echo "$HOME"') 'Linux command changed.'
$encodedActivity = Get-OperatorActivityCommand 'windows' $settings.id
$activitySource = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($encodedActivity -split ' ')[-1]))
Assert-True ($activitySource.Contains("TSuiteSupport/$($settings.id)/client.ps1")) 'Wrong Windows activity target.'
Assert-True ($activitySource.Contains('-Mode Activity')) 'Wrong Windows activity mode.'

$script:testRoot = Join-Path ([IO.Path]::GetTempPath()) ("TSuite operator space ' " + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:testRoot)
$windows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
try {
    if ($windows) {
        Set-OperatorDirectoryPermissions $script:testRoot
        Assert-Rejected { [TSuiteSupport.WindowsRelay]::CreateSessionDirectory($script:testRoot) } 'Atomic session creation accepted an existing directory.'
        $tools = Get-OperatorTools
    } else {
        $tools = [pscustomobject]@{ Ssh = (Get-Command ssh).Source; Keygen = (Get-Command ssh-keygen).Source }
    }
    # Exercise native CRT quoting against a real key generator (empty -N and a path with spaces).
    $identity = Join-Path $script:testRoot 'identity'
    $keygen = [TSuiteSupport.WindowsRelay]::Capture($tools.Keygen,
        [string[]]@('-q', '-t', 'ed25519', '-N', '', '-f', $identity), 20000)
    Assert-True ($keygen.ExitCode -eq 0) ('Key generation failed: ' + $keygen.Error)
    Assert-True (Test-Path -LiteralPath "$identity.pub") 'Empty passphrase/path quoting failed.'
    if ($windows) {
        Set-OperatorFilePermissions $identity
        Set-OperatorFilePermissions "$identity.pub"
        Assert-OperatorDirectoryPermissions $script:testRoot
    }

    $remote = [pscustomobject]@{ remote_port = 22000; customer_host_key = 'ssh-ed25519 AAAA' }
    $customer = [string[]](Get-OperatorCustomerArguments $script:testRoot $settings $remote $tools)
    $parsed = [TSuiteSupport.WindowsRelay]::Capture($tools.Ssh, [string[]](@('-G') + $customer), 20000)
    Assert-True ($parsed.ExitCode -eq 0) ('SSH configuration failed: ' + $parsed.Error)
    $normalized = $script:testRoot.Replace('\', '/')
    Assert-True ($parsed.Output.Contains("certificatefile $normalized/identity-cert.pub")) 'SSH config path with spaces was split.'
    Assert-True ($parsed.Output.Contains("userknownhostsfile $normalized/customer_known_hosts")) 'Pinned customer host path was split.'
    Assert-True ($parsed.Output.Contains('stricthostkeychecking true') -or $parsed.Output.Contains('stricthostkeychecking yes')) 'Host checking disabled.'
    Assert-True ($parsed.Output.Contains('proxycommand')) 'Restricted Edge proxy missing.'
    $edge = [TSuiteSupport.WindowsRelay]::Capture($tools.Ssh,
        [string[]](@('-G') + @(Get-OperatorEdgeArguments $script:testRoot $settings)), 20000)
    Assert-True ($edge.Output.Contains("identityfile $normalized/identity")) 'Edge identity path with spaces was split.'
    Assert-True ($edge.Output.Contains('hostname edge.example.com')) 'Edge host mismatch.'
    $remote.customer_host_key = 'ssh-ed25519 BBBB'
    Assert-Rejected { Get-OperatorCustomerArguments $script:testRoot $settings $remote $tools } 'Changed customer host key accepted.'

    Write-OperatorFile (Join-Path $script:testRoot 'session.json') ($settings | ConvertTo-Json -Compress)
    $settings.expires_at = 2000001000
    Save-OperatorLease $script:testRoot $settings
    $saved = [IO.File]::ReadAllText((Join-Path $script:testRoot 'session.json')) | ConvertFrom-Json
    Assert-True ($saved.expires_at -eq 2000001000) 'Confirmed lease was not saved atomically.'
    Assert-Rejected { Write-OperatorFile $identity 'replacement' } 'An existing private key was overwritten.'

    # Byte-preserving relay with enough output to fill pipe buffers before reading stdin.
    $hostExecutable = (Get-Process -Id $PID).Path
    $fixture = @'
$stdout = [Console]::OpenStandardOutput()
$stderr = [Console]::OpenStandardError()
$payload = New-Object byte[] 131072
for ($index = 0; $index -lt $payload.Length; $index++) { $payload[$index] = $index % 256 }
$stdout.Write($payload, 0, $payload.Length)
$stderr.WriteByte(69)
[Console]::OpenStandardInput().CopyTo($stdout)
exit 7
'@
    $fixtureArgs = [string[]]@('-NoProfile', '-NonInteractive', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fixture)))
    $activityLog = Join-Path $script:testRoot 'activity.txt'
    $reportScript = "[IO.File]::AppendAllText('" + $activityLog.Replace("'", "''") + "', 'activity'); exit 0"
    $reportArgs = [string[]]@('-NoProfile', '-NonInteractive', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($reportScript)))
    $relayExecutable = $hostExecutable
    if ($windows) {
        # Windows PowerShell's host can consume redirected stdin before the script
        # opens it. Exercise raw pipes with a native child, as we do with ssh.exe.
        $relayExecutable = Join-Path $script:testRoot 'relay-fixture.exe'
        Add-Type -OutputAssembly $relayExecutable -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public static class RelayFixture {
    public static int Main(string[] args) {
        if (args.Length == 2 && args[0] == "report") {
            File.AppendAllText(args[1], "activity");
            return 0;
        }
        using (Stream output = Console.OpenStandardOutput())
        using (Stream error = Console.OpenStandardError()) {
            byte[] payload = new byte[131072];
            for (int i = 0; i < payload.Length; i++) payload[i] = (byte)(i % 256);
            output.Write(payload, 0, payload.Length);
            error.WriteByte(69);
            Console.OpenStandardInput().CopyTo(output);
            output.Flush(); error.Flush();
        }
        return 7;
    }
}
'@
        $fixtureArgs = [string[]]@()
        $reportArgs = [string[]]@('report', $activityLog)
    }
    $inputStream = New-Object IO.MemoryStream
    $inputStream.Write([byte[]]@(0, 255, 13, 10), 0, 4)
    $inputStream.Position = 0
    $outputStream = New-Object IO.MemoryStream
    $errorStream = New-Object IO.MemoryStream
    try {
        $exitCode = [TSuiteSupport.WindowsRelay]::RunCommand($relayExecutable, $fixtureArgs, $reportArgs,
            $inputStream, $outputStream, $errorStream)
        Assert-True ($exitCode -eq 7) 'Remote command exit code was lost.'
        $outputBytes = $outputStream.ToArray()
        Assert-True ($outputBytes.Length -eq 131076) ("Binary stdout/stdin truncated: received $($outputBytes.Length), expected 131076.")
        for ($index = 0; $index -lt 131072; $index++) {
            if ($outputBytes[$index] -ne ($index % 256)) { throw 'Binary stdout transcoded.' }
        }
        Assert-True ($outputBytes[131073] -eq 255) 'Binary stdin transcoded.'
        Assert-True ($errorStream.Length -eq 1 -and $errorStream.ToArray()[0] -eq 69) 'stderr mixed with stdout.'
        $reports = [IO.File]::ReadAllText($activityLog)
        Assert-True ($reports -eq 'activity' -or $reports -eq 'activityactivity') 'Output caused spurious activity reporting.'
    } finally {
        $inputStream.Dispose(); $outputStream.Dispose(); $errorStream.Dispose()
    }
    Assert-Rejected {
        $sleep = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 10'))
        [TSuiteSupport.WindowsRelay]::Capture($hostExecutable,
            [string[]]@('-NoProfile', '-NonInteractive', '-EncodedCommand', $sleep), 100)
    } 'SSH helper timeout was not enforced.'

    if ($windows) {
        # Claim is fully exercised with real keygen and ACLs; only the HTTPS broker is replaced.
        $script:claimParent = Join-Path $script:testRoot 'claimed/portable'
        function Get-OperatorParent { return $script:claimParent }
        $script:claimId = 'abcdef012345'
        $script:claimExpiry = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 900
        function Request-OperatorClaim { param($Grant, $PublicKey)
            Assert-True ($PublicKey.StartsWith('ssh-ed25519 ')) 'Claim did not submit a real local public key.'
            return [pscustomobject]@{
                id = $script:claimId; host = 'edge.example.com'; port = 22; user = 'tsuite-operator'
                expires_at = $script:claimExpiry; certificate = 'ssh-ed25519-cert-v01@openssh.com AAAA'
                known_hosts = 'edge.example.com ssh-ed25519 AAAA'
            }
        }
        $grantToken = 'A' * 43
        $grantJson = @{ id = $script:claimId; token = $grantToken; url = 'https://edge.example.com/support' } | ConvertTo-Json -Compress
        $session = New-OperatorSession $grantJson $tools
        Assert-OperatorDirectoryPermissions $session.Root
        $originalIdentity = [IO.File]::ReadAllText((Join-Path $session.Root 'identity'))
        foreach ($file in Get-ChildItem -LiteralPath $session.Root -File) {
            Assert-True (-not ([IO.File]::ReadAllText($file.FullName).Contains($grantToken))) 'Bearer grant persisted to disk.'
        }
        Assert-Rejected { New-OperatorSession $grantJson $tools } 'Claim overwrote an existing identity.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $session.Root 'identity')) -ceq $originalIdentity) 'Failed competing claim removed existing identity.'
        # Execute the saved library to ensure source packaging and the adjacent relay are usable.
        $libraryCheck = ". '" + (Join-Path $session.Root 'support.ps1').Replace("'", "''") + "' -Mode Library; Initialize-OperatorRelay"
        $libraryResult = [TSuiteSupport.WindowsRelay]::Capture($hostExecutable,
            [string[]]@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand',
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($libraryCheck))), 20000)
        Assert-True ($libraryResult.ExitCode -eq 0) ('Saved client failed: ' + $libraryResult.Error)
    }

    # Watcher uses real lifecycle logic with only OS/network boundaries replaced.
    function Assert-OperatorDirectoryPermissions { param($Path) }
    if (-not $windows) { function Get-OperatorUserSid { return 'test-user' } }
    function Get-OperatorTime { return 2000002000 }
    function Get-OperatorStatus { param($Root, $Settings, $Tools) throw 'network unavailable' }
    Watch-OperatorSession $script:testRoot $settings $tools
    Assert-True (-not (Test-Path -LiteralPath $script:testRoot)) 'Offline expiry retained local private keys.'
    [void][IO.Directory]::CreateDirectory($script:testRoot)
    Write-OperatorFile (Join-Path $script:testRoot 'identity') 'fixture'
    $settings.expires_at = 2000010000
    function Get-OperatorStatus { param($Root, $Settings, $Tools)
        throw [UnauthorizedAccessException]::new('revoked')
    }
    Watch-OperatorSession $script:testRoot $settings $tools
    Assert-True (-not (Test-Path -LiteralPath $script:testRoot)) 'Revocation retained local private keys.'

    [void][IO.Directory]::CreateDirectory($script:testRoot)
    $settings.expires_at = 2000001000 # The initial cached lease is stale, but the server has renewed it.
    Write-OperatorFile (Join-Path $script:testRoot 'session.json') ($settings | ConvertTo-Json -Compress)
    $script:statusCalls = 0
    $script:now = 2000002000
    $script:sleeps = 0
    function Get-OperatorTime { return $script:now }
    function Get-OperatorStatus { param($Root, $Settings, $Tools)
        $script:statusCalls++
        if ($script:statusCalls -gt 1) { throw 'offline' }
        return [pscustomobject]@{ id = $Settings.id; status = 'enrolled'; expires_at = 2000003000 }
    }
    function Start-Sleep { param($Seconds)
        $saved = [IO.File]::ReadAllText((Join-Path $script:testRoot 'session.json')) | ConvertFrom-Json
        Assert-True ($saved.expires_at -eq 2000003000) 'Watcher failed to persist a confirmed renewal.'
        $script:sleeps++
        $script:now = 2000004000
    }
    Watch-OperatorSession $script:testRoot $settings $tools
    Assert-True ($script:sleeps -eq 1) 'Watcher deleted a renewed lease or invented an offline renewal.'
    Assert-True (-not (Test-Path -LiteralPath $script:testRoot)) 'Last confirmed lease did not govern offline deletion.'
    Write-Output 'Native operator validation, SSH path quoting, binary relay and cleanup tests passed.'
} finally {
    if (Test-Path -LiteralPath $script:testRoot) { [IO.Directory]::Delete($script:testRoot, $true) }
}
