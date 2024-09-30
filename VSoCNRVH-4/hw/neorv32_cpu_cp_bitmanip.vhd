-- ================================================================================ --
-- NEORV32 CPU - Co-Processor: Bit-Manip. Co-Processor Unit (RISC-V "B" Extension)  --
-- -------------------------------------------------------------------------------- --
-- RISC-V "B" ISA Extension = Zba + Zbb + Zbs                                       --
--  Zba: Address-generation instructions                                            --
--  Zbb: Basic bit-manipulation instructions                                        --
--  Zbs: Single-bit instructions                                                    --
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

entity neorv32_cpu_cp_bitmanip is
  generic (
    FAST_SHIFT_EN : boolean  -- use barrel shifter for shift operations
  );
  port (
    -- global control --
    clk_i   : in  std_ulogic; -- global clock, rising edge
    rstn_i  : in  std_ulogic; -- global reset, low-active, async
    ctrl_i  : in  ctrl_bus_t; -- main control bus
    start_i : in  std_ulogic; -- trigger operation
    -- data input --
    cmp_i   : in  std_ulogic_vector(1 downto 0); -- comparator status
    rs1_i   : in  std_ulogic_vector(XLEN-1 downto 0); -- rf source 1
    rs2_i   : in  std_ulogic_vector(XLEN-1 downto 0); -- rf source 2
    shamt_i : in  std_ulogic_vector(index_size_f(XLEN)-1 downto 0); -- shift amount
    -- result and status --
    res_o   : out std_ulogic_vector(XLEN-1 downto 0); -- operation result
    valid_o : out std_ulogic -- data output valid
  );
end neorv32_cpu_cp_bitmanip;

architecture neorv32_cpu_cp_bitmanip_rtl of neorv32_cpu_cp_bitmanip is

  -- Zbb - logic with negate --
  constant op_andn_c  : natural := 0;
  constant op_orn_c   : natural := 1;
  constant op_xnor_c  : natural := 2;
  -- Zbb - count leading/trailing zeros --
  constant op_cz_c    : natural := 3;
  -- Zbb - count population --
  constant op_cpop_c  : natural := 4;
  -- Zbb - minimum/maximum --
  constant op_max_c   : natural := 5;
  -- Zbb - sign/zero-extension --
  constant op_sext_c  : natural := 6;
  constant op_zexth_c : natural := 7;
  -- Zbb - bitwise rotation --
  constant op_rot_c   : natural := 8;
  -- Zbb - or-combine --
  constant op_orcb_c  : natural := 9;
  -- Zbb - byte-reverse --
  constant op_rev8_c  : natural := 10;
  -- Zba - shifted-add --
  constant op_shadd_c : natural := 11;
  -- Zbs - single-bit operations --
  constant op_bclr_c  : natural := 12;
  constant op_bext_c  : natural := 13;
  constant op_binv_c  : natural := 14;
  constant op_bset_c  : natural := 15;
  --
  constant op_width_c : natural := 16;

  -- controller --
  type ctrl_state_t is (S_IDLE, S_START_SHIFT, S_BUSY_SHIFT);
  signal ctrl_state : ctrl_state_t;
  signal cmd        : std_ulogic_vector(op_width_c-1 downto 0);
  signal valid      : std_ulogic;

  -- operand buffers --
  signal rs1_reg  : std_ulogic_vector(XLEN-1 downto 0);
  signal rs2_reg  : std_ulogic_vector(XLEN-1 downto 0);
  signal sha_reg  : std_ulogic_vector(index_size_f(XLEN)-1 downto 0);
  signal less_reg : std_ulogic;

  -- serial shifter --
  type shifter_t is record
    start   : std_ulogic;
    run     : std_ulogic;
    nxt     : std_ulogic;
    bcnt    : std_ulogic_vector(index_size_f(XLEN) downto 0); -- bit counter
    cnt     : std_ulogic_vector(index_size_f(XLEN) downto 0); -- iteration counter
    cnt_max : std_ulogic_vector(index_size_f(XLEN) downto 0);
    sreg    : std_ulogic_vector(XLEN-1 downto 0);
  end record;
  signal shifter : shifter_t;

  -- barrel shifter --
  type bs_level_t is array (index_size_f(XLEN) downto 0) of std_ulogic_vector(XLEN-1 downto 0);
  signal bs_level : bs_level_t;
  signal bs_shift : std_ulogic_vector(index_size_f(XLEN)-1 downto 0);

  -- operation results --
  type res_t is array (0 to op_width_c-1) of std_ulogic_vector(XLEN-1 downto 0);
  signal res_int, res_out : res_t;

  -- shifted-add and one-hot results --
  signal adder_res, one_hot_res : std_ulogic_vector(XLEN-1 downto 0);

