create_clock -period 40.00                          [get_ports {clk_25m}]
create_clock -period 10.00                           core_clk
create_clock -period 2.50                           sdram_clk
create_clock -period 2.50                           rx_cal_clk
create_clock -period 2.50                           tx_cal_clk
create_clock -period 40.00 [get_ports {jtag_inst1_TCK}]
# axi_clk is not an object of this design: both instantiations of the SoC tie the
# sub-module's axi_clk port to core_clk, and rtl/v_dma/video_dma_read.v says so in
# a comment.  This line asked for a 200 MHz clock on a port the netlist does not
# have, so Efinity answered 'No valid object(s) found for 'axi_clk'' once per read
# and the real clock - core_clk at 100 MHz - was left to stand on its own.
# create_clock -period 5.000                          axi_clk
create_clock -period 2.5000                         tx_cal_clk_90edge
# Same story as axi_clk: no such object, one 'No valid object(s)' warning per read.
# The peripheral clock of this SoC is core_clk.
# create_clock -period 10.0000                        peripheralClk

# These four lines used to be one 'set_clock_groups -group {x}' each, with no option
# at all.  Efinity defaulted each of them to -exclusive and said so four times per
# read.  The intent is the usual one for PLL domains, so it is now written the way
# the asynchronous groups further down already write it: one statement, the option
# spelled out, one group per clock domain.
# jtag_inst1_TCK belongs in here too.  Now that the JTAG clock is actually
# created above, the tool starts timing the core_clk <-> TCK paths inside the
# SoC's jtagBridge, and they come out at 0.010 and 0.015 ns of slack - present,
# and therefore reported as passing, but with no margin at all.  Before the
# clock existed those paths were not timed either, so putting TCK in the
# asynchronous group restores the previous treatment rather than hiding
# anything new: JTAG is a debug clock driven by the pod, not a data domain.
set_clock_groups -asynchronous -group {core_clk} -group {sdram_clk} -group {rx_cal_clk} -group {tx_cal_clk} -group {jtag_inst1_TCK}


# GPIO Constraints
####################
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {i_arstn}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {i_arstn}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {io_jtag_tck}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {io_jtag_tck}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {io_jtag_tdi}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {io_jtag_tdi}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {io_jtag_tms}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {io_jtag_tms}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {system_uart_0_io_rxd}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {system_uart_0_io_rxd}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {io_jtag_tdo}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {io_jtag_tdo}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {system_uart_0_io_txd}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {system_uart_0_io_txd}]

