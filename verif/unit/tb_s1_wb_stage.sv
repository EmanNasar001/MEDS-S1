// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// tb_s1_wb_stage : unit testbench for s1_wb_stage                   [WIP -- T-02]
//
// The testbench plays MEM (drives MEM/WB), the completion buffer (checks the
// write port), retire (drives flush_i) and ID (drives the operand read
// addresses and checks the bypass).  Reference models live in
// verif/common/s1_wb_stage_model.svh, and the expected outputs there are built
// from SPEC 9.1 and 9.2 rather than from the DUT's inputs.
//
//   * The control space is exhaustive: all 256 combinations of valid, flush,
//     complete, exc, rd_we, rd==x0, csr_we and sb_alloc, each with independent
//     random payloads.  Everything else is a corner of that space with a name.
//   * The bypass is exhaustive too: every destination against every read
//     address, 32 x 32, on every read port.
//   * Three instances run the same stimulus at N_READ 1, 2 and 3 and must
//     agree, so nothing here depends on the default read-port count (R-V2).
//
// s1_wb_stage is combinational, so there is no clock: a test case is applied,
// allowed to settle, and checked.  There is no state to sequence and no
// handshake to deadlock -- the liveness property that replaces R-V5's usual one
// is that WB cannot refuse a completion, and it is checked on every case.
//
// Run:  make test-unit TB=s1_wb_stage
// =============================================================================

module tb_s1_wb_stage
  import s1_pkg::*;
