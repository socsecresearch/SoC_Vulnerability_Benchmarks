.file "main.S"
.section .text
.balign 4
.global main


main:
	li	a5,136
	csrw	mstatus,a5
	jal 	ra, goto_user_mode
	csrw 	mstatus, a5
	add 	a5, a5, 1

goto_user_mode:
	csrw	mepc,ra
	lui	ra,0x2
	addi	ra,ra,-2048
	csrc	mstatus,ra
	mret
.end
