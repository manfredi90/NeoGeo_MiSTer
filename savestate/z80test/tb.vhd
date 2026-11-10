library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.prog_pkg.all;
entity tb is generic (TCAP : integer := 5000; NEV : integer := 4000; HALTCAP : integer := 0); end tb;
architecture sim of tb is
  type mem_t is array(0 to 65535) of std_logic_vector(7 downto 0);
  signal clk : std_logic := '0';
  signal cyc : integer := 0;
  signal cenp, cenn : std_logic := '0';
  -- A
  signal rstA : std_logic := '0';
  signal AA : std_logic_vector(15 downto 0);
  signal DIA, DOA : std_logic_vector(7 downto 0);
  signal mreqA, iorqA, rdA, wrA, m1A, bndA : std_logic;
  signal intA, nmiA : std_logic := '1';
  signal regA : std_logic_vector(211 downto 0);
  signal extA : std_logic_vector(1 downto 0);
  -- B
  signal rstB : std_logic := '0';
  signal setB : std_logic := '0';
  signal cenpB, cennB : std_logic := '0';
  signal AB : std_logic_vector(15 downto 0);
  signal DIB, DOB : std_logic_vector(7 downto 0);
  signal mreqB, iorqB, rdB, wrB, m1B, bndB : std_logic;
  signal intB, nmiB : std_logic := '1';
  signal regB : std_logic_vector(211 downto 0);
  signal extB : std_logic_vector(1 downto 0);
  signal dirB : std_logic_vector(211 downto 0) := (others => '0');
  signal dextB : std_logic_vector(1 downto 0) := "00";
  signal captured : boolean := false;
  signal bstarted : boolean := false;
  type ev_t is array(0 to NEV-1) of integer;
  shared variable memA, memB : mem_t;
  shared variable evA, evB : ev_t;
  shared variable neA, neB : integer := 0;
