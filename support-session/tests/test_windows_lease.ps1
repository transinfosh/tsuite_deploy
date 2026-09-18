# Isolated activity/lease tests; no real Windows account, ACL, service or task mutation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'customer/windows-client.ps1') -Mode Library
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tsuite-lease-' + [guid]::NewGuid().ToString('N'))
$Id = '012345abcdef'
$directory = Join-Path $testRoot $Id
[void][IO.Directory]::CreateDirectory($directory)
$state = [pscustomobject]@{session_id=$Id; ops_user='tsuite-ops-012345ab'; sshd_path='sshd.exe'; expires_at=100; idle_timeout_seconds=300}
function Get-SupportRoot { return $testRoot }
try {
    Assert-True (-not (Test-SupportActivity $state $null).active) 'No input must not renew.'
    Write-Utf8 (Join-Path $directory 'activity') 'operator input'
    $first = Test-SupportActivity $state $null
    Assert-True $first.active 'Recent operator input must renew.'
    Assert-True (-not (Test-SupportActivity $state $first.snapshot).active) 'The same input must not renew repeatedly.'
    (Get-Item (Join-Path $directory 'activity')).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-60)
    Assert-True (-not (Test-SupportActivity $state $null).active) 'Stale operator input must expire.'
    (Get-Item (Join-Path $directory 'activity')).LastWriteTimeUtc = [datetime]::UtcNow
    Assert-True (Test-SupportActivity $state $first.snapshot).active 'New operator input must renew again.'

    $script:events = @()
    function Get-LocalUser { param($Name) return [pscustomobject]@{Description="TSuite temporary support $Id"; SID='fixture'} }
    function Set-ServiceFilePermissions { param($Path) $script:events += 'acl' }
    function Set-LocalUser { param($SID, $AccountExpires) $script:events += 'account'; if ($script:failAccount) { throw 'fixture failure' } }
    $script:failAccount = $false
    $keyPath = Join-Path $directory 'authorized_keys'
    Write-Utf8 $keyPath 'expiry-time="20260909000000Z" ssh-ed25519 fixture'
    Write-Utf8 (Join-Path $directory 'session.json') ($state | ConvertTo-Json)
    Set-SupportExpiry $state 200
    Assert-True ((Get-Content (Join-Path $directory 'session.json') -Raw | ConvertFrom-Json).expires_at -eq 200) 'Successful renewal must persist watchdog expiry.'
    Assert-True ($script:events -join ',' -eq 'acl,account') 'Native ACL and account updated before committing state.'
    $script:failAccount = $true
    $failed = $false
    try { Set-SupportExpiry $state 300 } catch { $failed = $true }
    Assert-True $failed 'A native expiry failure must not be ignored.'
    Assert-True ((Get-Content (Join-Path $directory 'session.json') -Raw | ConvertFrom-Json).expires_at -eq 200) 'Partial failure must keep last confirmed watchdog expiry.'

    $script:failAccount = $false
    $state | Add-Member -NotePropertyName portable_operator -NotePropertyValue $false
    Set-SupportExpiry $state 400
    Assert-True ((Get-Content (Join-Path $directory 'session.json') -Raw | ConvertFrom-Json).expires_at -eq 400) 'Explicit non-portable sessions must renew with one key.'
    $state.portable_operator = $true
    $script:events = @()
    $failed = $false
    try { Set-SupportExpiry $state 500 } catch {
        if ($_.Exception.Message -ne 'Invalid key expiry.') { throw }
        $failed = $true
    }
    Assert-True $failed 'Portable sessions must reject a missing second key.'
    Assert-True ($script:events.Count -eq 0 -and $state.expires_at -eq 400) 'Invalid keys must not update native or watchdog expiry.'
    Assert-True ((Get-Content (Join-Path $directory 'session.json') -Raw | ConvertFrom-Json).expires_at -eq 400) 'Rejected renewal must retain confirmed expiry on disk.'
    Write-Utf8 $keyPath ('expiry-time="20260909000000Z" ssh-ed25519 fixture' + "`n" +
        'expiry-time="20260909000000Z" cert-authority ssh-ed25519 fixture-ca')
    Set-SupportExpiry $state 500
    $expectedExpiry = [DateTimeOffset]::FromUnixTimeSeconds(500).UtcDateTime.ToString('yyyyMMddHHmmssZ')
    Assert-True ([regex]::Matches((Get-Content $keyPath -Raw), ('expiry-time="' + $expectedExpiry + '"')).Count -eq 2) 'Portable renewal must update both key deadlines.'
    Assert-True ((Get-Content (Join-Path $directory 'session.json') -Raw | ConvertFrom-Json).expires_at -eq 500) 'Portable renewal must persist confirmed expiry.'
    Assert-True ($script:events -join ',' -eq 'acl,account') 'Portable renewal must apply native restrictions before committing state.'

    $state.expires_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300
    $script:leaseActivities = @()
    function Read-SupportState { param($Id) return $state }
    function Request-SupportLease { param($State, [bool]$Active) $script:leaseActivities += $Active; return $State.expires_at }
    function Start-Sleep { param($Seconds) throw 'end iteration' }
    Write-Utf8 (Join-Path $directory 'activity') 'new input'
    foreach ($iteration in 1..2) {
        try { Watch-SupportLease $Id } catch { if ($_.Exception.Message -ne 'end iteration') { throw } }
    }
    Assert-True ($script:leaseActivities.Count -eq 2 -and $script:leaseActivities[0] -eq $true -and $script:leaseActivities[1] -eq $false) 'Monitor restart must not replay acknowledged input.'
    Write-Host 'Windows activity and lease tests passed.'
} finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force
}
