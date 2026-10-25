<#
.SYNOPSIS
    把 Verilator（MSYS2 ucrt64 构建）装进 tools\rtl_runtime\verilator。

.DESCRIPTION
    项目自带、可回退：只往 tools\rtl_runtime\verilator 解包，不碰系统 PATH，
    也不动已有的 ucrt64（iverilog）运行时。编译生成的 C++ 需要一个 g++
    （MSYS2 mingw64 或 Strawberry Perl 自带即可）。
#>
param(
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $root 'tools/rtl_runtime'
$dest    = Join-Path $runtime 'verilator'
$bin     = Join-Path $dest 'ucrt64/bin/verilator_bin.exe'
if ((Test-Path $bin) -and -not $Force) {
    Write-Host ('verilator already present: ' + $bin)
    & $bin --version
    return
}
$downloads = Join-Path $runtime 'downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$packages = @(
    @('verilator-5.050-1', 'A3ADB510E9A5298C0FF563AF570A4411EA11FD19F7ECB12C8780C561FF462C86')
)
foreach ($package in $packages) {
    $name    = 'mingw-w64-ucrt-x86_64-' + $package[0] + '-any.pkg.tar.zst'
    $archive = Join-Path $downloads $name
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-Host ('downloading ' + $name)
        Invoke-WebRequest -Uri ('https://repo.msys2.org/mingw/ucrt64/' + $name) -OutFile $archive -UseBasicParsing
    }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($hash -ne $package[1]) { throw "Package checksum mismatch: $name" }
    $members = & tar -tf $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot list $name" }
    foreach ($member in $members) {
        if ([IO.Path]::IsPathRooted($member) -or $member.Contains('..')) { throw "Unsafe archive path: $member" }
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    & tar -xf $archive -C $dest
    if ($LASTEXITCODE -ne 0) { throw "Cannot extract $name" }
    Write-Host ('Verified ' + $name)
}
$env:VERILATOR_ROOT = Join-Path $dest 'ucrt64/share/verilator'
& $bin --version
Write-Host 'verilator ready.'
