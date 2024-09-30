-- ================================================================================ --
-- NEORV32 SoC - System Configuration Information Memory (SYSINFO)                  --
-- -------------------------------------------------------------------------------- --
-- The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              --
-- Copyright (c) NEORV32 contributors.                                              --
-- Copyright (c) 2020 - 2024 Stephan Nolting. All rights reserved.                  --
-- Licensed under the BSD-3-Clause license, see LICENSE for details.                --
-- SPDX-License-Identifier: BSD-3-Clause                                            --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_sysinfo is
  generic (
    CLOCK_FREQUENCY       : natural; -- clock frequency of clk_i in Hz
    CLOCK_GATING_EN       : boolean; -- enable clock gating when in sleep mode
    INT_BOOTLOADER_EN     : boolean; -- boot configuration: true = boot explicit bootloader; false = boot from int/ext (I)MEM
    MEM_INT_IMEM_EN       : boolean; -- implement processor-internal instruction memory
    MEM_INT_IMEM_SIZE     : natural; -- size of processor-internal instruction memory in bytes
    MEM_INT_DMEM_EN       : boolean; -- implement processor-internal data memory
    MEM_INT_DMEM_SIZE     : natural; -- size of processor-internal data memory in bytes
    ICACHE_EN             : boolean; -- implement instruction cache
    ICACHE_NUM_BLOCKS     : natural; -- i-cache: number of blocks (min 2), has to be a power of 2
    ICACHE_BLOCK_SIZE     : natural; -- i-cache: block size in bytes (min 4), has to be a power of 2
    DCACHE_EN             : boolean; -- implement data cache
    DCACHE_NUM_BLOCKS     : natural; -- d-cache: number of blocks (min 2), has to be a power of 2
    DCACHE_BLOCK_SIZE     : natural; -- d-cache: block size in bytes (min 4), has to be a power of 2
    XBUS_EN               : boolean; -- implement external memory bus interface?
    XBUS_CACHE_EN         : boolean; -- implement external bus cache
    XBUS_CACHE_NUM_BLOCKS : natural; -- x-cache: number of blocks (min 1), has to be a power of 2
    XBUS_CACHE_BLOCK_SIZE : natural; -- x-cache: block size in bytes (min 4), has to be a power of 2
    XIP_EN                : boolean; -- implement execute in place module (XIP)?
    XIP_CACHE_EN          : boolean; -- implement execute in place cache?
    XIP_CACHE_NUM_BLOCKS  : natural; -- number of blocks (min 1), has to be a power of 2
    XIP_CACHE_BLOCK_SIZE  : natural; -- block size in bytes (min 4), has to be a power of 2
    ON_CHIP_DEBUGGER_EN   : boolean; -- implement OCD?
    IO_GPIO_EN            : boolean; -- implement general purpose IO port (GPIO)?
    IO_MTIME_EN           : boolean; -- implement machine system timer (MTIME)?
    IO_UART0_EN           : boolean; -- implement primary universal asynchronous receiver/transmitter (UART0)?
    IO_UART1_EN           : boolean; -- implement secondary universal asynchronous receiver/transmitter (UART1)?
    IO_SPI_EN             : boolean; -- implement serial peripheral interface (SPI)?
    IO_SDI_EN             : boolean; -- implement serial data interface (SDI)?
    IO_TWI_EN             : boolean; -- implement two-wire interface (TWI)?
    IO_PWM_EN             : boolean; -- implement pulse-width modulation controller (PWM)?
    IO_WDT_EN             : boolean; -- implement watch dog timer (WDT)?
    IO_TRNG_EN            : boolean; -- implement true random number generator (TRNG)?
    IO_CFS_EN             : boolean; -- implement custom functions subsystem (CFS)?
    IO_NEOLED_EN          : boolean; -- implement NeoPixel-compatible smart LED interface (NEOLED)?
    IO_XIRQ_EN            : boolean; -- implement external interrupts controller (XIRQ)?
    IO_GPTMR_EN           : boolean; -- implement general purpose timer (GPTMR)?
    IO_ONEWIRE_EN         : boolean; -- implement 1-wire interface (ONEWIRE)?
    IO_DMA_EN             : boolean; -- implement direct memory access controller (DMA)?
    IO_SLINK_EN           : boolean; -- implement stream link interface (SLINK)?
    IO_CRC_EN             : boolean  -- implement cyclic redundancy check unit (CRC)?
  );
  port (
    clk_i     : in  std_ulogic; -- global clock line
    rstn_i    : in  std_ulogic; -- global reset line, low-active, async
    bus_req_i : in  bus_req_t;  -- bus request
    bus_rsp_o : out bus_rsp_t   -- bus response
  );
