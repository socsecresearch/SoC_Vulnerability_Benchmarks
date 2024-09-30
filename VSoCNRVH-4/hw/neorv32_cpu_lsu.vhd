-- ================================================================================ --
-- NEORV32 CPU - Load/Store Unit                                                    --
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

entity neorv32_cpu_lsu is
  generic (
    AMO_LRSC_ENABLE : boolean -- enable atomic LR/SC operations
  );
  port (
    -- global control --
    clk_i       : in  std_ulogic; -- global clock, rising edge
    rstn_i      : in  std_ulogic := '0'; -- global reset, low-active, async
    ctrl_i      : in  ctrl_bus_t; -- main control bus
    -- cpu data access interface --
    addr_i      : in  std_ulogic_vector(XLEN-1 downto 0); -- access address
    wdata_i     : in  std_ulogic_vector(XLEN-1 downto 0); -- write data
    rdata_o     : out std_ulogic_vector(XLEN-1 downto 0); -- read data
    mar_o       : out std_ulogic_vector(XLEN-1 downto 0); -- current memory address register
    wait_o      : out std_ulogic; -- wait for access to complete
    ma_load_o   : out std_ulogic; -- misaligned load data address
    ma_store_o  : out std_ulogic; -- misaligned store data address
    be_load_o   : out std_ulogic; -- bus error on load data access
    be_store_o  : out std_ulogic; -- bus error on store data access
    pmp_fault_i : in  std_ulogic; -- PMP read/write access fault
    -- data bus --
    bus_req_o   : out bus_req_t; -- request
    bus_rsp_i   : in  bus_rsp_t  -- response
  );
end neorv32_cpu_lsu;

architecture neorv32_cpu_lsu_rtl of neorv32_cpu_lsu is

  signal mar         : std_ulogic_vector(XLEN-1 downto 0); -- memory address register
  signal misaligned  : std_ulogic; -- misaligned address
  signal arbiter_req : std_ulogic; -- pending bus request
  signal arbiter_err : std_ulogic; -- access error

