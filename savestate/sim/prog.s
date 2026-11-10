| Test program for the savestate simulation: keeps all the registers busy, uses the
| user stack and a level 1 interrupt, and writes a trace to $200000.
	.text
	.globl	_start
_start:
	.long	0x0010F000		| SSP
	.long	start
	.fill	23,4,0			| vectors 2..24
	.long	irq1			| level 1 autovector ($64)
	.fill	6,4,0			| level 2..7
	.fill	256-32,4,0
start:
	move.w	#0x2000,%sr
	lea	0x0010E000,%a0
	move.l	%a0,%usp
	moveq	#1,%d0
	move.l	#0x12345678,%d1
	move.l	#0x0F0F0F0F,%d2
	move.l	#0x55AA55AA,%d3
	move.l	#0x01234567,%d4
	moveq	#0,%d5
	moveq	#0,%d6
	moveq	#7,%d7
	lea	0x00100000,%a1
	lea	0x00100010,%a2
	lea	0x00100100,%a3
	lea	0x00100200,%a4
	lea	0x00100300,%a5
	lea	0x00100400,%a6
	andi.w	#0xDFFF,%sr		| user mode
loop:
	addq.l	#1,%d0
	add.l	%d0,%d1
	roxl.l	#1,%d2
	addx.l	%d1,%d3
	eor.l	%d3,%d4
	move.l	%d4,(%a1)+
	cmpa.l	#0x00101000,%a1
	blt.s	1f
	lea	0x00100000,%a1
1:	move.l	-4(%a1),%d5
	add.l	(%a2),%d6
	addq.l	#4,%a2
	cmpa.l	#0x00101000,%a2
	blt.s	2f
	lea	0x00100000,%a2
2:	bsr	sub
	move.l	%d0,0x00200000
	move.l	%d4,0x00200000
	move.l	%d6,0x00200000
	move.l	%a1,0x00200000
	move.l	%d7,0x00200000
	bra	loop
sub:	movem.l	%d0-%d1/%a3,-(%sp)
	move.l	(%a3),%d0
	add.l	%d5,%d0
	move.l	%d0,(%a3)+
	move.l	%a3,%d1
	andi.l	#0x001003FF,%d1
	movea.l	%d1,%a3
	dbra	%d7,3f
	moveq	#7,%d7
3:	movem.l	(%sp)+,%d0-%d1/%a3
	rts
irq1:	movem.l	%d0/%a0,-(%sp)
	move.l	0x0010F800,%d0
	addq.l	#1,%d0
	move.l	%d0,0x0010F800
	move.w	#0,0x00200010		| acknowledge
	movem.l	(%sp)+,%d0/%a0
	rte
