param([string]$HostGcc = 'D:/Vitis_HLS/2022.2/tps/mingw/8.3.0/win64.o/nt/bin/gcc.exe')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$oldPath = $env:PATH
Push-Location $root
try {
    $env:PATH = $bin + ';' + $env:PATH
    foreach ($test in @('tb_bgm_flash_spi', 'tb_bgm_pcm_fifo', 'tb_audio_apb')) {
        & "$bin/iverilog.exe" -g2012 -I rtl/bitblt -s $test -o "work_sim/$test.vvp" `
            rtl/audio/bgm_flash_spi.v rtl/audio/bgm_pcm_fifo.v rtl/apb/apb_command_dispatcher.v `
            rtl/bitblt/bitblt_asset_rom.v "tests/$test.sv"
        if ($LASTEXITCODE -ne 0) { throw "$test elaboration failed" }
        & "$bin/vvp.exe" "work_sim/$test.vvp"
        if ($LASTEXITCODE -ne 0) { throw "$test failed" }
    }
    & $HostGcc -std=c11 -O2 -Wall -Wextra -Werror -Wno-int-to-pointer-cast `
        -I sw/driver -I tests tests/audio_flash_host.c -o work_sim/audio_flash_host.exe
    if ($LASTEXITCODE -ne 0) { throw 'C driver test build failed' }
    & .\work_sim\audio_flash_host.exe
    if ($LASTEXITCODE -ne 0) { throw 'C driver tests failed' }
} finally { $env:PATH = $oldPath; Pop-Location }
