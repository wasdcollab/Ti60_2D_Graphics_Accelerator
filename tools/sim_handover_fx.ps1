$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runtime=Join-Path $root 'tools/rtl_runtime/ucrt64'
$link=Join-Path $env:TEMP 'ti60_handover_ivl'
if (!(Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target $runtime | Out-Null }
$item=Get-Item -LiteralPath $link
if($item.LinkType -ne 'Junction' -or $item.Target -ne $runtime){throw 'Runtime junction belongs to another checkout'}
$bin=Join-Path $link 'bin'
$helpers=Join-Path $link 'lib/ivl'
$env:PATH=$bin+';'+$env:PATH
Push-Location $root
try {
 & "$bin/iverilog.exe" -B $helpers -g2012 -s tb_fx_ring -o work_sim/merge_20261029/fx.vvp tests/tb_fx_ring.sv rtl/display_engine/2_layer_generators/video_fx_ring.v
 if($LASTEXITCODE -ne 0){throw 'elaboration failed'}
 $lines=& "$bin/vvp.exe" work_sim/merge_20261029/fx.vvp 2>&1
 $lines | Set-Content -Encoding UTF8 work_sim/merge_20261029/fx_rtl.log
 $lines | Write-Output
 if($LASTEXITCODE -ne 0 -or ($lines -join "`n") -notmatch 'PASS' -or ($lines -join "`n") -match 'FATAL:|ERROR:'){throw 'FX regression failed'}
} finally {Pop-Location}