;
  localparam int unsigned NR    = 2;      // the configuration under detailed test
  localparam int unsigned NR_LO = 1;
  localparam int unsigned NR_HI = 3;

  logic    flush, wb_valid;
  mem_wb_t wb;

  logic                  cb_we,  cb_we1,  cb_we3;
  logic [CB_IDX_W-1:0]   cb_idx, cb_idx1, cb_idx3;
  wb_upd_t               cb_upd, cb_upd1, cb_upd3;

  logic [REG_ADDR_W-1:0] raddr  [NR];
  logic                  hit    [NR];
  logic [XLEN-1:0]       fdata;
  logic [REG_ADDR_W-1:0] raddr1 [NR_LO];
  logic                  hit1   [NR_LO];
  logic [XLEN-1:0]       fdata1;
  logic [REG_ADDR_W-1:0] raddr3 [NR_HI];
  logic                  hit3   [NR_HI];
  logic [XLEN-1:0]       fdata3;

  s1_wb_stage #(.N_READ(NR)) dut (
    .flush_i(flush), .wb_valid_i(wb_valid), .wb_i(wb),
    .cb_we_o(cb_we), .cb_idx_o(cb_idx), .cb_upd_o(cb_upd),
    .fwd_raddr_i(raddr), .fwd_hit_o(hit), .fwd_data_o(fdata)
  );

  s1_wb_stage #(.N_READ(NR_LO)) dut_lo (
    .flush_i(flush), .wb_valid_i(wb_valid), .wb_i(wb),
    .cb_we_o(cb_we1), .cb_idx_o(cb_idx1), .cb_upd_o(cb_upd1),
    .fwd_raddr_i(raddr1), .fwd_hit_o(hit1), .fwd_data_o(fdata1)
  );

  s1_wb_stage #(.N_READ(NR_HI)) dut_hi (
    .flush_i(flush), .wb_valid_i(wb_valid), .wb_i(wb),
    .cb_we_o(cb_we3), .cb_idx_o(cb_idx3), .cb_upd_o(cb_upd3),
    .fwd_raddr_i(raddr3), .fwd_hit_o(hit3), .fwd_data_o(fdata3)
  );

  `include "verif/common/s1_wb_stage_model.svh"

  int unsigned checks = 0, errors = 0, apps = 0;

  task automatic check(input string name, input logic [XLEN-1:0] got, input logic [XLEN-1:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      if (errors <= 25) $display("  FAIL #%0d %-36s got=0x%016h exp=0x%016h", apps, name, got, exp);
    end
  endtask

  int cv_write, cv_nowrite, cv_x0, cv_exc, cv_exc_kill, cv_mxif, cv_mxif_exc, cv_flush,
      cv_csr, cv_csr_kill, cv_sb, cv_sb_exc, cv_hit1p, cv_hit2p, cv_miss, cv_idle,
      cv_load, cv_store, cv_idx_all;
  int idx_seen[CB_DEPTH];

  ins_t cur;
  exp_t exp;

  // ---------------------------------------------------------------------------
  // Apply one case and check every output of all three instances
  // ---------------------------------------------------------------------------
  task automatic verify();
    int h;
    check("cb_we", XLEN'(cb_we), XLEN'(exp.cb_we));

    // The payload is meaningful only with cb_we: an entry WB does not own keeps
    // what ID put in it, and the testbench must not constrain what WB presents
    // on a port the completion buffer is not sampling.
    if (exp.cb_we) begin
      check("cb_idx",         XLEN'(cb_idx),            XLEN'(exp.cb_idx));
      check("upd.done",       XLEN'(cb_upd.done),       XLEN'(exp.upd.done));
      check("upd.norollback", XLEN'(cb_upd.norollback), XLEN'(exp.upd.norollback));
      check("upd.rd",         XLEN'(cb_upd.rd),         XLEN'(exp.upd.rd));
      check("upd.rd_we",      XLEN'(cb_upd.rd_we),      XLEN'(exp.upd.rd_we));
      check("upd.result",     cb_upd.result,            exp.upd.result);
      check("upd.next_pc",    cb_upd.next_pc,           exp.upd.next_pc);
      check("upd.exc",        XLEN'(cb_upd.exc),        XLEN'(exp.upd.exc));
      check("upd.exccode",    XLEN'(cb_upd.exccode),    XLEN'(exp.upd.exccode));
      check("upd.exctval",    cb_upd.exctval,           exp.upd.exctval);
      check("upd.csr.we",     XLEN'(cb_upd.csr.we),     XLEN'(exp.upd.csr.we));
      check("upd.csr.addr",   XLEN'(cb_upd.csr.addr),   XLEN'(exp.upd.csr.addr));
      check("upd.csr.wdata",  cb_upd.csr.wdata,         exp.upd.csr.wdata);
      check("upd.sb_alloc",   XLEN'(cb_upd.sb_alloc),   XLEN'(exp.upd.sb_alloc));
      check("upd.rvfi.addr",  cb_upd.rvfi.addr,         exp.upd.rvfi.addr);
      check("upd.rvfi.rmask", XLEN'(cb_upd.rvfi.rmask), XLEN'(exp.upd.rvfi.rmask));
      check("upd.rvfi.wmask", XLEN'(cb_upd.rvfi.wmask), XLEN'(exp.upd.rvfi.wmask));
      check("upd.rvfi.rdata", cb_upd.rvfi.rdata,        exp.upd.rvfi.rdata);
      check("upd.rvfi.wdata", cb_upd.rvfi.wdata,        exp.upd.rvfi.wdata);
      idx_seen[exp.cb_idx]++;
    end

    // WB has no ready and must never need one: every completion the main pipe
    // owns is taken in the cycle it is offered, or discarded by the flush that
    // removed its entry.  Nothing else may make it wait.
    if (wb_valid && main_pipe_owns(cur))
      check("completion taken or flushed", XLEN'(cb_we | flush), 1);

    for (int k = 0; k < NR; k++)
      check($sformatf("fwd_hit[%0d]", k), XLEN'(hit[k]),
            XLEN'(exp.fwd && (raddr[k] == exp.fwd_rd)));
    if (exp.fwd) check("fwd_data", fdata, exp.fwd_data);

    check("N_READ=1 cb_we", XLEN'(cb_we1), XLEN'(cb_we));
    check("N_READ=3 cb_we", XLEN'(cb_we3), XLEN'(cb_we));
    if (exp.cb_we) begin
      check("N_READ=1 payload", XLEN'(cb_upd1 == cb_upd && cb_idx1 == cb_idx), 1);
      check("N_READ=3 payload", XLEN'(cb_upd3 == cb_upd && cb_idx3 == cb_idx), 1);
    end
    check("N_READ=1 hit[0]",  XLEN'(hit1[0]), XLEN'(hit[0]));
    check("N_READ=3 hit[0]",  XLEN'(hit3[0]), XLEN'(hit[0]));
    check("N_READ=3 hit[1]",  XLEN'(hit3[1]), XLEN'(hit[1]));
    check("N_READ=3 hit[2]",  XLEN'(hit3[2]),
          XLEN'(exp.fwd && (raddr3[2] == exp.fwd_rd)));
    if (exp.fwd) begin
      check("N_READ=1 fwd_data", fdata1, fdata);
      check("N_READ=3 fwd_data", fdata3, fdata);
    end

    if (!wb_valid)                                          cv_idle++;
    else if (flush)                                         cv_flush++;
    if (exp.cb_we &&  exp.upd.rd_we)                        cv_write++;
    if (exp.cb_we && !exp.upd.rd_we)                        cv_nowrite++;
    if (wb_valid && !flush && cur.rd_we && cur.rd == '0)    cv_x0++;
    if (exp.cb_we && cur.exc)                               cv_exc++;
    if (exp.cb_we && cur.exc && cur.rd_we && cur.rd != '0)  cv_exc_kill++;
    if (wb_valid && !flush && !cur.complete && !cur.exc)    cv_mxif++;
    if (wb_valid && !flush && !cur.complete &&  cur.exc)    cv_mxif_exc++;
    if (exp.cb_we && exp.upd.csr.we)                        cv_csr++;
    if (exp.cb_we && cur.csr_we && cur.exc)                 cv_csr_kill++;
    if (exp.cb_we && cur.sb_alloc)                          cv_sb++;
    if (exp.cb_we && cur.sb_alloc && cur.exc)               cv_sb_exc++;
    if (exp.cb_we && |cur.rmask)                            cv_load++;
    if (exp.cb_we && |cur.wmask)                            cv_store++;
    if (exp.fwd) begin
      h = 0;
      for (int k = 0; k < NR; k++) if (hit[k]) h++;
      if      (h == 0) cv_miss++;
      else if (h == 1) cv_hit1p++;
      else             cv_hit2p++;
    end
  endtask

  task automatic apply(ins_t n, bit valid, bit flush_v,
                       logic [REG_ADDR_W-1:0] r0, logic [REG_ADDR_W-1:0] r1,
                       logic [REG_ADDR_W-1:0] r2);
    cur       = n;
    wb        = render_wb(n);
    wb_valid  = valid;
    flush     = flush_v;
    raddr[0]  = r0; raddr[1]  = r1;
    raddr1[0] = r0;
    raddr3[0] = r0; raddr3[1] = r1; raddr3[2] = r2;
    #1;
    apps++;
    exp = golden(n, valid, flush_v);
    verify();
  endtask

  // One read address: the destination a third of the time, so hits are common,
  // otherwise any register.
  //
  // The draws go through named variables on purpose.  Verilator 5.036 hoists a
  // $urandom call out of a conditional expression, so writing this as
  // `(($urandom % 100) < 35) ? rd : REG_ADDR_W'($urandom)` makes consecutive
  // read addresses agree 95% of the time instead of 37%, and the two-port cases
  // the bypass most needs -- one port hitting while the other misses -- almost
  // never get generated.  The testbench still passed; it just stopped testing
  // what it claimed to.  Anything random in this file is drawn into a variable
  // first for that reason.
  function automatic logic [REG_ADDR_W-1:0] pick_raddr(logic [REG_ADDR_W-1:0] rd);
    int                    bias;
    logic [REG_ADDR_W-1:0] any;
    bias = $urandom % 100;
    any  = REG_ADDR_W'($urandom);
    if (bias < 35) return rd;
    return any;
  endfunction

  task automatic apply_rand(ins_t n, bit valid, bit flush_v);
    logic [REG_ADDR_W-1:0] r0, r1, r2;
    r0 = pick_raddr(n.rd);
    r1 = pick_raddr(n.rd);
    r2 = pick_raddr(n.rd);
    apply(n, valid, flush_v, r0, r1, r2);
  endtask

  // ---------------------------------------------------------------------------
  // A case built from the control bits directly, so the exhaustive sweep does
  // not inherit make_ins's idea of which combinations are sensible
  // ---------------------------------------------------------------------------
  function automatic ins_t ctrl_ins(int bits);
    ins_t n;
    logic [REG_ADDR_W-1:0] any_rd;
    any_rd      = REG_ADDR_W'(1 + ($urandom % 31));
    n           = blank_ins();
    n.kind      = K_ALU;
    n.idx       = CB_IDX_W'($urandom);
    n.complete  = bits[0];
    n.exc       = bits[1];
    n.rd_we     = bits[2];
    n.rd        = bits[3] ? REG_ADDR_W'(0) : any_rd;
    n.csr_we    = bits[4];
    n.sb_alloc  = bits[5];
    n.result    = {$urandom, $urandom};
    n.next_pc   = {$urandom, $urandom};
    n.exccode   = 6'($urandom);
    n.exctval   = {$urandom, $urandom};
    n.csr_addr  = 12'($urandom);
    n.csr_wdata = {$urandom, $urandom};
    n.maddr     = {$urandom, $urandom};
    n.rmask     = NB'($urandom);
    n.wmask     = NB'($urandom);
    n.mrdata    = {$urandom, $urandom};
    n.mwdata    = {$urandom, $urandom};
    return n;
  endfunction

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  initial begin
    ins_t n;
    logic cb0;
    logic [CB_IDX_W-1:0] ix0;
    wb_upd_t u0;
    int hits;

    wb = '0; wb_valid = 0; flush = 0;
    raddr[0] = '0; raddr[1] = '0; raddr1[0] = '0;
    raddr3[0] = '0; raddr3[1] = '0; raddr3[2] = '0;
    #1;
    check("idle: no completion-buffer write", XLEN'(cb_we), 0);
    check("idle: no bypass on port 0",        XLEN'(hit[0]), 0);
    check("idle: no bypass on port 1",        XLEN'(hit[1]), 0);

    $display("[directed] nothing is presented: wb_i is ignored");
    for (int k = 0; k < 2000; k++) begin
      n = rand_ins();
      apply_rand(n, 1'b0, 1'($urandom));
    end

    $display("[exhaustive] every control combination: valid x flush x 6 payload bits");
    for (int rep = 0; rep < 96; rep++)
      for (int bits = 0; bits < 64; bits++)
        for (int v = 0; v < 2; v++)
          for (int f = 0; f < 2; f++)
            apply_rand(ctrl_ins(bits), 1'(v), 1'(f));

    $display("[exhaustive] bypass: every destination against every read address");
    for (int rd = 0; rd < 32; rd++) begin
      n        = make_ins(K_ALU);
      n.rd     = REG_ADDR_W'(rd);
      n.rd_we  = 1;
      n.result = {$urandom, $urandom};
      for (int ra = 0; ra < 32; ra++)
        apply(n, 1'b1, 1'b0, REG_ADDR_W'(ra), REG_ADDR_W'(31 - ra), REG_ADDR_W'((ra + 7) % 32));
    end

    $display("[directed] one completion of each class, fields checked by name");
    n = make_ins(K_ALU); n.rd = 5'd7; n.rd_we = 1; n.result = 64'hDEAD_BEEF_0BAD_F00D;
    apply(n, 1'b1, 1'b0, 5'd7, 5'd8, 5'd9);
    check("ALU: entry marked done",      XLEN'(cb_upd.done),       1);
    check("ALU: norollback set",         XLEN'(cb_upd.norollback), 1);
    check("ALU: register write",         XLEN'(cb_upd.rd_we),      1);
    check("ALU: destination",            XLEN'(cb_upd.rd),         7);
    check("ALU: result",                 cb_upd.result,            64'hDEAD_BEEF_0BAD_F00D);
    check("ALU: bypass answers rs1",     XLEN'(hit[0]),            1);
    check("ALU: bypass ignores rs2",     XLEN'(hit[1]),            0);
    check("ALU: bypass data",            fdata,                    64'hDEAD_BEEF_0BAD_F00D);
    check("ALU: no store-buffer entry",  XLEN'(cb_upd.sb_alloc),   0);
    check("ALU: no CSR write",           XLEN'(cb_upd.csr.we),     0);

    n = make_ins(K_LOAD); n.rd = 5'd3; n.result = 64'h0000_0000_0000_FF01;
    n.maddr = 64'h8000_0040; n.rmask = 8'h03; n.mrdata = 64'h0000_0000_0000_FF01;
    apply(n, 1'b1, 1'b0, 5'd3, 5'd3, 5'd4);
    check("LOAD: result is the loaded value", cb_upd.result,            64'h0000_0000_0000_FF01);
    check("LOAD: RVFI addr",                  cb_upd.rvfi.addr,         64'h8000_0040);
    check("LOAD: RVFI rmask",                 XLEN'(cb_upd.rvfi.rmask), 8'h03);
    check("LOAD: RVFI wmask clear",           XLEN'(cb_upd.rvfi.wmask), 0);
    check("LOAD: RVFI rdata",                 cb_upd.rvfi.rdata,        64'h0000_0000_0000_FF01);
    check("LOAD: both read ports hit",        XLEN'(hit[0] & hit[1]),   1);

    n = make_ins(K_STORE); n.maddr = 64'h8000_0080; n.wmask = 8'hF0;
    n.mwdata = 64'h1122_3344_5566_7788; n.sb_alloc = 1;
    apply(n, 1'b1, 1'b0, 5'd1, 5'd2, 5'd3);
    check("STORE: no register write",      XLEN'(cb_upd.rd_we),      0);
    check("STORE: destination zeroed",     XLEN'(cb_upd.rd),         0);
    check("STORE: result zeroed",          cb_upd.result,            0);
    check("STORE: store-buffer entry",     XLEN'(cb_upd.sb_alloc),   1);
    check("STORE: RVFI wmask",             XLEN'(cb_upd.rvfi.wmask), 8'hF0);
    check("STORE: RVFI wdata",             cb_upd.rvfi.wdata,        64'h1122_3344_5566_7788);
    check("STORE: no bypass",              XLEN'(hit[0] | hit[1]),   0);

    n = make_ins(K_JAL); n.rd = 5'd1; n.result = 64'h8000_1004; n.next_pc = 64'h8000_2000;
    apply(n, 1'b1, 1'b0, 5'd1, 5'd0, 5'd1);
    check("JAL: link value",   cb_upd.result,  64'h8000_1004);
    check("JAL: pc_wdata",     cb_upd.next_pc, 64'h8000_2000);
    check("JAL: bypass hits",  XLEN'(hit[0]),  1);

    n = make_ins(K_CSR); n.rd = 5'd9; n.result = 64'h0000_0000_0000_1800;
    n.csr_addr = 12'h300; n.csr_wdata = 64'h0000_0000_0000_1808; n.csr_we = 1;
    apply(n, 1'b1, 1'b0, 5'd9, 5'd0, 5'd0);
    check("CSR: old value to rd",   cb_upd.result,           64'h0000_0000_0000_1800);
    check("CSR: pending write",     XLEN'(cb_upd.csr.we),    1);
    check("CSR: address",           XLEN'(cb_upd.csr.addr),  12'h300);
    check("CSR: write data",        cb_upd.csr.wdata,        64'h0000_0000_0000_1808);

    $display("[directed] x0 is never written and never forwarded");
    for (int k = 0; k < 200; k++) begin
      n = rand_ins(); n.rd_we = 1; n.rd = '0; n.exc = 0; n.complete = 1;
      apply(n, 1'b1, 1'b0, 5'd0, REG_ADDR_W'($urandom), 5'd0);
      check("x0: no register write",  XLEN'(cb_upd.rd_we),    0);
      check("x0: result zeroed",      cb_upd.result,          0);
      check("x0: no bypass on x0",    XLEN'(hit[0]),          0);
      check("x0: entry still done",   XLEN'(cb_upd.done),     1);
    end

    $display("[directed] a trap writes nothing but still resolves the entry");
    for (int k = 0; k < 400; k++) begin
      n = rand_ins();
      n.complete = 1; n.exc = 1; n.rd_we = 1;
      n.rd = REG_ADDR_W'(1 + ($urandom % 31));
      n.csr_we = 1; n.exccode = 6'($urandom % 16); n.exctval = {$urandom, $urandom};
      apply(n, 1'b1, 1'b0, n.rd, n.rd, n.rd);
      check("trap: entry written",       XLEN'(cb_we),           1);
      check("trap: marked done",         XLEN'(cb_upd.done),     1);
      check("trap: no register write",   XLEN'(cb_upd.rd_we),    0);
      check("trap: no CSR write",        XLEN'(cb_upd.csr.we),   0);
      check("trap: no bypass",           XLEN'(hit[0] | hit[1]), 0);
      check("trap: cause reported",      XLEN'(cb_upd.exccode),  XLEN'(n.exccode));
      check("trap: mtval reported",      cb_upd.exctval,         n.exctval);
    end

    $display("[directed] an MXIF candidate's entry is left to the MXIF port");
    for (int k = 0; k < 400; k++) begin
      n = make_ins(K_MXIF);
      n.rd_we = 1; n.rd = REG_ADDR_W'(1 + ($urandom % 31));
      apply(n, 1'b1, 1'b0, n.rd, n.rd, n.rd);
      check("candidate: entry untouched", XLEN'(cb_we),           0);
      check("candidate: no bypass",       XLEN'(hit[0] | hit[1]), 0);
      // ... unless it trapped on the way down, in which case nobody else will
      // ever claim it and WB must resolve it.
      n.exc = 1; n.exccode = EXC_INSTR_ACCESS_FAULT;
      apply(n, 1'b1, 1'b0, n.rd, n.rd, n.rd);
      check("faulted candidate: entry written", XLEN'(cb_we),          1);
      check("faulted candidate: done",          XLEN'(cb_upd.done),    1);
      check("faulted candidate: cause",         XLEN'(cb_upd.exccode), XLEN'(EXC_INSTR_ACCESS_FAULT));
      check("faulted candidate: no bypass",     XLEN'(hit[0]),         0);
    end

    $display("[directed] flush discards the completion and the bypass with it");
    for (int k = 0; k < 400; k++) begin
      n = rand_ins(); n.complete = 1; n.exc = 0;
      n.rd_we = 1; n.rd = REG_ADDR_W'(1 + ($urandom % 31));
      apply(n, 1'b1, 1'b1, n.rd, n.rd, n.rd);
      check("flush: no entry written", XLEN'(cb_we),           0);
      check("flush: no bypass",        XLEN'(hit[0] | hit[1]), 0);
      apply(n, 1'b1, 1'b0, n.rd, n.rd, n.rd);
      check("after flush: entry written", XLEN'(cb_we),  1);
      check("after flush: bypass",        XLEN'(hit[0]), 1);
    end

    $display("[directed] a store-buffer entry survives an exception on the same completion");
    // Illegal at the source -- s1_mem_stage never allocates for an access that
    // faulted -- and checked anyway, because the failure mode if WB ever gates
    // it is a store-buffer slot that is allocated and never commits.
    n = make_ins(K_STORE); n.sb_alloc = 1; n.exc = 1; n.exccode = EXC_STORE_ACCESS_FAULT;
    apply(n, 1'b1, 1'b0, 5'd1, 5'd2, 5'd3);
    check("sb_alloc passed through unchanged", XLEN'(cb_upd.sb_alloc), 1);
    check("sb_alloc case still traps",         XLEN'(cb_upd.exc),      1);

    $display("[probe] the completion-buffer write does not depend on the read addresses");
    for (int k = 0; k < 400; k++) begin
      n = rand_ins();
      apply(n, 1'b1, 1'b0, 5'd1, 5'd2, 5'd3);
      cb0 = cb_we; ix0 = cb_idx; u0 = cb_upd;
      apply(n, 1'b1, 1'b0, n.rd, n.rd, n.rd);
      check("cb_we independent of read addresses",  XLEN'(cb_we),  XLEN'(cb0));
      if (cb0) begin
        check("cb_idx independent of read addresses",  XLEN'(cb_idx), XLEN'(ix0));
        check("payload independent of read addresses", XLEN'(cb_upd == u0), 1);
      end
    end

    $display("[probe] every completion-buffer index is reachable");
    for (int i = 0; i < CB_DEPTH; i++) begin
      n = make_ins(K_ALU); n.idx = CB_IDX_W'(i);
      apply(n, 1'b1, 1'b0, 5'd1, 5'd2, 5'd3);
      check($sformatf("index %0d addressed", i), XLEN'(cb_idx), XLEN'(i));
    end

    $display("[random] soak: random classes, random flush, random operand reads");
    for (int k = 0; k < 120000; k++) begin
      bit v, f;
      v = (($urandom % 100) < 85);
      f = (($urandom % 100) < 10);
      apply_rand(rand_ins(), v, f);
    end

    for (int i = 0; i < CB_DEPTH; i++) if (idx_seen[i] > 0) cv_idx_all++;

    $display("coverage: write %0d nowrite %0d x0 %0d exc %0d exc_kill %0d csr %0d csr_kill %0d",
             cv_write, cv_nowrite, cv_x0, cv_exc, cv_exc_kill, cv_csr, cv_csr_kill);
    $display("          mxif %0d mxif_exc %0d flush %0d idle %0d sb %0d sb_exc %0d",
             cv_mxif, cv_mxif_exc, cv_flush, cv_idle, cv_sb, cv_sb_exc);
    $display("          load %0d store %0d bypass hit1 %0d hit2 %0d miss %0d indices %0d/%0d",
             cv_load, cv_store, cv_hit1p, cv_hit2p, cv_miss, cv_idx_all, CB_DEPTH);
    check("coverage all hit", XLEN'(cv_write > 0 && cv_nowrite > 0 && cv_x0 > 0 && cv_exc > 0
          && cv_exc_kill > 0 && cv_csr > 0 && cv_csr_kill > 0 && cv_mxif > 0 && cv_mxif_exc > 0
          && cv_flush > 0 && cv_idle > 0 && cv_sb > 0 && cv_sb_exc > 0 && cv_load > 0
          && cv_store > 0 && cv_hit1p > 0 && cv_hit2p > 0 && cv_miss > 0
          && cv_idx_all == CB_DEPTH), 1);

    if (errors != 0) $fatal(1, "=== FAIL : %0d of %0d checks ===", errors, checks);
    $display("=== PASS : %0d checks ===", checks);
    $finish;
  end
endmodule
