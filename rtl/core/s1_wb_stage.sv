// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// s1_wb_stage : WB stage -- completion-buffer write port and bypass  [WIP -- T-02]
// Description  :
// Stage five of the pipeline.  It takes the MEM/WB completion s1_mem_stage
// produces (#18) and does the two things SPEC 7.5 leaves at WB once 7.5's other
// two bullets are read against 6 and 9.2: it writes the completion buffer entry
// the instruction owns, and it answers ID's operand reads for the value that
// entry is about to hold.  Architectural state -- the register file, the CSR
// file, the store buffer, RVFI -- is written at the retire pointer, not here.
// Contract and the reading of SPEC 7.5: docs/modules/s1_wb_stage.md.
//
// Purely combinational, like s1_alu: MEM owns the MEM/WB register, the
// completion buffer owns the register the update lands in, and putting a third
// one between them would cost a forwarding bubble for nothing.
//
// Reference: SPEC 6, 7.5, 8.1, 9.1, 9.2, 28.2; INTERFACES.md 1.4a.
// Testbench: verif/unit/tb_s1_wb_stage.sv.
// =============================================================================

module s1_wb_stage
  import s1_pkg::*;
#(
  parameter int unsigned N_READ = 2     // ID operand read ports the bypass answers
) (
  input  logic                  flush_i,      // retire flush

  // MEM/WB.  No ready: the entry was allocated in ID, so WB cannot refuse.
  input  logic                  wb_valid_i,
  input  mem_wb_t               wb_i,

  // Completion buffer write port.  `cb_upd_o` is meaningful only with `cb_we_o`.
  output logic                  cb_we_o,
  output logic [CB_IDX_W-1:0]   cb_idx_o,
  output wb_upd_t               cb_upd_o,

  // Forwarding to ID -- the MEM/WB source of SPEC 8.1's operand mux.  The
  // compare lives here, with the value, so ID's operand mux stays a mux.
  input  logic [REG_ADDR_W-1:0] fwd_raddr_i [N_READ],
  output logic                  fwd_hit_o   [N_READ],
  output logic [XLEN-1:0]       fwd_data_o
);

  if (N_READ < 1) begin : g_bad_nread
    $error("s1_wb_stage: N_READ must be at least 1");
  end

  // ---------------------------------------------------------------------------
  // Has the main pipe finished with this instruction?
  //
  // An MXIF candidate travels the main pipe as a placeholder.  It carries
  // `complete = 0` and the MXIF port, not WB, marks its entry done and clears
  // its rollback once the coprocessor answers (INTERFACES.md 1.4a).  WB must
  // therefore leave that entry alone entirely: the rd and rd_we the decoder put
  // in it at ID are the live copy, and writing this placeholder's fields over
  // them would lose the register the coprocessor is going to write.
  //
  // The one exception is a candidate that trapped before it was ever offered to
  // a coprocessor -- a fetch or address fault carried down from IF or EX.  It
  // will never be offloaded, so it is resolved here like anything else.
  // ---------------------------------------------------------------------------
  logic resolved;
  logic wr_reg;

  assign resolved = wb_i.complete | wb_i.exc;

  // A trapping instruction writes nothing: SPEC 9.2 step 6 skips steps 1-3.
  //
  // x0 is dropped here rather than at retire because the bypass is fed from the
  // same signal.  Retire writing x0 is harmless -- the register file discards
  // it -- but a bypass that answers with it turns `addi x0, x1, 1` into a
  // corrupted operand for the next reader of x0, and that reader is entitled to
  // zero.  One gate, at the only place that can get it wrong.
  assign wr_reg = wb_i.rd_we & ~wb_i.exc & (wb_i.rd != '0);

  // ---------------------------------------------------------------------------
  // Completion buffer write port
  // ---------------------------------------------------------------------------
  assign cb_we_o  = wb_valid_i & resolved & ~flush_i;
  assign cb_idx_o = wb_i.cb_idx;

  always_comb begin
    // Default first (R-C3): every field below is assigned on every path, but
    // the struct is wide and a field added to wb_upd_t later must not become a
    // latch because someone missed a line here.
    cb_upd_o            = '0;

    // Both constants, and both true by construction rather than by choice:
    // `cb_we_o` is asserted only for an instruction the main pipe has resolved,
    // and a resolved main-pipe instruction cannot fault again (SPEC 9.1).
    cb_upd_o.done       = 1'b1;
    cb_upd_o.norollback = 1'b1;

    cb_upd_o.rd         = wr_reg ? wb_i.rd     : '0;
    cb_upd_o.rd_we      = wr_reg;
    cb_upd_o.result     = wr_reg ? wb_i.result : '0;
    cb_upd_o.next_pc    = wb_i.next_pc;

    cb_upd_o.exc        = wb_i.exc;
    cb_upd_o.exccode    = wb_i.exccode;
    cb_upd_o.exctval    = wb_i.exctval;

    // Suppressed for the same reason as the register write, and by the same
    // rule.  A CSR write that survived its instruction's trap would be visible
    // architectural state from an instruction that never executed.
    cb_upd_o.csr.we     = wb_i.csr_we & ~wb_i.exc;
    cb_upd_o.csr.addr   = wb_i.csr_addr;
    cb_upd_o.csr.wdata  = wb_i.csr_wdata;

    // Passed through unchanged, deliberately.  MEM allocates a store-buffer
    // entry only for an access that already passed every check, so `sb_alloc`
    // and `exc` are mutually exclusive at the source.  Gating it here as well
    // would look defensive but would strand the entry: allocated in MEM, never
    // committed at retire, never drained, and the buffer one slot smaller for
    // the rest of time.  If the two are ever seen together the bug is upstream.
    cb_upd_o.sb_alloc   = wb_i.sb_alloc;

    cb_upd_o.rvfi.addr  = wb_i.mem_addr;
    cb_upd_o.rvfi.rmask = wb_i.mem_rmask;
    cb_upd_o.rvfi.wmask = wb_i.mem_wmask;
    cb_upd_o.rvfi.rdata = wb_i.mem_rdata;
    cb_upd_o.rvfi.wdata = wb_i.mem_wdata;
  end

  // ---------------------------------------------------------------------------
  // Bypass to ID
  //
  // This covers exactly one cycle.  The entry is written at the end of this
  // cycle, so from the next one the completion buffer's own bypass (SPEC 8.1's
  // fourth source) answers for it; until then nothing else can, because the
  // value exists only on this port.  Without it every consumer of a load or a
  // multi-cycle result would stall one cycle for a value already in hand.
  // ---------------------------------------------------------------------------
  logic fwd_valid;

  assign fwd_valid  = cb_we_o & wr_reg;
  assign fwd_data_o = cb_upd_o.result;

  always_comb begin
    for (int unsigned k = 0; k < N_READ; k++) begin
      // `fwd_valid` already excludes x0, so a read of x0 cannot match and ID
      // keeps the register file's hard zero.
      fwd_hit_o[k] = fwd_valid & (fwd_raddr_i[k] == wb_i.rd);
    end
  end

endmodule
