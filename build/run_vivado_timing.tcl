# Final engineering package build.
# GUI Tcl Console:
#   cd <package-root>
#   source build/run_vivado_timing.tcl
#
# Shell:
#   vivado -mode batch -source build/run_vivado_timing.tcl

set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
puts "Build root: [pwd]"

set part xc7a200tfbg484-2
set top  hdmi_wrapper
set report_dir [file join $root build reports]
set board_dir  [file join $root board]

# Vivado resolves the RTL-relative $readmemh paths against each HDL source
# directory. The package layout keeps weights at the repository root and the
# RTL in src/rtl/cnn_alarm, so the source paths use ../../../weights/...
set required_mem {
    qin.mem
    w1.mem
    w2.mem
    w3.mem
    w4.mem
    b1.mem
    b2.mem
    b3.mem
    b4.mem
}
foreach name $required_mem {
    set path [file join $root weights $name]
    if {![file exists $path]} {
        error "Missing required CNN weight file: $path"
    }
}
puts "CNN weights: [llength $required_mem] required files found under [file join $root weights]"

if {[info exists ::env(BUILD_PREFLIGHT_ONLY)] && $::env(BUILD_PREFLIGHT_ONLY) eq "1"} {
    puts "PREFLIGHT_OK"
    exit 0
}

file mkdir $report_dir
file mkdir $board_dir

proc collect_v {dir} {
    set result {}
    foreach f [glob -nocomplain -directory $dir *.v] {
        lappend result $f
    }
    foreach d [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $d]} {
            set result [concat $result [collect_v $d]]
        }
    }
    return $result
}

set rtl_files [collect_v [file join $root src rtl]]
if {[llength $rtl_files] == 0} {
    error "No Verilog sources found under [file join $root src rtl]"
}
puts "RTL files: [llength $rtl_files]"
read_verilog $rtl_files
read_xdc [file join $root src xdc hdmi_wrapper.xdc]

# A missing memory initialization file is a critical warning in Vivado and
# produces a technically invalid build. Treat that condition as fatal.
set_msg_config -severity {CRITICAL WARNING} -new_severity {ERROR}

synth_design -top $top -part $part -flatten_hierarchy rebuilt
opt_design
place_design
route_design

report_utilization -file [file join $report_dir utilization_post_route.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -max_paths 20 -file [file join $report_dir timing_summary_post_route.rpt]
report_timing -sort_by group -max_paths 20 -path_type summary \
    -file [file join $report_dir timing_paths_post_route.rpt]
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]
report_ram_utilization -file [file join $report_dir ram_utilization.rpt]
report_power -file [file join $report_dir power_post_route.rpt]
report_drc -file [file join $report_dir drc_post_route.rpt]

write_bitstream -force [file join $board_dir hdmi_wrapper.bit]
puts "BUILD_COMPLETE"
