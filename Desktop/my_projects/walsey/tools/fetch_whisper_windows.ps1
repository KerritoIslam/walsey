#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads the official whisper.cpp Windows x64 build and the Whisper
    base.en model for the voice testbed.

.DESCRIPTION
    Explicit, one-time setup step for Windows only. The voice testbed's FFI
    adapter loads whisper.dll and ggml.dll from next to the executable, and
    apps/walsey_voice_test/windows/runner/CMakeLists.txt copies the DLLs from
    windows/whisper/ at build time when they are present.

    The binaries come from the official whisper.cpp "b5454" GitHub release
    (whisper-bin-x64.zip, 8,928,640 bytes); the build identifies itself as
    whisper.cpp 1.9.5. The model is ggml-base.en.bin (147,964,211 bytes)
    from https://huggingface.co/ggerganov/whisper.cpp (MIT licence), the
    same artifact measured in docs/voice_accuracy.md.

    Nothing downloads these files automatically: not at build time, not at
    app startup. If they are missing, the app still builds and runs; speech
    recognition reports "native library unavailable" (or "model required")
    and typed commands keep working.

    The model can also be installed from inside the app (Language models ->
    Install). This script additionally places a developer copy under
    windows/whisper/ so the local build works without an in-app download.

    The DLLs and the model are third-party binaries (MIT) and are
    deliberately not committed to the repository.

.PARAMETER Destination
    Folder to install the DLLs and model into. Defaults to
    apps/walsey_voice_test/windows/whisper relative to the repository root.

.PARAMETER Force
    Download again and overwrite existing copies.

.PARAMETER BinariesUrl
    Override the release URL (for example to use a mirror or a local test
    server).

.PARAMETER ModelUrl
    Override the model URL.

.PARAMETER SkipModel
    Fetch only the DLLs.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/fetch_whisper_windows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/fetch_whisper_windows.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\walsey_voice_test\windows\whisper'),
    [switch]$Force,
    [string]$BinariesUrl = '',
    [string]$ModelUrl = '',
    [switch]$SkipModel
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$binariesVersion = 'b5454'
$binariesArchiveName = 'whisper-bin-x64.zip'
if ([string]::IsNullOrWhiteSpace($BinariesUrl)) {
    $BinariesUrl = "https://github.com/ggml-org/whisper.cpp/releases/download/$binariesVersion/$binariesArchiveName"
}
# Size of the published release asset; used to reject a truncated download.
$binariesExpectedBytes = 8928640
$requiredDlls = @('whisper.dll', 'ggml.dll', 'ggml-base.dll')

$modelFileName = 'ggml-base.en.bin'
if ([string]::IsNullOrWhiteSpace($ModelUrl)) {
    $ModelUrl = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin'
}
# Published by Hugging Face as X-Linked-Size for ggml-base.en.bin (checked
# 2026-10-26); used to reject a truncated download. The MD5/SHA-256 pinned in
# the app's catalogue were computed from an artifact of exactly this size.
$modelExpectedBytes = 147964211

$destinationPath = [System.IO.Path]::GetFullPath($Destination)

if (-not $Force -and (Test-Path (Join-Path $destinationPath 'whisper.dll'))) {
    Write-Host "Whisper Windows binaries are already present in:"
    Write-Host "  $destinationPath"
    Write-Host 'Nothing to do. Pass -Force to download again.'
    exit 0
}

Write-Host "Downloading $BinariesUrl"
Write-Host 'The release archive is about 9 MB.'

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("walsey-whisper-" + [System.Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $workDirectory $binariesArchiveName
New-Item -ItemType Directory -Force -Path $workDirectory | Out-Null

try {
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'Continue'
    Invoke-WebRequest -Uri $BinariesUrl -OutFile $archivePath -UseBasicParsing
    $ProgressPreference = $previousProgress

    $size = (Get-Item $archivePath).Length
    if ($size -ne $binariesExpectedBytes) {
        throw "Downloaded archive is $size bytes, expected $binariesExpectedBytes. " +
              'Delete it and run the script again.'
    }

    $extractPath = Join-Path $workDirectory 'extract'
    Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force

    $library = Get-ChildItem -Path $extractPath -Recurse -Filter 'whisper.dll' |
        Select-Object -First 1
    if ($null -eq $library) {
        throw "The archive did not contain whisper.dll."
    }
    $sourceDirectory = $library.Directory.FullName

    New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
    foreach ($dll in $requiredDlls) {
        if (-not (Test-Path (Join-Path $sourceDirectory $dll))) {
            throw "The release archive is missing $dll. Nothing was installed."
        }
    }
    # whisper.dll imports ggml.dll and ggml-base.dll; the ggml CPU backend
    # loads its per-instruction-set variants (ggml-cpu-*.dll) at runtime.
    Get-ChildItem -Path $sourceDirectory -Filter '*.dll' | Where-Object {
        ($_.Name -in $requiredDlls) -or ($_.Name -like 'ggml-cpu-*.dll')
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destinationPath -Force
    }

    if (-not $SkipModel) {
        $modelTarget = Join-Path $destinationPath $modelFileName
        if ($Force -or -not (Test-Path $modelTarget)) {
            Write-Host "Downloading $ModelUrl"
            Write-Host 'The model is about 141 MB. This is the only network step.'
            $ProgressPreference = 'Continue'
            Invoke-WebRequest -Uri $ModelUrl -OutFile $modelTarget -UseBasicParsing
            $ProgressPreference = $previousProgress
            $modelSize = (Get-Item $modelTarget).Length
            if ($modelSize -ne $modelExpectedBytes) {
                Remove-Item -Force $modelTarget
                throw "Downloaded model is $modelSize bytes, expected $modelExpectedBytes. " +
                      'It was deleted; run the script again.'
            }
        } else {
            Write-Host "Model already present: $modelTarget"
        }
    }

    Write-Host ''
    Write-Host 'Whisper files installed:'
    Get-ChildItem -Path $destinationPath -File | ForEach-Object {
        Write-Host ("  {0} ({1:N0} bytes)" -f $_.Name, $_.Length)
    }
    Write-Host ''
    Write-Host 'The DLLs are copied next to the executable, and the model into a'
    Write-Host '"models" subfolder next to it, by the Windows build. The model can'
    Write-Host 'also be installed from inside the app (Language models -> Install).'
}
finally {
    if (Test-Path $workDirectory) {
        Remove-Item -Recurse -Force $workDirectory
    }
}
