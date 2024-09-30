-- ================================================================================ --
-- NEORV32 SoC - Two-Wire Interface Controller (TWI)                                --
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

entity neorv32_twi is
  generic (
    IO_TWI_FIFO : natural range 1 to 2**15 -- TWI RTX fifo depth, has to be a power of two, min 1
  );
  port (
    clk_i       : in  std_ulogic; -- global clock line
    rstn_i      : in  std_ulogic; -- global reset line, low-active, async
    bus_req_i   : in  bus_req_t;  -- bus request
    bus_rsp_o   : out bus_rsp_t;  -- bus response
    clkgen_en_o : out std_ulogic; -- enable clock generator
    clkgen_i    : in  std_ulogic_vector(7 downto 0);
    twi_sda_i   : in  std_ulogic; -- serial data line input
    twi_sda_o   : out std_ulogic; -- serial data line output
    twi_scl_i   : in  std_ulogic; -- serial clock line input
    twi_scl_o   : out std_ulogic; -- serial clock line output
    irq_o       : out std_ulogic  -- interrupt
  );
end neorv32_twi;

architecture neorv32_twi_rtl of neorv32_twi is

  -- control register --
  constant ctrl_en_c         : natural :=  0; -- r/w: module enable (reset when zero)
  constant ctrl_prsc0_c      : natural :=  1; -- r/w: CLK prsc bit 0
  constant ctrl_prsc1_c      : natural :=  2; -- r/w: CLK prsc bit 1
  constant ctrl_prsc2_c      : natural :=  3; -- r/w: CLK prsc bit 2
  constant ctrl_cdiv0_c      : natural :=  4; -- r/w: clock divider bit 0
  constant ctrl_cdiv1_c      : natural :=  5; -- r/w: clock divider bit 1
  constant ctrl_cdiv2_c      : natural :=  6; -- r/w: clock divider bit 2
  constant ctrl_cdiv3_c      : natural :=  7; -- r/w: clock divider bit 3
  constant ctrl_clkstr_en_c  : natural :=  8; -- r/w: enable clock stretching
  --
  constant ctrl_fifo_size0_c : natural := 15; -- r/-: log2(fifo size), bit 0 (lsb)
  constant ctrl_fifo_size1_c : natural := 16; -- r/-: log2(fifo size), bit 1
  constant ctrl_fifo_size2_c : natural := 17; -- r/-: log2(fifo size), bit 2
  constant ctrl_fifo_size3_c : natural := 18; -- r/-: log2(fifo size), bit 3 (msb)
  --
  constant ctrl_tx_full_c    : natural := 29; -- r/-: TX FIFO full
  constant ctrl_rx_avail_c   : natural := 30; -- r/-: RX FIFO data available
  constant ctrl_busy_c       : natural := 31; -- r/-: Set if TWI unit is busy

  -- data/command register --
  constant dcmd_lsb_c    : natural :=  0; -- r/w: data byte LSB
  constant dcmd_msb_c    : natural :=  7; -- r/w: data byte MSB
  constant dcmd_ack_c    : natural :=  8; -- r/w: ACK/NACK/MACK
  constant dcmd_cmd_lo_c : natural :=  9; -- -/w: operation command; 00=NOP, 01=START
  constant dcmd_cmd_hi_c : natural := 10; -- -/w: operation command; 10=STOP, 11=DATA

  -- control register --
  type ctrl_t is record
    enable : std_ulogic;
    prsc   : std_ulogic_vector(2 downto 0);
    cdiv   : std_ulogic_vector(3 downto 0);
    clkstr : std_ulogic;
  end record;
  signal ctrl : ctrl_t;

  -- FIFO interface --
  type fifo_t is record
    clear              : std_ulogic; -- sync reset, high-active
    rx_we,    tx_we    : std_ulogic; -- write enable
    rx_re,    tx_re    : std_ulogic; -- read enable
    rx_wdata, rx_rdata : std_ulogic_vector(8 downto 0); -- RX read/write data
    tx_wdata, tx_rdata : std_ulogic_vector(10 downto 0); -- TX read/write data
    rx_avail, tx_avail : std_ulogic; -- data available?
    rx_free,  tx_free  : std_ulogic; -- free entry available?
  end record;
  signal fifo : fifo_t;

  -- clock generator --
  type clk_gen_t is record
    cnt          : std_ulogic_vector(3 downto 0); -- clock divider
    tick         : std_ulogic; -- actual TWI clock tick
    halt         : std_ulogic; -- halt clock during clock stretching
    phase_gen    : std_ulogic_vector(3 downto 0); -- clock phase generator
    phase_gen_ff : std_ulogic_vector(3 downto 0);
    phase        : std_ulogic_vector(3 downto 0);
  end record;
  signal clk_gen : clk_gen_t;

  -- bus engine --
  type engine_t is record
    state  : std_ulogic_vector(2 downto 0); -- FSM state
    bitcnt : std_ulogic_vector(3 downto 0); -- bit counter
    sreg   : std_ulogic_vector(8 downto 0); -- main rx/tx shift reg
    done   : std_ulogic; -- data transmission done
    busy   : std_ulogic; -- bus operation in progress
  end record;
  signal engine : engine_t;

  -- tristate I/O control --
  type io_con_t is record
    sda_in_ff, scl_in_ff : std_ulogic_vector(1 downto 0); -- input sync
    sda_in,    scl_in    : std_ulogic;
    sda_out,   scl_out   : std_ulogic;
  end record;
  signal io_con : io_con_t;

