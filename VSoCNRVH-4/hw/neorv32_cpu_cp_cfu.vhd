-- ================================================================================ --
-- NEORV32 CPU - Co-Processor: Custom (RISC-V Instructions) Functions Unit (CFU)    --
-- -------------------------------------------------------------------------------- --
-- For custom/user-defined RISC-V instructions See the  CPU's documentation for     --
-- more information. Also take a look at the "software-counterpart" this default    --
-- CFU hardware in 'sw/example/demo_cfu'.                                           --
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

entity neorv32_cpu_cp_cfu is
  port (
    -- global control --
    clk_i       : in  std_ulogic; -- global clock, rising edge
    rstn_i      : in  std_ulogic; -- global reset, low-active, async
    -- operation control --
    start_i     : in std_ulogic; -- operation trigger/strobe
    active_i    : in std_ulogic; -- operation in progress, CPU is waiting for CFU
    -- CSR interface --
    csr_we_i    : in  std_ulogic; -- write enable
    csr_addr_i  : in  std_ulogic_vector(1 downto 0); -- address
    csr_wdata_i : in  std_ulogic_vector(31 downto 0); -- write data
    csr_rdata_o : out std_ulogic_vector(31 downto 0) := (others => '0'); -- read data
    -- operands --
    rtype_i     : in std_ulogic; -- instruction type (R3-type or R4-type)
    funct3_i    : in std_ulogic_vector(2 downto 0); -- "funct3" bit-field from custom instruction word
    funct7_i    : in std_ulogic_vector(6 downto 0); -- "funct7" bit-field from custom instruction word
    rs1_i       : in  std_ulogic_vector(31 downto 0); -- rf source 1
    rs2_i       : in  std_ulogic_vector(31 downto 0); -- rf source 2
    rs3_i       : in  std_ulogic_vector(31 downto 0); -- rf source 3
    -- result and status --
    result_o    : out std_ulogic_vector(31 downto 0) := (others => '0'); -- operation result
    valid_o     : out std_ulogic := '0' -- result valid, operation done; set one cycle before result_o is valid
  );
