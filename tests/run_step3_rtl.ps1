param([string]$VivadoBin = 'D:/Xilinx/Vivado/2022.2/bin')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$simulationDir = Join-Path $projectRoot 'work_sim/step3_rtl'
New-Item -ItemType Directory -Force -Path $simulationDir | Out-Null
Push-Location $simulationDir
try {
    # XSim rejects a BOM accepted by Efinity; normalize only the simulation copy.
    $timingSource = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'rtl/v_dma/video_timing_gen.v'))
    [System.IO.File]::WriteAllText((Join-Path $simulationDir 'video_timing_gen_sim.v'), $timingSource, [System.Text.UTF8Encoding]::new($false))
    & D:/Anaconda/python.exe -E (Join-Path $PSScriptRoot 'right_demo_reference.py')
    if ($LASTEXITCODE -ne 0) { throw 'reference generation failed' }
    $cases = @(
        @{Name='i2c_gamepad'; Top='tb_i2c_gamepad'; Files=@('../../tests/tb_i2c_gamepad.sv','../../rtl/common/i2c_gamepad_top.v')},
        @{Name='hud'; Files=@('../../tests/tb_step3_hud.sv','../../rtl/v_dma/video_dual_hud.v')},
        @{Name='bitblt'; Files=@('../../tests/tb_step3_bitblt.sv','../../rtl/bitblt/bitblt_top.v','../../rtl/bitblt/bitblt_apb_regs.v','../../rtl/bitblt/bitblt_stride_gen.v','../../rtl/bitblt/bitblt_axi_master.v','../../rtl/bitblt/bitblt_axi_read_master.v','../../rtl/bitblt/bitblt_read_fifo.v','../../rtl/bitblt/bitblt_align_shifter.v','../../rtl/bitblt/bitblt_alpha_blend.v','../../rtl/bitblt/bitblt_asset_rom.v')},
        @{Name='write_guard'; Files=@('../../tests/tb_step3_write_guard.sv','../../rtl/v_dma/video_write_guard.v')}
    )
    foreach ($case in $cases) {
        & (Join-Path $VivadoBin 'xvlog.bat') -sv @($case.Files)
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $($case.Name)" }
        $top = if ($case.Top) { $case.Top } else { "tb_step3_$($case.Name)" }
        & (Join-Path $VivadoBin 'xelab.bat') $top -s "step3_$($case.Name)"
        if ($LASTEXITCODE -ne 0) { throw "xelab failed: $($case.Name)" }
        $simulationOutput = & (Join-Path $VivadoBin 'xsim.bat') "step3_$($case.Name)" -runall 2>&1
        $simulationExit = $LASTEXITCODE
        $simulationOutput | Tee-Object -FilePath "$($case.Name)_regression.log"
        # XSim can return zero even after $fatal. Require explicit test success.
        $joinedOutput = $simulationOutput -join "`n"
        if ($simulationExit -ne 0 -or $joinedOutput -notmatch 'PASS .* RTL:' -or $joinedOutput -match '(?i)fatal:|ERROR:') {
            throw "RTL simulation failed: $($case.Name)"
        }
    }
} finally {
    Pop-Location
}
