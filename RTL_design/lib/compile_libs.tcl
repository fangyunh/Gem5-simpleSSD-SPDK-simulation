# Compile ASAP7 .lib files to .db format for Design Compiler
# Must be run with: dc_shell-t -f compile_libs.tcl

enable_write_lib_mode

set lib_dir [pwd]
set lib_files {
    asap7sc7p5t_AO_RVT_TT_nldm_211120
    asap7sc7p5t_OA_RVT_TT_nldm_211120
    asap7sc7p5t_INVBUF_RVT_TT_nldm_220122
    asap7sc7p5t_SEQ_RVT_TT_nldm_220123
    asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120
}

foreach lib_name $lib_files {
    set lib_file ${lib_name}.lib
    set db_file ${lib_name}.db
    puts "INFO: Converting $lib_file -> $db_file"
    read_lib $lib_file
    write_lib $lib_name -format db -output $db_file
    puts "INFO: Done with $lib_name"
}

puts "INFO: All libraries compiled successfully."
exit
