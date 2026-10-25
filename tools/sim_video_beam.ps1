<#
.SYNOPSIS
    video_beam 座台（tests/tb_video_beam.sv）的 Verilator 工作台。

.DESCRIPTION
    A3 把玩家激光和 cut/beam 预警细线从引擎搬到了扫描端。这个脚本把
    video_beam.v 单独拎出来，喂给它整屏的 (x, y)，再拿固件自己在开机时写进
    MM_LASER_GLOW 的那张贴图逐像素对一遍。

    参考不是 RTL 里那张表的副本：tools/dump_beam_ref.py 从模拟 DDR 里把固件
    真正建出来的 16x768 字节 dump 成 hex，$readmemh 直接读进座台。RTL 的查表和
    固件的贴图只要有一个像素不一致，这里就报出来。

    rtl\ 与 tests\ 下已有文件一律只读；产物写进 work_sim\video-beam\。

.EXAMPLE
    .\tools\sim_video_beam.ps1
    .\tools\sim_video_beam.ps1 -Rebuild
#>
param(
    [ValidateSet('verilator','iverilog')][string]$Backend = 'verilator',
    [switch]$Rebuild,
    [switch]$NoRun,
    [int]$Jobs = 0
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

$rtlFile = Join-Path $root 'rtl/display_engine/2_layer_generators/video_beam.v'
$tbFile  = Join-Path $root 'tests/tb_video_beam.sv'
$top     = 'tb_video_beam'
foreach ($f in @($rtlFile, $tbFile)) {
    if (-not (Test-Path $f)) { throw "not found: $f" }
}

$outDir = Join-Path $root ("work_sim/video-beam/$Backend")
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$log = Join-Path $outDir 'sim.log'

# The reference sheet: the firmware's own bytes, dumped out of the emulated DDR.
Write-Host '[0/3] dumping the firmware sheet (MM_LASER_GLOW) ...'
& python (Join-Path $root 'tools/dump_beam_ref.py')
if ($LASTEXITCODE -ne 0) { throw 'dump_beam_ref.py failed' }
Copy-Item (Join-Path $root 'simulator/output/laser_glow.hex') (Join-Path $outDir 'laser_glow.hex') -Force

if ($Backend -eq 'iverilog') {
    $bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
    $iv  = Join-Path $bin 'iverilog.exe'
    $vvp = Join-Path $bin 'vvp.exe'
    if (-not (Test-Path $iv)) { throw "iverilog not found: $iv -- run tools/setup_iverilog_portable.ps1" }
    $env:PATH = $bin + ';' + $env:PATH
    $vvpFile = Join-Path $outDir 'tb.vvp'
    if ($Rebuild -or -not (Test-Path $vvpFile)) {
        Write-Host '[1/3] iverilog compile ...'
        & $iv -B (Join-Path $root 'tools/rtl_runtime/ucrt64/lib/ivl') -g2012 -o $vvpFile $rtlFile $tbFile
        if ($LASTEXITCODE -ne 0) { throw 'iverilog compile failed' }
    }
    if ($NoRun) { return }
    Write-Host '[2/3] vvp run ...'
    Push-Location $outDir
    & $vvp $vvpFile 2>&1 | Out-File -Encoding ascii $log
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -ne 0) { throw "vvp exited $code" }
} else {
    $vroot = Join-Path $root 'tools/rtl_runtime/verilator/ucrt64'
    $vbin  = Join-Path $vroot 'bin/verilator_bin.exe'
    $vinc  = Join-Path $vroot 'share/verilator/include'
    $vstd  = Join-Path $vinc 'vltstd'
    if (-not (Test-Path $vbin)) { throw "verilator not found: $vbin -- run tools/setup_verilator_portable.ps1" }
    $env:VERILATOR_ROOT = Join-Path $vroot 'share/verilator'

    $gpp = $null
    foreach ($c in @('C:\msys64\mingw64\bin\g++.exe','C:\Strawberry\c\bin\g++.exe')) {
        if (Test-Path $c) { $gpp = $c; break }
    }
    if (-not $gpp) {
        $g = Get-Command g++ -ErrorAction SilentlyContinue
        if ($g) { $gpp = $g.Source }
    }
    if (-not $gpp) { throw 'No g++ found; install MSYS2 mingw-w64 or Strawberry Perl.' }
    $env:PATH = (Split-Path -Parent $gpp) + ';' + (Join-Path $vroot 'bin') + ';' + $env:PATH

    $objDir = Join-Path $outDir 'obj'
    $exe    = Join-Path $outDir 'sim.exe'
    if ($Rebuild -or -not (Test-Path $exe)) {
        if (Test-Path $objDir) { Remove-Item -Recurse -Force $objDir }
        New-Item -ItemType Directory -Force -Path $objDir | Out-Null
        Write-Host ('[1/3] verilator ' + (& $vbin --version) + ' : Verilog -> C++ ...')
        & $vbin --cc --exe --main --timing -O3 -Wno-fatal -Wno-WIDTH -Wno-UNUSED --top-module $top -Mdir $objDir $rtlFile $tbFile
        if ($LASTEXITCODE -ne 0) { throw 'verilator elaboration failed' }

        $flags  = @('-O2','-fcoroutines','-faligned-new',
            "-I$objDir","-I$vinc","-I$vstd",
            '-DVERILATOR=1','-DVM_COVERAGE=0','-DVM_SC=0','-DVM_TIMING=1','-DVM_TRACE=0',
            '-DVM_TRACE_FST=0','-DVM_TRACE_VCD=0','-DVM_TRACE_SAIF=0','-DVM_VPI=0','-DVL_TIME_CONTEXT',
            '-Wno-unused-parameter','-Wno-unused-variable','-Wno-sign-compare')
        $srcs = @(Get-ChildItem $objDir -Filter 'V*.cpp' | ForEach-Object { $_.FullName })
        $srcs += @((Join-Path $vinc 'verilated.cpp'), (Join-Path $vinc 'verilated_timing.cpp'),
                   (Join-Path $vinc 'verilated_threads.cpp'))
        Write-Host ('[2/3] g++ : ' + $srcs.Count + ' TUs, up to ' + $Jobs + ' in parallel ...')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $pending = @()
        foreach ($s in $srcs) {
            $name = [IO.Path]::GetFileNameWithoutExtension($s)
            $o    = Join-Path $objDir ($name + '.o')
            $al   = $flags + @('-c', $s, '-o', $o)
            $proc = Start-Process -FilePath $gpp -ArgumentList $al -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $objDir ($name + '.out')) -RedirectStandardError (Join-Path $objDir ($name + '.log'))
            $pending += ,@($proc, $name)
            while ((@($pending | Where-Object { -not $_[0].HasExited })).Count -ge $Jobs) { Start-Sleep -Milliseconds 40 }
        }
        foreach ($pair in $pending) { $pair[0].WaitForExit() }
        $sw.Stop()
        $bad = @(Get-ChildItem $objDir -Filter '*.log' | Where-Object { (Get-Content $_.FullName -Raw) -match 'error:' })
        if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Host ('  ! ' + $_.Name) }; throw 'C++ compile failed' }
        Write-Host ('      compiled in {0:N1} s' -f $sw.Elapsed.TotalSeconds)
        $objs = @(Get-ChildItem $objDir -Filter '*.o' | ForEach-Object { $_.FullName })
        $lp = Start-Process -FilePath $gpp -ArgumentList ($flags + @('-o', $exe) + $objs) -NoNewWindow -PassThru -Wait -RedirectStandardOutput (Join-Path $outDir 'link.out') -RedirectStandardError (Join-Path $outDir 'link.log')
        if ($lp.ExitCode -ne 0) { Get-Content (Join-Path $outDir 'link.log') | Select-Object -First 20; throw 'link failed' }
    }
    if ($NoRun) { return }
    Write-Host '[3/3] native run (tb clock) ...'
    Push-Location $outDir
    & $exe 2>&1 | Out-File -Encoding ascii $log
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -ne 0) { throw "simulation exited $code" }
}

$lines = Get-Content $log
foreach ($l in ($lines | Where-Object { $_ -match 'CHECKED|PASS |FAIL |sheet:|magenta-keyed|beam:|y=' })) {
    Write-Host ('---- ' + $l)
}
Write-Host ('---- log : ' + $log)
if (-not ($lines | Where-Object { $_ -match '^PASS ' })) { throw 'tb_video_beam did not report PASS' }
