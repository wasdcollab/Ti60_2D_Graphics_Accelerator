param([switch]$Large, [switch]$BeforeFix, [switch]$Overlap, [switch]$BeforeLatch, [int]$MaxBurst=64)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $projectRoot 'tools/rtl_runtime/ucrt64/bin'
if (-not (Test-Path -LiteralPath (Join-Path $bin 'iverilog.exe'))) {
    throw 'Run tools/setup_iverilog_portable.ps1 first, or use the existing Vivado runner.'
}
$env:PATH=$bin+';'+$env:PATH
$tag=if ($Large) { 'large' } else { 'baseline' }
if ($Overlap) { $tag='overlap' }
if ($BeforeLatch) { $tag+='-before-latch' }
if ($BeforeFix) { $tag+='-before' }
$simDir=Join-Path $projectRoot "work_sim/bitblt-$tag-mb$MaxBurst"
New-Item -ItemType Directory -Force -Path $simDir | Out-Null
$files=@('bitblt_top.v','../apb/apb_command_dispatcher.v','bitblt_stride_gen.v','bitblt_axi_master.v',
         'bitblt_axi_read_master.v','bitblt_read_fifo.v','bitblt_align_shifter.v','bitblt_alpha_blend.v',
         'bitblt_asset_rom.v') |
    ForEach-Object { Join-Path $projectRoot "rtl/bitblt/$_" }
if ($BeforeFix) { $files[2]=Join-Path $projectRoot 'backups/bitblt_stride_gen_before_credit_fix_20260916.v' }
if ($BeforeLatch) {
    $saved=Join-Path $projectRoot 'docs/recovery_evidence/cmd_latch_before/rtl/bitblt/bitblt_top.v'
    if (!(Test-Path -LiteralPath $saved)) { $saved=Join-Path (Split-Path $projectRoot -Parent) 'before_cmd_latch_20261025/rtl/bitblt/bitblt_top.v' }
    $files[0]=$saved
}
if ($Overlap) { $files+=Join-Path $projectRoot 'rtl/dma/video_write_guard.v' }
$argsIcarus=@('-g2012','-DBITBLT_PORTABLE_TB','-I', $PSScriptRoot, '-I', (Join-Path $projectRoot 'rtl/bitblt'), ('-DBITBLT_MAX_BURST='+$MaxBurst),
              '-s','tb_step3_bitblt_copy','-o',(Join-Path $simDir 'test.vvp'))
if ($Large) { $argsIcarus+='-DBITBLT_LARGE_TEST' }
if ($Overlap) { $argsIcarus+='-DBITBLT_OVERLAP_TEST' }
& (Join-Path $bin 'iverilog.exe') @argsIcarus @files (Join-Path $PSScriptRoot 'tb_step3_bitblt_copy.sv')
if ($LASTEXITCODE -ne 0) { throw 'RTL compile failed' }
Push-Location $simDir
try {
    $out=& (Join-Path $bin 'vvp.exe') 'test.vvp' 2>&1
    $exit=$LASTEXITCODE
    $out | Tee-Object -FilePath 'regression.log'
    $text=$out -join "`n"
    if ($BeforeLatch) {
        if (!$Overlap -or $exit -eq 0 -or $text -notmatch 'DONE timeout') { throw 'Expected command overlap deadlock was not reproduced' }
        Write-Host 'PASS expected pre-fix command overlap deadlock reproduced'
    } elseif ($BeforeFix) {
        if ($exit -eq 0 -or $text -notmatch 'DONE timeout') { throw 'Expected pre-fix COPY deadlock was not reproduced' }
        Write-Host 'PASS expected pre-fix large COPY deadlock reproduced'
    } else {
        $marker=if ($Overlap) { 'PASS BitBlt OVERLAP' } elseif ($Large) { 'PASS BitBlt LARGE' } else { 'PASS BitBlt ALPHA' }
        if ($exit -ne 0 -or $text -notmatch $marker -or $text -match '(?i)FATAL:|ERROR:') { throw 'RTL regression failed' }
    }
} finally { Pop-Location }
