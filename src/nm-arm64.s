	.arch armv8-a
	.file	"nm.c"
	.text
	.align	2
	.type	parse_int, %function
parse_int:
.LFB5:
	.cfi_startproc
	cbz	x0, .L8
	ldrb	w2, [x0]
	cbz	w2, .L8
	mov	w3, 0
	mov	w4, 10
.L3:
	ldrb	w2, [x0]
	cbnz	w2, .L4
	mov	w0, 0
	str	w3, [x1]
.L1:
	ret
.L4:
	sub	w2, w2, #48
	and	w5, w2, 255
	cmp	w5, 9
	bhi	.L8
	madd	w2, w3, w4, w2
	cmp	w3, w2
	bgt	.L8
	add	x0, x0, 1
	mov	w3, w2
	b	.L3
.L8:
	mov	w0, -1
	b	.L1
	.cfi_endproc
.LFE5:
	.size	parse_int, .-parse_int
	.align	2
	.type	parse_uint, %function
parse_uint:
.LFB6:
	.cfi_startproc
	cbz	x0, .L16
	ldrb	w2, [x0]
	cbz	w2, .L16
	mov	w3, 0
	mov	w5, 10
.L11:
	ldrb	w2, [x0]
	cbnz	w2, .L12
	mov	w0, 0
	str	w3, [x1]
.L9:
	ret
.L12:
	sub	w4, w2, #48
	and	w4, w4, 255
	cmp	w4, 9
	bhi	.L16
	madd	w2, w3, w5, w2
	sub	w2, w2, #48
	cmp	w3, w2
	bhi	.L16
	add	x0, x0, 1
	mov	w3, w2
	b	.L11
.L16:
	mov	w0, -1
	b	.L9
	.cfi_endproc
.LFE6:
	.size	parse_uint, .-parse_uint
	.align	2
	.global	_start
	.type	_start, %function
_start:
.LFB4:
	.cfi_startproc
#APP
// 57 "nm.c" 1
	mov x0, sp
 bl c_main

// 0 "" 2
#NO_APP
	ret
	.cfi_endproc
.LFE4:
	.size	_start, .-_start
	.section	.rodata.str1.1,"aMS",@progbits,1
.LC0:
	.string	"nm add|del|clear|blk|unb|list|hide|unhide|clrhide|setdev|addmap|clrmap|enable|disable\n"
.LC1:
	.string	"/dev/vfs_helper"
	.text
	.align	2
	.global	c_main
	.type	c_main, %function
c_main:
.LFB7:
	.cfi_startproc
	ldr	x4, [x0]
	cmp	x4, 1
	ble	.L97
	stp	x29, x30, [sp, -96]!
	.cfi_def_cfa_offset 96
	.cfi_offset 29, -96
	.cfi_offset 30, -88
	mov	x7, x0
	mov	x8, 56
	mov	x29, sp
	mov	x0, -100
	adrp	x1, .LC1
	mov	x2, 2
	add	x1, x1, :lo12:.LC1
	mov	x3, 0
	stp	x19, x20, [sp, 16]
	stp	x21, x22, [sp, 32]
	str	x23, [sp, 48]
	.cfi_offset 19, -80
	.cfi_offset 20, -72
	.cfi_offset 21, -64
	.cfi_offset 22, -56
	.cfi_offset 23, -48
#APP
// 54 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
	mov	x21, x0
	tbnz	w0, #31, .L49
	ldr	x1, [x7, 16]
	ldrb	w19, [x1]
	str	wzr, [sp, 68]
	cmp	w19, 97
	bne	.L22
	ldrb	w0, [x1, 1]
	cmp	w0, 100
	bne	.L23
	ldrb	w0, [x1, 2]
	cmp	w0, 100
	bne	.L23
	ldrb	w0, [x1, 3]
	cmp	w0, 109
	bne	.L50
.L23:
	ldrb	w0, [x1, 1]
	cmp	w0, 100
	bne	.L29
	ldrb	w0, [x1, 2]
	cmp	w0, 100
	bne	.L29
	ldrb	w0, [x1, 3]
	cmp	w0, 109
	bne	.L29
	cmp	x4, 2
	beq	.L20
	ldr	x6, [x7, 24]
	mov	x1, 20016
	movk	x1, 0x4008, lsl 16