# JTAG Constraints
####################
# The JTAG clock has to exist for the delays below to have something to reference.
# It was commented out while the twelve lines that depend on it were left active,
# so every one of them came back as 'No clocks matched jtag_inst1_TCK'.
# jtag_inst1_TCK is real - ti60_top.peri.xml declares it under efxpt:jtag.
set_output_delay -clock jtag_inst1_TCK -max 0.134 [get_ports {jtag_inst1_TDO}]
set_output_delay -clock jtag_inst1_TCK -min -0.075 [get_ports {jtag_inst1_TDO}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_CAPTURE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_CAPTURE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.279 [get_ports {jtag_inst1_SEL}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.162 [get_ports {jtag_inst1_SEL}]
# jtag_inst1_RESET and jtag_inst1_UPDATE are declared in ti60_top.peri.xml (under
# efxpt:jtag), but the tool does not consider them ports of the netlist and
# answered both of them with 'No ports matched' - twelve warnings per build, all
# of them about constraints that were doing nothing.  CAPTURE, SEL and SHIFT do
# resolve, so those stay.
# set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_RESET}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_RESET}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_UPDATE}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_UPDATE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.388 [get_ports {jtag_inst1_SHIFT}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.225 [get_ports {jtag_inst1_SHIFT}]
# JTAG Constraints (extra... not used by current Efinity debug tools)
# create_clock -period 40.00 [get_ports {jtag_inst1_DRCK}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_RUNTEST}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_RUNTEST}]
# Create separate clock groups for JTAG clocks. Remove DRCK clock from the list below if it is not defined.
# set_clock_groups -asynchronous -group {jtag_inst1_TCK jtag_inst1_DRCK}

# HSIO GPIO Constraints
#########################
# clk_25m is already created on line 1.  A second create_clock for the same port
# only produced 'A clock with name 'clk_25m' already exists. Overwriting the
# previous clock with the same name' on every read.
# create_clock -period 40.00 [get_ports {clk_25m}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -max 0.302 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -min -0.140 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -max 0.302 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -min -0.140 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -max 0.302 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -min -0.140 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -max 0.302 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -min -0.140 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -max 0.302 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -min -0.140 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -max 0.302 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -min -0.140 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -max 0.302 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -min -0.140 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -max 0.302 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -min -0.140 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -max 0.302 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -min -0.140 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -max 0.302 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -min -0.140 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -max 0.302 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -min -0.140 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -max 0.302 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -min -0.140 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -max 0.302 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -min -0.140 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -max 0.302 [get_ports {ddr_addr[13]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -min -0.140 [get_ports {ddr_addr[13]}]
# ddr_addr stops at [13] here: rtl/ddr3_controller/ddr3_parameter.vh sets ROW_WIDTH
# to 14, so [14] and [15] are not ports of the netlist and these four lines were
# dead ('set_output_delay: No valid output port(s) found').  ti60_top.peri.xml does
# hand those two bits pins (GPIOR_P_06 / GPIOB_N_11) and the pinout report places
# them, so RTL and pinout disagree - but an SDC file cannot fix that, and leaving
# four constraints in place that are silently ignored is worse than removing them.
# set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~109}] -max 0.302 [get_ports {ddr_addr[14]}]
# set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~109}] -min -0.140 [get_ports {ddr_addr[14]}]
# set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~143~1}] -max 0.302 [get_ports {ddr_addr[15]}]
# set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~143~1}] -min -0.140 [get_ports {ddr_addr[15]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -max 0.302 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -min -0.140 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -max 0.302 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -min -0.140 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -max 0.302 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -min -0.140 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -max 0.302 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -min -0.140 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -max 0.302 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -min -0.140 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -max 0.302 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -min -0.140 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -max 0.302 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -min -0.140 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -max 0.302 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -min -0.140 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -max 0.302 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -min -0.140 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -max 0.302 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -min -0.140 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -max 0.302 [get_ports {ddr_ras_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -min -0.140 [get_ports {ddr_ras_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {ddr_reset_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {ddr_reset_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -max 0.302 [get_ports {ddr_we_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -min -0.140 [get_ports {ddr_we_n}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -max 0.476 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -min 0.276 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_oe[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_oe[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -max 0.476 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -min 0.276 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_oe[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_oe[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -max 0.476 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -min 0.276 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_oe[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_oe[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -max 0.476 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -min 0.276 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_oe[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_oe[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -max 0.476 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -min 0.276 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_oe[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_oe[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -max 0.476 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -min 0.276 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_oe[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_oe[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -max 0.476 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -min 0.276 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_oe[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_oe[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -max 0.476 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -min 0.276 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_oe[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_oe[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -max 0.476 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -min 0.276 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_oe[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_oe[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -max 0.476 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -min 0.276 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_oe[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_oe[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -max 0.476 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -min 0.276 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_oe[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_oe[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -max 0.476 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -min 0.276 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_oe[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_oe[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -max 0.476 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -min 0.276 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_oe[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_oe[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -max 0.476 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -min 0.276 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_oe[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_oe[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -max 0.476 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -min 0.276 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_oe[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_oe[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -max 0.476 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -min 0.276 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_oe[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_oe[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[1]}]

# Clockout Interface
######################
# ddr_addr[0] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}]
# ddr_addr[10] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}]
# ddr_addr[11] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}]
# ddr_addr[12] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}]
# ddr_addr[13] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}]
# ddr_addr[14] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~109}]
# ddr_addr[15] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~143~1}]
# ddr_addr[1] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}]
# ddr_addr[2] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}]
# ddr_addr[3] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}]
# ddr_addr[4] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}]
# ddr_addr[5] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}]
# ddr_addr[6] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}]
# ddr_addr[7] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}]
# ddr_addr[8] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}]
# ddr_addr[9] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}]
# ddr_ba[0] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}]
# ddr_ba[1] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}]
# ddr_ba[2] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}]
# ddr_cas_n -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}]
# ddr_ck -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}]
# ddr_cke[0] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}]
# ddr_cs_n[0] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}]
# ddr_dm[0] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}]
# ddr_dm[1] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}]
# ddr_dq[0] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}]
# ddr_dq[0] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}]
# ddr_dq[10] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}]
# ddr_dq[10] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}]
# ddr_dq[11] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}]
# ddr_dq[11] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}]
# ddr_dq[12] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}]
# ddr_dq[12] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}]
# ddr_dq[13] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}]
# ddr_dq[13] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}]
# ddr_dq[14] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}]
# ddr_dq[14] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}]
# ddr_dq[15] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}]
# ddr_dq[15] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}]
# ddr_dq[1] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}]
# ddr_dq[1] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}]
# ddr_dq[2] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}]
# ddr_dq[2] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}]
# ddr_dq[3] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}]
# ddr_dq[3] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}]
# ddr_dq[4] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}]
# ddr_dq[4] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}]
# ddr_dq[5] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}]
# ddr_dq[5] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}]
# ddr_dq[6] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}]
# ddr_dq[6] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}]
# ddr_dq[7] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}]
# ddr_dq[7] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}]
# ddr_dq[8] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}]
# ddr_dq[8] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}]
# ddr_dq[9] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}]
# ddr_dq[9] -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}]
# ddr_dqs[0] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}]
# ddr_dqs[0] -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}]
# ddr_dqs[0] -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}]
# ddr_dqs[1] -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}]
# ddr_dqs[1] -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}]
# ddr_dqs[1] -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}]
# ddr_odt[0] -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}]
# ddr_ras_n -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}]
# ddr_we_n -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}]
# The SPI pins are tied off in RTL (rtl/ti60_top.v passes () for write/writeEnable
# and 1'b0 for read on all four data lines), so system_spi_0_io_data_*_IN / _OUT /
# _OE are not ports of the netlist.  All twelve lines were reported as
# 'set_input_delay / set_output_delay: No valid ... port(s) found'.  If SPI is ever
# wired up, these constraints come back with it.
# set_input_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~59}] -max 0.476 [get_ports {system_spi_0_io_data_0_IN}]
# set_input_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~59}] -min 0.276 [get_ports {system_spi_0_io_data_0_IN}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~61}] -max 0.302 [get_ports {system_spi_0_io_data_0_OUT}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~61}] -min -0.140 [get_ports {system_spi_0_io_data_0_OUT}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~61}] -max 0.302 [get_ports {system_spi_0_io_data_0_OE}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~61}] -min -0.140 [get_ports {system_spi_0_io_data_0_OE}]
# set_input_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~60}] -max 0.476 [get_ports {system_spi_0_io_data_1_IN}]
# set_input_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~60}] -min 0.276 [get_ports {system_spi_0_io_data_1_IN}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~62}] -max 0.302 [get_ports {system_spi_0_io_data_1_OUT}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~62}] -min -0.140 [get_ports {system_spi_0_io_data_1_OUT}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~62}] -max 0.302 [get_ports {system_spi_0_io_data_1_OE}]
# set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~62}] -min -0.140 [get_ports {system_spi_0_io_data_1_OE}]

# HDMI Clocks
set_input_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~60}] -max 0.476 [get_ports {system_spi_0_io_data_1_IN}]
set_input_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~60}] -min 0.276 [get_ports {system_spi_0_io_data_1_IN}]
set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~61}] -max 0.302 [get_ports {system_spi_0_io_data_0_OUT}]
set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~61}] -min -0.140 [get_ports {system_spi_0_io_data_0_OUT}]
set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~31}] -max 0.302 [get_ports {system_spi_0_io_sclk_write}]
set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~31}] -min -0.140 [get_ports {system_spi_0_io_sclk_write}]
set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~30}] -max 0.302 [get_ports {system_spi_0_io_ss}]
set_output_delay -clock core_clk -reference_pin [get_ports {core_clk~CLKOUT~1~30}] -min -0.140 [get_ports {system_spi_0_io_ss}]

# HDMI Clocks
create_clock -period 11.667 hdmi_tx_slow_clk
create_clock -period 2.333  hdmi_tx_fast_clk

# Asynchronous Clock Groups
set_clock_groups -asynchronous -group {hdmi_tx_slow_clk hdmi_tx_fast_clk} -group {core_clk} -group {sdram_clk rx_cal_clk tx_cal_clk tx_cal_clk_90edge}
