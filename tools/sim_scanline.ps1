$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$env:PATH = $bin + ';' + $env:PATH
$out = Join-Path $root 'work_sim/scanline'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $root
try {
    & "$bin/iverilog.exe" -g2012 -s tb_bullet_scanline -o "$out/test.vvp" tests/tb_bullet_scanline.sv rtl/display_engine/2_layer_generators/video_bullet_scanline.v rtl/common/simple_dual_port_ram.v
    if ($LASTEXITCODE -ne 0) { throw 'elaboration failed' }
    & "$bin/vvp.exe" "$out/test.vvp" | Tee-Object "$out/sim.log"
    if ($LASTEXITCODE -ne 0) { throw 'simulation failed' }
    & "$bin/iverilog.exe" -g2012 -s tb_scanline_prefetch -o "$out/prefetch.vvp" tests/tb_scanline_prefetch.sv rtl/dma/dma_scanline_prefetch.v rtl/common/simple_dual_port_ram.v
    if ($LASTEXITCODE -ne 0) { throw 'prefetch elaboration failed' }
    & "$bin/vvp.exe" "$out/prefetch.vvp" | Tee-Object "$out/prefetch.log"
    if ($LASTEXITCODE -ne 0) { throw 'prefetch simulation failed' }
} finally { Pop-Location }
