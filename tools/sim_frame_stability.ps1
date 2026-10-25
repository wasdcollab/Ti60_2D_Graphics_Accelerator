$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$env:PATH = $bin + ';' + $env:PATH
Push-Location $root
try {
    $cases = @{
        tb_frame_publish = @('rtl/apb/apb_command_dispatcher.v','rtl/bitblt/bitblt_asset_rom.v')
        tb_fb_frame_abort = @('rtl/dma/dma_fb_reader.v')
        tb_gearbox_check = @('rtl/dma/dma_top.v','rtl/dma/dma_fb_reader.v',
            'rtl/dma/dma_scanline_prefetch.v','rtl/dma/dma_bucket_prefetch.v',
            'rtl/dma/async_fifo.v','rtl/common/simple_dual_port_ram.v',
            'rtl/display_engine/1_timing/video_timing_gen.v')
    }
    foreach($name in $cases.Keys) {
        & "$bin/iverilog.exe" -g2012 -I rtl/bitblt -s $name -o "work_sim/$name.vvp" "tests/$name.sv" @($cases[$name])
        if($LASTEXITCODE -ne 0) { throw "$name elaboration failed" }
        & "$bin/vvp.exe" "work_sim/$name.vvp"
        if($LASTEXITCODE -ne 0) { throw "$name failed" }
    }
} finally { Pop-Location }
