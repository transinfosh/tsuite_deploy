# Native Windows ACL regression. Uses throwaway files; no accounts or services are changed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'customer/windows-client.ps1') -Mode Library
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Output 'SKIP: native Windows ACL verification requires Windows.'
    return
}
$directory = Join-Path ([IO.Path]::GetTempPath()) ('tsuite-acl-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
try {
    $path = Join-Path $directory 'ssh_host_ed25519_key'
    [IO.File]::WriteAllText($path, 'test fixture - no private key material')
    $before = New-Object Security.AccessControl.FileSecurity
    $before.SetAccessRuleProtection($true, $false)
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $before.SetOwner($current)
    $before.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($current, 'FullControl', 'Allow')))
    $before.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')), 'Read', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $before
    # Reproduce the keygen-created personal owner plus unwanted explicit grant, then repair.
    Set-ServiceFilePermissions $path
    Set-ServiceFilePermissions $path
    $acl = Get-Acl -LiteralPath $path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544') { throw 'The service file still has a personal owner.' }
    if (-not $acl.AreAccessRulesProtected) { throw 'The service file still inherits permissions.' }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { throw 'Unexpected grants remain on the service file.' }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
        if ($rule.Count -ne 1 -or $rule[0].AccessControlType -ne 'Allow' -or
            $rule[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
            throw "Missing service file access: $sid"
        }
    }

    $runtime = Join-Path $directory 'runtime'
    [void][IO.Directory]::CreateDirectory($runtime)
    $runtimeFile = Join-Path $runtime 'sshd-session.exe'
    [IO.File]::WriteAllText($runtimeFile, 'public runtime fixture')
    Set-OpenSshRuntimePermissions $runtime $true
    Set-OpenSshRuntimePermissions $runtime $true
    Assert-OpenSshRuntimePermissions $runtime
    $runtimeRules = @((Get-Acl -LiteralPath $runtimeFile).GetAccessRules(
        $true, $true, [Security.Principal.SecurityIdentifier]))
    $usersRule = @($runtimeRules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' })
    if ($usersRule.Count -ne 1 -or
        ($usersRule[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
            [Security.AccessControl.FileSystemRights]::ReadAndExecute -or
        ($usersRule[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -ne 0) {
        throw 'Restricted OpenSSH children do not have read-execute-only runtime access.'
    }

    $statePath = Join-Path $directory 'session.json'
    $lockReady = Join-Path $directory 'lock-ready'
    [IO.File]::WriteAllText($statePath, '{"session_id":"012345abcdef"}')
    $lockScript = @"
`$stream = [IO.File]::Open('$statePath', [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
[IO.File]::WriteAllText('$lockReady', 'ready')
Start-Sleep -Milliseconds 300
`$stream.Dispose()
"@
    $encodedLockScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($lockScript))
    $locker = Start-Process -FilePath powershell.exe -ArgumentList (
        '-NoProfile -NonInteractive -EncodedCommand {0}' -f $encodedLockScript) -PassThru
    try {
        for ($attempt = 0; $attempt -lt 20 -and -not (Test-Path -LiteralPath $lockReady); $attempt++) {
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path -LiteralPath $lockReady)) { throw 'Could not establish the state-file lock fixture.' }
        $stateText = Read-Utf8WithRetry $statePath
        if ($stateText -cne '{"session_id":"012345abcdef"}') {
            throw 'State-file retry returned unexpected content.'
        }
    } finally {
        if (-not $locker.HasExited) { $locker.Kill(); $locker.WaitForExit() }
        $locker.Dispose()
    }
    Write-Output 'Windows ACL normalization and locked state-file retry passed.'
} finally {
    [IO.Directory]::Delete($directory, $true)
}
