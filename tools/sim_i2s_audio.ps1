$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'tools/rtl_runtime/ucrt64/bin'
$iverilog = Join-Path $bin 'iverilog.exe'
$vvp = Join-Path $bin 'vvp.exe'
$out = Join-Path $root 'work_sim/i2s_audio.vvp'
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
$oldPath = $env:PATH
try {
    $env:PATH = $bin + ';' + $env:PATH
    & $iverilog -g2012 -s tb_i2s_tx -o $out `
        (Join-Path $root 'rtl/audio/i2s_tx.v') `
        (Join-Path $root 'tests/tb_i2s_tx.v')
    if ($LASTEXITCODE -ne 0) { throw 'I2S elaboration failed' }
    & $vvp $out
    if ($LASTEXITCODE -ne 0) { throw 'I2S simulation failed' }
} finally {
    $env:PATH = $oldPath
}