end neorv32_cpu_cp_cfu;


  -- **************************************************************************************************************************
  -- CFU Interface Documentation
  -- **************************************************************************************************************************

  -- ----------------------------------------------------------------------------------------
  -- Input Operands
  -- ----------------------------------------------------------------------------------------
  -- > rtype_i  (input,  2-bit): instruction R-type; driven by the instruction word's OPCODE bit 5
  -- > funct3_i (input,  3-bit): 3-bit function select / immediate value; driven by instruction word's <funct3> bit-field
  -- > funct7_i (input,  7-bit): 7-bit function select / immediate value; driven by instruction word's <funct7> bit-field, r3-type only
  --
  -- > rs1_i    (input, 32-bit): source register 1; selected by instruction word's <rs1> bit-field
  -- > rs2_i    (input, 32-bit): source register 2; selected by instruction word's <rs2> bit-field
  -- > rs3_i    (input, 32-bit): source register 3; selected by instruction word's <rs3> bit-field, r4-type only
  --
  -- [NOTE] All input operands/signals remain stable during CFU operation.
  --
  -- The general instruction type is identified by the <rtype_i> input.
  -- r3type_c (= 0): R3-type instructions (custom-0 opcode); 'rs1', 'rs2' and 'funct7' and 'funct3'
  -- r4type_c (= 1): R4-type instructions (custom-1 opcode); 'rs1', 'rs2', 'rs3' and 'funct3'
  --
  -- The signals <rs1_i>, <rs2_i> and <rs3_i> provide the actual source operand data read from the CPU's register
  -- file. These register operands are adressed by the custom instruction word's 'rs1', 'rs2' and 'rs3' bit-fields.
  --
  -- [NOTE] The R4-type instructions provide an additional source register (rs3). When this input source is actually used,
  --        the hardware requirements of the register file will increase by +50% due to the additional read port.
  --
  -- The actual CFU operation can be defined by using the <funct3_i> and/or <funct7_i> signals (depending on the R-type).
  -- Both signals are driven by the according bit-fields of the custom instruction word. These immediates can be used to
  -- select the actual function or to provide small literals for certain operations (like shift amounts, offsets, ...).

  -- ----------------------------------------------------------------------------------------
  -- Operation Control, Result and Status
  -- ----------------------------------------------------------------------------------------
  -- > start_i  (input,   1-bit): operation trigger (start processing, high for one cycle)
  -- > active_i (input,   1-bit): operation in progress while (optional signal)
  --
  -- > result_o (output, 32-bit): processing result
  -- > valid_o  (output,  1-bit): set high when processing is done
  --
  -- The start of a new CFU operation is indicated by <start_i> being high for exactly one cycle. The CFU may operate while
  -- <active_i> is high and should terminate (and reset) all internal operations when it clears again. However, using
  -- <active_i> is optional. When the CFU has completed processing, the data returned via <result_o> will be written to the
  -- CPU's register file (indexed by the 'rd' bit-field).
  --
  -- [TIP] For complex CFU designs it is highly recommended to register <result_o> in order to keep the CPU's critical
  --       path as short as possible.
  --
  -- The <valid_o> signal is used to signal the completion of the CFU operation. For pure-combinatorial instructions
  -- (completing within 1 clock cycle) <valid_o> can be hardwired to 1. If the CFU requires several clock cycles for
  -- completion the <valid_o> signal has to be set exactly ONE CYCLE BEFORE <result_o> is valid.
  --
  -- Example interface timing for a multi-cycle CFU operation:
  -- clk_i    ____/----\____/----\____/----\____/----\____/----\____
  -- start_i  ____/---------\_______________________________________ trigger is high for one cycle
  -- active_i ____/-----------------------------\___________________ cease processing when low
  -- valid_o  ....\___________________/---------\................... set one cycle before output phase, zero during processing
  -- result_o ..................................|DDDDDDDDD|......... don't care ('.') except for output phase ('D')
  --
  -- [NOTE] If the <valid_o> signal is not set within a bound time window (default = 512 cycles; see "monitor_mc_tmo_c"
  --        constant in the main NEORV32 package file) the CFU operation is automatically terminated by the hardware
  --        (clearing <active_i>) and an illegal instruction exception is raised.

  -- ----------------------------------------------------------------------------------------
  -- CFU-Internal Control and Status Registers (CFU-CSRs)
  -- ----------------------------------------------------------------------------------------
  -- > csr_we_i    (input,   1-bit): set to indicate a valid CFU CSR write access, high for one cycle
  -- > csr_addr_i  (input,   2-bit): CSR address
  -- > csr_wdata_i (input,  32-bit): CSR write data
  -- > csr_rdata_i (output, 32-bit): CSR read data
  --
  -- The CFU provides four directly accessible CSR addresses for implementing custom control and status register inside the CFU.
  --  These registers can be used to pass further operands, to check the unit's status or to configure operation modes.
  --
  -- [TIP] If more than four CFU-internal CSRs are required the designer can implement an "indirect access mechanism" based
  --       on just two of the default CSRs: one CSR is used to configure the index while the other is used as an alias to
  --       exchange data with the indexed CFU-internal CSR.


  -- **************************************************************************************************************************
  -- Actual CFU User Logic Example: XTEA - Extended Tiny Encryption Algorithm (replace this with your custom logic)
  -- **************************************************************************************************************************

  -- This CFU example implements the Extended Tiny Encryption Algorithm (XTEA).
  -- The CFU provides 5 custom instructions to accelerate encryption and decryption using dedicated hardware.
  -- Furthermore, 4 CFU-internal control and status registers (CSRs) are implemented for key storage.

  -- The RTL code is not optimized at all (not for area, not for clock speed, not for performance) and was
  -- implemented according to an open-source software C reference:
  -- https://de.wikipedia.org/wiki/Extended_Tiny_Encryption_Algorithm

architecture neorv32_cpu_cp_cfu_rtl of neorv32_cpu_cp_cfu is

  -- CFU instruction type formats --
  constant r3type_c : std_ulogic := '0'; -- R3-type CFU instructions (custom-0 opcode)
  constant r4type_c : std_ulogic := '1'; -- R4-type CFU instructions (custom-1 opcode)

  -- instruction identifiers (funct3 bit-field) --
  constant xtea_enc_v0_c : std_ulogic_vector(2 downto 0) := "000";
  constant xtea_enc_v1_c : std_ulogic_vector(2 downto 0) := "001";
  constant xtea_dec_v0_c : std_ulogic_vector(2 downto 0) := "010";
  constant xtea_dec_v1_c : std_ulogic_vector(2 downto 0) := "011";
  constant xtea_init_c   : std_ulogic_vector(2 downto 0) := "100";

  -- round-key update --
  constant xtea_delta_c : std_ulogic_vector(31 downto 0) := x"9e3779b9";

  -- key storage (accessed via CFU CSRs) --
  type key_mem_t is array (0 to 3) of std_ulogic_vector(31 downto 0);
  signal key_mem : key_mem_t;

  -- processing logic --
  type xtea_t is record
    done : std_ulogic; -- multi-cycle done shift register
    opa  : std_ulogic_vector(31 downto 0); -- input operand a
    opb  : std_ulogic_vector(31 downto 0); -- input operand b
    sum  : std_ulogic_vector(31 downto 0); -- round key buffer
    res  : std_ulogic_vector(31 downto 0); -- operation results
  end record;
  signal xtea : xtea_t;

  -- helpers --
  signal tmp_a, tmp_b, tmp_x, tmp_y, tmp_z, tmp_r : std_ulogic_vector(31 downto 0);