begin

  -- Bus Access -----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  bus_access: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      bus_rsp_o   <= rsp_terminate_c;
      ctrl.enable <= '0';
      ctrl.prsc   <= (others => '0');
      ctrl.cdiv   <= (others => '0');
    elsif rising_edge(clk_i) then
      -- bus handshake defaults --
      bus_rsp_o.ack  <= bus_req_i.stb;
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');
      -- read/write access --
      if (bus_req_i.stb = '1') then
        if (bus_req_i.rw = '1') then -- write access
          if (bus_req_i.addr(2) = '0') then -- control register
            ctrl.enable <= bus_req_i.data(ctrl_en_c);
            ctrl.prsc   <= bus_req_i.data(ctrl_prsc2_c downto ctrl_prsc0_c);
            ctrl.cdiv   <= bus_req_i.data(ctrl_cdiv3_c downto ctrl_cdiv0_c);
            ctrl.clkstr <= bus_req_i.data(ctrl_clkstr_en_c);
          end if;
        else -- read access
          if (bus_req_i.addr(2) = '0') then -- control register
            bus_rsp_o.data(ctrl_en_c)                        <= ctrl.enable;
            bus_rsp_o.data(ctrl_prsc2_c downto ctrl_prsc0_c) <= ctrl.prsc;
            bus_rsp_o.data(ctrl_cdiv3_c downto ctrl_cdiv0_c) <= ctrl.cdiv;
            bus_rsp_o.data(ctrl_clkstr_en_c)                 <= ctrl.clkstr;
            --
            bus_rsp_o.data(ctrl_fifo_size3_c downto ctrl_fifo_size0_c) <= std_ulogic_vector(to_unsigned(index_size_f(IO_TWI_FIFO), 4));
            --
            bus_rsp_o.data(ctrl_tx_full_c)  <= not fifo.tx_free;
            bus_rsp_o.data(ctrl_rx_avail_c) <= fifo.rx_avail;
            bus_rsp_o.data(ctrl_busy_c)     <= engine.busy or fifo.tx_avail; -- bus engine busy or TX FIFO not empty
          else -- RX FIFO
            bus_rsp_o.data(8 downto 0) <= fifo.rx_rdata; -- ACK + data
          end if;
        end if;
      end if;
    end if;
  end process bus_access;


  -- Data FIFO ("Ring Buffer") --------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------

  -- global FIFO clear --
  fifo.clear <= not ctrl.enable;


  -- TX FIFO --
  tx_fifo_inst: entity neorv32.neorv32_fifo
  generic map (
    FIFO_DEPTH => IO_TWI_FIFO,
    FIFO_WIDTH => 11, -- command, MACK, data
    FIFO_RSYNC => true,
    FIFO_SAFE  => true,
    FULL_RESET => false
  )
  port map (
    -- control --
    clk_i   => clk_i,
    rstn_i  => rstn_i,
    clear_i => fifo.clear,
    half_o  => open,
    -- write port --
    wdata_i => fifo.tx_wdata,
    we_i    => fifo.tx_we,
    free_o  => fifo.tx_free,
    -- read port --
    re_i    => fifo.tx_re,
    rdata_o => fifo.tx_rdata,
    avail_o => fifo.tx_avail
  );

  fifo.tx_we    <= '1' when (bus_req_i.stb = '1') and (bus_req_i.rw = '1') and (bus_req_i.addr(2) = '1') else '0';
  fifo.tx_wdata <= bus_req_i.data(dcmd_cmd_hi_c downto dcmd_lsb_c);
  fifo.tx_re    <= '1' when (engine.busy = '0') and (fifo.tx_avail = '1') and (clk_gen.tick = '1') else '0';


  -- RX FIFO --
  rx_fifo_inst: entity neorv32.neorv32_fifo
  generic map (
    FIFO_DEPTH => IO_TWI_FIFO,
    FIFO_WIDTH => 9, -- ACK + data
    FIFO_RSYNC => true,
    FIFO_SAFE  => true,
    FULL_RESET => false
  )
  port map (
    -- control --
    clk_i   => clk_i,
    rstn_i  => rstn_i,
    clear_i => fifo.clear,
    half_o  => open,
    -- write port --
    wdata_i => fifo.rx_wdata,
    we_i    => fifo.rx_we,
    free_o  => fifo.rx_free,
    -- read port --
    re_i    => fifo.rx_re,
    rdata_o => fifo.rx_rdata,
    avail_o => fifo.rx_avail
  );

  fifo.rx_wdata <= engine.sreg(0) & engine.sreg(8 downto 1); -- ACK + data
  fifo.rx_we    <= engine.done;
  fifo.rx_re    <= '1' when (bus_req_i.stb = '1') and (bus_req_i.rw = '0') and (bus_req_i.addr(2) = '1') else '0';


  -- IRQ if enabled and TX FIFO is empty and bus engine is idle --
  irq_generator: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      irq_o <= '0';
    elsif rising_edge(clk_i) then
      irq_o <= ctrl.enable and (not fifo.tx_avail) and (not engine.busy);
    end if;
  end process irq_generator;


  -- TWI Clock Generator --------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  clock_generator: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      clk_gen.tick <= '0';
      clk_gen.cnt  <= (others => '0');
    elsif rising_edge(clk_i) then
      if (ctrl.enable = '0') then -- reset/disabled
        clk_gen.tick <= '0';
        clk_gen.cnt  <= (others => '0');
      else
        clk_gen.tick <= '0'; -- default
        if (clkgen_i(to_integer(unsigned(ctrl.prsc))) = '1') then -- pre-scaled clock
          if (clk_gen.cnt = ctrl.cdiv) then -- clock divider for fine-tuning
            clk_gen.tick <= '1';
            clk_gen.cnt  <= (others => '0');
          else
            clk_gen.cnt <= std_ulogic_vector(unsigned(clk_gen.cnt) + 1);
          end if;
        end if;
      end if;
    end if;
  end process clock_generator;

  -- global clock generator enable --
  clkgen_en_o <= ctrl.enable;

  -- generate four non-overlapping clock phases --
  phase_generator: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      clk_gen.phase_gen    <= (others => '0');
      clk_gen.phase_gen_ff <= (others => '0');
    elsif rising_edge(clk_i) then
      clk_gen.phase_gen_ff <= clk_gen.phase_gen;
      if (ctrl.enable = '0') or (engine.busy = '0') then -- disabled or idle
        clk_gen.phase_gen <= "0001"; -- make sure to start with a new phase beginning
      elsif (clk_gen.tick = '1') and (clk_gen.halt = '0') then -- clock tick and no clock stretching
        clk_gen.phase_gen <= clk_gen.phase_gen(2 downto 0) & clk_gen.phase_gen(3); -- rotate left
      end if;
    end if;
  end process phase_generator;

  -- TWI bus signals are set/sampled using 4 clock phases --
  clk_gen.phase(0) <= clk_gen.phase_gen_ff(0) and (not clk_gen.phase_gen(0)); -- first step
  clk_gen.phase(1) <= clk_gen.phase_gen_ff(1) and (not clk_gen.phase_gen(1));
  clk_gen.phase(2) <= clk_gen.phase_gen_ff(2) and (not clk_gen.phase_gen(2));
  clk_gen.phase(3) <= clk_gen.phase_gen_ff(3) and (not clk_gen.phase_gen(3)); -- last step

  -- Clock Stretching Detector --
  -- controller wants to drive SCL high, but SCL is still pulled low by peripheral --
  clk_gen.halt <= '1' when (io_con.scl_out = '1') and (io_con.scl_in_ff(1) = '0') and (ctrl.clkstr = '1') else '0';


  -- TWI Bus Engine -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  twi_engine: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      io_con.sda_in_ff <= (others => '0');
      io_con.scl_in_ff <= (others => '0');
      io_con.sda_out   <= '0';
      io_con.scl_out   <= '0';
      engine.state     <= (others => '0');
      engine.bitcnt    <= (others => '0');
      engine.sreg      <= (others => '0');
      engine.done      <= '0';
    elsif rising_edge(clk_i) then
      -- input synchronizer --
      io_con.sda_in_ff <= io_con.sda_in_ff(0) & io_con.sda_in;
      io_con.scl_in_ff <= io_con.scl_in_ff(0) & io_con.scl_in;

      -- defaults --
      engine.done <= '0';

      -- serial engine --
      engine.state(2) <= ctrl.enable; -- module enabled?
      case engine.state is

        when "100" => -- IDLE: waiting for operation requests
        -- ------------------------------------------------------------
          engine.bitcnt <= (others => '0');
          engine.sreg   <= fifo.tx_rdata(dcmd_msb_c downto dcmd_lsb_c) & (not fifo.tx_rdata(dcmd_ack_c)); -- data + HOST ACK
          if (fifo.tx_avail = '1') and (clk_gen.tick = '1') then -- trigger new operation on next TWI clock pulse
            engine.state(1 downto 0) <= fifo.tx_rdata(dcmd_cmd_hi_c downto dcmd_cmd_lo_c);
          end if;

        when "101" => -- START: generate (repeated) START condition
        -- ------------------------------------------------------------
          if (clk_gen.phase(0) = '1') then
            io_con.sda_out <= '1';
          elsif (clk_gen.phase(1) = '1') then
            io_con.sda_out <= '0';
          end if;
          --
          if (clk_gen.phase(0) = '1') then
            io_con.scl_out <= '1';
          elsif (clk_gen.phase(3) = '1') then
            io_con.scl_out <= '0';
            engine.state(1 downto 0) <= "00"; -- go back to IDLE
          end if;

        when "110" => -- STOP: generate STOP condition
        -- ------------------------------------------------------------
          if (clk_gen.phase(0) = '1') then
            io_con.sda_out <= '0';
          elsif (clk_gen.phase(3) = '1') then
            io_con.sda_out <= '1';
            engine.state(1 downto 0) <= "00"; -- go back to IDLE
          end if;
          --
          if (clk_gen.phase(0) = '1') then
            io_con.scl_out <= '0';
          elsif (clk_gen.phase(1) = '1') then
            io_con.scl_out <= '1';
          end if;

        when "111" => -- TRANSMISSION: send/receive byte + ACK/NACK/MACK
        -- ------------------------------------------------------------
          -- SCL clocking --
          if (clk_gen.phase(0) = '1') or (clk_gen.phase(3) = '1') then
            io_con.scl_out <= '0'; -- set SCL low after transmission to keep bus claimed
          elsif (clk_gen.phase(1) = '1') then -- first half + second half of valid data strobe
            io_con.scl_out <= '1';
          end if;
          -- SDA output --
          if (engine.bitcnt = "1001") and (clk_gen.phase(0) = '1') then
            io_con.sda_out <= '0'; -- set SDA low after transmission to keep bus claimed
          elsif (clk_gen.phase(0) = '1') then
            io_con.sda_out <= engine.sreg(8); -- MSB first
          end if;
          -- SDA input --
          if (clk_gen.phase(2) = '1') then
            engine.sreg <= engine.sreg(7 downto 0) & io_con.sda_in_ff(1); -- sample SDA input and shift left
          end if;
          -- bit counter --
          if (clk_gen.phase(3) = '1') then
            engine.bitcnt <= std_ulogic_vector(unsigned(engine.bitcnt) + 1);
          end if;
          -- transmission done --
          if (engine.bitcnt = "1001") and (clk_gen.phase(0) = '1') then
            engine.done              <= '1';
            engine.state(1 downto 0) <= "00"; -- go back to IDLE
          end if;

        when others => -- "0---" OFFLINE: TWI deactivated, bus unclaimed
        -- ------------------------------------------------------------
          io_con.scl_out           <= '1'; -- SCL driven by pull-up resistor
          io_con.sda_out           <= '1'; -- SDA driven by pull-up resistor
          engine.state(1 downto 0) <= "00"; -- stay here, go to IDLE when activated

      end case;
    end if;
  end process twi_engine;

  -- bus operation in progress --
  engine.busy <= '1' when (engine.state(2) = '1') and (engine.state(1 downto 0) /= "00") else '0';


  -- Tristate Driver Interface --------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  twi_sda_o     <= io_con.sda_out; -- NOTE: signal lines can only be actively driven low
  twi_scl_o     <= io_con.scl_out;
  io_con.sda_in <= to_stdulogic(to_bit(twi_sda_i)); -- "to_bit" to avoid hardware-vs-simulation mismatch
  io_con.scl_in <= to_stdulogic(to_bit(twi_scl_i)); -- "to_bit" to avoid hardware-vs-simulation mismatch


end neorv32_twi_rtl;
