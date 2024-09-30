OUTPUT_FORMAT("elf32-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)


/* ************************************************************************************************* */
/* +++ NEORV32 memory configuration +++                                                              */
/* If the symbols are not explicitly defined the default configurations are used. If required, only  */
/* edit the very last entry in each row.                                                             */
/* NOTE: section sizes have to be a multiple of 4 bytes; base addresses have to be 32-bit-aligned.   */
/* ************************************************************************************************* */

/* Default rom/ram (IMEM/DMEM) sizes */
__neorv32_rom_size = 2048M;
__neorv32_ram_size = 8K;

/* Default HEAP size (= 0; no heap at all) */
__neorv32_heap_size = 0;

/* Default section base addresses */
__neorv32_rom_base = 0x00000000; /*TO_DO MAKEFILE START_ADDRESS ARGUMENT*/
__neorv32_ram_base = 0x80000000;

/* ************************************************************************************************* */
/* If compiling the bootloader, the ROM section is automatically re-mapped to the processor-internal */
/* bootloader ROM address space.                                                                     */
/* ************************************************************************************************* */
MEMORY
{
  rom  (rx) : ORIGIN = __neorv32_rom_base, LENGTH = __neorv32_rom_size /*TO DO*/
  ram (rwx) : ORIGIN = __neorv32_ram_base, LENGTH = __neorv32_ram_size
}


/* ************************************************************************************************* */
SECTIONS
{

  /* First part of the actual executable file: actual instructions */
  .text : ALIGN(4)
  {
    PROVIDE(__text_start = .);
    PROVIDE(__textstart = .);

    KEEP(*(.text.crt0)); /* keep start-up code crt0 right at the beginning of rom */

    *(.text.unlikely .text.*_unlikely .text.unlikely.*)
    *(.text.exit .text.exit.*)
    *(.text.startup .text.startup.*)
    *(.text.hot .text.hot.*)
    *(SORT(.text.sorted.*))
    *(.text .stub .text.* .gnu.linkonce.t.*)
    /* .gnu.warning sections are handled specially by elf.em.  */
    *(.gnu.warning)

    /* finish section on WORD boundary */
    . = ALIGN(4);
    PROVIDE (__etext = .);
    PROVIDE (_etext = .);
    PROVIDE (etext = .);
  } > rom


  /* Second part of the actual executable: read-only data, PLACED RIGHT NEXT to .text using "__etext" symbol */
  .rodata __etext :
  {
    /* constant data like strings */
    *(.rodata .rodata.* .gnu.linkonce.r.*)
    *(.rodata1)

    /* finish section on WORD boundary */
    . = ALIGN(4);
    __RODATA_END__ = .;
  } > rom


  /* initialized read/write data, accessed in RAM, placed in ROM, copied during boot - not part of the final executable */
  .data : ALIGN(4)
  {
    __DATA_BEGIN__ = .;
    __SDATA_BEGIN__ = .;
    *(.sdata2 .sdata2.* .gnu.linkonce.s2.*)
    *(.data1)
    *(.data .data.* .gnu.linkonce.d.*)
    . = ALIGN(4);
    _edata = .;
    PROVIDE (edata = .);
    __DATA_END__ = .;
    __global_pointer$ = __DATA_END__ + 0x800;
  } > ram AT > rom


  /* zero/non-initialized read/write data placed in RAM - not part of the final executable */
  .bss (NOLOAD): ALIGN(4)
  {
    __BSS_START__ = .;
    *(.dynsbss)
    *(.sbss .sbss.* .gnu.linkonce.sb.*)
    *(.sbss2 .sbss2.* .gnu.linkonce.sb2.*)
    *(.tbss .tbss.* .gnu.linkonce.tb.*) *(.tcommon)
    *(.scommon)
    *(.dynbss)
    *(.bss .bss.* .gnu.linkonce.b.*)
    /* finish section on WORD boundary */
    . = ALIGN(4);
    __BSS_END__ = .;
    _end = .; PROVIDE (end = .);
  } > ram


  /* heap for dynamic memory allocation (use carefully!) - not part of the final executable */
  .heap : ALIGN(4)
  {
    PROVIDE(__heap_start = .);
    . = __neorv32_heap_size;
    /* finish section on WORD boundary */
    . = ALIGN(4);
    PROVIDE(__heap_end = .);
  } > ram


  /* Yet unused */
  .jcr                : { KEEP (*(.jcr)) }
  .got                : { *(.got.plt) *(.igot.plt) *(.got) *(.igot) }  .interp         : { *(.interp) }
  .note.gnu.build-id  : { *(.note.gnu.build-id) }
  .hash               : { *(.hash) }
  .gnu.hash           : { *(.gnu.hash) }
  .dynsym             : { *(.dynsym) }
  .dynstr             : { *(.dynstr) }
  .gnu.version        : { *(.gnu.version) }
  .gnu.version_d      : { *(.gnu.version_d) }
  .gnu.version_r      : { *(.gnu.version_r) }
  .rela.init          : { *(.rela.init) }
  .rela.text          : { *(.rela.text .rela.text.* .rela.gnu.linkonce.t.*) }
  .rela.fini          : { *(.rela.fini) }
  .rela.rodata        : { *(.rela.rodata .rela.rodata.* .rela.gnu.linkonce.r.*) }
  .rela.data.rel.ro   : { *(.rela.data.rel.ro .rela.data.rel.ro.* .rela.gnu.linkonce.d.rel.ro.*) }
  .rela.data          : { *(.rela.data .rela.data.* .rela.gnu.linkonce.d.*) }
  .rela.tdata         : { *(.rela.tdata .rela.tdata.* .rela.gnu.linkonce.td.*) }
  .rela.tbss          : { *(.rela.tbss .rela.tbss.* .rela.gnu.linkonce.tb.*) }
  .rela.ctors         : { *(.rela.ctors) }
  .rela.dtors         : { *(.rela.dtors) }
  .rela.got           : { *(.rela.got) }
  .rela.sdata         : { *(.rela.sdata .rela.sdata.* .rela.gnu.linkonce.s.*) }
  .rela.sbss          : { *(.rela.sbss .rela.sbss.* .rela.gnu.linkonce.sb.*) }
  .rela.sdata2        : { *(.rela.sdata2 .rela.sdata2.* .rela.gnu.linkonce.s2.*) }
  .rela.sbss2         : { *(.rela.sbss2 .rela.sbss2.* .rela.gnu.linkonce.sb2.*) }
  .rela.bss           : { *(.rela.bss .rela.bss.* .rela.gnu.linkonce.b.*) }


  /* Stabs debugging sections.  */
  .stab          0 : { *(.stab) }
  .stabstr       0 : { *(.stabstr) }
  .stab.excl     0 : { *(.stab.excl) }
  .stab.exclstr  0 : { *(.stab.exclstr) }
  .stab.index    0 : { *(.stab.index) }
  .stab.indexstr 0 : { *(.stab.indexstr) }
  .comment       0 : { *(.comment) }
  .gnu.build.attributes : { *(.gnu.build.attributes .gnu.build.attributes.*) }
  /* DWARF debug sections.
     Symbols in the DWARF debugging sections are relative to the beginning
     of the section so we begin them at 0.  */
  /* DWARF 1 */
  .debug          0 : { *(.debug) }
  .line           0 : { *(.line) }
  /* GNU DWARF 1 extensions */
  .debug_srcinfo  0 : { *(.debug_srcinfo) }
  .debug_sfnames  0 : { *(.debug_sfnames) }
  /* DWARF 1.1 and DWARF 2 */
  .debug_aranges  0 : { *(.debug_aranges) }
  .debug_pubnames 0 : { *(.debug_pubnames) }
  /* DWARF 2 */
  .debug_info     0 : { *(.debug_info .gnu.linkonce.wi.*) }
  .debug_abbrev   0 : { *(.debug_abbrev) }
  .debug_line     0 : { *(.debug_line .debug_line.* .debug_line_end) }
  .debug_frame    0 : { *(.debug_frame) }
  .debug_str      0 : { *(.debug_str) }
  .debug_loc      0 : { *(.debug_loc) }
  .debug_macinfo  0 : { *(.debug_macinfo) }
  /* SGI/MIPS DWARF 2 extensions */
  .debug_weaknames 0 : { *(.debug_weaknames) }
  .debug_funcnames 0 : { *(.debug_funcnames) }
  .debug_typenames 0 : { *(.debug_typenames) }
  .debug_varnames  0 : { *(.debug_varnames) }
  /* DWARF 3 */
  .debug_pubtypes 0 : { *(.debug_pubtypes) }
  .debug_ranges   0 : { *(.debug_ranges) }
  /* DWARF Extension.  */
  .debug_macro    0 : { *(.debug_macro) }
  .debug_addr     0 : { *(.debug_addr) }
  .gnu.attributes 0 : { KEEP (*(.gnu.attributes)) }
  /DISCARD/ : { *(.note.GNU-stack) *(.gnu_debuglink) *(.gnu.lto_*) }


  /* Export symbols for neorv32 crt0 start-up code */
  PROVIDE(__crt0_max_heap            = __neorv32_heap_size);
  PROVIDE(__crt0_imem_begin          = ORIGIN(rom));
  PROVIDE(__crt0_dmem_begin          = ORIGIN(ram));
  PROVIDE(__crt0_stack_begin         = (ORIGIN(ram) + LENGTH(ram)) - 4);
  PROVIDE(__crt0_bss_start           = __BSS_START__);
  PROVIDE(__crt0_bss_end             = __BSS_END__);
  PROVIDE(__crt0_copy_data_src_begin = LOADADDR(.data));
  PROVIDE(__crt0_copy_data_dst_begin = ADDR(.data));
  PROVIDE(__crt0_copy_data_dst_end   = ADDR(.data) + SIZEOF(.data));
}
