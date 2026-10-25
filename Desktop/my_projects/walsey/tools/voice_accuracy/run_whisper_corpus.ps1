#Requires -Version 5.1
<#
.SYNOPSIS
    Transcribes a WAV corpus with a whisper.cpp command-line build.

.DESCRIPTION
    Runs the same recordings and the same expected sentences as
    bin/voice_accuracy.dart, but through whisper.cpp instead of Vosk, and writes
    a tab-separated transcript file:

        <file name>TAB<raw transcript>TAB<engine milliseconds>

    The third column is whisper.cpp's own "total time" (encode + decode, model
    already loaded), which is comparable to the Vosk harness's per-file decode
    time. Process startup and model loading are excluded from it on purpose;
    they are reported separately below.

    bin/voice_accuracy.dart --transcripts <this file> then scores the result with
    the exact same exact-match / WER / parser code as the Vosk runs.

    Nothing is downloaded here: point -WhisperCli and -Model at files you already
    have (for example the whisper-bin-x64 release archive and ggml-base.en.bin).

.PARAMETER CorpusDirectory
    Folder containing expected.tsv and the WAV files.

.PARAMETER WhisperCli
    Path to whisper-cli.exe.

.PARAMETER Model
    Path to a ggml model (ggml-base.en.bin, ggml-small.en.bin, ...).

.PARAMETER OutputFile
    Where to write the transcript TSV. Defaults to <CorpusDirectory>\whisper.tsv.

.PARAMETER Threads
    whisper.cpp CPU threads. Defaults to 4 so the result is reproducible.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CorpusDirectory,
    [Parameter(Mandatory = $true)][string]$WhisperCli,
    [Parameter(Mandatory = $true)][string]$Model,
    [string]$OutputFile = '',
    [int]$Threads = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $WhisperCli)) { throw "whisper-cli not found: $WhisperCli" }
if (-not (Test-Path $Model)) { throw "model not found: $Model" }
$manifest = Join-Path $CorpusDirectory 'expected.tsv'
if (-not (Test-Path $manifest)) { throw "expected.tsv not found in $CorpusDirectory" }
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $CorpusDirectory 'whisper.tsv'
}

$entries = Get-Content $manifest | Where-Object {
    $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#')
}
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('walsey_whisper_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null

$results = New-Object System.Collections.Generic.List[string]
$totalEngineMs = 0.0
$totalWallMs = 0.0
$index = 0
try {
    foreach ($entry in $entries) {
        $index++
        $tab = $entry.IndexOf("`t")
        if ($tab -le 0) { continue }
        $name = $entry.Substring(0, $tab).Trim()
        $audio = Join-Path $CorpusDirectory $name
        if (-not (Test-Path $audio)) {
            Write-Warning "missing audio: $name"
            continue
        }
        $outBase = Join-Path $temp ([System.IO.Path]::GetFileNameWithoutExtension($name))
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        # whisper.cpp writes progress to stderr; PowerShell would treat that as a
        # terminating error under `Stop`, so relax it just for the native call.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $log = & $WhisperCli -m $Model -f $audio -l en -t $Threads -oj -of $outBase 2>&1
        }
        finally {
            $ErrorActionPreference = $previous
        }
        $clock.Stop()
        $totalWallMs += $clock.ElapsedMilliseconds
        $jsonPath = "$outBase.json"
        if (-not (Test-Path $jsonPath)) {
            Write-Warning "no JSON output for $name"
            continue
        }
        $json = Get-Content $jsonPath -Raw | ConvertFrom-Json
        $text = (@($json.transcription) | ForEach-Object { $_.text }) -join ' '
        $text = (($text -replace '\s+', ' ').Trim())
        $engineMs = $clock.ElapsedMilliseconds
        $match = [regex]::Match(($log -join "`n"), 'total time =\s*([0-9.]+)\s*ms')
        if ($match.Success) {
            $engineMs = [double]::Parse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $totalEngineMs += $engineMs
        }
        $results.Add(('{0}{1}{2}{1}{3}' -f $name, "`t", $text, [int][math]::Round($engineMs)))
        Write-Progress -Activity 'whisper.cpp corpus' -Status "$index/$($entries.Count) $name" -PercentComplete ((100 * $index) / [math]::Max($entries.Count, 1))
    }

    Set-Content -Path $OutputFile -Value $results -Encoding UTF8
    Write-Host ''
    Write-Host ("files        {0}" -f $results.Count)
    Write-Host ("engine time  {0:N0} ms ({1:N2} s)" -f $totalEngineMs, ($totalEngineMs / 1000))
    Write-Host ("wall time    {0:N0} ms (includes process start + model load per file)" -f $totalWallMs)
    Write-Host ("wrote        {0}" -f $OutputFile)
}
finally {
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}