.L26:
	sxtw	x0, w21
	mov	x2, x6
	mov	x8, 29
#APP
// 44 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
	cmp	x0, 0
	mov	x2, x0
	cset	w0, gt
	cmp	w19, 118
	ccmp	w0, 0, 4, eq
	beq	.L47
	add	w2, w2, 48
	mov	w0, 10
	mov	x8, 64
	add	x1, sp, x8
	strb	w2, [sp, 64]
	mov	x2, 2
	strb	w0, [sp, 65]
	mov	x0, 1
.L98:
#APP
// 44 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
	b	.L32
.L22:
	cmp	w19, 99
	mov	w0, 118
	ccmp	w19, w0, 4, ne
	beq	.L25
	cmp	w19, 108
	beq	.L51
	mov	x0, 3
.L24:
	cmp	x0, x4
	bgt	.L20
	cmp	w19, 97
	beq	.L23
	cmp	w19, 101
	bne	.L31
	ldrb	w0, [x1, 1]
	cmp	w0, 110
	bne	.L32
	mov	x1, 20032
	b	.L99
.L50:
	mov	x0, 4
	b	.L24
.L48:
	ldrb	w0, [x1, 1]
	cmp	w0, 108
	bne	.L55
	ldrb	w0, [x1, 2]
	cmp	w0, 114
	bne	.L55
	ldrb	w0, [x1, 3]
	cmp	w0, 104
	beq	.L54
	cmp	w0, 109
	bne	.L55
	mov	x1, 20018
.L99:
	mov	x6, 0
	b	.L26
.L31:
	cmp	w19, 100
	bne	.L33
	ldrb	w0, [x1, 1]
	cmp	w0, 105
	bne	.L29
	ldrb	w0, [x1, 2]
	cmp	w0, 115
	bne	.L29
	mov	x1, 20033
	b	.L99
.L33:
	adrp	x3, .LANCHOR0
	cmp	w19, 117
	add	x6, x3, :lo12:.LANCHOR0
	bne	.L34
	ldrb	w0, [x1, 1]
	cmp	w0, 110
	bne	.L35
	ldrb	w0, [x1, 2]
	cmp	w0, 104
	bne	.L35
	ldr	x0, [x7, 24]
	add	x1, sp, 72
	bl	parse_int
	cmn	w0, #1
	beq	.L20
	ldr	w0, [sp, 72]
	mov	x1, 19985
	str	w0, [x6, 12]!
.L102:
	movk	x1, 0x4004, lsl 16
	b	.L26
.L34:
	cmp	w19, 104
	bne	.L37
	ldrb	w0, [x1, 1]
	cmp	w0, 105
	bne	.L32
	ldr	x0, [x7, 24]
	add	x1, sp, 72
	bl	parse_int
	cmn	w0, #1
	beq	.L20
	ldr	w0, [sp, 72]
	mov	x1, 19984
	str	w0, [x6, 12]!
	b	.L102
.L37:
	cmp	w19, 115
	bne	.L40
	ldrb	w0, [x1, 1]
	cmp	w0, 101
	bne	.L32
	ldrb	w0, [x1, 2]
	cmp	w0, 116
	bne	.L32
	cmp	x4, 4
	ble	.L20
	ldr	x0, [x7, 24]
	mov	x1, x6
	bl	parse_int
	cmn	w0, #1
	beq	.L20
	ldr	x0, [x7, 32]
	add	x1, x6, 4
	bl	parse_uint
	cmn	w0, #1
	beq	.L20
	ldr	x0, [x7, 40]
	add	x1, x6, 8
	bl	parse_uint
	cmn	w0, #1
	beq	.L20
	mov	x1, 20000
	movk	x1, 0x400c, lsl 16
	b	.L26
.L40:
	cmp	w19, 108
	bhi	.L32
	cmp	w19, 99
	bhi	.L32
	cmp	w19, 98
	beq	.L35
.L32:
	mov	x0, 0
.L21:
	mov	x8, 93
#APP
// 27 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
.L29:
	ldr	x0, [x7, 24]
	str	x0, [sp, 72]
	cmp	w19, 100
	beq	.L58
	ldr	x22, [x7, 32]
	ldrb	w0, [x22]
	cmp	w0, 47
	beq	.L44
	adrp	x20, path_buffer
	add	x20, x20, :lo12:path_buffer
	mov	x0, x20
	mov	x8, 17
	mov	x1, 4096
