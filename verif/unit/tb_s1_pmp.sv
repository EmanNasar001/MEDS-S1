// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author(s)    : Eman Nasar (fatehulnasareman@gmail.com) (Oct 2026)
// Modified By  :
//
// tb_s1_pmp : unit testbench for s1_pmp                            [WIP -- R-02]
// Description  :
// Drives one access at a time and compares the verdict with a model that
// decides byte by byte.  The model derives a NAPOT range by counting trailing
// ones in pmpaddr; the RTL derives it with mask arithmetic.  Neither shares
// code with the other, which is the point.
//
// Four instances run the same stimulus at REGIONS 0, 1, 4 and 16 (R-V2).
//
// Run:  make test-unit TB=s1_pmp
// =============================================================================

module tb_s1_pmp
  import s1_pkg::*;
;
  localparam int unsigned PA_W = PLEN - 2;
  localparam int unsigned RMAX = 16;

  logic [XLEN-1:0]          addr;
  logic [2:0]               size;
  logic                     rd, wr, ex;
  priv_lvl_e                priv;
  logic [RMAX-1:0][7:0]     cfg;
  logic [RMAX-1:0][PA_W-1:0] adr;

  logic allow0, allow1, allow4, allow16;

  // Each instance sees only the entries it implements.
  logic [0:0][7:0]      cfg0;   logic [0:0][PA_W-1:0]  adr0;   // REGIONS=0 -> PMP_W=1
  logic [0:0][7:0]      cfg1;   logic [0:0][PA_W-1:0]  adr1;
  logic [3:0][7:0]      cfg4;   logic [3:0][PA_W-1:0]  adr4;

  always_comb begin
    cfg0 = cfg[0:0]; adr0 = adr[0:0];
    cfg1 = cfg[0:0]; adr1 = adr[0:0];
    cfg4 = cfg[3:0]; adr4 = adr[3:0];
  end

  s1_pmp #(.REGIONS(0))  dut0  (.addr_i(addr), .size_i(size), .rd_i(rd), .wr_i(wr), .ex_i(ex),
                                .priv_i(priv), .pmpcfg_i(cfg0), .pmpaddr_i(adr0), .allow_o(allow0));
  s1_pmp #(.REGIONS(1))  dut1  (.addr_i(addr), .size_i(size), .rd_i(rd), .wr_i(wr), .ex_i(ex),
                                .priv_i(priv), .pmpcfg_i(cfg1), .pmpaddr_i(adr1), .allow_o(allow1));
  s1_pmp #(.REGIONS(4))  dut4  (.addr_i(addr), .size_i(size), .rd_i(rd), .wr_i(wr), .ex_i(ex),
                                .priv_i(priv), .pmpcfg_i(cfg4), .pmpaddr_i(adr4), .allow_o(allow4));
  s1_pmp #(.REGIONS(16)) dut16 (.addr_i(addr), .size_i(size), .rd_i(rd), .wr_i(wr), .ex_i(ex),
                                .priv_i(priv), .pmpcfg_i(cfg), .pmpaddr_i(adr), .allow_o(allow16));

  int unsigned checks = 0, errors = 0, apps = 0;

  task automatic check(input string name, input logic got, input logic exp);
    checks++;
    if (got !== exp) begin
      errors++;
      if (errors <= 25)
        $display("  FAIL #%0d %-34s got=%0d exp=%0d  addr=0x%016h sz=%0d rwx=%0d%0d%0d %s",
                 apps, name, got, exp, addr, size, rd, wr, ex, priv.name());
    end
  endtask

  // ---------------------------------------------------------------------------
  // The model: decide byte by byte, lowest matching entry wins
  // ---------------------------------------------------------------------------
  function automatic bit model(int nreg);
    logic [127:0] lo, hi, ab;
    int unsigned  n, k;
    bit           any_b, all_b, inr;
    // With no entries implemented nothing is restricted -- the configuration a
    // core without PMP is built with.
    if (nreg == 0) return 1'b1;
    n = 1 << size;
    for (int unsigned i = 0; i < nreg; i++) begin
      lo = '0; hi = '0;
      unique case (cfg[i][4:3])
        2'b00: continue;                                   // OFF
        2'b01: begin                                       // TOR
          lo = (i == 0) ? 128'd0 : 128'(adr[i-1]) * 4;
          hi = 128'(adr[i]) * 4;
        end
        2'b10: begin                                       // NA4
          lo = 128'(adr[i]) * 4;
          hi = lo + 4;
        end
        default: begin                                     // NAPOT
          k = 0;
          while (k < PA_W && adr[i][k]) k++;
          lo = ((128'(adr[i]) >> (k + 1)) << (k + 1)) * 4;
          hi = lo + (128'(1) << (k + 3));
        end
      endcase
      any_b = 1'b0;
      all_b = 1'b1;
      for (int unsigned j = 0; j < n; j++) begin
        ab    = 128'(addr) + j;
        inr   = (ab >= lo) && (ab < hi);
        any_b |= inr;
        all_b &= inr;
      end
      if (any_b)
        return all_b && ((priv == PRIV_M && !cfg[i][7])
                         || ((!rd || cfg[i][0]) && (!wr || cfg[i][1]) && (!ex || cfg[i][2])));
    end
    return (priv == PRIV_M);
  endfunction

  task automatic apply(logic [XLEN-1:0] a, logic [2:0] sz,
                       bit r, bit w, bit x, priv_lvl_e m);
    addr = a; size = sz; rd = r; wr = w; ex = x; priv = m;
    #1;
    apps++;
    check("REGIONS=0",  allow0,  model(0));
    check("REGIONS=1",  allow1,  model(1));
    check("REGIONS=4",  allow4,  model(4));
    check("REGIONS=16", allow16, model(16));
  endtask

  // Sweep every permission request and both privileges at one address/size.
  task automatic sweep(logic [XLEN-1:0] a, logic [2:0] sz);
    for (int p = 0; p < 2; p++)
      for (int c = 0; c < 8; c++)
        apply(a, sz, 1'(c[0]), 1'(c[1]), 1'(c[2]), p ? PRIV_M : PRIV_U);
  endtask

  task automatic clear_map();
    cfg = '0;
    adr = '0;
  endtask

  int cv_m, cv_u, cv_allow, cv_deny, cv_tor, cv_na4, cv_napot, cv_off,
      cv_locked, cv_partial, cv_nomatch, cv_x;

  task automatic cover_sample();
    if (priv == PRIV_M) cv_m++; else cv_u++;
    if (allow16) cv_allow++; else cv_deny++;
    if (ex)      cv_x++;
    for (int unsigned i = 0; i < RMAX; i++) begin
      if (cfg[i][4:3] == 2'b00) cv_off++;
      if (cfg[i][4:3] == 2'b01) cv_tor++;
      if (cfg[i][4:3] == 2'b10) cv_na4++;
      if (cfg[i][4:3] == 2'b11) cv_napot++;
      if (cfg[i][7])            cv_locked++;
    end
  endtask

  localparam logic [XLEN-1:0] BASE = 64'h8000_0000;

  initial begin
    clear_map();
    addr = '0; size = '0; rd = 0; wr = 0; ex = 0; priv = PRIV_M;
    #1;

    $display("[directed] no entries implemented: nothing is restricted");
    for (int sz = 0; sz < 4; sz++) sweep(BASE, 3'(sz));
    check("REGIONS=0 always allows", allow0, 1'b1);

    $display("[directed] all entries OFF: M passes, U fails");
    clear_map();
    apply(BASE, 3'd3, 1'b1, 1'b0, 1'b0, PRIV_M);
    check("OFF: M allowed", allow16, 1'b1);
    apply(BASE, 3'd3, 1'b1, 1'b0, 1'b0, PRIV_U);
    check("OFF: U denied",  allow16, 1'b0);

    $display("[directed] NA4, read-only, unlocked");
    clear_map();
    adr[0] = PA_W'(BASE >> 2); cfg[0] = 8'h11;          // A=NA4, R=1
    sweep(BASE,        3'd0);                            // inside, 1 byte
    sweep(BASE + 4,    3'd0);                            // just outside
    sweep(BASE,        3'd2);                            // 4 bytes: exactly covers
    sweep(BASE,        3'd3);                            // 8 bytes: straddles the top
    sweep(BASE - 2,    3'd2);                            // straddles the bottom

    $display("[directed] TOR, entry 0 so the base is zero");
    clear_map();
    adr[0] = PA_W'((BASE + 'h100) >> 2); cfg[0] = 8'h0B; // A=TOR, R|W
    sweep(BASE,         3'd3);
    sweep(BASE + 'h100, 3'd3);                           // at the top: excluded
    sweep(BASE + 'hF8,  3'd3);                           // last covered doubleword

    $display("[directed] TOR with a lower bound from the entry below");
    clear_map();
    adr[0] = PA_W'((BASE + 'h100) >> 2);
    adr[1] = PA_W'((BASE + 'h200) >> 2); cfg[1] = 8'h09; // A=TOR, R
    sweep(BASE + 'h0F8, 3'd3);                           // below the range
    sweep(BASE + 'h100, 3'd3);                           // first covered
    sweep(BASE + 'h1F8, 3'd3);                           // last covered
    sweep(BASE + 'h200, 3'd3);                           // above

    $display("[directed] NAPOT at every size from 8 bytes to 1 MiB");
    for (int unsigned lg = 3; lg <= 20; lg++) begin
      clear_map();
      adr[0] = PA_W'((BASE >> 2) | ((1 << (lg - 3)) - 1));
      cfg[0] = 8'h1F;                                    // A=NAPOT, R|W|X
      sweep(BASE,                        3'd3);          // first doubleword
      sweep(BASE + XLEN'((1 << lg) - 8), 3'd3);          // last doubleword
      sweep(BASE + XLEN'(1 << lg),       3'd3);          // first outside
      sweep(BASE - 8,                    3'd3);          // last below
    end

    $display("[directed] NAPOT covering the whole space");
    clear_map();
    adr[0] = '1; cfg[0] = 8'h1F;
    sweep(64'h0,                3'd3);
    sweep(64'hFFFF_FFFF_FFFF_F8, 3'd3);
    apply(64'h0, 3'd3, 1'b1, 1'b1, 1'b1, PRIV_U);
    check("whole-space NAPOT allows U", allow16, 1'b1);

    $display("[directed] a locked entry binds M too");
    clear_map();
    adr[0] = PA_W'(BASE >> 2); cfg[0] = 8'h91;           // L | NA4 | R
    apply(BASE, 3'd2, 1'b1, 1'b0, 1'b0, PRIV_M);
    check("locked read allowed for M",  allow16, 1'b1);
    apply(BASE, 3'd2, 1'b0, 1'b1, 1'b0, PRIV_M);
    check("locked write denied for M",  allow16, 1'b0);
    apply(BASE, 3'd2, 1'b0, 1'b0, 1'b1, PRIV_M);
    check("locked execute denied for M", allow16, 1'b0);
    clear_map();
    adr[0] = PA_W'(BASE >> 2); cfg[0] = 8'h11;           // unlocked
    apply(BASE, 3'd2, 1'b0, 1'b1, 1'b0, PRIV_M);
    check("unlocked write allowed for M", allow16, 1'b1);

    $display("[directed] each permission bit on its own");
    for (int unsigned b = 0; b < 3; b++) begin
      clear_map();
      adr[0] = PA_W'(BASE >> 2);
      cfg[0] = 8'h10 | 8'(1 << b);                       // NA4 with one of R/W/X
      apply(BASE, 3'd2, 1'b1, 1'b0, 1'b0, PRIV_U);
      check("R granted only by cfg[0]", allow16, 1'(b == 0));
      apply(BASE, 3'd2, 1'b0, 1'b1, 1'b0, PRIV_U);
      check("W granted only by cfg[1]", allow16, 1'(b == 1));
      apply(BASE, 3'd2, 1'b0, 1'b0, 1'b1, PRIV_U);
      check("X granted only by cfg[2]", allow16, 1'(b == 2));
    end

    $display("[directed] the lowest matching entry decides, not the most permissive");
    clear_map();
    adr[0] = PA_W'(BASE >> 2);             cfg[0] = 8'h10;      // NA4, no permissions
    adr[1] = PA_W'((BASE >> 2) | 7);       cfg[1] = 8'h1F;      // NAPOT 64B, R|W|X
    apply(BASE, 3'd2, 1'b1, 1'b0, 1'b0, PRIV_U);
    check("entry 0 wins and denies", allow16, 1'b0);
    // ... and an entry below the matching one that does not match is skipped.
    clear_map();
    adr[0] = PA_W'((BASE + 'h1000) >> 2);  cfg[0] = 8'h10;      // elsewhere
    adr[1] = PA_W'(BASE >> 2);             cfg[1] = 8'h19;      // NAPOT 8B, R
    apply(BASE, 3'd2, 1'b1, 1'b0, 1'b0, PRIV_U);
    check("non-matching entry skipped", allow16, 1'b1);

    $display("[directed] an access straddling two entries is denied");
    clear_map();
    // A = 10 is NA4, so 0x17 is NA4 with R|W|X.  (0x1F would be A = 11, NAPOT,
    // and with no trailing ones in pmpaddr that is an 8-byte region -- which
    // would cover the whole access and allow it.)
    adr[0] = PA_W'(BASE >> 2);        cfg[0] = 8'h17;           // NA4: 4 bytes
    adr[1] = PA_W'((BASE + 4) >> 2);  cfg[1] = 8'h17;           // the next 4
    apply(BASE, 3'd3, 1'b1, 1'b0, 1'b0, PRIV_U);                // 8 bytes, needs both
    check("partial match denied", allow16, 1'b0);
    cv_partial++;

    $display("[directed] no entry matches");
    clear_map();
    adr[0] = PA_W'((BASE + 'h1000) >> 2); cfg[0] = 8'h1F;
    apply(BASE, 3'd3, 1'b1, 1'b0, 1'b0, PRIV_M);
    check("no match: M allowed", allow16, 1'b1);
    apply(BASE, 3'd3, 1'b1, 1'b0, 1'b0, PRIV_U);
    check("no match: U denied",  allow16, 1'b0);
    cv_nomatch++;

    $display("[random] fuzzed maps against the byte-by-byte model");
    for (int unsigned run = 0; run < 1200; run++) begin
      clear_map();
      for (int unsigned i = 0; i < RMAX; i++) begin
        int unsigned mode, lgn;
        mode = $urandom % 100;
        lgn  = $urandom % 6;
        if (mode < 25) begin
          cfg[i] = 8'($urandom) & 8'h87;                        // OFF, keep L and RWX bits
        end else begin
          adr[i] = PA_W'(((BASE + ($urandom % 'h400)) >> 2) | ((1 << lgn) - 1));
          cfg[i] = (8'($urandom) & 8'h87) | 8'((($urandom % 3) + 1) << 3);
        end
      end
      for (int unsigned k = 0; k < 24; k++) begin
        logic [XLEN-1:0] a;
        logic [2:0]      sz;
        a  = BASE + XLEN'($urandom % 'h480);
        sz = 3'($urandom % 4);
        apply(a, sz, 1'($urandom), 1'($urandom), 1'($urandom),
              ($urandom % 2) ? PRIV_M : PRIV_U);
        cover_sample();
      end
    end

    $display("coverage: M %0d U %0d allow %0d deny %0d  X-requests %0d",
             cv_m, cv_u, cv_allow, cv_deny, cv_x);
    $display("          entries seen: off %0d tor %0d na4 %0d napot %0d locked %0d",
             cv_off, cv_tor, cv_na4, cv_napot, cv_locked);
    check("coverage all hit", 1'(cv_m > 0 && cv_u > 0 && cv_allow > 0 && cv_deny > 0
          && cv_x > 0 && cv_off > 0 && cv_tor > 0 && cv_na4 > 0 && cv_napot > 0
          && cv_locked > 0 && cv_partial > 0 && cv_nomatch > 0), 1'b1);

    if (errors != 0) $fatal(1, "=== FAIL : %0d of %0d checks ===", errors, checks);
    $display("=== PASS : %0d checks ===", checks);
    $finish;
  end
endmodule
