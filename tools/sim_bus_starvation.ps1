param(
    [ValidateSet('vendor','fixed')] [string]$Arbiter = 'fixed',
    [ValidateSet('1300','8000')]    [string]$Load    = '1300',
    [string]$Tag = '',
    [switch]$ExpectStall
)
# Reproduce the board's DROP=65535 on the bucket coprocessor:
#
#   vendor : rtl/common/Axi_Mux.v as it was in release_drop65535_fix_20261024
#            (tests/fixtures/Axi_Mux_vendor.v, the Sta_Cnl_Switch arbiter)
#   fixed  : the fair background round robin in the working tree
#
# With -Arbiter vendor and -Load 1300 the coprocessor never gets its first
# read grant, its 4,000,000-cycle watchdog sets fault, and the firmware's
# bucket_build_finish() publishes DROP = 65535 - the board's B/T fields.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin  = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$env:PATH = $bin + ';' + $env:PATH
if (-not $Tag) { $Tag = "starvation-$Arbiter-$Load" }
$out = Join-Path $root "work_sim/$Tag"
New-Item -ItemType Directory -Force $out | Out-Null

$arb = if ($Arbiter -eq 'vendor') { 'tests/fixtures/Axi_Mux_vendor.v' } else { 'rtl/common/Axi_Mux.v' }
$src = @(
    'tests/tb_bucket_coprocessor_axi.sv',
    'rtl/dma/dma_bucket_coprocessor.v',
    'rtl/dma/video_write_guard.v',
    $arb,
    'rtl/common/simple_dual_port_ram.v',
    'tests/efx_srl8_model.v'
)
$flags = @('-g2012', '-DBUCKET_TEST_LARGE', '-DBUCKET_TEST_MUX', '-DBUCKET_TEST_BOARD',
           '-DBUCKET_TEST_BUS_LOADED', '-I', 'rtl/common',
           '-s', 'tb_bucket_coprocessor_axi')
if ($Load -eq '8000') { $flags += '-DBUCKET_TEST_LOAD_8000' }

Push-Location $root
try {
    & "$bin/iverilog.exe" @flags -o "$out/sim.vvp" @src
    if ($LASTEXITCODE -ne 0) { throw 'elaboration failed' }
    & "$bin/vvp.exe" "$out/sim.vvp" | Tee-Object "$out/sim.log"
    $rc = $LASTEXITCODE
    if($ExpectStall) {
        if($rc -eq 0 -or !(Select-String -Quiet -Path "$out/sim.log" -Pattern 'bucket job starved on the bus')) {
            throw 'expected starvation was not reproduced'
        }
        Write-Host "PASS expected starvation: $Arbiter/$Load"
    } else {
        if($rc -ne 0) { throw "bus-loaded regression failed: $out/sim.log" }
        Write-Host "PASS bus-loaded regression: $Arbiter/$Load"
    }
} finally { Pop-Location }
