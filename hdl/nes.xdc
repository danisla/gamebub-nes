########################################
# NES core
########################################

# The SDRAM controller runs at 4x the NES master clock (phase aligned), and the
# NES core issues requests and consumes results with a fixed schedule. Relax
# paths between the two domains by one SDRAM clock, same as NES_MiSTer NES.sdc.
set_multicycle_path -setup -start 2 \
    -from [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/* && IS_SEQUENTIAL}] \
    -to [get_clocks -of_objects [get_pins handheld_top/core/mmcm/mmcm/CLKOUT0]]
set_multicycle_path -hold -start 1 \
    -from [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/* && IS_SEQUENTIAL}] \
    -to [get_clocks -of_objects [get_pins handheld_top/core/mmcm/mmcm/CLKOUT0]]
set_multicycle_path -setup 2 \
    -from [get_clocks -of_objects [get_pins handheld_top/core/mmcm/mmcm/CLKOUT0]] \
    -to [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/* && IS_SEQUENTIAL}]
set_multicycle_path -hold 1 \
    -from [get_clocks -of_objects [get_pins handheld_top/core/mmcm/mmcm/CLKOUT0]] \
    -to [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/* && IS_SEQUENTIAL}]

# Mapper flags only change while the NES is held in reset (after a ROM load).
set_false_path -from [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/mapper_flags_reg*}]

# Pack SDRAM signal registers into the I/O blocks for consistent timing.
# (SDRAM_A[12:11] also drive DQM, so they can't be packed.)
set_property IOB TRUE [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/SDRAM_A_reg[*] && NAME !~ *SDRAM_A_reg[11] && NAME !~ *SDRAM_A_reg[12]}]
set_property IOB TRUE [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/SDRAM_BA_reg[*]}]
set_property IOB TRUE [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/SDRAM_n*_reg}]
set_property IOB TRUE [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/SDRAM_DQ_OUT_reg[*]}]
set_property IOB TRUE [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/data_reg_reg[*]}]

########################################
# SDRAM I/O timing
########################################
# The SDRAM clock is forwarded (ODDR) from a phase shifted copy of the SDRAM
# controller clock. These constraints check that its phase leaves margin for
# typical SDR SDRAM timing (CL2): command setup/hold (tIS/tIH) 1.5/0.8 ns,
# read data access/hold time (tAC/tOH) 6.0/2.5 ns, plus ~0.5 ns board delay.
create_generated_clock -name sdram_clk_out \
    -source [get_pins handheld_top/core/extModule/sdram_ctrl/sdramclk_ddr/C] -divide_by 1 \
    [get_ports sdram_clk]

set_output_delay -clock sdram_clk_out -max 2.0 [get_ports {sdram_a[*] sdram_bs[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm sdram_dq[*]}]
set_output_delay -clock sdram_clk_out -min -1.3 [get_ports {sdram_a[*] sdram_bs[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm sdram_dq[*]}]

set_input_delay -clock sdram_clk_out -max 6.5 [get_ports {sdram_dq[*]}]
set_input_delay -clock sdram_clk_out -min 2.5 [get_ports {sdram_dq[*]}]

# With CAS latency 2, data launched by an SDRAM clock edge is captured on the
# second following controller clock edge (see STATE_READY in nes_sdram.sv).
set_multicycle_path -setup 2 -from [get_clocks sdram_clk_out] \
    -to [get_cells -hier -filter {NAME =~ handheld_top/core/extModule/sdram_ctrl/data_reg_reg*}]