begin

  -- Instruction Decoding (One-Hot) ---------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- An "operation" decoding logic is used here just to distinguish between the different B instructions.
  -- A more general decoding as well as a valid-instruction-check is performed by the CPU control unit.

  -- Zbb - Basic bit-manipulation instructions --
  cmd(op_andn_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "10") and (ctrl_i.ir_funct12(7) = '0') and (ctrl_i.ir_funct3(1 downto 0) = "11") else '0';
  cmd(op_orn_c)   <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "10") and (ctrl_i.ir_funct12(7) = '0') and (ctrl_i.ir_funct3(1 downto 0) = "10") else '0';
  cmd(op_xnor_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "10") and (ctrl_i.ir_funct12(7) = '0') and (ctrl_i.ir_funct3(1 downto 0) = "00") else '0';
  cmd(op_max_c)   <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "00") and (ctrl_i.ir_funct12(5) = '1') and (ctrl_i.ir_funct3(2) = '1') else '0';
  cmd(op_zexth_c) <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "00") and (ctrl_i.ir_funct12(5) = '0') else '0';
  cmd(op_orcb_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "01") and (ctrl_i.ir_funct12(7) = '1') and (ctrl_i.ir_funct3(2 downto 0) = "101") else '0';
  cmd(op_cz_c)    <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "11") and (ctrl_i.ir_funct12(7) = '0') and (ctrl_i.ir_funct12(2 downto 1) = "00")  and (ctrl_i.ir_funct3(2) = '0') and (ctrl_i.ir_opcode(5) = '0') else '0';
  cmd(op_cpop_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "11") and (ctrl_i.ir_funct12(7) = '0') and (ctrl_i.ir_funct12(2 downto 0) = "010") and (ctrl_i.ir_funct3(2) = '0') and (ctrl_i.ir_opcode(5) = '0') else '0';
  cmd(op_sext_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "11") and (ctrl_i.ir_funct12(7) = '0') and (ctrl_i.ir_funct12(2 downto 1) = "10")  and (ctrl_i.ir_funct3(2) = '0') and (ctrl_i.ir_opcode(5) = '0') else '0';
  cmd(op_rot_c)   <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "11") and (ctrl_i.ir_funct12(7) = '0') and (((ctrl_i.ir_funct3(2 downto 0) = "001") and (ctrl_i.ir_opcode(5) = '1')) or (ctrl_i.ir_funct3(2 downto 0) = "101")) else '0';
  cmd(op_rev8_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "11") and (ctrl_i.ir_funct12(7) = '1') and (ctrl_i.ir_funct3(2 downto 0) = "101") else '0';

  -- Zba - Address generation instructions --
  cmd(op_shadd_c) <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "01") and (ctrl_i.ir_funct12(7) = '0') else '0';

  -- Zbs - Single-bit instructions --
  cmd(op_bclr_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "10") and (ctrl_i.ir_funct12(7) = '1') and (ctrl_i.ir_funct3(2) = '0') else '0';
  cmd(op_bext_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "10") and (ctrl_i.ir_funct12(7) = '1') and (ctrl_i.ir_funct3(2) = '1') else '0';
  cmd(op_binv_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "11") and (ctrl_i.ir_funct12(7) = '1') and (ctrl_i.ir_funct3(2) = '0') else '0';
  cmd(op_bset_c)  <= '1' when (ctrl_i.ir_funct12(10 downto 9) = "01") and (ctrl_i.ir_funct12(7) = '1') and (ctrl_i.ir_funct3(2) = '0') else '0';


  -- Co-Processor Controller ----------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  coprocessor_ctrl: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      ctrl_state    <= S_IDLE;
      rs1_reg       <= (others => '0');
      rs2_reg       <= (others => '0');
      sha_reg       <= (others => '0');
      less_reg      <= '0';
      shifter.start <= '0';
      valid         <= '0';
    elsif rising_edge(clk_i) then
      -- defaults --
      shifter.start <= '0';
      valid         <= '0';

      -- operand registers --
      if (start_i = '1') then
        less_reg <= cmp_i(cmp_less_c);
        rs1_reg  <= rs1_i;
        rs2_reg  <= rs2_i;
        sha_reg  <= shamt_i;
      end if;

      -- fsm --
      case ctrl_state is

        when S_IDLE => -- wait for operation trigger
        -- ------------------------------------------------------------
          if (start_i = '1') then
            if (not FAST_SHIFT_EN) and ((cmd(op_cz_c) or cmd(op_cpop_c) or cmd(op_rot_c)) = '1') then -- multi-cycle shift operation
              shifter.start <= '1';
              ctrl_state <= S_START_SHIFT;
            else
              valid      <= '1';
              ctrl_state <= S_IDLE;
            end if;
          end if;

        when S_START_SHIFT => -- one cycle delay to start shift operation
        -- ------------------------------------------------------------
          ctrl_state <= S_BUSY_SHIFT;

        when S_BUSY_SHIFT => -- wait for multi-cycle shift operation to finish
        -- ------------------------------------------------------------
          if (shifter.run = '0') or (ctrl_i.cpu_trap = '1') then -- abort on trap
            valid      <= '1';
            ctrl_state <= S_IDLE;
          end if;

        when others => -- undefined
        -- ------------------------------------------------------------
          ctrl_state <= S_IDLE;

      end case;
    end if;
  end process coprocessor_ctrl;


  -- Shifter Function Core (iterative: small but slow) --------------------------------------
  -- -------------------------------------------------------------------------------------------
  serial_shifter:
  if not FAST_SHIFT_EN generate

    serial_shifter_core: process(rstn_i, clk_i)
    begin
      if (rstn_i = '0') then
        shifter.cnt     <= (others => '0');
        shifter.sreg    <= (others => '0');
        shifter.cnt_max <= (others => '0');
        shifter.bcnt    <= (others => '0');
      elsif rising_edge(clk_i) then
        if (shifter.start = '1') then -- trigger new shift
          shifter.cnt  <= (others => '0');
          shifter.sreg <= rs1_reg;
          if (cmd(op_cpop_c) = '1') then -- population count
            shifter.cnt_max <= (others => '0');
            shifter.cnt_max(shifter.cnt_max'left) <= '1';
          else
            shifter.cnt_max <= '0' & shamt_i;
          end if;
          shifter.bcnt <= (others => '0');
        elsif (shifter.run = '1') then
          if ((cmd(op_rot_c) = '1') and (ctrl_i.ir_funct3(2) = '0')) or -- rol
             ((cmd(op_cz_c) = '1') and (ctrl_i.ir_funct12(0) = '0')) then -- ctz
            shifter.sreg <= shifter.sreg(shifter.sreg'left-1 downto 0) & shifter.nxt; -- left-shift
          else
            shifter.sreg <= shifter.nxt & shifter.sreg(shifter.sreg'left downto 1); -- right-shift
          end if;
          shifter.cnt <= std_ulogic_vector(unsigned(shifter.cnt) + 1); -- iteration counter
          if (shifter.sreg(0) = '1') then
            shifter.bcnt <= std_ulogic_vector(unsigned(shifter.bcnt) + 1); -- set-bits counter
          end if;
        end if;
      end if;
    end process serial_shifter_core;

    -- shifted-in bit --
    shifter.nxt <= '1' when (cmd(op_cz_c) = '1') else -- count zeros
                   shifter.sreg(0) when (ctrl_i.ir_funct3(2) = '1') else -- right shift
                   shifter.sreg(XLEN-1); -- left shift

    -- run control --
    serial_shifter_ctrl: process(cmd, ctrl_i, shifter)
    begin
      -- keep shifting until all bits are processed --
      if (cmd(op_cz_c) = '1') then -- count zeros
        if (ctrl_i.ir_funct12(0) = '0') then -- leading zeros
          shifter.run <= not shifter.sreg(XLEN-1);
        else -- trailing zeros
          shifter.run <= not shifter.sreg(0);
        end if;
      else -- population count / rotate
        if (shifter.cnt = shifter.cnt_max) then
          shifter.run <= '0';
        else
          shifter.run <= '1';
        end if;
      end if;
    end process serial_shifter_ctrl;

  end generate; -- /serial_shifter


  -- Shifter Function Core (parallel: fast but large) ---------------------------------------
  -- -------------------------------------------------------------------------------------------
  barrel_shifter:
  if FAST_SHIFT_EN generate

    -- rotator input layer: convert left-rotates to right-rotates (rotate by XLEN - N positions) --
    bs_shift <= std_ulogic_vector(unsigned(not sha_reg) + 1) when (ctrl_i.ir_funct3(2) = '0') else sha_reg;

    -- rotator mux layers: right-rotates only --
    bs_level(0) <= rs1_reg;
    barrel_shifter_core:
    for i in 0 to index_size_f(XLEN)-1 generate
      bs_level(i+1)(XLEN-1 downto XLEN-(2**i)) <= bs_level(i)((2**i)-1 downto 0)  when (bs_shift(i) = '1') else bs_level(i)(XLEN-1 downto XLEN-(2**i));
      bs_level(i+1)((XLEN-(2**i))-1 downto 0)  <= bs_level(i)(XLEN-1 downto 2**i) when (bs_shift(i) = '1') else bs_level(i)((XLEN-(2**i))-1 downto 0);
    end generate;
    shifter.sreg <= bs_level(index_size_f(XLEN)); -- rol/ror[i]

    -- population count --
    shifter.bcnt <= std_ulogic_vector(to_unsigned(popcount_f(rs1_reg), shifter.bcnt'length)); -- cpop

    -- count leading/trailing zeros --
    shifter.cnt <= std_ulogic_vector(to_unsigned(leading_zeros_f(rs1_reg), shifter.cnt'length)) when (ctrl_i.ir_funct12(0) = '0') else -- clz
                   std_ulogic_vector(to_unsigned(leading_zeros_f(bit_rev_f(rs1_reg)), shifter.cnt'length)); -- ctz

    -- unused --
    shifter.run <= '0';

  end generate; -- /barrel_shifter


  -- Shifted-Add ----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  shift_adder: process(rs1_reg, rs2_reg, ctrl_i)
    variable tmp_v : std_ulogic_vector(XLEN-1 downto 0);
  begin
    case ctrl_i.ir_funct3(2 downto 1) is
      when "01"   => tmp_v := rs1_reg(rs1_reg'left-1 downto 0) & '0';   -- << 1
      when "10"   => tmp_v := rs1_reg(rs1_reg'left-2 downto 0) & "00";  -- << 2
      when others => tmp_v := rs1_reg(rs1_reg'left-3 downto 0) & "000"; -- << 3
    end case;
    adder_res <= std_ulogic_vector(unsigned(rs2_reg) + unsigned(tmp_v));
  end process shift_adder;


  -- One-Hot Generator ----------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  shift_one_hot: process(sha_reg)
  begin
    one_hot_res <= (others => '0');
    one_hot_res(to_integer(unsigned(sha_reg))) <= '1';
  end process shift_one_hot;


  -- Operation Results ----------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- logic with negate --
  res_int(op_andn_c) <= rs1_reg and (not rs2_reg);
  res_int(op_orn_c)  <= rs1_reg or  (not rs2_reg);
  res_int(op_xnor_c) <= rs1_reg xor (not rs2_reg);

  -- count leading/trailing zeros --
  res_int(op_cz_c)(XLEN-1 downto shifter.cnt'left+1) <= (others => '0');
  res_int(op_cz_c)(shifter.cnt'left downto 0) <= shifter.cnt;

  -- population count --
  res_int(op_cpop_c)(XLEN-1 downto shifter.bcnt'left+1) <= (others => '0');
  res_int(op_cpop_c)(shifter.bcnt'left downto 0) <= shifter.bcnt;

  -- min/max select --
  res_int(op_max_c) <= rs1_reg when ((less_reg xor ctrl_i.ir_funct3(1)) = '1') else rs2_reg;

  -- sign-extension --
  res_int(op_sext_c)(XLEN-1 downto 16) <= (others => rs1_reg(15)) when (ctrl_i.ir_funct12(0) = '1') else (others => rs1_reg(7));
  res_int(op_sext_c)(15 downto 8)      <= rs1_reg(15 downto 8)    when (ctrl_i.ir_funct12(0) = '1') else (others => rs1_reg(7));
  res_int(op_sext_c)(7 downto 0)       <= rs1_reg(7 downto 0);

  -- zero-extension --
  res_int(op_zexth_c)(XLEN-1 downto 16) <= (others => '0');
  res_int(op_zexth_c)(15 downto 0)      <= rs1_reg(15 downto 0);

  -- rotate right/left --
  res_int(op_rot_c) <= shifter.sreg;

  -- or-combine.byte --
  or_combine_gen:
  for i in 0 to (XLEN/8)-1 generate -- byte loop
    res_int(op_orcb_c)(i*8+7 downto i*8) <= (others => or_reduce_f(rs1_reg(i*8+7 downto i*8)));
  end generate; -- i

  -- reversal.8 (byte swap) --
  res_int(op_rev8_c) <= bswap_f(rs1_reg);

  -- address generation instructions --
  res_int(op_shadd_c) <= adder_res;

  -- single-bit instructions --
  res_int(op_bclr_c) <= rs1_reg and (not one_hot_res);
  res_int(op_bext_c)(XLEN-1 downto 1) <= (others => '0');
  res_int(op_bext_c)(0) <= '1' when (or_reduce_f(rs1_reg and one_hot_res) = '1') else '0';
  res_int(op_binv_c) <= rs1_reg xor one_hot_res;
  res_int(op_bset_c) <= rs1_reg or one_hot_res;


  -- Output Select --------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  res_out(op_andn_c)  <= res_int(op_andn_c)  when (cmd(op_andn_c)  = '1') else (others => '0');
  res_out(op_orn_c)   <= res_int(op_orn_c)   when (cmd(op_orn_c)   = '1') else (others => '0');
  res_out(op_xnor_c)  <= res_int(op_xnor_c)  when (cmd(op_xnor_c)  = '1') else (others => '0');
  res_out(op_cz_c)    <= res_int(op_cz_c)    when (cmd(op_cz_c)    = '1') else (others => '0');
  res_out(op_cpop_c)  <= res_int(op_cpop_c)  when (cmd(op_cpop_c)  = '1') else (others => '0');
  res_out(op_max_c)   <= res_int(op_max_c)   when (cmd(op_max_c)   = '1') else (others => '0');
  res_out(op_sext_c)  <= res_int(op_sext_c)  when (cmd(op_sext_c)  = '1') else (others => '0');
  res_out(op_zexth_c) <= res_int(op_zexth_c) when (cmd(op_zexth_c) = '1') else (others => '0');
  res_out(op_rot_c)   <= res_int(op_rot_c)   when (cmd(op_rot_c)   = '1') else (others => '0');
  res_out(op_orcb_c)  <= res_int(op_orcb_c)  when (cmd(op_orcb_c)  = '1') else (others => '0');
  res_out(op_rev8_c)  <= res_int(op_rev8_c)  when (cmd(op_rev8_c)  = '1') else (others => '0');
  res_out(op_shadd_c) <= res_int(op_shadd_c) when (cmd(op_shadd_c) = '1') else (others => '0');
  res_out(op_bclr_c)  <= res_int(op_bclr_c)  when (cmd(op_bclr_c)  = '1') else (others => '0');
  res_out(op_bext_c)  <= res_int(op_bext_c)  when (cmd(op_bext_c)  = '1') else (others => '0');
  res_out(op_binv_c)  <= res_int(op_binv_c)  when (cmd(op_binv_c)  = '1') else (others => '0');
  res_out(op_bset_c)  <= res_int(op_bset_c)  when (cmd(op_bset_c)  = '1') else (others => '0');


  -- Output Gate ----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  output_gate: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      res_o <= (others => '0');
    elsif rising_edge(clk_i) then
      res_o <= (others => '0'); -- default
      if (valid = '1') then
        res_o <= res_out(op_andn_c) or res_out(op_orn_c)  or res_out(op_xnor_c) or res_out(op_cz_c)    or
                 res_out(op_cpop_c) or res_out(op_max_c)  or res_out(op_sext_c) or res_out(op_zexth_c) or
                 res_out(op_rot_c)  or res_out(op_orcb_c) or res_out(op_rev8_c) or res_out(op_shadd_c) or
                 res_out(op_bclr_c) or res_out(op_bext_c) or res_out(op_binv_c) or res_out(op_bset_c);
      end if;
    end if;
  end process output_gate;

  -- valid output --
  valid_o <= valid;


end neorv32_cpu_cp_bitmanip_rtl;
