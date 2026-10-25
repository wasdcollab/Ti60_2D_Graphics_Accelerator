<#
.SYNOPSIS
    BitBlt 单命令成本台（tests/tb_bitblt_cost.sv）的高速工作台。

.DESCRIPTION
    默认后端是 Verilator 原生仿真：Verilog -> C++ -> 本机 exe，全套 57 条命令
    从原来十几分钟压到十几秒。iverilog 后端保留下来做逐条数值对照。

    时钟默认由 host 主循环驱动（-Clock host）：一样是 5 ns 半周期，
    但省掉了 always #5 在 Verilator 时间轮里每周期两次的调度，
    实测同一份 RTL 快一倍左右。

    rtl\ 与 tests\ 下已有文件一律只读（新增的 tb_bitblt_cost_fast.sv 除外，
    它是新文件）；所有产物写进 work_sim\bitblt-cost\。

.EXAMPLE
    .\tools\sim_bitblt_cost_fast.ps1
    .\tools\sim_bitblt_cost_fast.ps1 -Clock tb -Tb original
    .\tools\sim_bitblt_cost_fast.ps1 -Backend iverilog -Tb original
#>
param(
    [ValidateSet('verilator','iverilog')][string]$Backend = 'verilator',
    [ValidateSet('fast','original')][string]$Tb = 'fast',
    [ValidateSet('host','tb')][string]$Clock = 'host',
    [ValidateSet('O2','O3','native')][string]$Opt = 'native',
    [switch]$Rebuild,
    [switch]$NoRun,
    [int]$Jobs = 0
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

$clockHost = ($Clock -eq 'host')
if ($clockHost -and $Tb -eq 'original') {
    Write-Warning '-Tb original 没有 TB_CLK_EXTERNAL 分支（原文件只读，不能改），自动回退到 -Clock tb'
    $clockHost = $false
}

$rtlDir   = Join-Path $root 'rtl/bitblt'
$testsDir = Join-Path $root 'tests'
$dutNames = @('bitblt_top.v','bitblt_stride_gen.v','bitblt_axi_read_master.v','bitblt_axi_master.v',
              'bitblt_apb_regs.v','bitblt_read_fifo.v','bitblt_align_shifter.v',
              'bitblt_alpha_blend.v','bitblt_asset_rom.v')
$sources = @($dutNames | ForEach-Object { Join-Path $rtlDir $_ })
if ($Tb -eq 'fast') {
    $tbFile = Join-Path $testsDir 'tb_bitblt_cost_fast.sv'
    $top    = 'tb_bitblt_cost_fast'
} else {
    $tbFile = Join-Path $testsDir 'tb_bitblt_cost.sv'
    $top    = 'tb_bitblt_cost'
}
if (-not (Test-Path $tbFile)) { throw "testbench not found: $tbFile" }
$sources += $tbFile

$tag    = "$Backend-$Tb-$($Clock)"
$outDir = Join-Path $root ("work_sim/bitblt-cost/$tag")
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$log = Join-Path $outDir 'sim.log'

function Find-Gpp {
    foreach ($c in @('C:\msys64\mingw64\bin\g++.exe','C:\Strawberry\c\bin\g++.exe')) {
        if (Test-Path $c) { return $c }
    }
    $g = Get-Command g++ -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    throw 'No g++ found; install MSYS2 mingw-w64 or Strawberry Perl.'
}

# The full command set of the fast bench is 57 commands (its own header says so and
# the run prints 57 COST lines).  There is no equivalent count for the original
# bench, whose command table is different, so that path only checks that the two
# numbers the bench prints agree with each other.
$expectedCmds = if ($Tb -eq 'fast') { 57 } else { 0 }

function Show-Result($logPath, $seconds) {
    $lines = Get-Content $logPath
    $cost  = @($lines | Where-Object { $_ -match '^COST ' })
    $tail  = @($lines | Where-Object { $_ -match '^(COSTPASS|SNPCHECK)' })
    $speed = @($lines | Where-Object { $_ -match 'cycles/s|walltime' })
    Write-Host ''
    Write-Host ('---- wall clock : {0:N2} s' -f $seconds)
    Write-Host ('---- COST lines : {0}' -f $cost.Count)
    foreach ($t in $tail)  { Write-Host ('---- ' + $t) }
    foreach ($s in $speed) { Write-Host ('---- ' + $s) }
    Write-Host ('---- log        : ' + $logPath)

    # These numbers used to be printed and nothing else: the verdict was the
    # process exit code, and the bench prints COSTPASS unconditionally, so a
    # section that returned early (57 COST lines down to 10, or a command list
    # that shrank) and a command that got slower both came out green.
    $pass = @($lines | Where-Object { $_ -match '^COSTPASS ' })
    if ($pass.Count -ne 1) { throw ('bitblt cost: expected one COSTPASS line, found ' + $pass.Count) }
    if ($pass[0] -notmatch 'cmds=(\d+)') { throw ('bitblt cost: COSTPASS has no cmds field: ' + $pass[0]) }
    $cmds = [int]$Matches[1]
    if ($cmds -ne $cost.Count) {
        throw ('bitblt cost: the bench counted ' + $cmds + ' commands but printed ' + $cost.Count + ' COST lines')
    }
    if ($expectedCmds -gt 0 -and $cmds -lt $expectedCmds) {
        throw ('bitblt cost: ' + $cmds + ' commands ran, the full set is ' + $expectedCmds + ' -- a section of the bench returned early')
    }
    if ($pass[0] -notmatch 'worst=(\d+)') { throw ('bitblt cost: COSTPASS has no worst field: ' + $pass[0]) }
    Write-Host ('---- verdict    : ' + $cmds + ' commands, worst ' + $Matches[1] + ' cycles')
}

if ($Backend -eq 'iverilog') {
    $bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
    $iv  = Join-Path $bin 'iverilog.exe'
    $vvp = Join-Path $bin 'vvp.exe'
    if (-not (Test-Path $iv)) { throw "iverilog not found: $iv -- run tools/setup_iverilog_portable.ps1" }
    $env:PATH = $bin + ';' + $env:PATH
    $vvpFile = Join-Path $outDir 'tb.vvp'
    if ($Rebuild -or -not (Test-Path $vvpFile)) {
        Write-Host '[1/2] iverilog compile ...'
        & $iv -B (Join-Path $root 'tools/rtl_runtime/ucrt64/lib/ivl') -g2012 "-I$rtlDir" "-I$testsDir" -o $vvpFile @sources
        if ($LASTEXITCODE -ne 0) { throw 'iverilog compile failed' }
    }
    if ($NoRun) { return }
    Write-Host '[2/2] vvp run (interpreter -- this is the slow path, expect many minutes) ...'
    Push-Location $root
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $vvp $vvpFile 2>&1 | Out-File -Encoding ascii $log
    $code = $LASTEXITCODE
    $sw.Stop()
    Pop-Location
    if ($code -ne 0) { throw "vvp exited $code" }
    Show-Result $log $sw.Elapsed.TotalSeconds
    return
}

$vroot = Join-Path $root 'tools/rtl_runtime/verilator/ucrt64'
$vbin  = Join-Path $vroot 'bin/verilator_bin.exe'
$vinc  = Join-Path $vroot 'share/verilator/include'
$vstd  = Join-Path $vinc 'vltstd'
if (-not (Test-Path $vbin)) { throw "verilator not found: $vbin -- run tools/setup_verilator_portable.ps1" }
$env:VERILATOR_ROOT = Join-Path $vroot 'share/verilator'
$gpp = Find-Gpp
$env:PATH = (Split-Path -Parent $gpp) + ';' + (Join-Path $vroot 'bin') + ';' + $env:PATH

$objDir = Join-Path $outDir 'obj'
$exe    = Join-Path $outDir 'sim.exe'
if ($Rebuild -or -not (Test-Path $exe)) {
    if (Test-Path $objDir) { Remove-Item -Recurse -Force $objDir }
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    Write-Host ('[1/3] verilator ' + (& $vbin --version) + ' : Verilog -> C++ ...')
    $genArgs = @('--cc','--exe','--timing','-O3',
                 '-Wno-fatal','-Wno-PINMISSING','-Wno-WIDTH','-Wno-UNOPTFLAT',
                 '--top-module',$top,'-Mdir',$objDir,"-I$rtlDir","-I$testsDir")
    if ($clockHost) { $genArgs += '-DTB_CLK_EXTERNAL' } else { $genArgs += '--main' }
    $genArgs += $sources
    & $vbin @genArgs
    if ($LASTEXITCODE -ne 0) { throw 'verilator elaboration failed' }

    $flags = switch ($Opt) {
        'O2'    { @('-O2') }
        'O3'    { @('-O3','-flto') }
        default { @('-O3','-march=native','-flto') }
    }
    $common = $flags + @('-fcoroutines','-faligned-new',
        "-I$objDir","-I$vinc","-I$vstd",
        '-DVERILATOR=1','-DVM_COVERAGE=0','-DVM_SC=0','-DVM_TIMING=1','-DVM_TRACE=0',
        '-DVM_TRACE_FST=0','-DVM_TRACE_VCD=0','-DVM_TRACE_SAIF=0','-DVM_VPI=0','-DVL_TIME_CONTEXT',
        '-Wno-bool-operation','-Wno-sign-compare','-Wno-unused-parameter','-Wno-unused-variable',
        '-Wno-unused-but-set-variable','-Wno-unused-but-set-parameter','-Wno-shadow',
        '-Wno-tautological-compare','-Wno-int-in-bool-context','-Wno-subobject-linkage',
        '-fcf-protection=none')
    $srcs = @(Get-ChildItem $objDir -Filter 'V*.cpp' | ForEach-Object { $_.FullName })
    $srcs += @((Join-Path $vinc 'verilated.cpp'), (Join-Path $vinc 'verilated_timing.cpp'),
               (Join-Path $vinc 'verilated_threads.cpp'))
    if ($clockHost) { $srcs += (Join-Path $root 'tools/sim_host_main.cpp') }
    $oDir = Join-Path $objDir 'o'
    New-Item -ItemType Directory -Force -Path $oDir | Out-Null
    Write-Host ('[2/3] g++ ' + ($flags -join ' ') + ' : ' + $srcs.Count + ' TUs, up to ' + $Jobs + ' in parallel ...')
    $hostFlags = @()
    if ($clockHost) { $hostFlags = @('-include', ('V' + $top + '.h'), ('-DTB_TOP=V' + $top)) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pending = @()
    foreach ($s in $srcs) {
        $name = [IO.Path]::GetFileNameWithoutExtension($s)
        $o    = Join-Path $oDir ($name + '.o')
        $extra = @()
        if ($name -eq 'sim_host_main') { $extra = $hostFlags }
        $al   = $common + $extra + @('-c', $s, '-o', $o)
        $proc = Start-Process -FilePath $gpp -ArgumentList $al -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $oDir ($name + '.out')) -RedirectStandardError (Join-Path $oDir ($name + '.log'))
        $pending += ,@($proc, $name)
        while ((@($pending | Where-Object { -not $_[0].HasExited })).Count -ge $Jobs) { Start-Sleep -Milliseconds 40 }
    }
    foreach ($pair in $pending) { $pair[0].WaitForExit() }
    $sw.Stop()
    $bad = @(Get-ChildItem $oDir -Filter '*.log' | Where-Object { (Get-Content $_.FullName -Raw) -match 'error:' })
    if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Host ('  ! ' + $_.Name) }; throw 'C++ compile failed' }
    Write-Host ('      compiled in {0:N1} s' -f $sw.Elapsed.TotalSeconds)
    $objs = @(Get-ChildItem $oDir -Filter '*.o' | ForEach-Object { $_.FullName })
    $lal  = $flags + @('-o', $exe) + $objs
    $lp = Start-Process -FilePath $gpp -ArgumentList $lal -NoNewWindow -PassThru -Wait -RedirectStandardOutput (Join-Path $outDir 'link.out') -RedirectStandardError (Join-Path $outDir 'link.log')
    if ($lp.ExitCode -ne 0) { Get-Content (Join-Path $outDir 'link.log') | Select-Object -First 20; throw 'link failed' }
}
if ($NoRun) { return }
Write-Host ('[3/3] native run (' + $Clock + ' clock) ...')
Push-Location $root
$sw2 = [Diagnostics.Stopwatch]::StartNew()
& $exe 2>&1 | Out-File -Encoding ascii $log
$code2 = $LASTEXITCODE
$sw2.Stop()
Pop-Location
if ($code2 -ne 0) { throw "simulation exited $code2" }
Show-Result $log $sw2.Elapsed.TotalSeconds
