#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the synthetic speech-recognition test set from commands.txt.

.DESCRIPTION
    Uses the Windows SAPI text-to-speech voices to speak every command in
    tools/voice_accuracy/commands.txt and writes one 16 kHz mono 16-bit PCM WAV
    per command per voice, plus an `expected.tsv` manifest:

        <file name>TAB<expected sentence>

    The audio format is chosen explicitly (16 kHz, 16-bit, mono) because that is
    exactly what the recognition pipeline requests from the microphone. If a
    test file had a different format, bin/voice_accuracy.dart rejects it instead
    of silently resampling.

    This is synthetic speech. It makes the test set deterministic and free of
    microphone/room variance, but it is NOT a substitute for the manual
    hardware checklist: real microphones, accents, distance and background noise
    behave differently.

    No network access, no cloud service, no model download: only the locally
    installed Windows voices are used.

.PARAMETER OutputDirectory
    Where the WAV files and expected.tsv are written. Defaults to
    %TEMP%\walsey_voice_corpus.

.PARAMETER CommandFile
    Command list. Defaults to commands.txt next to this script.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'walsey_voice_corpus'),
    [string]$CommandFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

if ([string]::IsNullOrWhiteSpace($CommandFile)) {
    $CommandFile = Join-Path (Split-Path -Parent $PSCommandPath) 'commands.txt'
}

if (-not (Test-Path $CommandFile)) {
    throw "Command file not found: $CommandFile"
}

$commands = Get-Content $CommandFile |
    Where-Object { $_.Trim().Length -gt 0 -and -not $_.TrimStart().StartsWith('#') } |
    ForEach-Object { $_.Trim() }

if ($commands.Count -lt 30) {
    throw "Expected at least 30 commands, found $($commands.Count)."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$synthesizer = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    $voices = @($synthesizer.GetInstalledVoices() |
        Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'en-*' })

    if ($voices.Count -eq 0) {
        throw 'No English SAPI voice is installed; the corpus cannot be generated.'
    }

    # 16 kHz mono PCM16: the exact format the recognizer expects.
    $format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
        16000,
        [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
        [System.Speech.AudioFormat.AudioChannel]::Mono)

    $manifest = New-Object System.Collections.Generic.List[string]
    $voiceIndex = 0
    foreach ($voice in $voices) {
        $voiceIndex++
        $voiceInfo = $voice.VoiceInfo
        $slug = ($voiceInfo.Name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
        $synthesizer.SelectVoice($voiceInfo.Name)
        $synthesizer.Rate = 0
        $synthesizer.Volume = 100

        $commandIndex = 0
        foreach ($command in $commands) {
            $commandIndex++
            $name = ('{0:d2}-{1:d2}-{2}.wav' -f $voiceIndex, $commandIndex, $slug)
            $path = Join-Path $OutputDirectory $name
            $synthesizer.SetOutputToWaveFile($path, $format)
            $synthesizer.Speak($command)
            $synthesizer.SetOutputToNull()
            $manifest.Add(('{0}{1}{2}' -f $name, "`t", $command))
        }
        Write-Host ("{0}: {1} files" -f $voiceInfo.Name, $commands.Count)
    }

    $manifestPath = Join-Path $OutputDirectory 'expected.tsv'
    Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8
    Write-Host ''
    Write-Host ("Wrote {0} WAV files and {1}" -f $manifest.Count, $manifestPath)
    Write-Host 'Next: dart run bin/voice_accuracy.dart --model <model path> --corpus <this folder>'
}
finally {
    $synthesizer.Dispose()
}
