# tools/run_bloom_sim.ps1 -- build & run the bloom filter bench, and JUDGE it.
# run_sim.bat did neither: it appended SIMULATION_FINISHED to tests/sim.log whether
# the bench passed, failed or fell over, and nothing looked at the result.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$xv = "D:\Xilinx\Vivado\2022.2\bin"
if (-not (Test-Path "$xv\xvlog.bat")) { throw "xvlog not found at $xv" }
$log = Join-Path $root "tests\sim.log"
Push-Location $root
try {
    & "$xv\xvlog.bat" -sv tests\tb_bloom_filter.sv rtl\display_engine\4_post_process\video_bloom_filter.v *> $log
    if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED (xvlog)"; exit 1 }
    & "$xv\xelab.bat" -debug typical work.tb_bloom_filter -s tb_bloom_sim *>> $log
    if ($LASTEXITCODE -ne 0) { Write-Host "ELABORATION FAILED (xelab)"; exit 1 }
    & "$xv\xsim.bat" tb_bloom_sim -R *>> $log
    $code = $LASTEXITCODE
} finally { Pop-Location }
$text = Get-Content $log -Raw
if ($text -match "FAIL tb_bloom_filter") { Write-Host "FAIL tb_bloom_filter"; exit 1 }
if ($text -notmatch "PASS tb_bloom_filter") { Write-Host "NO VERDICT in the log"; exit 1 }
if ($code -ne 0) { Write-Host ("xsim exited " + $code); exit 1 }
Write-Host "PASS tb_bloom_filter"
exit 0