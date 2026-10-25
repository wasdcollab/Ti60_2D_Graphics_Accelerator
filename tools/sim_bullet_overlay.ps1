<#
.SYNOPSIS
    video_bullet_overlay 的 Icarus / Verilator 座台。

.DESCRIPTION
    B1 把弹幕交给扫描端合成。这个脚本先用 tools/gen_bullet_tiles.py 把固件自己建的
    三套 tile 从模拟 DDR 里 dump 出来、建调色板、索引化，再把它们喂给 RTL，逐格子对一遍。

    参考不是 RTL 里那张表的副本，就是固件自己的像素。产物写进 work_sim/bullet-overlay/。

.EXAMPLE
    .\tools\sim_bullet_overlay.ps1
    .\tools\sim_bullet_overlay.ps1 -Rebuild
#>
param(
    [switch]$Rebuild,
    [switch]$NoRun,
    [int]$Jobs = 0,
    [ValidateSet('Auto', 'Icarus', 'Verilator')]
    [string]$Simulator = 'Auto'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

$sources = @(
    (Join-Path $root 'rtl/display_engine/2_layer_generators/video_bullet_overlay.v'),
    (Join-Path $root 'rtl/common/simple_dual_port_ram.v')
)
$tbFile = Join-Path $root 'tests/tb_bullet_overlay.sv'
$top    = 'tb_bullet_overlay'
foreach ($f in ($sources + $tbFile)) {
    if (-not (Test-Path $f)) { throw "not found: $f" }
}

$iverilog = Join-Path $root 'tools/rtl_runtime/ucrt64/bin/iverilog.exe'
if ($Simulator -eq 'Auto') {
    $Simulator = if (Test-Path $iverilog) { 'Icarus' } else { 'Verilator' }
}
$outDir = Join-Path $root ('work_sim/bullet-overlay/' + $Simulator.ToLower())
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$log = Join-Path $outDir 'sim.log'

Write-Host '[0/3] dumping the firmware tiles ...'
$python = Join-Path $root 'tools/pypy/pypy3.exe'
if (-not (Test-Path $python)) { $python = 'python' }
$oldPure = $env:SIM_PURE_PYTHON
$oldUtf8 = $env:PYTHONUTF8
try {
    $env:SIM_PURE_PYTHON = '1'
    $env:PYTHONUTF8 = '1'
    & $python (Join-Path $root 'tools/gen_bullet_tiles.py')
    if ($LASTEXITCODE -ne 0) { throw 'gen_bullet_tiles.py failed' }
    & $python (Join-Path $root 'tools/check_bullet_fallback.py')
    if ($LASTEXITCODE -ne 0) { throw 'Scanout fallback model check failed' }
} finally {
    $env:SIM_PURE_PYTHON = $oldPure
    $env:PYTHONUTF8 = $oldUtf8
}
foreach ($f in @('bullet_tiles.hex','bullet_palette.hex','bullet_stream.hex')) {
    Copy-Item (Join-Path $root "simulator/output/$f") (Join-Path $outDir $f) -Force
}

if ($Simulator -eq 'Icarus') {
    if (-not (Test-Path $iverilog)) { throw "iverilog not found: $iverilog" }
    $oldPath = $env:PATH
    try {
        $env:PATH = (Split-Path -Parent $iverilog) + ';' + $env:PATH
        $vvp = Join-Path (Split-Path -Parent $iverilog) 'vvp.exe'
        $image = Join-Path $outDir 'sim.vvp'
        # Always compile the small bench, so an older image cannot hide edits.
        & $iverilog -g2012 -s $top -o $image ($sources + $tbFile)
        if ($LASTEXITCODE -ne 0) { throw 'iverilog elaboration failed' }
        if ($NoRun) { return }
        Push-Location $outDir
        try {
            & $vvp $image 2>&1 | Out-File -Encoding ascii $log
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        Get-Content $log | Where-Object { $_ -match 'CHECKED|PASS |FAIL |stream:|probe:' } | Write-Host
        if ($code -ne 0 -or -not (Select-String -Path $log -Pattern '^PASS ')) {
            throw "bullet overlay simulation failed; see $log"
        }
        Write-Host "log: $log"
    } finally { $env:PATH = $oldPath }
    return
}

$vroot = Join-Path $root 'tools/rtl_runtime/verilator/ucrt64'
$vbin  = Join-Path $vroot 'bin/verilator_bin.exe'
$vinc  = Join-Path $vroot 'share/verilator/include'
$vstd  = Join-Path $vinc 'vltstd'
if (-not (Test-Path $vbin)) { throw "verilator not found: $vbin" }
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
$newerSources = @($sources + $tbFile | Where-Object {
    (Test-Path $exe) -and (Get-Item $_).LastWriteTimeUtc -gt (Get-Item $exe).LastWriteTimeUtc
})
if ($Rebuild -or -not (Test-Path $exe) -or $newerSources.Count -gt 0) {
    if (Test-Path $objDir) {
        $resolved = [IO.Path]::GetFullPath($objDir)
        $allowed = [IO.Path]::GetFullPath((Join-Path $root 'work_sim/bullet-overlay')) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clear a directory outside the simulation workspace: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    Write-Host ('[1/3] verilator ' + (& $vbin --version) + ' : Verilog -> C++ ...')
    & $vbin --cc --exe --main --timing -O3 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT --top-module $top -Mdir $objDir ($sources + $tbFile)
    if ($LASTEXITCODE -ne 0) { throw 'verilator elaboration failed' }
    $flags = @('-O2','-fcoroutines','-faligned-new',
        "-I$objDir","-I$vinc","-I$vstd",
        '-DVERILATOR=1','-DVM_COVERAGE=0','-DVM_SC=0','-DVM_TIMING=1','-DVM_TRACE=0',
        '-DVM_TRACE_FST=0','-DVM_TRACE_VCD=0','-DVM_TRACE_SAIF=0','-DVM_VPI=0','-DVL_TIME_CONTEXT',
        '-Wno-unused-parameter','-Wno-unused-variable','-Wno-sign-compare','-Wno-unused-but-set-variable')
    $srcs = @(Get-ChildItem $objDir -Filter 'V*.cpp' | ForEach-Object { $_.FullName })
    $srcs += @((Join-Path $vinc 'verilated.cpp'), (Join-Path $vinc 'verilated_timing.cpp'),
               (Join-Path $vinc 'verilated_threads.cpp'))
    Write-Host ('[2/3] g++ : ' + $srcs.Count + ' TUs, up to ' + $Jobs + ' in parallel ...')
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
    $bad = @(Get-ChildItem $objDir -Filter '*.log' | Where-Object { (Get-Content $_.FullName -Raw) -match 'error:' })
    if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Host ('  ! ' + $_.Name) }; throw 'C++ compile failed' }
    $objs = @(Get-ChildItem $objDir -Filter '*.o' | ForEach-Object { $_.FullName })
    $lp = Start-Process -FilePath $gpp -ArgumentList ($flags + @('-o', $exe) + $objs) -NoNewWindow -PassThru -Wait -RedirectStandardOutput (Join-Path $outDir 'link.out') -RedirectStandardError (Join-Path $outDir 'link.log')
    if ($lp.ExitCode -ne 0) { Get-Content (Join-Path $outDir 'link.log') | Select-Object -First 20; throw 'link failed' }
}
if ($NoRun) { return }
Write-Host '[3/3] native run ...'
Push-Location $outDir
& $exe 2>&1 | Out-File -Encoding ascii $log
$code = $LASTEXITCODE
Pop-Location
if ($code -ne 0) { throw "simulation exited $code" }

$lines = Get-Content $log
foreach ($l in ($lines | Where-Object { $_ -match 'CHECKED|PASS |FAIL |tiles:|palette|store' })) {
    Write-Host ('---- ' + $l)
}
Write-Host ('---- log : ' + $log)
if (-not ($lines | Where-Object { $_ -match '^PASS ' })) { throw 'tb_bullet_overlay did not report PASS' }
