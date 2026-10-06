// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author(s)    : Eman Nasar (fatehulnasareman@gmail.com) (Oct 2026)
// Modified By  :
//
// s1_pmp : physical memory protection check                        [WIP -- R-02]
// Description  :
// One access in, one allow/deny out.  The lowest-numbered matching entry
// decides and must cover every byte of the access; with no match, M-mode passes
// and S/U fail.  Purely combinational, so a caller can place it beside its own
// address generation -- the data path uses it in MEM, the fetch path on the
// instruction address.
// Contract: docs/modules/s1_pmp.md.
//
// Reference: privileged spec 3.7; SPEC 11.  Testbench: verif/unit/tb_s1_pmp.sv.
// =============================================================================

module s1_pmp
  import s1_pkg::*;
#(
  parameter int unsigned REGIONS = PMP_N,
  localparam int unsigned PMP_W  = (REGIONS > 0) ? REGIONS : 1,
  localparam int unsigned PA_W   = PLEN - 2,       // pmpaddr CSR width
  localparam int unsigned CMP_W  = XLEN + 2        // bounds may exceed 2**XLEN
) (
  // The access.  `size_i` is log2 bytes, so the access covers
  // [addr_i, addr_i + 2**size_i).
  input  logic [XLEN-1:0]            addr_i,
  input  logic [2:0]                 size_i,
  input  logic                       rd_i,         // needs R
  input  logic                       wr_i,         // needs W
  input  logic                       ex_i,         // needs X -- the fetch path
  input  priv_lvl_e                  priv_i,       // effective mode, after MPRV

  // The CSRs, as the CSR file holds them.  WARL legalisation -- granularity and
  // locked-entry writes -- is the CSR file's job, not this module's.
  input  logic [PMP_W-1:0][7:0]      pmpcfg_i,
  input  logic [PMP_W-1:0][PA_W-1:0] pmpaddr_i,

  output logic                       allow_o
);

  if (REGIONS > 64) begin : g_bad_regions
    $error("s1_pmp: REGIONS must not exceed 64");
  end

  // A core built without PMP restricts nothing.  Written as a separate branch
  // rather than a zero-trip loop: with REGIONS = 0 the loop bound makes the
  // comparison constant, which is a lint error, and the intent is clearer here.
  if (REGIONS == 0) begin : g_no_pmp
    logic unused;
    always_comb begin
      unused = ^addr_i ^ ^size_i ^ rd_i ^ wr_i ^ ex_i ^ ^priv_i;
      for (int unsigned i = 0; i < PMP_W; i++) unused ^= ^pmpcfg_i[i] ^ ^pmpaddr_i[i];
    end
    assign allow_o = 1'b1;

  end else begin : g_pmp

    // The lowest-numbered entry matching any byte decides, and it must match
    // every byte.  Bounds are compared at XLEN+2 bits so that a NAPOT entry
    // covering the whole address space still has a top above its base.
    always_comb begin
      logic [CMP_W-1:0] a_lo, a_hi, r_lo, r_hi;
      logic [PA_W-1:0]  tmask;
      logic [PA_W:0]    nmask, base_u;
      logic [PA_W+1:0]  top_u;
      logic             hit, any, all;

      a_lo    = CMP_W'(addr_i);
      a_hi    = a_lo + (CMP_W'(1) << size_i);
      // With no entry matching, M-mode is unrestricted and S/U are denied.
      allow_o = (priv_i == PRIV_M);
      hit     = 1'b0;

      for (int unsigned i = 0; i < REGIONS; i++) begin
        r_lo   = '0;
        r_hi   = '0;
        tmask  = '0;
        nmask  = '0;
        base_u = '0;
        top_u  = '0;
        unique case (pmpcfg_i[i][4:3])
          2'b01: begin                                            // TOR
            r_lo = (i == 0) ? '0 : CMP_W'(pmpaddr_i[(i == 0) ? 0 : i - 1]) << 2;
            r_hi = CMP_W'(pmpaddr_i[i]) << 2;
          end
          2'b10: begin                                            // NA4
            r_lo = CMP_W'(pmpaddr_i[i]) << 2;
            r_hi = r_lo + CMP_W'(4);
          end
          2'b11: begin                                            // NAPOT
            tmask  = pmpaddr_i[i] & ~(pmpaddr_i[i] + PA_W'(1));
            nmask  = {tmask, 1'b1};
            base_u = {1'b0, pmpaddr_i[i]} & ~nmask;
            top_u  = {1'b0, ({1'b0, pmpaddr_i[i]} | nmask)} + (PA_W+2)'(1);
            r_lo   = CMP_W'(base_u) << 2;
            r_hi   = CMP_W'(top_u) << 2;
          end
          default: ;                                              // OFF
        endcase

        any = (pmpcfg_i[i][4:3] != 2'b00) && (r_lo < r_hi) && (a_lo < r_hi) && (a_hi > r_lo);
        all = (a_lo >= r_lo) && (a_hi <= r_hi);
        if (!hit && any) begin
          hit     = 1'b1;
          // M-mode is bound only by a locked entry (cfg[7] = L).  Below M,
          // every permission the access needs must be granted.
          allow_o = all && ((priv_i == PRIV_M && !pmpcfg_i[i][7])
                            || ((!rd_i || pmpcfg_i[i][0])
                             && (!wr_i || pmpcfg_i[i][1])
                             && (!ex_i || pmpcfg_i[i][2])));
        end
      end
    end

    // cfg[6:5] are reserved and WARL-zero in the CSR file; they are encoding
    // bits with no behaviour here.
    logic unused_cfg;
    always_comb begin
      unused_cfg = 1'b0;
      for (int unsigned i = 0; i < PMP_W; i++) unused_cfg ^= ^pmpcfg_i[i][6:5];
    end
  end

endmodule
