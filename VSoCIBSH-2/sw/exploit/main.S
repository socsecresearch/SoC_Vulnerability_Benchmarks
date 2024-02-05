.file "main.S"
.section .text
.balign 4
.global main

main:
	li	a5,136
	li t0, (1 << 21)                    // TW bit is the 22nd bit in mstatus
	csrs mstatus, t0	// Set the TW bit in the mstatus register
	jal 	ra, goto_user_mode
	wfi
	add 	a5, a5, 1

	
goto_user_mode:
	csrw	mepc,ra
	lui	ra,0x2
	addi	ra,ra,-2048
	csrc	mstatus,ra
	mret

.end
