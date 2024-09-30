-- ================================================================================ --
-- NEORV32 SoC - Serial Data Interface (SDI)                                        --
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

entity neorv32_sdi is
  generic (
    RTX_FIFO : natural range 1 to 2**15 -- RTX fifo depth, has to be a power of two, min 1
  );
  port (
    clk_i     : in  std_ulogic; -- global clock line
    rstn_i    : in  std_ulogic; -- global reset line, low-active, async
    bus_req_i : in  bus_req_t;  -- bus request
    bus_rsp_o : out bus_rsp_t;  -- bus response
    sdi_csn_i : in  std_ulogic; -- low-active chip-select
    sdi_clk_i : in  std_ulogic; -- serial clock
    sdi_dat_i : in  std_ulogic; -- serial data input
    sdi_dat_o : out std_ulogic; -- serial data output
    irq_o     : out std_ulogic  -- CPU interrupt
  );
end neorv32_sdi;

architecture neorv32_sdi_rtl of neorv32_sdi is

  -- control register --
  constant ctrl_en_c           : natural :=  0; -- r/w: SDI enable
  --
  constant ctrl_fifo_size0_c   : natural :=  4; -- r/-: log2(FIFO size), bit 0 (lsb)
  constant ctrl_fifo_size1_c   : natural :=  5; -- r/-: log2(FIFO size), bit 1
  constant ctrl_fifo_size2_c   : natural :=  6; -- r/-: log2(FIFO size), bit 2
  constant ctrl_fifo_size3_c   : natural :=  7; -- r/-: log2(FIFO size), bit 3 (msb)
  --
  constant ctrl_irq_rx_avail_c : natural := 15; -- r/w: RX FIFO not empty
  constant ctrl_irq_rx_half_c  : natural := 16; -- r/w: RX FIFO at least half full
  constant ctrl_irq_rx_full_c  : natural := 17; -- r/w: RX FIFO full
  constant ctrl_irq_tx_empty_c : natural := 18; -- r/w: TX FIFO empty
  constant ctrl_irq_tx_nhalf_c : natural := 19; -- r/w: TX FIFO not at least half full
  --
  constant ctrl_rx_avail_c     : natural := 23; -- r/-: RX FIFO not empty
  constant ctrl_rx_half_c      : natural := 24; -- r/-: RX FIFO at least half full
  constant ctrl_rx_full_c      : natural := 25; -- r/-: RX FIFO full
  constant ctrl_tx_empty_c     : natural := 26; -- r/-: TX FIFO empty
  constant ctrl_tx_nhalf_c     : natural := 27; -- r/-: TX FIFO not at least half-full
  constant ctrl_tx_full_c      : natural := 28; -- r/-: TX FIFO full
  --
  constant ctrl_cs_active_c    : natural := 31; -- r/-: chip-select is active when set

  -- control register (see bit definitions above) --
  type ctrl_t is record
    enable       : std_ulogic;
    irq_rx_avail : std_ulogic;
    irq_rx_half  : std_ulogic;
    irq_rx_full  : std_ulogic;
    irq_tx_empty : std_ulogic;
    irq_tx_nhalf : std_ulogic;
  end record;
  signal ctrl : ctrl_t;

  -- input synchronizer --
  type sync_t is record
    sck_ff : std_ulogic_vector(2 downto 0);
    csn_ff : std_ulogic_vector(1 downto 0);
    sdi_ff : std_ulogic_vector(1 downto 0);
    sck    : std_ulogic;
    csn    : std_ulogic;
    sdi    : std_ulogic;
  end record;
  signal sync : sync_t;

  -- serial engine --
  type serial_t is record
    state  : std_ulogic_vector(2 downto 0);
    cnt    : std_ulogic_vector(3 downto 0);
    sreg   : std_ulogic_vector(7 downto 0);
    sdi_ff : std_ulogic;
    start  : std_ulogic;
    done   : std_ulogic;
  end record;
  signal serial : serial_t;

  -- RX/TX FIFO interface --
  type fifo_t is record
    we    : std_ulogic; -- write enable
    re    : std_ulogic; -- read enable
    clear : std_ulogic; -- sync reset, high-active
    wdata : std_ulogic_vector(7 downto 0); -- write data
    rdata : std_ulogic_vector(7 downto 0); -- read data
    avail : std_ulogic; -- data available?
    free  : std_ulogic; -- free entry available?
    half  : std_ulogic; -- half full
  end record;
  signal tx_fifo, rx_fifo : fifo_t;

