#Requires -Version 5.1
<#
.SYNOPSIS
    Builds whisper.cpp for Android and installs the .so files into the voice
    testbed's APK source set.

.DESCRIPTION
    Explicit, one-time build step for Android only. The voice testbed's FFI
    adapter loads libwhisper.so / libggml.so from the APK's lib/<abi> folder;
    android/app/build.gradle.kts adds jniLibs-whisper/ as a jniLibs source
    directory, and this script fills it.

    Source: the official whisper.cpp b5454 tag (the same revision as the
    Windows binaries fetched by tools/fetch_whisper_windows.ps1, which
    identifies itself as whisper.cpp 1.9.5). The build is CPU-only
    (GGML_NATIVE=OFF, OpenMP off — ggml uses its own thread pool, so no
    libomp.so dependency; examples/tests/server disabled). The APK ships
    exactly:
      libwhisper.so, libggml.so, libggml-base.so, libggml-cpu.so

    libggml-cpu.so is required: libwhisper.so and libggml.so carry a hard
    DT_NEEDED entry on it (verified with llvm-readelf on the b5454 build).

    Nothing builds or downloads these libraries at app-build time implicitly;
    if they are missing the APK still builds and runs, and speech recognition
    reports "native library unavailable" while typed commands keep working.

    The .so files are third-party binaries (MIT) and are deliberately not
    committed to the repository.

.PARAMETER NdkPath
    Android NDK to build with. Defaults to the newest NDK under
    %LOCALAPPDATA%\Android\Sdk\ndk.

.PARAMETER CMakePath
    CMake executable to use. Defaults to the newest one under
    %LOCALAPPDATA%\Android\Sdk\cmake, falling back to cmake on PATH.

.PARAMETER NinjaPath
    ninja executable used as CMAKE_MAKE_PROGRAM. Defaults to the ninja.exe
    bundled next to the selected SDK CMake, falling back to ninja on PATH.

.PARAMETER Source
    An already-extracted whisper.cpp source tree (for offline builds).
    Defaults to downloading the b5454 tarball into %TEMP%.

.PARAMETER Destination
    Folder the per-ABI .so files are written to. Defaults to
    apps/walsey_voice_test/android/app/src/main/jniLibs-whisper.

.PARAMETER Abis
    Android ABIs to build. Defaults to the three ABIs the app packages:
    arm64-v8a, armeabi-v7a, x86_64.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/build_whisper_android.ps1
#>
[CmdletBinding()]
param(
    [string]$NdkPath = '',
    [string]$CMakePath = '',
    [string]$NinjaPath = '',
    [string]$Source = '',
    [string]$Destination = '',
    [string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64'),
    [string]$SourceUrl = 'https://github.com/ggml-org/whisper.cpp/archive/refs/tags/b5454.tar.gz'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceTag = 'b5454'

if ([string]::IsNullOrWhiteSpace($Destination)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        throw 'Could not resolve the script folder; pass -Destination explicitly.'
    }
    $Destination = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\walsey_voice_test\android\app\src\main\jniLibs-whisper'
}

# --- locate the NDK ---------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($NdkPath)) {
    $sdkNdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\ndk'
    if (-not (Test-Path $sdkNdk)) {
        throw "No NDK found at $sdkNdk; pass -NdkPath explicitly."
    }
    $NdkPath = (Get-ChildItem $sdkNdk -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}
if (-not (Test-Path (Join-Path $NdkPath 'build\cmake\android.toolchain.cmake'))) {
    throw "$NdkPath does not look like an Android NDK (missing build/cmake/android.toolchain.cmake)."
}
Write-Host "NDK: $NdkPath"

# --- locate CMake -----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($CMakePath)) {
    $sdkCmake = Join-Path $env:LOCALAPPDATA 'Android\Sdk\cmake'
    if (Test-Path $sdkCmake) {
        $candidate = Get-ChildItem $sdkCmake -Directory |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1
        $CMakePath = Join-Path $candidate.FullName 'bin\cmake.exe'
    }
    if (-not (Test-Path $CMakePath)) {
        $CMakePath = (Get-Command cmake -ErrorAction SilentlyContinue).Source
    }
}
if ([string]::IsNullOrWhiteSpace($CMakePath) -or -not (Test-Path $CMakePath)) {
    throw 'No CMake found under %LOCALAPPDATA%\Android\Sdk\cmake or on PATH; pass -CMakePath explicitly.'
}
Write-Host "CMake: $CMakePath"

