param([string]$HostGcc = 'D:/Vitis_HLS/2022.2/tps/mingw/8.3.0/win64.o/nt/bin/gcc.exe')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$oldPath = $env:PATH
Push-Location $root
try {
    $env:PATH = $bin + ';' + $env:PATH
    New-Item -ItemType Directory -Force work_sim | Out-Null
    & python tools/build_asset_rom.py
    if ($LASTEXITCODE -ne 0) { throw 'Asset ROM generation failed' }
    foreach ($test in @('tb_bgm_pcm_fifo', 'tb_audio_apb')) {
        $out = "work_sim/$test.vvp"
        & "$bin/iverilog.exe" -g2012 -I rtl/bitblt -s $test -o $out `
            rtl/audio/bgm_pcm_fifo.v rtl/apb/apb_command_dispatcher.v `
            rtl/bitblt/bitblt_asset_rom.v "tests/$test.sv"
        if ($LASTEXITCODE -ne 0) { throw "$test elaboration failed" }
        & "$bin/vvp.exe" $out
        if ($LASTEXITCODE -ne 0) { throw "$test failed" }
    }
    & $HostGcc -shared -std=c11 -O2 -Wall -Wextra -Werror -Wno-int-to-pointer-cast `
        -I sw/driver -I tests tests/audio_stream_host.c -o work_sim/audio_stream_host.dll
    if ($LASTEXITCODE -ne 0) { throw 'Host firmware test compile failed' }
    & python tests/test_audio_stream.py
    if ($LASTEXITCODE -ne 0) { throw 'Firmware protocol tests failed' }
    & (Join-Path $root 'tools/sim_bgm_stage_a.ps1')
} finally {
    $env:PATH = $oldPath
    Pop-Location
}
