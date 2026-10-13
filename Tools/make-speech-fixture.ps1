# Synthesizes a known sentence with the Windows speech engine (SAPI), so the
# transcription tests have real speech with a known transcript. Output goes to
# Tests/Fixtures/generated/, which is gitignored: it is rebuilt from this script.
#
#   powershell -File Tools/make-speech-fixture.ps1
param([string]$OutDir = (Join-Path $PSScriptRoot "..\Tests\Fixtures\generated"))

Add-Type -AssemblyName System.Speech
New-Item -ItemType Directory -Force $OutDir | Out-Null

$text = "The quick brown fox jumps over the lazy dog. Please transcribe this recording carefully. We will meet on Thursday at three thirty."
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synth.SelectVoice("Microsoft Zira Desktop")
$path = Join-Path $OutDir "speech-zira.wav"
# 16 kHz mono 16-bit, the shape speech engines expect.
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$synth.SetOutputToWaveFile($path, $format)
$synth.Speak($text)
$synth.Dispose()
Set-Content -Path (Join-Path $OutDir "speech-zira.txt") -Value $text -Encoding utf8
Write-Host "wrote $path"
