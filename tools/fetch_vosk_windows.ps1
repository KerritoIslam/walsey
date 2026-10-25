#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads the official Vosk Windows x64 native library for the voice testbed.

.DESCRIPTION
    Explicit, one-time setup step for Windows only. The voice testbed's FFI
    adapter loads libvosk.dll from next to the executable, and
    apps/walsey_voice_test/windows/runner/CMakeLists.txt copies the DLLs from
    windows/vosk/ at build time when they are present.

    Nothing downloads this library automatically: not at build time, not at app
    startup. If it is missing, the app still builds and runs; speech recognition
    reports "native library unavailable" and typed commands keep working.

    Android does not need this script: the same native library comes from Maven
    Central through android/app/build.gradle.kts.

    The DLLs are third-party binaries (Apache License 2.0) and are deliberately
    not committed to the repository.

.PARAMETER Destination
    Folder to extract the DLLs into. Defaults to
    apps/walsey_voice_test/windows/vosk relative to the repository root.

.PARAMETER Force
    Download again and overwrite an existing copy.

.PARAMETER Url
    Override the release URL (for example to use a mirror or a local test
    server). The default is the official Alpha Cephei GitHub release.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/fetch_vosk_windows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/fetch_vosk_windows.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\walsey_voice_test\windows\vosk'),
    [switch]$Force,
    [string]$Url = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$version = '0.3.45'
$archiveName = "vosk-win64-$version.zip"
if ([string]::IsNullOrWhiteSpace($Url)) {
    $Url = "https://github.com/alphacep/vosk-api/releases/download/v$version/$archiveName"
}
# Size of the published release asset; used to reject a truncated download.
$expectedBytes = 14882445
$requiredDlls = @(
    'libvosk.dll',
    'libstdc++-6.dll',
    'libgcc_s_seh-1.dll',
    'libwinpthread-1.dll'
)

$destinationPath = [System.IO.Path]::GetFullPath($Destination)

if (-not $Force -and (Test-Path (Join-Path $destinationPath 'libvosk.dll'))) {
    Write-Host "Vosk Windows DLLs are already present in:"
    Write-Host "  $destinationPath"
    Write-Host 'Nothing to do. Pass -Force to download again.'
    exit 0
}

Write-Host "Downloading $Url"
Write-Host 'The release archive is about 15 MB.'

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("walsey-vosk-" + [System.Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $workDirectory $archiveName
New-Item -ItemType Directory -Force -Path $workDirectory | Out-Null

try {
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'Continue'
    Invoke-WebRequest -Uri $Url -OutFile $archivePath -UseBasicParsing
    $ProgressPreference = $previousProgress

    $size = (Get-Item $archivePath).Length
    if ($size -ne $expectedBytes) {
        throw "Downloaded archive is $size bytes, expected $expectedBytes. " +
              'Delete it and run the script again.'
    }

    $extractPath = Join-Path $workDirectory 'extract'
    Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force

    $library = Get-ChildItem -Path $extractPath -Recurse -Filter 'libvosk.dll' |
        Select-Object -First 1
    if ($null -eq $library) {
        throw "The archive did not contain libvosk.dll."
    }
    $sourceDirectory = $library.Directory.FullName

    New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
    foreach ($dll in $requiredDlls) {
        $candidate = Join-Path $sourceDirectory $dll
        if (-not (Test-Path $candidate)) {
            throw "The release archive is missing $dll. Nothing was installed."
        }
    }
    Get-ChildItem -Path $sourceDirectory -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destinationPath -Force
    }

    Write-Host ''
    Write-Host 'Vosk Windows DLLs installed:'
    Get-ChildItem -Path $destinationPath -File | ForEach-Object {
        Write-Host ("  {0} ({1:N0} bytes)" -f $_.Name, $_.Length)
    }
    Write-Host ''
    Write-Host 'They are copied next to the executable by the Windows build.'
    Write-Host 'Speech models are still downloaded separately, per language, from'
    Write-Host 'inside the app (Language models -> Install).'
}
finally {
    if (Test-Path $workDirectory) {
        Remove-Item -Recurse -Force $workDirectory
    }
}

