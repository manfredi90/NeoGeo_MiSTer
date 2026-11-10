| Savestate handler for the 68000, run from the hidden ROM at $FF0000.
| Entered through the level 7 autovector that the savestate controller forces.
| Saves the registers to the meta RAM, waits for the controller, then reloads the
| registers from the restore area and returns to the interrupted program.
|
| Meta RAM at $FF0400 (word index = (address - $FF0400) / 2):
|   $FF0410  restore area: D0-D7/A0-A6, USP, SSP   (words 8..41)
|   $FF0500  save area:    D0-D7/A0-A6, USP, SSP   (words 128..161)
| Control port $FF0800: write = registers saved, read != 0 = go on.

	.text
	.globl	_start
_start:
	movem.l	%d0-%d7/%a0-%a6,0xFF0500
	move.l	%usp,%a0
	move.l	%a0,0xFF053C
	move.l	%a7,0xFF0540
	move.w	#1,0xFF0800
wait:
	move.b	%d0,0x300001		| watchdog kick
	tst.w	0xFF0800
	beq.s	wait
	movea.l	0xFF0450,%a7
	movea.l	0xFF044C,%a0
	move.l	%a0,%usp
	movem.l	0xFF0410,%d0-%d7/%a0-%a6
	rte
