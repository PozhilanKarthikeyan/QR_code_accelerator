create_clock -period 1 -waveform {0.0 0.5} [get_ports Clk]

set_input_delay -clock Clk 0.4 [all_inputs]

set_output_delay -clock Clk 0.4 [all_outputs] 





