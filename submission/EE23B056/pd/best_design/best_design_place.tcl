####### Placement only (no CTS, no routing) for mkQRDecoder.
####### Run from icc1/work/ :  icc_shell -shared_license -f ../scripts/icc_place.tcl | tee ../reports/best_icc_run.log
set L 170                          ;# core width = height in um; post-place_opt cell area ~20.0k um^2 -> ~72-73% utilisation
set TAG design_4_p10               ;# the synthesis run being placed
set DESIGN mkQRDecoder
file mkdir ../reports
file mkdir ../results

source ../scripts/icc_lib_setup.tcl
source ../scripts/icc_initial_setup.tcl
#
read_verilog -top $DESIGN -cell $DESIGN ../../syn/outputs/$TAG/$DESIGN.verilog_noassign.v
read_sdc ../scripts/best_design_place.sdc
#
link -force
current_design
catch {set_fix_multiple_port_nets -all -buffer_constants}
#
create_port {VDD VSS} -direction inout
set_user_grid -user_grid {{0 0} {0.0005 0.0005}}
set_fp_pin_constraints -allowed_layers {M2 M3} -pin_spacing 4
create_floorplan -control_type width_and_height -core_width $L -core_height $L
#
derive_pg_connection -power_net {VDD} -ground_net {VSS} -power_pin {VDD} -ground_pin {VSS}
derive_pg_connection -power_net {VDD} -ground_net {VSS} -tie
connect_net {VDD} {VDD}
connect_net {VSS} {VSS}
#
# Power straps: same layers/widths as udcounter, steps scaled up for the larger core
create_power_straps -direction vertical   -start_at 3.000 -nets {VDD VSS} -layer M6 \
  -width 0.5 -configure step_and_stop -step 14 -stop $L -pitch_within_group 1.0
create_power_straps -direction horizontal -start_at 2.500 -nets {VDD VSS} -layer M5 \
  -width 0.5 -configure step_and_stop -step 14 -stop $L -pitch_within_group 1.0
create_power_straps -direction vertical   -start_at 2.000 -nets {VDD VSS} -layer M4 \
  -width 0.2 -configure step_and_stop -step 7  -stop $L -pitch_within_group 0.3
#
preroute_standard_cells -extend_for_multiple_connections -extension_gap 50 -connect horizontal \
  -fill_empty_rows -port_filter_mode off -cell_master_filter_mode off -cell_instance_filter_mode \
  off -voltage_area_filter_mode off -route_type {P/G Std. Cell Pin Conn}
#
derive_pg_connection -power_net {VDD} -ground_net {VSS} -power_pin {VDD} -ground_pin {VSS}
derive_pg_connection -power_net {VDD} -ground_net {VSS} -power_pin {VDD} -ground_pin {VSS} -tie
#
set_operating_conditions -analysis_type on_chip_variation -max ss0p72v125c -min ff0p88v125c \
  -min_library {saed14rvt_base_ff0p88v125c} -max_library {saed14rvt_base_ss0p72v125c}
#
set_auto_disable_drc_nets -constant false
set_fix_hold CLK
set_app_var enable_recovery_removal_arcs true
set_place_opt_strategy -layer_optimization_effort high
set_place_opt_strategy -consider_routing true
create_fp_placement -effort high
#
derive_pg_connection -power_net {VDD} -ground_net {VSS} -power_pin {VDD} -ground_pin {VSS}
derive_pg_connection -power_net {VDD} -ground_net {VSS} -power_pin {VDD} -ground_pin {VSS} -tie
place_opt -effort high -congestion -continue_on_missing_scandef
#
# Same path groups as synthesis, so the f2f numbers are comparable with Table 5
set unq_input_list [all_inputs]
foreach_in_collection unq_clock_element [all_clocks] {
     set unq_clock_name [get_port $unq_clock_element]
     set unq_input_list [remove_from_collection $unq_input_list $unq_clock_name]
}
group_path -name f2f -from [all_registers]  -to [all_registers] -critical_range 0.15
group_path -name i2f -from $unq_input_list  -to [all_registers] -critical_range 0.15
group_path -name f2o -from [all_registers]  -to [all_outputs]   -critical_range 0.15
group_path -name i2o -from $unq_input_list  -to [all_outputs]   -critical_range 0.15
#
report_timing -delay_type max -transition -max_paths 5 -nosplit > ../reports/best_design_post_place_timing.rpt
report_qor   > ../reports/best_design_post_place_qor.rpt
report_power > ../reports/best_design_post_place_power.rpt
report_placement_utilization > ../reports/best_design_post_place_util.rpt
check_legality -verbose > ../reports/best_design_post_place_legality.rpt
catch {echo "boundary bbox: [get_attribute [current_design] boundary_bounding_box]" > ../reports/best_design_dimensions.rpt}
#
save_mw_cel -as ${DESIGN}_place
write_verilog -no_physical_only_cells -no_pg_pin_only_cells -no_corner_pad_cells ../results/${DESIGN}_place.v
exit