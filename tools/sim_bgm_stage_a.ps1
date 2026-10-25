$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$oldPath = $env:PATH
Push-Location $root
try {
    $env:PATH = $bin + ';' + $env:PATH
    New-Item -ItemType Directory -Force 'work_sim' | Out-Null
    $values = @('00', '7f', '80', 'ff')
    $fixture = [string[]](0..2047 | ForEach-Object { $values[$_ % 4] })
    [IO.File]::WriteAllLines((Join-Path $root 'work_sim/bgm_test.hex'), $fixture)
    foreach ($test in @('tb_bgm_pcm_rom', 'tb_game_audio_pcm')) {
        $out = "work_sim/$test.vvp"
        & "$bin/iverilog.exe" -g2012 -Wall -I rtl/audio -s $test -o $out `
            rtl/audio/bgm_pcm_rom.v rtl/audio/game_audio_synth.v "tests/$test.sv"
        if ($LASTEXITCODE -ne 0) { throw "$test elaboration failed" }
        & "$bin/vvp.exe" $out
        if ($LASTEXITCODE -ne 0) { throw "$test simulation failed" }
    }
    & (Join-Path $root 'tools/sim_i2s_audio.ps1')
} finally {
    $env:PATH = $oldPath
    Pop-Location
}