begin

  -- CFU-Internal Control and Status Registers (CFU-CSRs): 128-Bit Key Storage --------------
  -- -------------------------------------------------------------------------------------------
  -- synchronous write access --
  csr_write_access: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      key_mem <= (others => (others => '0'));
    elsif rising_edge(clk_i) then
      if (csr_we_i = '1') then -- CSR write enable
        key_mem(to_integer(unsigned(csr_addr_i))) <= csr_wdata_i; -- write to CSR address
      end if;
    end if;
  end process csr_write_access;

  -- asynchronous read access --
  csr_rdata_o <= key_mem(to_integer(unsigned(csr_addr_i)));


  -- XTEA Processing Core ------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  xtea_core: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      xtea.done <= '0';
      xtea.opa  <= (others => '0');
      xtea.opb  <= (others => '0');
      xtea.sum  <= (others => '0');
      xtea.res  <= (others => '0');
    elsif rising_edge(clk_i) then

      -- trigger new operation --
      xtea.done <= '0'; -- default
      if (start_i = '1') and (rtype_i = r3type_c) then -- execution trigger and correct instruction type
        xtea.opa  <= rs1_i; -- buffer input operand rs1 (for improved physical timing)
        xtea.opb  <= rs2_i; -- buffer input operand rs2 (for improved physical timing)
        xtea.done <= '1'; -- result is available in the 2nd cycle
      end if;

      -- data processing --
      if (xtea.done = '1') then -- second-stage execution trigger
        -- update "sum" round key --
        if (funct3_i(2) = '1') then -- initialize
          xtea.sum <= xtea.opa; -- set initial round key
        elsif (funct3_i(1 downto 0) = xtea_enc_v0_c(1 downto 0)) then -- encrypt v0
          xtea.sum <= std_ulogic_vector(unsigned(xtea.sum) + unsigned(xtea_delta_c));
        elsif (funct3_i(1 downto 0) = xtea_dec_v1_c(1 downto 0)) then -- decrypt v1
          xtea.sum <= std_ulogic_vector(unsigned(xtea.sum) - unsigned(xtea_delta_c));
        end if;
        -- process "v" operands --
        if (funct3_i(1) = '0') then -- encrypt
          xtea.res <= std_ulogic_vector(unsigned(tmp_b) + unsigned(tmp_r));
        else -- decrypt
          xtea.res <= std_ulogic_vector(unsigned(tmp_b) - unsigned(tmp_r));
        end if;
      end if;

    end if;
  end process xtea_core;

  -- helpers --
  tmp_a <= xtea.opb when (funct3_i(0) = '0') else xtea.opa; -- v1 / v0 select
  tmp_b <= xtea.opa when (funct3_i(0) = '0') else xtea.opb; -- v0 / v1 select
  tmp_x <= xtea.opb(27 downto 0) & "0000"  when (funct3_i(0) = '0') else xtea.opa(27 downto 0) & "0000";  -- v << 4
  tmp_y <= "00000" & xtea.opb(31 downto 5) when (funct3_i(0) = '0') else "00000" & xtea.opa(31 downto 5); -- v >> 5
  tmp_z <= key_mem(to_integer(unsigned(xtea.sum(1 downto 0)))) when (funct3_i(0) = '0') else -- key[sum & 3]
           key_mem(to_integer(unsigned(xtea.sum(12 downto 11)))); -- key[(sum >> 11) & 3]
  tmp_r <= std_ulogic_vector(unsigned(tmp_x xor tmp_y) + unsigned(tmp_a)) xor std_ulogic_vector(unsigned(xtea.sum) + unsigned(tmp_z));


  -- Function Result Select -----------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  result_select: process(rtype_i, funct3_i, xtea)
  begin
    if (rtype_i = r3type_c) then -- R3-type instructions; function select via "funct3" and ""funct7
    -- ----------------------------------------------------------------------
      case funct3_i is -- just check "funct3" here; "funct7" bit-field is ignored in this example
        when xtea_enc_v0_c | xtea_enc_v1_c | xtea_dec_v0_c | xtea_dec_v1_c => -- xtea encryption/decryption
          result_o <= xtea.res; -- processing result
          valid_o  <= xtea.done; -- multi-cycle processing done when set
        when xtea_init_c => -- xtea initialization
          result_o <= (others => '0'); -- just output zero
          valid_o  <= '1'; -- pure-combinatorial, so we are done "immediately"
        when others => -- all unspecified operations
          result_o <= (others => '0'); -- no logic implemented
          valid_o  <= '0'; -- this will cause an illegal instruction exception after timeout
      end case;

    else -- R4-type instructions; function select via "funct3" (but ignored here)
    -- ----------------------------------------------------------------------
      result_o <= (others => '0'); -- no logic implemented
      valid_o  <= '0'; -- this will cause an illegal instruction exception after timeout

    end if;
  end process result_select;


end neorv32_cpu_cp_cfu_rtl;
