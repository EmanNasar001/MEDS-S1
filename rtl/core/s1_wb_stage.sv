// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author(s)    : Eman Nasar (fatehulnasareman@gmail.com) (Sep 2026)
// Modified By  :
//
// s1_wb_stage : WB stage -- completion arbitration and bypass       [WIP -- T-02]
// Description  :
// Stage five.  Every result the core produces reaches the completion buffer
// through here: the main pipe's over MEM/WB, and the multi-cycle units' over
// their own channels.  WB picks one per cycle, writes the entry it names, and
// puts the value on the forwarding bus.
// Contract, arbitration rules and timing: docs/modules/s1_wb_stage.md.
//
// Reference: SPEC 6, 7.5, 8.1, 8.2, 9.1, 9.2, 28.2; INTERFACES.md 1.4a.
// Testbench: verif/unit/tb_s1_wb_stage.sv.
// =============================================================================

module s1_wb_stage
  import s1_pkg::*;
#(
  parameter int unsigned N_UC   = 2,    // multi-cycle completion channels (MUL, DIV)
  localparam int unsigned RR_W  = (N_UC > 1) ? $clog2(N_UC) : 1
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // Retire flush only -- never the EX mispredict (see module page).
  input  logic                  flush_i,

  // MEM/WB.  No ready: the entry was allocated in ID, so WB cannot refuse.
  input  logic                  wb_valid_i,
  input  mem_wb_t               wb_i,

  // Multi-cycle units.  These have a ready; the main pipe does not.
  input  logic [N_UC-1:0]       uc_valid_i,
  output logic [N_UC-1:0]       uc_ready_o,
  input  md_rsp_t [N_UC-1:0]    uc_i,

  // Completion buffer write port.  `cb_upd_o` is meaningful only with `cb_we_o`.
  output logic                  cb_we_o,
  output logic [CB_IDX_W-1:0]   cb_idx_o,
  output wb_upd_t               cb_upd_o,

  // SPEC 8.1's MEM/WB forwarding source, value only: the match is made against
  // the EX/MEM register a cycle earlier, not here (see module page).
  output logic [XLEN-1:0]       fwd_data_o,

  // Perf (SPEC 12): a multi-cycle result was held off by a busier channel.
  output logic                  uc_stall_o
);

  if (N_UC < 1) begin : g_bad_nuc
    $error("s1_wb_stage: N_UC must be at least 1; tie uc_valid_i[0] low if unused");
  end

  // An un-offloaded MXIF candidate is the MXIF port's entry, not WB's, so WB
  // leaves it alone unless it trapped on the way down (INTERFACES.md 1.4a).
  logic resolved, main_takes;

  assign resolved   = wb_i.complete | wb_i.exc;
  assign main_takes = wb_valid_i & resolved & ~flush_i;

  // The grant rotates: fixed priority would starve DIV behind MUL.
  logic [N_UC-1:0]  uc_req, uc_gnt;
  logic [RR_W-1:0]  rr_q, rr_d;
  logic             uc_port_free, uc_go;

  assign uc_req = uc_valid_i;

  assign uc_port_free = ~main_takes & ~flush_i;

  // Compared against the rank rather than indexed by it, so no signal takes a
  // variable index.
  always_comb begin
    uc_gnt = '0;
    for (int unsigned i = 0; i < N_UC; i++)
      for (int unsigned k = 0; k < N_UC; k++)
        if ((k == ((32'(rr_q) + i) % N_UC)) && uc_req[k] && (uc_gnt == '0))
          uc_gnt[k] = 1'b1;
  end

  assign uc_go = uc_port_free & (uc_gnt != '0);

  always_comb begin
    rr_d = rr_q;
    for (int unsigned k = 0; k < N_UC; k++)
      if (uc_gnt[k]) rr_d = RR_W'((k + 1) % N_UC);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)     rr_q <= '0;
    else if (uc_go)  rr_q <= rr_d;
  end

  // A flush drains every channel, so no unit is left holding a result for an
  // entry that no longer exists.
  always_comb begin
    for (int unsigned k = 0; k < N_UC; k++)
      uc_ready_o[k] = flush_i | (uc_port_free & uc_gnt[k]);
  end

  // Any channel that wanted the port and did not get it.  A flush drains, so it
  // is not a stall.
  assign uc_stall_o = ~flush_i & ((uc_req & ~(uc_go ? uc_gnt : {N_UC{1'b0}})) != '0);

  // The granted channel's payload.
  md_rsp_t uc_sel;
  always_comb begin
    uc_sel = '0;
    for (int unsigned k = 0; k < N_UC; k++)
      if (uc_gnt[k]) uc_sel = uc_i[k];
  end

  // A trap writes nothing (SPEC 9.2 step 6).  x0 is dropped here, not at
  // retire, because the forwarding bus is fed from the same signal.
  logic                  wr_reg;
  logic [REG_ADDR_W-1:0] sel_rd;
  logic [XLEN-1:0]       sel_result;

  assign sel_rd     = main_takes ? wb_i.rd     : uc_sel.rd;
  assign sel_result = main_takes ? wb_i.result : uc_sel.result;

  always_comb begin
    if      (main_takes) wr_reg = wb_i.rd_we & ~wb_i.exc & (wb_i.rd != '0);
    // RV64M cannot trap, so x0 is a unit result's only reason not to write.
    // The uc_go term matters: uc_gnt ignores who holds the port, so without it
    // the forwarding bus would show a unit's value while cb_we_o was low.
    else if (uc_go)      wr_reg = (uc_sel.rd != '0);
    else                 wr_reg = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // Completion buffer write port
  // ---------------------------------------------------------------------------
  assign cb_we_o  = main_takes | uc_go;
  assign cb_idx_o = main_takes ? wb_i.cb_idx : uc_sel.cb_idx;

  always_comb begin
    cb_upd_o            = '0;              // R-C3: no field becomes a latch

    // Constant because cb_we_o only fires for a resolved completion, and
    // neither producer can fault afterwards (SPEC 9.1).
    cb_upd_o.done       = 1'b1;
    cb_upd_o.norollback = 1'b1;
    cb_upd_o.from_main  = main_takes;

    cb_upd_o.rd         = wr_reg ? sel_rd     : '0;
    cb_upd_o.rd_we      = wr_reg;
    cb_upd_o.result     = wr_reg ? sel_result : '0;

    // Below belongs to the instruction, not its result, and only the main pipe
    // carries it.  from_main tells the buffer to keep what it already has.
    if (main_takes) begin
      cb_upd_o.next_pc    = wb_i.next_pc;

      cb_upd_o.exc        = wb_i.exc;
      cb_upd_o.exccode    = wb_i.exccode;
      cb_upd_o.exctval    = wb_i.exctval;

      // Suppressed by a trap, for the same reason as the register write.
      cb_upd_o.csr.we     = wb_i.csr_we & ~wb_i.exc;
      cb_upd_o.csr.addr   = wb_i.csr_addr;
      cb_upd_o.csr.wdata  = wb_i.csr_wdata;

      // Ungated on purpose: gating it would strand the slot for ever, and MEM
      // never allocates one for an access that faulted.
      cb_upd_o.sb_alloc   = wb_i.sb_alloc;

      cb_upd_o.rvfi.addr  = wb_i.mem_addr;
      cb_upd_o.rvfi.rmask = wb_i.mem_rmask;
      cb_upd_o.rvfi.wmask = wb_i.mem_wmask;
      cb_upd_o.rvfi.rdata = wb_i.mem_rdata;
      cb_upd_o.rvfi.wdata = wb_i.mem_wdata;
    end
  end

  // No match output: ID picks the source a cycle before this bus carries the
  // value, so a match computed here would be one instruction stale.  Already
  // gated, so a trap, no destination or x0 all read as zero.  Module page has
  // the cycle diagram.
  assign fwd_data_o = cb_upd_o.result;

endmodule
