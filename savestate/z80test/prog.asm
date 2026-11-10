        org 0
        jp start
        ds 0x38-3
        ; IM1 interrupt: count, touch alternates, return
        push af
        push hl
        ld hl,(irqcnt)
        inc hl
        ld (irqcnt),hl
        ex af,af'
        inc a
        ex af,af'
        pop hl
        pop af
        ei
        reti
        ds 0x66-$
        push af
        ld a,(nmicnt)
        inc a
        ld (nmicnt),a
        out (0x10),a
        pop af
        retn
start:
        ld sp,0xff00
        im 1
        ld ix,0x8000
        ld iy,0x8100
        ld a,0x55
        ex af,af'
        ld bc,0x1234
        exx
        ld bc,0x0101
        ld de,0x0202
        ld hl,0x0303
        exx
        ei
loop:
        ld b,7
inner:
        ld a,(ix+3)
        add a,b
        ld (ix+3),a
        ld (iy-2),b
        rl (ix+5)
        set 3,(iy+7)
        bit 3,(iy+7)
        res 3,(iy+7)
        inc (ix+1)
        exx
        add hl,bc
        ld (0x8200),hl
        exx
        ld a,i
        ld r,a
        neg
        ld (0x8201),a
        cpl
        out (0x20),a
        in a,(0x30)
        ld (0x8202),a
        djnz inner
        ld hl,0x8000
        ld de,0x8400
        ld bc,0x20
        ldir
        ld hl,0x841f
        ld de,0x8500
        ld bc,0x10
        lddr
        ld a,(cnt)
        inc a
        ld (cnt),a
        and 7
        jr nz,nohalt
        halt
nohalt:
        push ix
        pop hl
        ld (0x8300),hl
        call sub1
        ex (sp),hl
        ex (sp),hl
        rrd
        rld
        ld a,(cnt)
        cp 0x80
        jr nz,loop
        di
        ld a,1
        ld (0x8600),a
        ei
        jp loop
sub1:
        ld hl,0x8700
        ld a,(hl)
        daa
        sbc a,0x13
        ld (hl),a
        ret
cnt:    db 0
irqcnt: dw 0
nmicnt: db 0
