# sim_bitblt.ps1 -- build & run the BitBlt full-engine bench.
# Usage:  .\tools\sim_bitblt.ps1 -W 9 -H 9 -Op 1 -Lat 150 -Cmds 1
#         .\tools\sim_bitblt.ps1 -W 1366 -H 8 -SrcDir tmp\v4
param(
  [int]$W = 9, [int]$H = 9, [int]$Op = 1, [int]$Lat = 150, [int]$Cmds = 1,
  [string]$SrcDir = "rtl\bitblt", [switch]$Alpha, [switch]$Vdma,
  [switch]$Jitter, [string]$Tag = "", [switch]$Quiet
)
$p = "E:\FPGA\Ti60_2D_Graphics_Accelerator"
$iv = "$p\tools\rtl_runtime\ucrt64\bin\iverilog.exe"
$vv = "$p\tools\rtl_runtime\ucrt64\bin\vvp.exe"
$lib = "$p\tools\rtl_runtime\ucrt64\lib\ivl"
$models = (Get-ChildItem "D:\Efinix\efinity\2026.1\sim_models\verilog\*.v" | ForEach-Object { $_.FullName })
$src = @(
  "$p\tests\tb_bitblt_suite.v",
  "$p\$SrcDir\bitblt_top.v", "$p\$SrcDir\bitblt_stride_gen.v",
  "$p\$SrcDir\bitblt_axi_read_master.v", "$p\$SrcDir\bitblt_axi_master.v",
  "$p\rtl\bitblt\bitblt_apb_regs.v", "$p\rtl\bitblt\bitblt_read_fifo.v",
  "$p\rtl\bitblt\bitblt_align_shifter.v", "$p\rtl\bitblt\bitblt_alpha_blend.v",
  "$p\rtl\common\Axi_Mux.v", "$p\rtl\common\simple_dual_port_ram.v"
)
if (-not $Tag) { $Tag = "w${W}_h${H}_op${Op}_lat${Lat}" }
New-Item -ItemType Directory -Force -Path "$p\tmp\sim" | Out-Null
$out = "$p\tmp\sim\$Tag.vvp"
$d = @("-DCMD_W=$W","-DCMD_H=$H","-DCMD_OP=$Op","-DTB_LAT=$Lat","-DTB_CMDS=$Cmds")
if ($Alpha)  { $d += "-DTB_ALPHA" }
if ($Vdma)   { $d += "-DTB_VDMA" }
if ($Jitter) { $d += "-DTB_JITTER" }
& $iv -B $lib -g2012 -I "$p\rtl\common" -I "$p\rtl\bitblt" $d -o $out $src $models 2>$null
if (-not (Test-Path $out)) { Write-Host "COMPILE FAILED: $Tag"; exit 1 }
$log = & $vv $out 2>&1
if ($Quiet) { $log | Select-String -Pattern "^  cmd|RESULT|STUCK|INCOMPLETE|violations|peaks|write ch" }
else { $log | Select-Object -First 20 }