begin

  -- Access Address -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  mem_addr_reg: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      mar        <= (others => '0');
      misaligned <= '0';
    elsif rising_edge(clk_i) then
      if (ctrl_i.lsu_mo_we = '1') then
        mar <= addr_i; -- memory address register
        case ctrl_i.ir_funct3(1 downto 0) is -- alignment check
          when "00"   => misaligned <= '0'; -- byte
          when "01"   => misaligned <= addr_i(0); -- half-word
          when others => misaligned <= addr_i(1) or addr_i(0); -- word
        end case;
      end if;
    end if;
  end process mem_addr_reg;

  bus_req_o.addr <= mar; -- bus address
  mar_o          <= mar; -- for MTVAL CSR


  -- Access Type ----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  mem_type_reg: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      bus_req_o.rw   <= '0';
      bus_req_o.priv <= '0';
      bus_req_o.rvso <= '0';
    elsif rising_edge(clk_i) then
      if (ctrl_i.lsu_mo_we = '1') then
        -- read/write --
        bus_req_o.rw <= ctrl_i.lsu_rw;
        -- privilege level --
        bus_req_o.priv <= ctrl_i.lsu_priv;
        -- reservation set operation --
        if AMO_LRSC_ENABLE and (ctrl_i.ir_opcode(2) = opcode_amo_c(2)) then
          bus_req_o.rvso <= '1';
        else
          bus_req_o.rvso <= '0';
        end if;
      end if;
    end if;
  end process mem_type_reg;

  bus_req_o.src   <= '0'; -- 0 = data access
  bus_req_o.fence <= ctrl_i.lsu_fence; -- this is valid without STB being set


  -- Data Output - Alignment and Byte Enable ------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  mem_do_reg: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      bus_req_o.data <= (others => '0');
      bus_req_o.ben  <= (others => '0');
    elsif rising_edge(clk_i) then
      if (ctrl_i.lsu_mo_we = '1') then
        case ctrl_i.ir_funct3(1 downto 0) is
          when "00" => -- byte
            bus_req_o.data <= wdata_i(7 downto 0) & wdata_i(7 downto 0) & wdata_i(7 downto 0) & wdata_i(7 downto 0);
            bus_req_o.ben  <= (others => '0');
            bus_req_o.ben(to_integer(unsigned(addr_i(1 downto 0)))) <= '1';
          when "01" => -- half-word
            bus_req_o.data <= wdata_i(15 downto 0) & wdata_i(15 downto 0);
            bus_req_o.ben  <= addr_i(1) & addr_i(1) & (not addr_i(1)) & (not addr_i(1));
          when others => -- word
            bus_req_o.data <= wdata_i;
            bus_req_o.ben  <= (others => '1');
        end case;
      end if;
    end if;
  end process mem_do_reg;


  -- Data Input - Alignment and Sign-Extension ----------------------------------------------
  -- -------------------------------------------------------------------------------------------
  mem_di_reg: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      rdata_o <= (others => '0');
    elsif rising_edge(clk_i) then
      rdata_o <= (others => '0'); -- output zero if there is no memory access
      if (arbiter_req = '1') then -- pending request
        case ctrl_i.ir_funct3(1 downto 0) is
          when "00" => -- byte
            case mar(1 downto 0) is
              when "00" => -- byte 0
                rdata_o <= replicate_f((not ctrl_i.ir_funct3(2)) and bus_rsp_i.data(7), 24) & bus_rsp_i.data(7 downto 0);
              when "01" => -- byte 1
                rdata_o <= replicate_f((not ctrl_i.ir_funct3(2)) and bus_rsp_i.data(15), 24) & bus_rsp_i.data(15 downto 8);
              when "10" => -- byte 2
                rdata_o <= replicate_f((not ctrl_i.ir_funct3(2)) and bus_rsp_i.data(23), 24) & bus_rsp_i.data(23 downto 16);
              when others => -- byte 3
                rdata_o <= replicate_f((not ctrl_i.ir_funct3(2)) and bus_rsp_i.data(31), 24) & bus_rsp_i.data(31 downto 24);
            end case;
          when "01" => -- half-word
            if (mar(1) = '0') then -- low half-word
              rdata_o <= replicate_f((not ctrl_i.ir_funct3(2)) and bus_rsp_i.data(15), 16) & bus_rsp_i.data(15 downto 0);
            else -- high half-word
              rdata_o <= replicate_f((not ctrl_i.ir_funct3(2)) and bus_rsp_i.data(31), 16) & bus_rsp_i.data(31 downto 16);
            end if;
          when others => -- word
            rdata_o <= bus_rsp_i.data;
        end case;
      end if;
    end if;
  end process mem_di_reg;


  -- Access Arbiter -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  access_arbiter: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      arbiter_err <= '0';
      arbiter_req <= '0';
    elsif rising_edge(clk_i) then
      arbiter_err <= bus_rsp_i.err or pmp_fault_i; -- buffer stage
      if (arbiter_req = '0') then -- idle
        arbiter_req <= ctrl_i.lsu_req;
      elsif (bus_rsp_i.ack = '1') or (ctrl_i.cpu_trap = '1') then -- normal termination or start of trap handling
        arbiter_req <= '0';
      end if;
    end if;
  end process access_arbiter;

  -- wait for bus response --
  wait_o <= not bus_rsp_i.ack;

  -- output access/alignment errors to control unit --
  ma_load_o  <= arbiter_req and (not ctrl_i.lsu_rw) and misaligned;  -- misaligned load
  be_load_o  <= arbiter_req and (not ctrl_i.lsu_rw) and arbiter_err; -- load bus error
  ma_store_o <= arbiter_req and (    ctrl_i.lsu_rw) and misaligned;  -- misaligned store
  be_store_o <= arbiter_req and (    ctrl_i.lsu_rw) and arbiter_err; -- store bus error

  -- access request (all source signals are driven by registers) --
  bus_req_o.stb <= ctrl_i.lsu_req and (not misaligned) and (not pmp_fault_i);


end neorv32_cpu_lsu_rtl;