begin

  -- Bus Access -----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  bus_access: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      bus_rsp_o         <= rsp_terminate_c;
      ctrl.enable       <= '0';
      ctrl.irq_rx_avail <= '0';
      ctrl.irq_rx_half  <= '0';
      ctrl.irq_rx_full  <= '0';
      ctrl.irq_tx_empty <= '0';
      ctrl.irq_tx_nhalf <= '0';
    elsif rising_edge(clk_i) then
      -- bus handshake --
      bus_rsp_o.ack  <= bus_req_i.stb;
      bus_rsp_o.err  <= '0';
      bus_rsp_o.data <= (others => '0');

      -- read/write access --
      if (bus_req_i.stb = '1') then
        if (bus_req_i.rw = '1') then -- write access
          if (bus_req_i.addr(2) = '0') then -- control register
            ctrl.enable <= bus_req_i.data(ctrl_en_c);
            --
            ctrl.irq_rx_avail <= bus_req_i.data(ctrl_irq_rx_avail_c);
            ctrl.irq_rx_half  <= bus_req_i.data(ctrl_irq_rx_half_c);
            ctrl.irq_rx_full  <= bus_req_i.data(ctrl_irq_rx_full_c);
            ctrl.irq_tx_empty <= bus_req_i.data(ctrl_irq_tx_empty_c);
            ctrl.irq_tx_nhalf <= bus_req_i.data(ctrl_irq_tx_nhalf_c);
          end if;
        else -- read access
          if (bus_req_i.addr(2) = '0') then -- control register
            bus_rsp_o.data(ctrl_en_c) <= ctrl.enable;
            --
            bus_rsp_o.data(ctrl_fifo_size3_c downto ctrl_fifo_size0_c) <= std_ulogic_vector(to_unsigned(index_size_f(RTX_FIFO), 4));
            --
            bus_rsp_o.data(ctrl_irq_rx_avail_c) <= ctrl.irq_rx_avail;
            bus_rsp_o.data(ctrl_irq_rx_half_c)  <= ctrl.irq_rx_half;
            bus_rsp_o.data(ctrl_irq_rx_full_c)  <= ctrl.irq_rx_full;
            bus_rsp_o.data(ctrl_irq_tx_empty_c) <= ctrl.irq_tx_empty;
            bus_rsp_o.data(ctrl_irq_tx_nhalf_c) <= ctrl.irq_tx_nhalf;
            --
            bus_rsp_o.data(ctrl_rx_avail_c) <= rx_fifo.avail;
            bus_rsp_o.data(ctrl_rx_half_c)  <= rx_fifo.half;
            bus_rsp_o.data(ctrl_rx_full_c)  <= not rx_fifo.free;
            bus_rsp_o.data(ctrl_tx_empty_c) <= not tx_fifo.avail;
            bus_rsp_o.data(ctrl_tx_nhalf_c) <= not tx_fifo.half;
            bus_rsp_o.data(ctrl_tx_full_c)  <= not tx_fifo.free;
            --
            bus_rsp_o.data(ctrl_cs_active_c) <= not sync.csn;
          else -- data register
            bus_rsp_o.data(7 downto 0) <= rx_fifo.rdata;
          end if;
        end if;
      end if;
    end if;
  end process bus_access;


  -- Data FIFO ("Ring Buffer") --------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------

  -- TX --
  tx_fifo_inst: entity neorv32.neorv32_fifo
  generic map (
    FIFO_DEPTH => RTX_FIFO, -- number of fifo entries; has to be a power of two; min 1
    FIFO_WIDTH => 8,        -- size of data elements in fifo (32-bit only for simulation)
    FIFO_RSYNC => true,     -- sync read
    FIFO_SAFE  => true,     -- safe access
    FULL_RESET => false     -- no HW reset, try to infer BRAM
  )
  port map (
    -- control --
    clk_i   => clk_i,         -- clock, rising edge
    rstn_i  => rstn_i,        -- async reset, low-active
    clear_i => tx_fifo.clear, -- sync reset, high-active
    half_o  => tx_fifo.half,  -- FIFO at least half-full
    -- write port --
    wdata_i => tx_fifo.wdata, -- write data
    we_i    => tx_fifo.we,    -- write enable
    free_o  => tx_fifo.free,  -- at least one entry is free when set
    -- read port --
    re_i    => tx_fifo.re,    -- read enable
    rdata_o => tx_fifo.rdata, -- read data
    avail_o => tx_fifo.avail  -- data available when set
  );

  -- write access (CPU) --
  tx_fifo.clear <= not ctrl.enable;
  tx_fifo.wdata <= bus_req_i.data(7 downto 0);
  tx_fifo.we    <= '1' when (bus_req_i.stb = '1') and (bus_req_i.rw = '1') and (bus_req_i.addr(2) = '1') else '0';

  -- read access (SDI) --
  tx_fifo.re <= serial.start;


  -- RX --
  rx_fifo_inst: entity neorv32.neorv32_fifo
  generic map (
    FIFO_DEPTH => RTX_FIFO, -- number of fifo entries; has to be a power of two; min 1
    FIFO_WIDTH => 8,        -- size of data elements in fifo (32-bit only for simulation)
    FIFO_RSYNC => true,     -- sync read
    FIFO_SAFE  => true,     -- safe access
    FULL_RESET => false     -- no HW reset, try to infer BRAM
  )
  port map (
    -- control --
    clk_i   => clk_i,         -- clock, rising edge
    rstn_i  => rstn_i,        -- async reset, low-active
    clear_i => rx_fifo.clear, -- sync reset, high-active
    half_o  => rx_fifo.half,  -- FIFO at least half-full
    -- write port --
    wdata_i => rx_fifo.wdata, -- write data
    we_i    => rx_fifo.we,    -- write enable
    free_o  => rx_fifo.free,  -- at least one entry is free when set
    -- read port --
    re_i    => rx_fifo.re,    -- read enable
    rdata_o => rx_fifo.rdata, -- read data
    avail_o => rx_fifo.avail  -- data available when set
  );

  -- write access (SDI) --
  rx_fifo.wdata <= serial.sreg;
  rx_fifo.we    <= serial.done;

  -- read access (CPU) --
  rx_fifo.clear <= not ctrl.enable;
  rx_fifo.re    <= '1' when (bus_req_i.stb = '1') and (bus_req_i.rw = '0') and (bus_req_i.addr(2) = '1') else '0';


  -- Interrupt Generator --
  irq_generator: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      irq_o <= '0';
    elsif rising_edge(clk_i) then
      irq_o <= ctrl.enable and (
               (ctrl.irq_rx_avail and      rx_fifo.avail)  or -- RX FIFO not empty
               (ctrl.irq_rx_half  and      rx_fifo.half)   or -- RX FIFO at least half full
               (ctrl.irq_rx_full  and (not rx_fifo.free))  or -- RX FIFO full
               (ctrl.irq_tx_empty and (not tx_fifo.avail)) or -- TX FIFO empty
               (ctrl.irq_tx_nhalf and (not tx_fifo.half)));   -- TX FIFO not at least half full
    end if;
  end process irq_generator;


  -- Input Synchronizer ---------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  synchronizer: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      sync.sck_ff <= (others => '0');
      sync.csn_ff <= (others => '0');
      sync.sdi_ff <= (others => '0');
    elsif rising_edge(clk_i) then
      sync.sck_ff <= sync.sck_ff(1 downto 0) & sdi_clk_i;
      sync.csn_ff <= sync.csn_ff(0) & sdi_csn_i;
      sync.sdi_ff <= sync.sdi_ff(0) & sdi_dat_i;
    end if;
  end process synchronizer;

  sync.sck <= sync.sck_ff(1) xor sync.sck_ff(2); -- edge detect
  sync.csn <= sync.csn_ff(1);
  sync.sdi <= sync.sdi_ff(1);


  -- Serial Engine --------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  serial_engine: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      serial.start  <= '0';
      serial.done   <= '0';
      serial.state  <= (others => '0');
      serial.cnt    <= (others => '0');
      serial.sreg   <= (others => '0');
      serial.sdi_ff <= '0';
    elsif rising_edge(clk_i) then
      -- defaults --
      serial.start <= '0';
      serial.done  <= '0';

      -- FSM --
      serial.state(2) <= ctrl.enable;
      case serial.state is

        when "100" => -- enabled but idle, waiting for new transmission trigger
        -- ------------------------------------------------------------
          serial.cnt <= (others => '0');
          if (tx_fifo.avail = '0') then -- send zero if no RX data available
            serial.sreg <= (others => '0');
          else
            serial.sreg <= tx_fifo.rdata;
          end if;
          if (sync.csn = '0') then -- start new transmission on falling edge of chip-select
            serial.start             <= '1';
            serial.state(1 downto 0) <= "10";
          end if;

        when "110" => -- bit phase A: sample
        -- ------------------------------------------------------------
          serial.sdi_ff <= sdi_dat_i;
          if (sync.csn = '1') then -- transmission aborted?
            serial.state(1 downto 0) <= "00";
          elsif (sync.sck = '1') then
            serial.cnt               <= std_ulogic_vector(unsigned(serial.cnt) + 1);
            serial.state(1 downto 0) <= "11";
          end if;

        when "111" => -- bit phase B: shift
        -- ------------------------------------------------------------
          if (sync.csn = '1') then -- transmission aborted?
            serial.state(1 downto 0) <= "00";
          elsif (sync.sck = '1') then
            serial.sreg <= serial.sreg(serial.sreg'left-1 downto 0) & serial.sdi_ff;
            if (serial.cnt(3) = '1') then -- done?
              serial.done              <= '1';
              serial.state(1 downto 0) <= "00";
            else
              serial.state(1 downto 0) <= "10";
            end if;
          end if;

        when others => -- "0--": disabled
        -- ------------------------------------------------------------
          serial.state(1 downto 0) <= "00";

      end case;
    end if;
  end process serial_engine;

  -- serial data output --
  sdi_dat_o <= serial.sreg(serial.sreg'left);


end neorv32_sdi_rtl;
