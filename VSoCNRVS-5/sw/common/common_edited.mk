# -----------------------------------------------------------------------------
# USER CONFIGURATION
# -----------------------------------------------------------------------------
# User's application sources (*.c, *.cpp, *.s, *.S); add additional files here
APP_SRC ?= $(wildcard ./*.c) $(wildcard ./*.s) $(wildcard ./*.cpp) $(wildcard ./*.S)

# User's application include folders (don't forget the '-I' before each entry)
APP_INC ?= -I .
# User's application include folders - for assembly files only (don't forget the '-I' before each entry)
ASM_INC ?= -I .

# Optimization
EFFORT ?= -Os

# Compiler toolchain
RISCV_PREFIX ?= riscv32-unknown-elf-

# CPU architecture and ABI
MARCH ?= rv32i_zicsr
MABI  ?= ilp32

# User flags for additional configuration (will be added to compiler flags)
USER_FLAGS ?=

# Relative or absolute path to the NEORV32 home folder
NEORV32_HOME ?= ../../..
NEORV32_LOCAL_RTL ?= $(NEORV32_HOME)/rtl

# GDB arguments
GDB_ARGS ?= -ex "target extended-remote localhost:3333"


# -----------------------------------------------------------------------------
# NEORV32 framework
# -----------------------------------------------------------------------------
# Path to NEORV32 linker script and startup file
NEORV32_COM_PATH = $(NEORV32_HOME)/sw/common
# Path to NEORV32 core rtl folder
NEORV32_RTL_PATH = $(NEORV32_LOCAL_RTL)/core

# Core libraries (peripheral and CPU drivers) ###H.ASHUVA LAB
CORE_SRC  = $(wildcard $(NEORV32_SRC_PATH)/*.c)
# Application start-up code
CORE_SRC += $(NEORV32_COM_PATH)/crt0_edited.S

# Linker script
LD_SCRIPT ?= $(NEORV32_COM_PATH)/neorv32_edited.ld

# Main output files
APP_ELF  = my_main.elf
APP_ASM  = main.asm

# -----------------------------------------------------------------------------
# Sources and objects
# -----------------------------------------------------------------------------
# Define all sources
SRC  = $(APP_SRC)
SRC += $(CORE_SRC)

# Define all object files
OBJ = $(SRC:%=%.o)


# -----------------------------------------------------------------------------
# Tools and flags
# -----------------------------------------------------------------------------
# Compiler tools
CC      = $(RISCV_PREFIX)gcc
OBJDUMP = $(RISCV_PREFIX)objdump
OBJCOPY = $(RISCV_PREFIX)objcopy
SIZE    = $(RISCV_PREFIX)size
GDB     = $(RISCV_PREFIX)gdb

# Host native compiler
CC_X86 = gcc -Wall -O -g

# Compiler & linker flags
CC_OPTS  = -march=$(MARCH) -mabi=$(MABI) $(EFFORT) -Wall -ffunction-sections -fdata-sections -nostartfiles -mno-fdiv
CC_OPTS += -mstrict-align -mbranch-cost=10 -g -Wl,--gc-sections
CC_OPTS += $(USER_FLAGS)
LD_LIBS =  -lm -lc -lgcc
LD_LIBS += $(USER_LIBS)

# -----------------------------------------------------------------------------
# Application output definitions
# -----------------------------------------------------------------------------
.PHONY: check info help elf_info clean clean_all bootloader
.DEFAULT_GOAL := help

# 'compile' is still here for compatibility
asm:     $(APP_ASM)
elf:     $(APP_ELF)
all:     $(APP_ASM) $(APP_ELF)

# -----------------------------------------------------------------------------
# General targets: Assemble, compile, link, dump
# -----------------------------------------------------------------------------
# Compile app *.s sources (assembly)
%.s.o: %.s
	@$(CC) -c $(CC_OPTS)  $(ASM_INC) $< -o $@

# Compile app *.S sources (assembly + C pre-processor)
%.S.o: %.S
	@$(CC) -c $(CC_OPTS) $(ASM_INC) $< -o $@

# Compile app *.c sources
%.c.o: %.c
	@$(CC) -c $(CC_OPTS) -I $(NEORV32_INC_PATH) $(APP_INC) $< -o $@

# Link object files and show memory utilization
$(APP_ELF): $(OBJ)
	@$(CC) $(CC_OPTS) -T $(LD_SCRIPT) $(OBJ) $(LD_LIBS) -o $@
	@echo "Memory utilization:"
	@$(SIZE) $(APP_ELF)

# Assembly listing file (for debugging)
$(APP_ASM): $(APP_ELF)
	@$(OBJDUMP) -d -S -z  $< > $@


# -----------------------------------------------------------------------------
# Show final ELF details (just for debugging)
# -----------------------------------------------------------------------------
elf_info: $(APP_ELF)
	@$(OBJDUMP) -x $(APP_ELF)


# -----------------------------------------------------------------------------
# Run GDB
# -----------------------------------------------------------------------------
gdb:
	@$(GDB) $(APP_ELF) $(GDB_ARGS)


# -----------------------------------------------------------------------------
# Clean up
# -----------------------------------------------------------------------------
clean:
	@rm -f *.elf *.o *.bin *.out *.asm *.vhd *.hex .gdb_history

clean_all: clean
	@rm -f $(OBJ) $(IMAGE_GEN)


