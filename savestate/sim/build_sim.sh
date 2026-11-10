#!/bin/sh
# 68000 + ss_ctrl savestate simulation (Verilator 5). Needs binutils for m68k.
set -e
cd "$(dirname "$0")"
m68k-linux-gnu-as -m68000 -o prog.o prog.s
m68k-linux-gnu-ld -Ttext=0 -e _start -o prog.elf prog.o
m68k-linux-gnu-objcopy -O binary prog.elf prog.bin
rm -f prog.o prog.elf
python3 -c "
d=open('prog.bin','rb').read()
open('prog.hex','w').write('\n'.join('%04x'%(d[i]<<8|d[i+1]) for i in range(0,len(d),2))+'\n')"
# fx68k with packed structs: Verilator does not take its unpacked ones
mkdir -p fx
sed -e 's/^typedef struct {/typedef struct packed {/' \
    -e 's|s_nanod Nanod;|s_nanod Nanod /*verilator split_var*/;|' \
    -e 's|s_irdecod Irdecod;|s_irdecod Irdecod /*verilator split_var*/;|' \
    -e 's|output s_nanod Nanod,|output s_nanod Nanod /*verilator split_var*/,|' \
    ../../rtl/cpu/FX68K/fx68k.sv > fx/fx68k.sv
cp ../../rtl/cpu/FX68K/fx68kAlu.sv ../../rtl/cpu/FX68K/uaddrPla.sv fx/
cp ../../rtl/cpu/FX68K/microrom.mem ../../rtl/cpu/FX68K/nanorom.mem .
verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-LATCH \
	-Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-COMBDLY -Wno-ALWCOMBORDER --top-module tb \
	-I../../rtl/ss -Ifx tb.sv dpram_sim.v ../../rtl/ss/ss_ctrl.sv ../../rtl/cpu/cpu_68k.v \
	fx/fx68k.sv fx/fx68kAlu.sv fx/uaddrPla.sv sim_main.cpp -o simv -j 2
echo "run: ./obj_dir/simv"
