param([string]$Coprocessor='rtl/dma/dma_bucket_coprocessor.v', [string]$Guard='rtl/dma/video_write_guard.v', [string]$Tag='board-fixed')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$bin=Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$env:PATH=$bin+';'+$env:PATH
$out=Join-Path $root "work_sim/$Tag"
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $root
try {
    & "$bin/iverilog.exe" -g2012 -DBUCKET_TEST_LARGE -DBUCKET_TEST_MUX -DBUCKET_TEST_BOARD -I rtl/common `
        -s tb_bucket_coprocessor_axi -o "$out/test.vvp" tests/tb_bucket_coprocessor_axi.sv `
        $Coprocessor $Guard rtl/common/Axi_Mux.v rtl/common/simple_dual_port_ram.v tests/efx_srl8_model.v
    if($LASTEXITCODE -ne 0) { throw 'elaboration failed' }
    & "$bin/vvp.exe" "$out/test.vvp" | Tee-Object "$out/result.log"
    if($LASTEXITCODE -ne 0) { throw 'board contention test failed' }
} finally { Pop-Location }
