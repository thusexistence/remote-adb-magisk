[CmdletBinding()]
param(
    [string]$Version = '1.2.0',
    [string]$SourceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SourceDirectory) {
    $SourceDirectory = Join-Path $scriptRoot 'remote-adb-magisk'
}

if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "Module source directory not found: $SourceDirectory"
}

$requiredFiles = @(
    'module.prop',
    'customize.sh',
    'service.sh',
    'uninstall.sh',
    'remote-adb.conf.example',
    'META-INF\com\google\android\update-binary',
    'META-INF\com\google\android\updater-script'
)
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $SourceDirectory $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required module file not found: $path"
    }
}

$moduleProp = Get-Content -LiteralPath (Join-Path $SourceDirectory 'module.prop') -Raw
if ($moduleProp -notmatch "(?m)^version=$([regex]::Escape($Version))\s*$") {
    throw "module.prop version does not match requested build version $Version"
}

$versionedZip = Join-Path $scriptRoot "remote-adb-magisk-v$Version.zip"
$latestZip = Join-Path $scriptRoot 'remote-adb-magisk.zip'

Remove-Item -LiteralPath $versionedZip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $latestZip -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path.TrimEnd('\', '/')
$zipStream = [System.IO.File]::Open($versionedZip, [System.IO.FileMode]::CreateNew)
$archive = New-Object System.IO.Compression.ZipArchive(
    $zipStream,
    [System.IO.Compression.ZipArchiveMode]::Create,
    $false
)
try {
    Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | ForEach-Object {
        $entryName = $_.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $_.FullName,
            $entryName,
            [System.IO.Compression.CompressionLevel]::Optimal
        )
    }
}
finally {
    $archive.Dispose()
    $zipStream.Dispose()
}
Copy-Item -LiteralPath $versionedZip -Destination $latestZip -Force

Write-Host "Built: $versionedZip" -ForegroundColor Green
Write-Host "Latest alias: $latestZip" -ForegroundColor Green
