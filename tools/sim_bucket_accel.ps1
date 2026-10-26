param([switch]$Direct, [switch]$Large, [switch]$Load10000, [switch]$Load20000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$env:PATH = $bin + ';' + $env:PATH
$name = if ($Direct) { 'bucket-direct' } else { 'bucket-mux' }
if ($Large) { $name += '-large' }
if ($Load10000) { $name += '-10000' }
if ($Load20000) { $name += '-20000' }
$out = Join-Path $root "work_sim/$name"
New-Item -ItemType Directory -Force $out | Out-Null
$sources = @('tests/tb_bucket_coprocessor_axi.sv', 'rtl/dma/dma_bucket_coprocessor.v', 'rtl/common/simple_dual_port_ram.v')
$flags = @('-g2012', '-DBUCKET_TEST_SNAPSHOT', '-s', 'tb_bucket_coprocessor_axi', '-I', 'rtl/common')
if ($Large) { $flags += '-DBUCKET_TEST_LARGE' }
if ($Load10000) { $flags += '-DBUCKET_TEST_10000' }
if ($Load20000) { $flags += '-DBUCKET_TEST_20000' }
if (-not $Direct) {
    $flags += '-DBUCKET_TEST_MUX'
    $sources += @('rtl/common/Axi_Mux.v', 'tests/efx_srl8_model.v')
}
Push-Location $root
try {
    & "$bin/iverilog.exe" @flags -o "$out/sim.vvp" @sources
    if ($LASTEXITCODE -ne 0) { throw 'elaboration failed' }
    & "$bin/vvp.exe" "$out/sim.vvp" | Tee-Object "$out/sim.log"
    if ($LASTEXITCODE -ne 0) { throw "simulation failed: $out/sim.log" }
} finally { Pop-Location }
