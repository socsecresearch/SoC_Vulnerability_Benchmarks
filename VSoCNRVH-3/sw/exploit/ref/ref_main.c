#include <neorv32.h>
#include <string.h>


int main(){
	//neorv32_cpu_csr_set(CSR_MSTATUS, 1 << CSR_MSTATUS_MIE);
	//uint32_t a;
	//neorv32_cpu_csr_write(768, a);
	//neorv32_cpu_csr_set(CSR_MSTATUS, 1 << CSR_MSTATUS_MPIE);
	//code for user mode
	//neorv32_cpu_csr_set (CSR_MSTATUS, 1 << CSR_MSTATUS_TW);
	uint32_t a = (uint32_t)neorv32_cpu_csr_read(CSR_CYCLE);
	//neorv32_cpu_csr_write(CSR_MCOUNTEREN, 1);
	neorv32_cpu_goto_user_mode();
	a = (uint32_t)neorv32_cpu_csr_read(CSR_CYCLE);
	neorv32_cpu_csr_write(CSR_CYCLE, 0);
	//asm volatile ("wfi");
	return 0;
}
