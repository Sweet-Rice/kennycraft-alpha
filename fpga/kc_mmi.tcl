# MMI for the inferred memories that updatemem patches (sourced by
# fpga/build.tcl).
#
# write_mem_info only describes XPM memories (here the ddr_bridge FIFOs), not
# the inferred $readmemh BRAMs, so kc_write_mmi builds the same map for them
# from the placed RAMB cells. Synthesis records which address and bit range of
# the RTL array each inferred block RAM holds (ram_addr_* / ram_slice_*);
# kc_record_brams saves those right after synth_design, and kc_write_mmi pairs
# them with each cell's LOC after implementation. Each memory becomes one
# "processor" (name) with one address space of depth * width / 8 bytes;
# updatemem selects it with -proc. updatemem 2026.1 accepts only MemType
# RAMB32 (data bits, no parity) and reads Placement as a RAMB36 site, so only
# RAMB36-resident memories can be listed (not the RAMB18 palette). MEM files
# hold one word per entry
# with ceil(width / 4) hex digits (fpga/hex2mem.py).
# <mmi>_bram_info.txt lists every cell and its mapping.
#
#   mems  list of {name cell_pattern width depth}, width and depth of the RTL array

set kc_bram_map [dict create]

proc kc_brams {pattern} {
    return [get_cells -hier -filter "PRIMITIVE_TYPE =~ BMEM.bram.* && NAME =~ $pattern"]
}

proc kc_record_brams {mems} {
    global kc_bram_map
    foreach m $mems {
        set cells [kc_brams [lindex $m 1]]
        if {[llength $cells] == 0} { error "kc_record_brams: no block RAM matches [lindex $m 1]" }
        foreach c $cells {
            set v {}
            foreach p {ram_addr_begin ram_addr_end ram_slice_begin ram_slice_end} {
                lappend v [get_property $p $c]
            }
            dict set kc_bram_map $c $v
        }
    }
}

proc kc_write_mmi {file mems} {
    global kc_bram_map
    set info [open "[file rootname $file]_bram_info.txt" w]
    set f [open $file w]
    puts $f "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    puts $f "<MemInfo Version=\"1\" Minor=\"0\">"
    foreach m $mems {
        lassign $m name pattern width depth
        set blocks [dict create]
        foreach c [kc_brams $pattern] {
            if {![dict exists $kc_bram_map $c]} { error "kc_write_mmi: $c was not recorded after synthesis" }
            lassign [dict get $kc_bram_map $c] ab ae sb se
            # every memory here is split by bits only; a depth split would need
            # BRAM-local address ranges per BusBlock
            if {$ab != 0} { error "kc_write_mmi: $c starts at word $ab (depth split)" }
            set loc  [get_property LOC $c]
            puts $info "$name $c $loc addr $ab..$ae bits $sb..$se"
            dict lappend blocks "$ab $ae" [list $se $sb [lindex [split $loc _] 1]]
        }
        puts $f "  <Processor Endianness=\"Little\" InstPath=\"$name\">"
        puts $f "    <AddressSpace Name=\"$name\" Begin=\"0\" End=\"[expr {$depth * $width / 8 - 1}]\">"
        foreach key [lsort -integer -index 0 [dict keys $blocks]] {
            lassign $key ab ae
            puts $f "      <BusBlock>"
            foreach lane [lsort -integer -decreasing -index 0 [dict get $blocks $key]] {
                lassign $lane se sb place
                puts $f "        <BitLane MemType=\"RAMB32\" Placement=\"$place\">"
                puts $f "          <DataWidth MSB=\"$se\" LSB=\"$sb\"/>"
                puts $f "          <AddressRange Begin=\"$ab\" End=\"$ae\"/>"
                puts $f "          <Parity ON=\"false\" NumBits=\"0\"/>"
                puts $f "        </BitLane>"
            }
            puts $f "      </BusBlock>"
        }
        puts $f "    </AddressSpace>"
        puts $f "  </Processor>"
    }
    puts $f "  <Config>"
    puts $f "    <Option Name=\"Part\" Val=\"[get_property PART [current_design]]\"/>"
    puts $f "  </Config>"
    puts $f "</MemInfo>"
    close $f
    close $info
}
