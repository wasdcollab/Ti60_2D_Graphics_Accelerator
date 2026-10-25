@echo off
call D:\Xilinx\Vivado\2022.2\bin\xvlog.bat -sv tests\tb_bloom_filter.sv rtl\v_dma\video_bloom_filter.v > tests\sim.log 2>&1
call D:\Xilinx\Vivado\2022.2\bin\xelab.bat -debug typical work.tb_bloom_filter -s tb_bloom_sim >> tests\sim.log 2>&1
call D:\Xilinx\Vivado\2022.2\bin\xsim.bat tb_bloom_sim -R >> tests\sim.log 2>&1
echo SIMULATION_FINISHED >> tests\sim.log