begin
  clk <= not clk after 5 ns;

  ua: entity work.T80pa port map(RESET_n=>rstA, CLK=>clk, CEN_p=>cenp, CEN_n=>cenn, WAIT_n=>'1', INT_n=>intA, NMI_n=>nmiA,
      BUSRQ_n=>'1', M1_n=>m1A, MREQ_n=>mreqA, IORQ_n=>iorqA, RD_n=>rdA, WR_n=>wrA, A=>AA, DI=>DIA, DO=>DOA,
      REG=>regA, REG_EXT=>extA, BOUNDARY=>bndA);
  ub: entity work.T80pa port map(RESET_n=>rstB, CLK=>clk, CEN_p=>cenpB, CEN_n=>cennB, WAIT_n=>'1', INT_n=>intB, NMI_n=>nmiB,
      BUSRQ_n=>'1', M1_n=>m1B, MREQ_n=>mreqB, IORQ_n=>iorqB, RD_n=>rdB, WR_n=>wrB, A=>AB, DI=>DIB, DO=>DOB,
      REG=>regB, REG_EXT=>extB, BOUNDARY=>bndB, DIRSet=>setB, DIR=>dirB, DIR_EXT=>dextB);

  DIA <= memA(to_integer(unsigned(AA))) when iorqA='1' else x"FF" when m1A='0' else std_logic_vector(unsigned(AA(7 downto 0)) + 3);
  DIB <= memB(to_integer(unsigned(AB))) when iorqB='1' else x"FF" when m1B='0' else std_logic_vector(unsigned(AB(7 downto 0)) + 3);

  process(clk)
    variable bcA, bcB : integer := 0;
    variable bndA_d, bndB_d : std_logic := '0';
    variable irqA, irqB : boolean := false;
    variable wrA_d, wrB_d : std_logic := '1';
    variable bseq : integer := 0;
    variable pend : boolean := false;
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      cenp <= '1' when cyc mod 4 = 0 else '0';
      cenn <= '1' when cyc mod 4 = 2 else '0';
      if cyc = 1 then
        for i in 0 to 65535 loop memA(i) := x"00"; end loop;
        for i in PROG'range loop memA(i) := std_logic_vector(to_unsigned(PROG(i),8)); end loop;
      end if;
      if cyc = 20 then rstA <= '1'; end if;

      -- A memory/io writes
      if wrA = '0' and mreqA = '0' then memA(to_integer(unsigned(AA))) := DOA; end if;
      if wrB = '0' and mreqB = '0' and bstarted then memB(to_integer(unsigned(AB))) := DOB; end if;
      if wrA = '1' and wrA_d = '0' then
        if captured and neA < NEV then evA(neA) := to_integer(unsigned(AA))*256 + to_integer(unsigned(DOA)); if iorqA='0' then evA(neA) := evA(neA) + 65536*256; end if; neA := neA + 1; end if;
      end if;
      wrA_d := wrA;
      if wrB = '1' and wrB_d = '0' then
        if neB < NEV then evB(neB) := to_integer(unsigned(AB))*256 + to_integer(unsigned(DOB)); if iorqB='0' then evB(neB) := evB(neB) + 65536*256; end if; neB := neB + 1; end if;
      end if;
      wrB_d := wrB;

      -- interrupts driven by instruction (boundary) counts
      if false then -- trace of the boundaries (debug)
        report "bnd cyc=" & integer'image(cyc) & " PC=" & to_hstring(regA(79 downto 64)) & " A=" & to_hstring(AA) & " SP=" & to_hstring(regA(63 downto 48)) & " ext=" & to_hstring(extA) & " AF=" & to_hstring(regA(15 downto 0)) & " IFF=" & to_hstring(regA(211 downto 208)) & " irq=" & boolean'image(irqA) & " nmi=" & std_logic'image(nmiA);
      end if;
      if bndA = '1' and bndA_d = '0' then
        if captured then bcA := bcA + 1; else bcA := bcA + 1; end if;
        if bcA mod 53 = 0 then irqA := true; end if;
        if bcA mod 211 = 100 then nmiA <= '0'; else nmiA <= '1'; end if;
      end if;
      bndA_d := bndA;
      if m1A = '0' and iorqA = '0' then irqA := false; end if;
      intA <= '0' when irqA else '1';

      if bstarted then
        if bndB = '1' and bndB_d = '0' then
          bcB := bcB + 1;
          if false then report "B bnd cyc=" & integer'image(cyc) & " PC=" & to_hstring(regB(79 downto 64)) & " SP=" & to_hstring(regB(63 downto 48)) & " AF=" & to_hstring(regB(15 downto 0)) & " irq=" & boolean'image(irqB) & " IFF=" & to_hstring(regB(211 downto 208)); end if;
          if bcB mod 53 = 0 then irqB := true; end if;
          if bcB mod 211 = 100 then nmiB <= '0'; else nmiB <= '1'; end if;
        end if;
        bndB_d := bndB;
        if m1B = '0' and iorqB = '0' then irqB := false; end if;
        intB <= '0' when irqB else '1';
      end if;

      -- capture A at a boundary after TCAP
      if not captured and cyc > TCAP and bndA = '1' and cenp = '0' and (HALTCAP = 0 or extA(0) = '1') then
        captured <= true;
        dirB <= regA; dextB <= extA;
        memB := memA;
        bcB := bcA - 1; irqB := irqA; bndB_d := '1';
        report "capture at cyc " & integer'image(cyc) & " PC=" & integer'image(to_integer(unsigned(regA(79 downto 64)))) & " halt=" & std_logic'image(extA(0)) & " nmi=" & std_logic'image(extA(1)) & " bc=" & integer'image(bcA);
        bseq := 1;
      end if;
      -- B: reset, then DIRSet, then run
      if bseq > 0 and bseq < 100 then
        bseq := bseq + 1;
        if bseq = 5 then rstB <= '1'; setB <= '1'; end if;
        if bseq = 6 then setB <= '0'; end if;
        if bseq = 8 then bstarted <= true; bseq := 100; end if;
      end if;
      if bstarted then
        cenpB <= '1' when cyc mod 4 = 0 else '0';
        cennB <= '1' when cyc mod 4 = 2 else '0';
      end if;

      if neA >= NEV and neB >= NEV then
        for i in 0 to -1 loop
          report "ev " & integer'image(i) & " A=" & to_hstring(std_logic_vector(to_unsigned(evA(i),28))) & " B=" & to_hstring(std_logic_vector(to_unsigned(evB(i),28)));
        end loop;
        for i in 0 to NEV-1 loop
          if evA(i) /= evB(i) then
            report "MISMATCH at event " & integer'image(i) & " A=" & integer'image(evA(i)) & " B=" & integer'image(evB(i)) severity failure;
          end if;
        end loop;
        report "OK " & integer'image(NEV) & " events match" severity failure;
      end if;
    end if;
  end process;
end sim;
