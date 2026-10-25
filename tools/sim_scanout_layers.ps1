<#
.SYNOPSIS
    Verilator bench for tests/tb_scanout_layers.sv -- composite the frame the
    SCANOUT would put on the wire, out of the firmware own registers, bucket
    tables and tile store.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/sim_scanout_layers.ps1 -Case stress
    powershell -ExecutionPolicy Bypass -File tools/sim_scanout_layers.ps1 -Case menu -Rebuild
#>
param(
    [ValidateSet("menu","game","stress","exit","pause","cut","cutpause","beampause","beamfree")][string]$Case = "stress",
    [switch]$Rebuild,
    [switch]$NoDump
)
$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$vroot = Join-Path $root "tools/rtl_runtime/verilator/ucrt64"
$vbin  = Join-Path $vroot "bin/verilator_bin.exe"
$vinc  = Join-Path $vroot "share/verilator/include"
$vstd  = Join-Path $vinc "vltstd"
if (-not (Test-Path $vbin)) { throw "verilator not found: $vbin" }
$env:VERILATOR_ROOT = Join-Path $vroot "share/verilator"

$gpp = "C:/msys64/mingw64/bin/g++.exe"
if (-not (Test-Path $gpp)) { $gpp = "C:/Strawberry/c/bin/g++.exe" }
if (-not (Test-Path $gpp)) { throw "no g++ found" }
$env:PATH = (Split-Path -Parent $gpp) + ";" + (Join-Path $vroot "bin") + ";" + $env:PATH

$outDir = Join-Path $root "work_sim/scanout"
$objDir = Join-Path $outDir "obj"
$exe    = Join-Path $outDir "scanout.exe"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (-not $NoDump) {
    Write-Host ("[0/3] dump firmware state for case " + $Case + " ...")
    Push-Location $root
    & python tools/dump_scanout_state.py $Case
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw "dump failed" }
    Pop-Location
}

$srcs = @(
    "rtl/v_dma/video_dma_read.v",
    "rtl/v_dma/video_timing_gen.v",
    "rtl/v_dma/async_fifo.v",
    "rtl/v_dma/video_bullet_overlay.v",
    "rtl/v_dma/video_weather.v",
    "rtl/v_dma/video_laser.v",
    "rtl/v_dma/video_beam.v",
    "rtl/v_dma/video_dual_hud.v",
    "rtl/common/simple_dual_port_ram.v",
    "tests/tb_scanout_layers.sv"
) | ForEach-Object { Join-Path $root $_ }

if ($Rebuild -or -not (Test-Path $exe)) {
    if (Test-Path $objDir) { Remove-Item -Recurse -Force $objDir }
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    Write-Host "[1/3] verilator : Verilog to C++ ..."
    $vflags = @("--cc","--exe","--main","--timing","-O3","-Wno-fatal","-Wno-WIDTH",
                "-Wno-UNUSED","-Wno-CASEINCOMPLETE","-Wno-DECLFILENAME","-Wno-UNDRIVEN",
                "-Wno-SYNCASYNCNET","-Wno-MISINDENT","-Wno-ALWNEVER","-Wno-LATCH",
                "--top-module","tb_scanout_layers","-Mdir",$objDir)
    & $vbin @vflags @srcs
    if ($LASTEXITCODE -ne 0) { throw "verilator elaboration failed" }

    $flags = @("-O2","-fcoroutines","-faligned-new",
        "-I$objDir","-I$vinc","-I$vstd",
        "-DVERILATOR=1","-DVM_COVERAGE=0","-DVM_SC=0","-DVM_TIMING=1","-DVM_TRACE=0",
        "-DVM_TRACE_FST=0","-DVM_TRACE_VCD=0","-DVM_TRACE_SAIF=0","-DVM_VPI=0",
        "-DVL_TIME_CONTEXT","-w")
    $cpp = @(Get-ChildItem $objDir -Filter "V*.cpp" | ForEach-Object { $_.FullName })
    $cpp += @((Join-Path $vinc "verilated.cpp"), (Join-Path $vinc "verilated_timing.cpp"),
              (Join-Path $vinc "verilated_threads.cpp"))
    Write-Host ("[2/3] g++ link : " + $cpp.Count + " TUs ...")
    & $gpp @flags @cpp "-o" $exe
    if ($LASTEXITCODE -ne 0) { throw "link failed" }
}

Write-Host "[3/3] run ..."
Push-Location $outDir
& $exe
$code = $LASTEXITCODE
Pop-Location
if ($code -eq 0) {
    $shot = Join-Path $outDir "scanout.ppm"
    if (Test-Path $shot) {
        $png = Join-Path $root "simulator/output/scanout_$Case.png"
        Copy-Item $shot (Join-Path $outDir "scanout_$Case.ppm") -Force
        Push-Location $root
        & python tools/ppm_to_png.py (Join-Path $outDir "scanout_$Case.ppm")
        Copy-Item (Join-Path $outDir "scanout_$Case.png") $png -Force
        Pop-Location
        Write-Host ("---- frame: " + $png)
    }
}
Write-Host ("---- scanout.exe exited " + $code)
exit $code