#APP
// 35 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
	cmp	x0, 0
	ble	.L44
	sub	x23, x0, #1
	ldrb	w1, [x20, x23]
	cmp	w1, 0
	csel	x23, x23, x0, eq
	mov	x0, x22
	bl	strlen
	add	x1, x23, 1
	add	x0, x1, x0
	cmp	x0, 4095
	bhi	.L59
	mov	w0, 47
	add	x1, x20, x1
	strb	w0, [x20, x23]
	mov	x0, 0
.L43:
	ldrb	w2, [x22, x0]
	strb	w2, [x1, x0]
	add	x0, x0, 1
	cbnz	w2, .L43
	mov	x22, x20
.L44:
	mov	w0, 1
	adrp	x2, .LANCHOR0
	add	x2, x2, :lo12:.LANCHOR0
	mov	x1, x22
	add	x2, x2, 16
	mov	x8, 79
	mov	x3, 0
	str	x22, [sp, 80]
	str	w0, [sp, 88]
	mov	x0, -100
#APP
// 54 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
	cbnz	x0, .L45
	ldr	w0, [x2, 16]
	and	w0, w0, 61440
	cmp	w0, 16384
	beq	.L46
.L45:
	mov	x1, 19969
.L100:
	add	x6, sp, 72
	movk	x1, 0x4018, lsl 16
	b	.L26
.L46:
	ldr	w0, [sp, 88]
	orr	w0, w0, 128
	str	w0, [sp, 88]
	b	.L45
.L35:
	ldr	x0, [x7, 24]
	add	x1, sp, 68
	bl	parse_uint
	cmn	w0, #1
	beq	.L20
	cmp	w19, 98
	bne	.L60
	mov	x1, 19973
.L101:
	add	x6, sp, 68
	movk	x1, 0x4004, lsl 16
	b	.L26
.L51:
	mov	x1, 19975
	adrp	x3, list_buffer
	movk	x1, 0x8004, lsl 16
	add	x6, x3, :lo12:list_buffer
	b	.L26
.L54:
	mov	x1, 19986
	b	.L99
.L55:
	mov	x1, 19971
	b	.L99
.L58:
	mov	x1, 19970
	b	.L100
.L60:
	mov	x1, 19974
	b	.L101
.L47:
	cmp	w19, 108
	ccmp	w0, 0, 4, eq
	beq	.L32
	mov	x1, x6
	mov	x8, 64
	mov	x0, 1
	b	.L98
.L20:
	mov	x0, 1
	b	.L21
.L49:
	mov	x0, x2
	b	.L21
.L59:
	mov	x0, 4
	b	.L21
.L25:
	cmp	w19, 99
	beq	.L48
	mov	x1, 19972
	movk	x1, 0x8004, lsl 16
	b	.L99
.L97:
	.cfi_def_cfa_offset 0
	.cfi_restore 19
	.cfi_restore 20
	.cfi_restore 21
	.cfi_restore 22
	.cfi_restore 23
	.cfi_restore 29
	.cfi_restore 30
	adrp	x1, .LC0
	mov	x8, 64
	mov	x0, 1
	add	x1, x1, :lo12:.LC0
	mov	x2, 88
#APP
// 44 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
	mov	x0, 1
	mov	x8, 93
#APP
// 27 "nm.c" 1
	svc 0
// 0 "" 2
#NO_APP
	.cfi_endproc
.LFE7:
	.size	c_main, .-c_main
	.bss
	.align	2
	.set	.LANCHOR0,. + 0
	.type	pd_buffer, %object
	.size	pd_buffer, 12
pd_buffer:
	.zero	12
	.type	int_buffer, %object
	.size	int_buffer, 4
int_buffer:
	.zero	4
	.type	stat_buffer, %object
	.size	stat_buffer, 128
stat_buffer:
	.zero	128
	.type	path_buffer, %object
	.size	path_buffer, 4096
path_buffer:
	.zero	4096
	.type	list_buffer, %object
	.size	list_buffer, 65536
list_buffer:
	.zero	65536
	.ident	"GCC: (Debian 14.2.0-19) 14.2.0"
	.section	.note.GNU-stack,"",@progbits
