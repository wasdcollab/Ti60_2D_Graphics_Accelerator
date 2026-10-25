<#
.SYNOPSIS
    把 PyPy 3.11（JIT 解释器）装进 tools\pypy，并装好 Pillow。

.DESCRIPTION
    项目自带、可回退：只往 tools\pypy 解包，不改系统 PATH，也不动 Anaconda。
    PyPy 是同一份 test_runner.py / rv32i_soc_vm.py 的另一种执行引擎，
    实测比 CPython 快 2.5~10 倍（场景越长收益越大）。
    想退回 CPython 的话，直接不用这个目录即可。
#>
param(
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tools'
$dest = Join-Path $tools 'pypy'
$exe = Join-Path $dest 'pypy.exe'
if ((Test-Path $exe) -and -not $Force) {
    Write-Host ('pypy already present: ' + $exe)
    & $exe --version
    return
}
$downloads = Join-Path $tools 'downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$name = 'pypy3.11-v7.3.20-win64.zip'
$archive = Join-Path $downloads $name
$expect = 'A8D36F6CEB1D9BE6CF24A73B0BA103E7567E396B2F7A33426B05E4A06330755B'
if (-not (Test-Path -LiteralPath $archive)) {
    Write-Host ('downloading ' + $name)
    Invoke-WebRequest -Uri ('https://downloads.python.org/pypy/' + $name) -OutFile $archive -UseBasicParsing
}
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($hash -ne $expect) { throw "Package checksum mismatch: $name" }
$members = & tar -tf $archive
if ($LASTEXITCODE -ne 0) { throw "Cannot list $name" }
foreach ($m in $members) {
    if ([IO.Path]::IsPathRooted($m) -or $m.Contains('..')) { throw "Unsafe archive path: $m" }
}
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$stage = Join-Path $downloads '_pypy_stage'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
& tar -xf $archive -C $stage
if ($LASTEXITCODE -ne 0) { throw "Cannot extract $name" }
$inner = Get-ChildItem $stage -Directory | Select-Object -First 1
Move-Item $inner.FullName $dest
Remove-Item -Recurse -Force $stage
Write-Host 'installing Pillow (test_runner imports it at module level) ...'
& $exe -m ensurepip | Out-Null
& $exe -m pip install --quiet --disable-pip-version-check pillow
& $exe -c "from PIL import Image; import sys; print('PIL OK on ' + sys.implementation.name)"
& $exe --version
Write-Host 'pypy ready.'
