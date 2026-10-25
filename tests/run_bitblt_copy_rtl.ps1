# =============================================================================
# tests/run_bitblt_copy_rtl.ps1
# -----------------------------------------------------------------------------
# Runs the vector driven BitBlt regression (tests/tb_step3_bitblt_copy.sv) under
# Vivado XSim for both burst-length configurations:
#
#     MAX_BURST_BEATS = 64   (project default, 1 KiB AXI bursts)
#     MAX_BURST_BEATS = 16   (fallback if an on-board DDR controller objects)
#
# The bench covers three families in one elaboration:
#     VEC  vectors : OP_FILL / OP_COPY block copy (byte-level alignment)
#     COLORKEY     : colour-key transparency special case
#     AVEC vectors : OP_ALPHA hardware alpha blending, including colour key
#                    combined with alpha, global alpha and byte accounting
#
# The per-vector hashes printed by the bench are captured so that
# simulator/blit_ref.py (VEC) and simulator/alpha_ref.py (AVEC) can be
# cross-checked against the RTL.
# =============================================================================
param([string]$VivadoBin = 'D:/Xilinx/Vivado/2022.2/bin')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$rtl = @(
    'bitblt_top.v', '../apb/apb_command_dispatcher.v', 'bitblt_stride_gen.v',
    'bitblt_axi_master.v', 'bitblt_axi_read_master.v',
    'bitblt_read_fifo.v', 'bitblt_align_shifter.v', 'bitblt_alpha_blend.v',
    'bitblt_asset_rom.v'
) | ForEach-Object { Join-Path $projectRoot "rtl/bitblt/$_" }
$tb = Join-Path $projectRoot 'tests/tb_step3_bitblt_copy.sv'

# bitblt_read_fifo.v is an inferred synchronous block RAM.  This unit-level
# regression therefore has no Efinity primitive-model dependency.
$logDir = Join-Path $projectRoot 'work_sim/step3_rtl'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if (-not (Test-Path (Join-Path $VivadoBin 'xvlog.bat'))) {
    throw "Vivado not found at $VivadoBin - pass -VivadoBin <path>"
}

foreach ($mb in 192, 64, 16) {
    $simDir = Join-Path $projectRoot "work_sim/bitblt_copy_mb$mb"
    if (Test-Path $simDir) { Remove-Item $simDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $simDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $simDir 'bitblt_burst_cfg.vh'),
        "``define BITBLT_MAX_BURST $mb`n", $utf8NoBom)

    Write-Host "=== BitBlt regression (COPY + ColorKey + ALPHA), MAX_BURST_BEATS = $mb ===" -ForegroundColor Cyan
    Push-Location $simDir
    try {
        & (Join-Path $VivadoBin 'xvlog.bat') -sv @rtl $tb
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed (mb=$mb)" }

        & (Join-Path $VivadoBin 'xelab.bat') tb_step3_bitblt_copy -s "bitblt_copy_mb$mb"
        if ($LASTEXITCODE -ne 0) { throw "xelab failed (mb=$mb)" }

        $out = & (Join-Path $VivadoBin 'xsim.bat') "bitblt_copy_mb$mb" -runall 2>&1
        $exit = $LASTEXITCODE
        $out | Set-Content -Path (Join-Path $logDir "bitblt_copy_mb$mb.log") -Encoding ascii
        $text = $out -join "`n"

        ($out | Where-Object { $_ -match '^VEC \d+ ok' }) |
            ForEach-Object { $_.Trim() } |
            Set-Content -Path (Join-Path $logDir "bitblt_copy_mb$mb.vec") -Encoding ascii

        ($out | Where-Object { $_ -match '^AVEC \d+ ok' }) |
            ForEach-Object { $_.Trim() } |
            Set-Content -Path (Join-Path $logDir "bitblt_alpha_mb$mb.vec") -Encoding ascii

        ($out | Select-String -Pattern 'PASS BitBlt|COLORKEY ok|FATAL|ERROR:' | Select-Object -First 5) |
            ForEach-Object { $_.ToString().Trim() } | Write-Host

        $vecCount = (Get-Content (Join-Path $logDir "bitblt_copy_mb$mb.vec") -ErrorAction SilentlyContinue).Count
        $alphaCount = (Get-Content (Join-Path $logDir "bitblt_alpha_mb$mb.vec") -ErrorAction SilentlyContinue).Count
        if ($exit -ne 0 -or $text -notmatch 'PASS BitBlt COPY' -or
            $text -notmatch 'PASS BitBlt ALPHA' -or $text -notmatch 'COLORKEY ok' -or
            $text -match '(?i)fatal:|ERROR:') {
            throw "BitBlt regression FAILED (mb=$mb)"
        }
        Write-Host "  -> $vecCount copy vectors + $alphaCount alpha vectors passed"
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# L2: same stimulus through the independent Python models, then hash compare
# ---------------------------------------------------------------------------
Write-Host "=== L2 cross-check (RTL vs Python reference models) ===" -ForegroundColor Cyan
Push-Location $projectRoot
try {
    foreach ($py in @('tools/gen_copy_vectors.py', 'tools/gen_alpha_vectors.py')) {
        & python -E $py
        if ($LASTEXITCODE -ne 0) { throw "$py failed" }
    }
    & python -E 'simulator/blit_ref.py' --out 'work_sim/step3_rtl/bitblt_copy_py.vec' --quiet
    if ($LASTEXITCODE -ne 0) { throw "blit_ref.py failed" }
    & python -E 'simulator/alpha_ref.py' --out 'work_sim/step3_rtl/bitblt_alpha_py.vec' --quiet
    if ($LASTEXITCODE -ne 0) { throw "alpha_ref.py failed" }

    & python -E 'tools/compare_blit_vectors.py'
    if ($LASTEXITCODE -ne 0) { throw "VEC cross-check failed" }
    & python -E 'tools/compare_blit_vectors.py' --tag AVEC
    if ($LASTEXITCODE -ne 0) { throw "AVEC cross-check failed" }
} finally {
    Pop-Location
}

Write-Host "[SUCCESS] BitBlt COPY + ColorKey + ALPHA regression passed for both burst configurations" -ForegroundColor Green
