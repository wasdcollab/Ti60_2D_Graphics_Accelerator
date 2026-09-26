# Project-local RTL simulator, not a system installation or global PATH edit.
# Packages and SHA256 values: https://packages.msys2.org/packages/<package>
$ErrorActionPreference = 'Stop'
$runtimeRoot = Join-Path $PSScriptRoot 'rtl_runtime'
$downloads = Join-Path $runtimeRoot 'downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$packages = @(
    @('iverilog-1~13.0-2', 'fd4d7d7cb60cda1eb437f5476673503d92964cf47ce6c11b460eb3bd05c43582'),
    @('bzip2-1.0.8-4', 'f03a2174034ddd2d96cecd34f617c5f8e2ef86c812b8d2bb3b8875257f2c8bfa'),
    @('readline-8.3.003-1', 'de2423c2e10fcd88272a0ab2f833f6a082cfe613d4c17c2f548cc50a5d2190c4'),
    @('zlib-1.3.2-2', '841401182976d2f9e17e5c0ebaac51f2a8014140ea53d67625e91c8fb3c85ea0'),
    @('gcc-libs-16.2.0-3', '5763fabf86fa13a4449ee765006d3446384ed66af7bf827459710eb777e0b11c'),
    @('termcap-1.3.1-7', '17b78eb63e89458a6ae4d56aa1dc357e1decb2f845b29fded79bccdd628d9d41'),
    @('libwinpthread-14.0.0.r375.g9c1abbbf5-1', '61d340fe8eebc77ee821badca246827fe90545e99685e503bdea16a8d25df512')
)
foreach ($package in $packages) {
    $name = 'mingw-w64-ucrt-x86_64-' + $package[0] + '-any.pkg.tar.zst'
    $archive = Join-Path $downloads $name
    if (-not (Test-Path -LiteralPath $archive)) {
        try {
            Invoke-WebRequest -Uri ('https://repo.msys2.org/mingw/ucrt64/' + $name) -OutFile $archive
        } catch {
            throw "Download failed for $name; obtain it from an official MSYS2 mirror and retain the SHA256 check."
        }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $package[1]) {
        throw "Package checksum mismatch: $name"
    }
    $members = & tar -tf $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot list $name" }
    foreach ($member in $members) {
        if ($member -match '(^[/\\]|^[A-Za-z]:|(^|[/\\])\.\.([/\\]|$))') {
            throw "Unsafe archive path: $member"
        }
    }
    & tar -xf $archive -C $runtimeRoot
    if ($LASTEXITCODE -ne 0) { throw "Cannot extract $name" }
    Write-Host "Verified $name"
}
$env:PATH = (Join-Path $runtimeRoot 'ucrt64/bin') + ';' + $env:PATH
& (Join-Path $runtimeRoot 'ucrt64/bin/iverilog.exe') -V
if ($LASTEXITCODE -ne 0) { throw 'Icarus compiler check failed' }
