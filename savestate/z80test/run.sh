#!/bin/bash
# T80 savestate test (GHDL + z80asm): a reference Z80 runs a program; at an instruction
# start (BOUNDARY) its registers and memory are copied to a second Z80, which is reset,
# loaded with DIRSet and must write the same data in the same order as the reference.
# usage: run.sh [capture cycle ...]   (HALTCAP=1 to capture only while halted)
set -e
cd "$(dirname "$0")"
W=$(mktemp -d)
z80asm -o $W/prog.bin prog.asm
python3 -c "
d=open('$W/prog.bin','rb').read()
print('library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;')
print('package prog_pkg is type rom_t is array(0 to %d) of integer; constant PROG : rom_t := ('%(len(d)-1) + ','.join(str(b) for b in d) + '); end package;')
" > $W/prog_pkg.vhd
T=../../rtl/cpu/T80
F="--std=08 -fsynopsys -frelaxed --workdir=$W"
ghdl -a $F $T/T80_Pack.vhd $T/T80_ALU.vhd $T/T80_MCode.vhd $T/T80_Reg.vhd $T/T80.vhd $T/T80pa.vhd $W/prog_pkg.vhd tb.vhd
ghdl -e $F -o $W/tb tb
for t in ${@:-3000 31337 77777 123457}; do
	$W/tb -gTCAP=$t -gHALTCAP=${HALTCAP:-0} --max-stack-alloc=0 2>&1 | grep -E "capture|OK|MISMATCH" | sed 's/.*:(report note)://; s/.*(report failure)://' | tr '\n' ' '
	echo
done
rm -rf $W