end neorv32_sysinfo;

architecture neorv32_sysinfo_rtl of neorv32_sysinfo is

  -- helpers --
  constant int_imem_en_c  : boolean := MEM_INT_IMEM_EN and boolean(MEM_INT_IMEM_SIZE > 0);
  constant int_dmem_en_c  : boolean := MEM_INT_DMEM_EN and boolean(MEM_INT_DMEM_SIZE > 0);
  constant xcache_en_c    : boolean := XBUS_EN and XBUS_CACHE_EN;
  constant xip_cache_en_c : boolean := XIP_EN and XIP_CACHE_EN;

  -- system information memory --
  type sysinfo_t is array (0 to 3) of std_ulogic_vector(31 downto 0);
  signal sysinfo : sysinfo_t;

  -- bus access buffer --
  signal buf_adr : std_ulogic_vector(1 downto 0);
  signal buf_ack : std_ulogic;

begin

  -- Construct Info Memory ------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- SYSINFO(0): Processor Clock Frequency in Hz --
  sysinfo_0_write: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      sysinfo(0) <= std_ulogic_vector(to_unsigned(CLOCK_FREQUENCY, 32)); -- initialize from generic
    elsif rising_edge(clk_i) then
      if (bus_req_i.stb = '1') and (bus_req_i.rw = '1') and (bus_req_i.addr(3 downto 2) = "00") then
        sysinfo(0) <= bus_req_i.data;
      end if;
    end if;
  end process sysinfo_0_write;

  -- SYSINFO(1): Internal Memory Configuration (sizes)
  sysinfo(1)(7  downto 0)  <= std_ulogic_vector(to_unsigned(index_size_f(MEM_INT_IMEM_SIZE), 8)); -- log2(IMEM size)
  sysinfo(1)(15 downto 8)  <= std_ulogic_vector(to_unsigned(index_size_f(MEM_INT_DMEM_SIZE), 8)); -- log2(DMEM size)
  sysinfo(1)(23 downto 16) <= (others => '0'); -- reserved
  sysinfo(1)(31 downto 24) <= (others => '0'); -- reserved

  -- SYSINFO(2): SoC Configuration --
  sysinfo(2)(0)  <= '1' when INT_BOOTLOADER_EN   else '0'; -- processor-internal bootloader implemented?
  sysinfo(2)(1)  <= '1' when XBUS_EN             else '0'; -- external bus interface implemented?
  sysinfo(2)(2)  <= '1' when int_imem_en_c       else '0'; -- processor-internal instruction memory implemented?
  sysinfo(2)(3)  <= '1' when int_dmem_en_c       else '0'; -- processor-internal data memory implemented?
  sysinfo(2)(4)  <= '1' when ON_CHIP_DEBUGGER_EN else '0'; -- on-chip debugger implemented?
  sysinfo(2)(5)  <= '1' when ICACHE_EN           else '0'; -- processor-internal instruction cache implemented?
  sysinfo(2)(6)  <= '1' when DCACHE_EN           else '0'; -- processor-internal data cache implemented?
  sysinfo(2)(7)  <= '1' when CLOCK_GATING_EN     else '0'; -- enable clock gating when in sleep mode
  sysinfo(2)(8)  <= '1' when xcache_en_c         else '0'; -- external bus interface cache implemented?
  sysinfo(2)(9)  <= '1' when XIP_EN              else '0'; -- execute in-place module implemented?
  sysinfo(2)(10) <= '1' when xip_cache_en_c      else '0'; -- execute in-place cache implemented?
  sysinfo(2)(11) <= '0';                                   -- reserved
  sysinfo(2)(12) <= '0';                                   -- reserved
  sysinfo(2)(13) <= '0';                                   -- reserved
  sysinfo(2)(14) <= '1' when IO_DMA_EN           else '0'; -- direct memory access controller (DMA) implemented?
  sysinfo(2)(15) <= '1' when IO_GPIO_EN          else '0'; -- general purpose input/output port unit (GPIO) implemented?
  sysinfo(2)(16) <= '1' when IO_MTIME_EN         else '0'; -- machine system timer (MTIME) implemented?
  sysinfo(2)(17) <= '1' when IO_UART0_EN         else '0'; -- primary universal asynchronous receiver/transmitter (UART0) implemented?
  sysinfo(2)(18) <= '1' when IO_SPI_EN           else '0'; -- serial peripheral interface (SPI) implemented?
  sysinfo(2)(19) <= '1' when IO_TWI_EN           else '0'; -- two-wire interface (TWI) implemented?
  sysinfo(2)(20) <= '1' when IO_PWM_EN           else '0'; -- pulse-width modulation unit (PWM) implemented?
  sysinfo(2)(21) <= '1' when IO_WDT_EN           else '0'; -- watch dog timer (WDT) implemented?
  sysinfo(2)(22) <= '1' when IO_CFS_EN           else '0'; -- custom functions subsystem (CFS) implemented?
  sysinfo(2)(23) <= '1' when IO_TRNG_EN          else '0'; -- true random number generator (TRNG) implemented?
  sysinfo(2)(24) <= '1' when IO_SDI_EN           else '0'; -- serial data interface (SDI) implemented?
  sysinfo(2)(25) <= '1' when IO_UART1_EN         else '0'; -- secondary universal asynchronous receiver/transmitter (UART1) implemented?
  sysinfo(2)(26) <= '1' when IO_NEOLED_EN        else '0'; -- NeoPixel-compatible smart LED interface (NEOLED) implemented?
  sysinfo(2)(27) <= '1' when IO_XIRQ_EN          else '0'; -- external interrupt controller (XIRQ) implemented?
  sysinfo(2)(28) <= '1' when IO_GPTMR_EN         else '0'; -- general purpose timer (GPTMR) implemented?
  sysinfo(2)(29) <= '1' when IO_SLINK_EN         else '0'; -- stream link interface (SLINK) implemented?
  sysinfo(2)(30) <= '1' when IO_ONEWIRE_EN       else '0'; -- 1-wire interface (ONEWIRE) implemented?
  sysinfo(2)(31) <= '1' when IO_CRC_EN           else '0'; -- cyclic redundancy check unit (CRC) implemented?

  -- SYSINFO(3): Cache Configuration --
  sysinfo(3)(3 downto 0)   <= std_ulogic_vector(to_unsigned(index_size_f(ICACHE_BLOCK_SIZE), 4)) when ICACHE_EN else (others => '0'); -- i-cache: log2(block_size_in_bytes)
  sysinfo(3)(7 downto 4)   <= std_ulogic_vector(to_unsigned(index_size_f(ICACHE_NUM_BLOCKS), 4)) when ICACHE_EN else (others => '0'); -- i-cache: log2(number_of_block)
  --
  sysinfo(3)(11 downto 8)  <= std_ulogic_vector(to_unsigned(index_size_f(DCACHE_BLOCK_SIZE), 4)) when DCACHE_EN else (others => '0'); -- d-cache: log2(block_size)
  sysinfo(3)(15 downto 12) <= std_ulogic_vector(to_unsigned(index_size_f(DCACHE_NUM_BLOCKS), 4)) when DCACHE_EN else (others => '0'); -- d-cache: log2(num_blocks)
  --
  sysinfo(3)(19 downto 16) <= std_ulogic_vector(to_unsigned(index_size_f(XIP_CACHE_BLOCK_SIZE), 4)) when xip_cache_en_c else (others => '0'); -- xip-cache: log2(block_size_in_bytes)
  sysinfo(3)(23 downto 20) <= std_ulogic_vector(to_unsigned(index_size_f(XIP_CACHE_NUM_BLOCKS), 4)) when xip_cache_en_c else (others => '0'); -- xip-cache: log2(number_of_block)
  --
  sysinfo(3)(27 downto 24) <= std_ulogic_vector(to_unsigned(index_size_f(XBUS_CACHE_BLOCK_SIZE), 4)) when xcache_en_c else (others => '0'); -- xbus-cache: log2(block_size_in_bytes)
  sysinfo(3)(31 downto 28) <= std_ulogic_vector(to_unsigned(index_size_f(XBUS_CACHE_NUM_BLOCKS), 4)) when xcache_en_c else (others => '0'); -- xbus-cache: log2(number_of_block)


  -- Bus Access -----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  access_buffer: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      buf_ack <= '0';
      buf_adr <= (others => '0');
    elsif rising_edge(clk_i) then
      buf_ack <= bus_req_i.stb;
      if (bus_req_i.stb = '1') then
        buf_adr <= bus_req_i.addr(3 downto 2);
      end if;
    end if;
  end process access_buffer;

  -- output gate and SYSINFO lookup --
  bus_rsp_o.data <= sysinfo(to_integer(unsigned(buf_adr))) when (buf_ack = '1') else (others => '0');
  bus_rsp_o.ack  <= buf_ack;
  bus_rsp_o.err  <= '0'; -- no bus errors


end neorv32_sysinfo_rtl;
