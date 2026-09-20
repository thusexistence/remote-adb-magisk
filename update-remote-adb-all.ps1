[CmdletBinding()]
param(
    [string]$AdbPath = 'adb.exe',
    [string]$ModulePath = '',
    [int]$TimeoutSeconds = 20,
    [int]$PushTimeoutSeconds = 90,
    [string[]]$TargetDeviceId = @(),
    [switch]$RebootAfterInstall,
    [switch]$ListOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$targetVersion = '1.2.2'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ModulePath) {
    $ModulePath = Join-Path $scriptRoot "remote-adb-magisk-v$targetVersion.zip"
}
$remoteModule = "/data/local/tmp/remote-adb-magisk-v$targetVersion.zip"

function Quote-ProcessArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-AdbCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$CommandTimeoutSeconds = $TimeoutSeconds
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbPath
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        if (-not $process.WaitForExit($CommandTimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{
                ExitCode = 124
                Stdout = ''
                Stderr = "Timed out after ${CommandTimeoutSeconds}s"
            }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $process.StandardOutput.ReadToEnd()
            Stderr = $process.StandardError.ReadToEnd()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-PropValue {
    param([string]$Text, [string]$Name)
    $match = [regex]::Match($Text, "(?m)^$([regex]::Escape($Name))=(.+?)\s*$")
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
}

if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
    throw "Module ZIP not found: $ModulePath. Run build-remote-adb-module.ps1 first."
}

$devicesResult = Invoke-AdbCommand -Arguments @('devices')
if ($devicesResult.ExitCode -ne 0) {
    throw "Could not query adb devices: $($devicesResult.Stderr.Trim())"
}

$onlineEndpoints = @(
    $devicesResult.Stdout -split "`r?`n" |
        ForEach-Object {
            if ($_ -match '^(\S+)\s+device\s*$') { $matches[1] }
        } |
        Where-Object { $_ }
)
if ($onlineEndpoints.Count -eq 0) {
    throw 'No online ADB devices found.'
}

Write-Host "Found $($onlineEndpoints.Count) online ADB endpoint(s). Inspecting installed modules..."

# One physical device can temporarily appear through more than one endpoint.
# Deduplicate by ro.serialno before installing anything.
$targetsByDeviceId = @{}
$inspectionFailures = New-Object System.Collections.Generic.List[object]
foreach ($endpoint in $onlineEndpoints) {
    $identity = Invoke-AdbCommand -Arguments @('-s', $endpoint, 'shell', 'getprop ro.serialno')
    $deviceId = $identity.Stdout.Trim()
    if ($identity.ExitCode -ne 0 -or -not $deviceId) {
        $inspectionFailures.Add([pscustomobject]@{ Endpoint=$endpoint; Reason='Could not read ro.serialno' })
        continue
    }
    if (-not $targetsByDeviceId.ContainsKey($deviceId)) {
        $targetsByDeviceId[$deviceId] = $endpoint
    }
}

$targets = New-Object System.Collections.Generic.List[object]
foreach ($entry in $targetsByDeviceId.GetEnumerator()) {
    $deviceId = [string]$entry.Key
    $endpoint = [string]$entry.Value
    if ($TargetDeviceId.Count -gt 0 -and $TargetDeviceId -notcontains $deviceId -and $TargetDeviceId -notcontains $endpoint) {
        continue
    }
    $propResult = Invoke-AdbCommand -Arguments @(
        '-s', $endpoint, 'shell',
        "su -c 'cat /data/adb/modules/remote_adb/module.prop 2>/dev/null'"
    )
    $moduleId = Get-PropValue -Text $propResult.Stdout -Name 'id'
    if ($propResult.ExitCode -ne 0 -or $moduleId -ne 'remote_adb') {
        Write-Host "[skip] $deviceId ($endpoint): remote_adb is not installed or root is unavailable"
        continue
    }
    $currentVersion = Get-PropValue -Text $propResult.Stdout -Name 'version'
    if (-not $Force -and $currentVersion -eq $targetVersion) {
        Write-Host "[skip] $deviceId ($endpoint): already v$targetVersion"
        continue
    }
    $targets.Add([pscustomobject]@{
        DeviceId = $deviceId
        Endpoint = $endpoint
        CurrentVersion = $currentVersion
    })
}

if ($targets.Count -eq 0) {
    if ($TargetDeviceId.Count -gt 0) {
        Write-Host "No matching device requires an update. Requested: $($TargetDeviceId -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host 'No installed Remote ADB modules require an update.' -ForegroundColor Green
    }
    exit 0
}

if ($ListOnly) {
    Write-Host ''
    Write-Host '===== Remote ADB update preview ====='
    $targets | Sort-Object DeviceId | Format-Table DeviceId,Endpoint,CurrentVersion -AutoSize
    Write-Host "Online endpoints: $($onlineEndpoints.Count)"
    Write-Host "Unique devices: $($targetsByDeviceId.Count)"
    Write-Host "Devices requiring update: $($targets.Count)"
    Write-Host 'ListOnly mode: no files were pushed and no modules were changed.' -ForegroundColor Green
    exit 0
}

Write-Host "Updating $($targets.Count) device(s) to Remote ADB v$targetVersion..."
$successes = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[object]

foreach ($target in $targets) {
    $label = "$($target.DeviceId) ($($target.Endpoint))"
    Write-Host "[push] ${label}: v$($target.CurrentVersion) -> v$targetVersion"
    $push = Invoke-AdbCommand -Arguments @('-s', $target.Endpoint, 'push', $ModulePath, $remoteModule) -CommandTimeoutSeconds $PushTimeoutSeconds
    if ($push.ExitCode -ne 0) {
        $failures.Add([pscustomobject]@{ Device=$label; Stage='push'; Error=$push.Stderr.Trim() })
        Write-Warning "[failed] ${label}: push failed"
        continue
    }

    $install = Invoke-AdbCommand -Arguments @(
        '-s', $target.Endpoint, 'shell',
        "su -c 'magisk --install-module $remoteModule'"
    ) -CommandTimeoutSeconds 60
    [void](Invoke-AdbCommand -Arguments @('-s', $target.Endpoint, 'shell', "rm -f $remoteModule"))
    if ($install.ExitCode -ne 0) {
        $details = ($install.Stdout + "`n" + $install.Stderr).Trim()
        $failures.Add([pscustomobject]@{ Device=$label; Stage='install'; Error=$details })
        Write-Warning "[failed] ${label}: Magisk install failed"
        continue
    }

    $verify = Invoke-AdbCommand -Arguments @(
        '-s', $target.Endpoint, 'shell',
        "su -c 'if [ -f /data/adb/modules_update/remote_adb/module.prop ]; then cat /data/adb/modules_update/remote_adb/module.prop; else cat /data/adb/modules/remote_adb/module.prop; fi'"
    )
    $queuedVersion = Get-PropValue -Text $verify.Stdout -Name 'version'
    if ($verify.ExitCode -ne 0 -or $queuedVersion -ne $targetVersion) {
        $failures.Add([pscustomobject]@{ Device=$label; Stage='verify'; Error="Queued version was '$queuedVersion'" })
        Write-Warning "[failed] ${label}: installed version could not be verified"
        continue
    }

    $successes.Add($target)
    Write-Host "[ready] ${label}: v$targetVersion queued; reboot required" -ForegroundColor Green
}

Write-Host ''
Write-Host '===== Remote ADB update summary ====='
Write-Host "Online endpoints: $($onlineEndpoints.Count)"
Write-Host "Unique devices: $($targetsByDeviceId.Count)"
Write-Host "Update candidates: $($targets.Count)"
Write-Host "Installed successfully: $($successes.Count)"
Write-Host "Failed: $($failures.Count)"

if ($failures.Count -gt 0) {
    $failures | Format-Table Device,Stage,Error -AutoSize
}

if ($RebootAfterInstall -and $successes.Count -gt 0) {
    Write-Host 'All install attempts are complete. Rebooting successful devices...'
    foreach ($target in $successes) {
        Write-Host "[reboot] $($target.DeviceId) ($($target.Endpoint))"
        [void](Invoke-AdbCommand -Arguments @('-s', $target.Endpoint, 'reboot') -CommandTimeoutSeconds 10)
    }
} elseif ($successes.Count -gt 0) {
    Write-Host 'Updates are staged but not active yet. Reboot after validating the summary.' -ForegroundColor Yellow
}

if ($failures.Count -gt 0) { exit 2 }
