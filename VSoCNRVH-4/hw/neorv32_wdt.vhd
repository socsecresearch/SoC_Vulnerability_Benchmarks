-- ================================================================================ --
-- NEORV32 SoC - Watch Dog Timer (WDT)                                              --
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

entity neorv32_wdt is
  port (
    clk_i       : in  std_ulogic; -- global clock line
    rstn_i      : in  std_ulogic; -- system reset, low-active, async
    rst_cause_i : in  std_ulogic_vector(1 downto 0); -- reset cause
    bus_req_i   : in  bus_req_t;  -- bus request
    bus_rsp_o   : out bus_rsp_t;  -- bus response
    cpu_debug_i : in  std_ulogic; -- CPU is in debug mode
    cpu_sleep_i : in  std_ulogic; -- CPU is in sleep mode
    clkgen_en_o : out std_ulogic; -- enable clock generator
    clkgen_i    : in  std_ulogic_vector(7 downto 0);
    rstn_o      : out std_ulogic  -- timeout reset, low_active, sync
  );
end neorv32_wdt;

architecture neorv32_wdt_rtl of neorv32_wdt is

  -- Reset password --
  constant reset_pwd_c : std_ulogic_vector(31 downto 0) := x"709d1ab3";

  -- Control register bits --
  constant ctrl_enable_c      : natural :=  0; -- r/w: WDT enable
  constant ctrl_lock_c        : natural :=  1; -- r/w: lock write access to control register when set
  constant ctrl_dben_c        : natural :=  2; -- r/w: allow WDT to continue operation even when CPU is in debug mode
  constant ctrl_sen_c         : natural :=  3; -- r/w: allow WDT to continue operation even when CPU is in sleep mode
  constant ctrl_strict_c      : natural :=  4; -- r/w: force hardware reset if reset password is incorrect
  constant ctrl_rcause_lo_c   : natural :=  5; -- r/-: cause of last system reset - low
  constant ctrl_rcause_hi_c   : natural :=  6; -- r/-: cause of last system reset - high
  --
  constant ctrl_timeout_lsb_c : natural :=  8; -- r/w: timeout value LSB
  constant ctrl_timeout_msb_c : natural := 31; -- r/w: timeout value MSB

  -- control register --
  type ctrl_t is record
    enable  : std_ulogic;
    lock    : std_ulogic;
    dben    : std_ulogic;
    sen     : std_ulogic;
    strict  : std_ulogic;
    timeout : std_ulogic_vector(23 downto 0);
  end record;
  signal ctrl : ctrl_t;

  -- prescaler clock generator --
  signal prsc_tick : std_ulogic;

  -- timeout counter --
  signal cnt                 : std_ulogic_vector(23 downto 0); -- timeout counter
  signal cnt_started         : std_ulogic;
  signal cnt_inc, cnt_inc_ff : std_ulogic; -- increment counter when set
  signal timeout_rst         : std_ulogic;

  -- misc --
  signal hw_rst      : std_ulogic;
  signal reset_wdt   : std_ulogic;
  signal reset_force : std_ulogic;

begin

  -- Bus Access -----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  bus_access: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      bus_rsp_o    <= rsp_terminate_c;
      ctrl.enable  <= '0'; -- disable WDT after reset
      ctrl.lock    <= '0'; -- unlock after reset
      ctrl.dben    <= '0';
      ctrl.sen     <= '0';
      ctrl.strict  <= '0';
      ctrl.timeout <= (others => '0');
      reset_wdt    <= '0';
      reset_force  <= '0';
    elsif rising_edge(clk_i) then
      -- bus handshake --
      bus_rsp_o.ack  <= bus_req_i.stb;
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      -- defaults --
      reset_wdt   <= '0';
      reset_force <= '0';

      if (bus_req_i.stb = '1') then

        -- write access --
        if (bus_req_i.rw = '1') then
          if (bus_req_i.addr(2) = '0') then -- control register
            if (ctrl.lock = '0') then -- update configuration only if not locked
              ctrl.enable  <= bus_req_i.data(ctrl_enable_c);
              ctrl.lock    <= bus_req_i.data(ctrl_lock_c) and ctrl.enable; -- lock only if already enabled
              ctrl.dben    <= bus_req_i.data(ctrl_dben_c);
              ctrl.sen     <= bus_req_i.data(ctrl_sen_c);
              ctrl.strict  <= bus_req_i.data(ctrl_strict_c);
              ctrl.timeout <= bus_req_i.data(ctrl_timeout_msb_c downto ctrl_timeout_lsb_c);
            else -- write access attempt to locked CTRL register
              reset_force <= '1';
            end if;
          else -- reset timeout counter - password check
            if (bus_req_i.data(31 downto 0) = reset_pwd_c) then
              reset_wdt <= '1'; -- password correct
            else
              reset_force <= '1'; -- password incorrect
            end if;
          end if;

        -- read access --
        else
          bus_rsp_o.data(ctrl_enable_c)                                <= ctrl.enable;
          bus_rsp_o.data(ctrl_lock_c)                                  <= ctrl.lock;
          bus_rsp_o.data(ctrl_dben_c)                                  <= ctrl.dben;
          bus_rsp_o.data(ctrl_sen_c)                                   <= ctrl.sen;
          bus_rsp_o.data(ctrl_rcause_hi_c downto ctrl_rcause_lo_c)     <= rst_cause_i;
          bus_rsp_o.data(ctrl_strict_c)                                <= ctrl.strict;
          bus_rsp_o.data(ctrl_timeout_msb_c downto ctrl_timeout_lsb_c) <= ctrl.timeout;
        end if;

      end if;
    end if;
  end process bus_access;


  -- Timeout Counter ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  wdt_counter: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      cnt_inc_ff  <= '0';
      cnt_started <= '0';
      cnt         <= (others => '0');
    elsif rising_edge(clk_i) then
      cnt_inc_ff  <= cnt_inc;
      cnt_started <= ctrl.enable and (cnt_started or prsc_tick); -- start with next clock tick
      if (ctrl.enable = '0') or (reset_wdt = '1') then -- watchdog disabled or reset with correct password
        cnt <= (others => '0');
      elsif (cnt_inc_ff = '1') then
        cnt <= std_ulogic_vector(unsigned(cnt) + 1);
      end if;
    end if;
  end process wdt_counter;

  -- clock generator --
  clkgen_en_o <= ctrl.enable; -- enable clock generator
  prsc_tick   <= clkgen_i(clk_div4096_c); -- clock enable tick

  -- valid counter increment? --
  cnt_inc <= '1' when ((prsc_tick = '1') and (cnt_started = '1')) and -- clock tick and started
                      ((cpu_debug_i = '0') or (ctrl.dben = '1'))  and -- not in debug mode or allowed to run in debug mode
                      ((cpu_sleep_i = '0') or (ctrl.sen = '1')) else '0'; -- not in sleep mode or allowed to run in sleep mode

  -- timeout detector --
  timeout_rst <= '1' when (cnt_started = '1') and (cnt = ctrl.timeout) else '0';


  -- Reset Generator ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  reset_generator: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      hw_rst <= '0';
    elsif rising_edge(clk_i) then
      hw_rst <= '0';
      if (ctrl.enable = '1') and -- enabled
         (((timeout_rst = '1') and (prsc_tick = '1')) or -- timeout
          ((ctrl.strict = '1') and (reset_force = '1'))) then -- strict mode and incorrect password
        hw_rst <= '1';
      end if;
    end if;
  end process reset_generator;

  -- system-wide reset --
  rstn_o <= not hw_rst;


end neorv32_wdt_rtl;