# --- locate ninja -------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($NinjaPath)) {
    # Windows PowerShell 5.1 does not expand $vars in bare -D...=$var tokens
    # and CMake cannot locate ninja by itself here, so resolve it up front and
    # hand it to CMake through -DCMAKE_MAKE_PROGRAM.
    $sdkNinja = Join-Path (Split-Path -Parent $CMakePath) 'ninja.exe'
    if (Test-Path $sdkNinja) {
        $NinjaPath = $sdkNinja
    } else {
        $NinjaPath = (Get-Command ninja -ErrorAction SilentlyContinue).Source
    }
}
if ([string]::IsNullOrWhiteSpace($NinjaPath) -or -not (Test-Path $NinjaPath)) {
    throw 'No ninja found next to the SDK CMake or on PATH; pass -NinjaPath explicitly.'
}
Write-Host "Ninja: $NinjaPath"

# --- source tree ------------------------------------------------------------
$sourceTree = $Source
$cleanUpSource = $false
if ([string]::IsNullOrWhiteSpace($sourceTree)) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'walsey-whisper-android'
    $sourceTree = Join-Path $tempRoot "whisper-$sourceTag-src"
    if (-not (Test-Path (Join-Path $sourceTree 'CMakeLists.txt'))) {
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        $tgz = Join-Path $tempRoot 'whisper.cpp.tar.gz'
        Write-Host "Downloading $SourceUrl"
        Invoke-WebRequest -Uri $SourceUrl -OutFile $tgz -UseBasicParsing
        if (Test-Path $sourceTree) {
            Remove-Item -Recurse -Force $sourceTree
        }
        New-Item -ItemType Directory -Force -Path $sourceTree | Out-Null
        tar -xzf $tgz -C $sourceTree --strip-components=1
        Remove-Item -Force $tgz
        $cleanUpSource = $true
    }
}
if (-not (Test-Path (Join-Path $sourceTree 'CMakeLists.txt'))) {
    throw "$sourceTree does not contain a whisper.cpp CMakeLists.txt."
}
Write-Host "Source: $sourceTree"

# --- build every ABI --------------------------------------------------------
$destinationPath = [System.IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null

# The CMake build tree stays in the temp folder: anything inside a jniLibs
# source directory risks being packaged into the APK.
$buildRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'walsey-whisper-android\build'
if (Test-Path $buildRoot) {
    # The source tree lives in a temporary location and may change between
    # runs; never reuse a CMake cache that points at a different checkout.
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

foreach ($abi in $Abis) {
    Write-Host ''
    Write-Host "=== Building $abi ==="
    $buildDir = Join-Path $buildRoot $abi
    & $CMakePath -S $sourceTree -B $buildDir `
        -G Ninja `
        -DCMAKE_BUILD_TYPE=Release `
        -DCMAKE_MAKE_PROGRAM="$NinjaPath" `
        -DCMAKE_TOOLCHAIN_FILE="$NdkPath\build\cmake\android.toolchain.cmake" `
        "-DANDROID_ABI=$abi" `
        -DANDROID_PLATFORM=android-24 `
        -DGGML_NATIVE=OFF `
        -DGGML_OPENMP=OFF `
        -DGGML_CCACHE=OFF `
        -DBUILD_SHARED_LIBS=ON `
        -DWHISPER_BUILD_EXAMPLES=OFF `
        -DWHISPER_BUILD_TESTS=OFF `
        -DWHISPER_BUILD_SERVER=OFF
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for $abi." }

    & $CMakePath --build $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed for $abi." }

    $abiDirectory = Join-Path $destinationPath $abi
    New-Item -ItemType Directory -Force -Path $abiDirectory | Out-Null
    $libraries = Get-ChildItem -Path $buildDir -Recurse -Filter '*.so' |
        Where-Object {
            $_.Name -in @(
                'libwhisper.so',
                'libggml.so',
                'libggml-base.so',
                'libggml-cpu.so'
            )
        }
    if (-not $libraries) {
        throw "Build for $abi produced none of the expected .so files."
    }
    foreach ($library in $libraries) {
        Copy-Item -LiteralPath $library.FullName -Destination $abiDirectory -Force
    }
    Get-ChildItem -Path $abiDirectory -File | ForEach-Object {
        Write-Host ("  {0} ({1:N0} bytes)" -f $_.Name, $_.Length)
    }
}

# The build tree lives in the temp folder; nothing to clean inside the app
# checkout.

Write-Host ''
Write-Host "Whisper Android libraries installed under:"
Write-Host "  $destinationPath"
Write-Host 'They are packaged into the APK by the next Gradle build.'
if ($cleanUpSource) {
    Write-Host "(Source tree kept at $sourceTree for incremental rebuilds.)"
}
