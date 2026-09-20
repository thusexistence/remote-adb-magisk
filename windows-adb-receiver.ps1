param(
    [int]$ListenPort = 39393,
    [string]$AdbPath = 'adb.exe',
    [string]$LogPath = '',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $LogPath) {
    $LogPath = Join-Path $scriptRoot 'windows-adb-receiver.log'
}
$listener = $null
$exitCode = 0

function Test-PrivateIPv4 {
    param([Parameter(Mandatory)][string]$Address)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return $false
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }
    $bytes = $parsed.GetAddressBytes()
    return (
        $bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    )
}

function Write-ReceiverLog {
    param(
        [string]$Message,
        [ConsoleColor]$ForegroundColor
    )

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        Write-Host $line -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host $line
    }

    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not write receiver log '$LogPath': $($_.Exception.Message)"
    }
}

try {
    $adbCommand = Get-Command -Name $AdbPath -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $adbCommand) {
        throw [System.IO.FileNotFoundException]::new(
            "ADB executable '$AdbPath' was not found."
        )
    }
    $resolvedAdbPath = $adbCommand.Source

    try {
        $listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Any,
            $ListenPort
        )
        $listener.Start()
    }
    catch {
        throw "Could not listen on TCP port $ListenPort. It may already be in use. $($_.Exception.Message)"
    }
    Write-ReceiverLog "Waiting for phones on TCP port $ListenPort"
    Write-ReceiverLog "Using ADB at $resolvedAdbPath"

    while ($true) {
        $client = $listener.AcceptTcpClient()
        $remoteAddress = $client.Client.RemoteEndPoint.ToString()
        $reader = $null
        $message = $null
        $readFailed = $false

        try {
            $reader = [System.IO.StreamReader]::new($client.GetStream())
            $message = $reader.ReadLine()
        }
        catch {
            $readFailed = $true
            Write-ReceiverLog "Failed to read a report from ${remoteAddress}: $($_.Exception.Message)" Yellow
        }
        finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }
            $client.Dispose()
        }

        if ($readFailed) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($message)) {
            Write-ReceiverLog "Ignored an empty report from $remoteAddress"
            continue
        }

        $fields = $message.Split('|')
        if ($fields.Count -ne 4 -or $fields[0] -ne 'ADB') {
            Write-ReceiverLog "Ignored malformed report from ${remoteAddress}: $message"
            continue
        }

        $deviceId = $fields[1]
        $endpoint = $fields[2]

        $endpointMatch = [regex]::Match($endpoint, '^([^:]+):(\d{1,5})$')
        $endpointIp = if ($endpointMatch.Success) { $endpointMatch.Groups[1].Value } else { '' }
        $endpointPort = if ($endpointMatch.Success) { [int]$endpointMatch.Groups[2].Value } else { 0 }
        if ($deviceId -notmatch '^[A-Za-z0-9._-]+$' -or
            -not $endpointMatch.Success -or
            -not (Test-PrivateIPv4 $endpointIp) -or
            $endpointPort -lt 1 -or $endpointPort -gt 65535) {
            Write-ReceiverLog "Ignored unsafe report from ${remoteAddress}: $message"
            continue
        }

        Write-ReceiverLog "Device $deviceId reported $endpoint"
        try {
            # Windows PowerShell 5.1 turns native stderr into an error record.
            # ADB writes normal daemon startup messages to stderr, so do not let
            # the script-wide Stop preference terminate the receiver here.
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $adbOutput = & $resolvedAdbPath connect $endpoint 2>&1
                $adbExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            Write-ReceiverLog ($adbOutput -join [Environment]::NewLine)

            if ($adbExitCode -ne 0) {
                Write-ReceiverLog "ADB connect exited with code $adbExitCode; the receiver will keep running." Yellow
            }
        }
        catch {
            Write-ReceiverLog "ADB connect failed: $($_.Exception.Message); the receiver will keep running." Red
        }
    }
}
catch {
    $exitCode = 1
    Write-ReceiverLog "Receiver stopped because of an error: $($_.Exception.Message)" Red

    $errorDetails = ($_ | Format-List * -Force | Out-String).TrimEnd()
    Write-Host $errorDetails -ForegroundColor Red

    if ($_.Exception.Message -match 'Could not listen on TCP port') {
        Write-ReceiverLog "TCP port $ListenPort is already occupied. Close the other receiver or choose another -ListenPort." Yellow
    }
    elseif ($_.Exception.Message -match 'ADB executable.*was not found') {
        Write-ReceiverLog "ADB was not found. Add adb.exe to PATH or pass -AdbPath with its full path." Yellow
    }
}
finally {
    if ($null -ne $listener) {
        $listener.Stop()
    }

    if (-not $NoPause) {
        Write-Host
        try {
            Read-Host 'Press Enter to close this window' | Out-Null
        }
        catch {
            # Some non-interactive hosts do not support Read-Host.
        }
    }
}

if ($exitCode -ne 0) {
    exit $exitCode
}
