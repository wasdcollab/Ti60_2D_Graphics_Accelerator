param([switch]$Large, [switch]$BeforeFix, [int]$MaxBurst=64)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $projectRoot 'tools/rtl_runtime/ucrt64/bin'
if (-not (Test-Path -LiteralPath (Join-Path $bin 'iverilog.exe'))) {
    throw 'Run tools/setup_iverilog_portable.ps1 first, or use the existing Vivado runner.'
}
$env:PATH=$bin+';'+$env:PATH
$tag=if ($Large) { 'large' } else { 'baseline' }
if ($BeforeFix) { $tag+='-before' }
$simDir=Join-Path $projectRoot "work_sim/bitblt-$tag-mb$MaxBurst"
New-Item -ItemType Directory -Force -Path $simDir | Out-Null
$files=@('bitblt_top.v','../apb/apb_command_dispatcher.v','bitblt_stride_gen.v','bitblt_axi_master.v',
         'bitblt_axi_read_master.v','bitblt_read_fifo.v','bitblt_align_shifter.v','bitblt_alpha_blend.v',
         'bitblt_asset_rom.v') |
    ForEach-Object { Join-Path $projectRoot "rtl/bitblt/$_" }
if ($BeforeFix) { $files[2]=Join-Path $projectRoot 'backups/bitblt_stride_gen_before_credit_fix_20260916.v' }
$argsIcarus=@('-g2012','-DBITBLT_PORTABLE_TB','-I', $PSScriptRoot, '-I', (Join-Path $projectRoot 'rtl/bitblt'), ('-DBITBLT_MAX_BURST='+$MaxBurst),
              '-s','tb_step3_bitblt_copy','-o',(Join-Path $simDir 'test.vvp'))
if ($Large) { $argsIcarus+='-DBITBLT_LARGE_TEST' }
& (Join-Path $bin 'iverilog.exe') @argsIcarus @files (Join-Path $PSScriptRoot 'tb_step3_bitblt_copy.sv')
if ($LASTEXITCODE -ne 0) { throw 'RTL compile failed' }
Push-Location $simDir
try {
    $out=& (Join-Path $bin 'vvp.exe') 'test.vvp' 2>&1
    $exit=$LASTEXITCODE
    $out | Tee-Object -FilePath 'regression.log'
    $text=$out -join "`n"
    if ($BeforeFix) {
        if ($exit -eq 0 -or $text -notmatch 'DONE timeout') { throw 'Expected pre-fix COPY deadlock was not reproduced' }
        Write-Host 'PASS expected pre-fix large COPY deadlock reproduced'
    } else {
        $marker=if ($Large) { 'PASS BitBlt LARGE' } else { 'PASS BitBlt ALPHA' }
        if ($exit -ne 0 -or $text -notmatch $marker -or $text -match '(?i)FATAL:|ERROR:') { throw 'RTL regression failed' }
    }
} finally { Pop-Location }
