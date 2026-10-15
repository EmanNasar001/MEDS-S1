# `s1_mem`

| | |
|---|---|
| **Status** | WIP — integration-verified; no unit testbench |
| **Authorship** | see the file header (`Author(s)` / `Modified By`) — CODING_STANDARD.md §5 |
| **Project** | R-02 (load/store unit, store buffer, PMP and atomics) |
| **Spec** | SPEC §7.4, §11, §14, §8.2; INTERFACES.md §1.5, §2, §9 (P1–P3); RISC-V A |
| **Source** | `rtl/core/s1_mem.sv` |
| **Testbench** | the integration testbench that lands with `s1_core`; none of its own |

## Purpose

The MEM stage. It takes one instruction per cycle from the EX/MEM register and does what SPEC §7.4
puts in MEM: the D$ access over I2, the physical-memory checks, store-buffer allocation so a write
reaches memory only after its instruction retires, and AMO / LR / SC sequencing. It owns the MEM/WB
register and produces one `mem_wb_t` per instruction.

## Interface contract

### Ports

| Signal | Dir | Width | Meaning | Contract |
|---|---|---|---|---|
| `clk_i`, `rst_ni` | in | 1 | clock, reset | async assert, sync de-assert |
| `flush_i` | in | 1 | retire flush | blocks the EX/MEM transfer, clears MEM/WB, drops uncommitted writes and the reservation |
| `priv_i` | in | `priv_lvl_e` | effective data privilege | `mstatus.MPRV` already applied |
| `mem_valid_i` / `mem_ready_o` | in / out | 1 | EX/MEM handshake | EX holds `mem_i` until `ready` (R-C10); `ready` is low during `flush_i` and never depends on `dmem_req_ready_i` |
| `mem_i` | in | `ex_mem_t` | EX/MEM register | |
| `wb_valid_o`, `wb_o` | out | 1, `mem_wb_t` | MEM/WB | one per instruction; **no ready** |
| `wb_pend_o` | out | 1 | MEM/WB holds a read the bus still owes | the hazard unit and CSR serialisation need this — without it a load in flight is invisible to them whenever memory latency exceeds one cycle |
| `oldest_tag_i` | in | `TAG_W` | oldest in-flight tag | holds non-idempotent reads back (P1) |
| `sb_commit_i`, `sb_commit_tag_i` | in | 1, `TAG_W` | a write retired | one per cycle |
| `chk_*_o` | out | — | the access in MEM, as a query | **answered combinationally in the same cycle** |
| `pma_i`, `pma_fault_i`, `pmp_allow_i` | in | `pma_t`, 1, 1 | the two checkers' answers | both checkers are **outside this core** |
| `dmem_*` | out/in | I2 MEM-REQ | D$ port | `valid` never depends on `ready`; payload stable while stalled; `rsp_ready` constant 1 |
| `sb_empty_o`, `sb_full_o` | out | 1 | store buffer status | `fence` waits on empty; full is a perf event |
| `store_err_o`, `store_err_addr_o` | out | 1, `XLEN` | a retired write got a bus error | one-cycle pulse; **imprecise** |

**Both physical-memory checks are external.** One query describes the access; two independent
checkers answer in the same cycle, in parallel with the D$ tag lookup. PMA comes from the generated
decoder, PMP from a checker reading the CSRs. Neither is inside the core, which is what lets the
fetch path share the same PMP checker.

## Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `STORE_BUF_N` | `SB_DEPTH` | ≥ 1 (elaboration error below) | store-buffer entries |

## Behaviour

```
 EX/MEM ─► width/sign/kind ─► checks (external) + alignment + atomics ─► fault?
             │
             ├─ read  (load, LR, AMO): merge older SB entries byte-wise ─► bytes left? ─► I2
             ├─ write (store, SC ok) : allocate an SB entry, uncommitted
             ▼
        MEM/WB register ──── response (+ 2nd beat) ──► extend ──► wb_o
             │ AMO: new = op(old, rs2) ──► allocate at completion
             │ LR : set the reservation at completion
 store buffer ──commit at retire──► drain the head over I2 ──► pop
```

**Byte windows and forwarding.** An access covers at most two 8-byte I2 beats, held as a 16-bit
byte mask and 128 bits of data. A read merges every older pending write, oldest first, so each byte
comes from its youngest writer; bytes nobody covers come from the bus, and only beats with an
uncovered byte are requested. A straddling access is two requests, low beat first.

**P1 and P2.** A read from a `!idempotent` or `strong_order` region waits for an empty store buffer
and never merges. A `!idempotent` read also waits until it is the oldest in flight.

**LR/SC.** LR records `{address, size}` when it completes. SC checks that reservation in MEM:
without an exact match it fails (`result = 1`) without touching memory and without faulting. Every
SC clears the reservation, and so does `flush_i`.

**The I2 port.** One request at a time. Priority: the second beat of the read in MEM/WB, then a
committed store-buffer head, then the read in MEM. Draining before new reads keeps a committed MMIO
write from being starved by a loop of loads. A presented request is frozen until accepted (R-C10).

**Store buffer.** Shift register, entry 0 oldest; committed entries are always a prefix. Each edge
applies commit, pop, flush and allocate, in that order.

## Exceptions and errors

| Condition | `exccode` |
|---|---|
| EX exception | passed through |
| check failure on a load or LR | `EXC_LOAD_ACCESS_FAULT` |
| check failure on a store, SC or AMO | `EXC_STORE_ACCESS_FAULT` |
| bus error on a read | load: load fault; AMO: store fault |
| bus error draining a retired write | none; `store_err_o` pulse |

All but the last are precise. A write's bus error arrives after retire and cannot be.

## Verification status

| Layer | Status | Where |
|---|---|---|
| Lint | clean once the shared types are available | `make lint` |
| Unit test | **none** — this module has no unit testbench | — |
| Integration | every retirement compared against spike, over the whole pipeline | the integration testbench that lands with `s1_core` |
| Co-simulation, arch tests | not yet | |

This module is verified **through the integrated core**, not on its own: an RV64I program and a C
sorting workload are run through the whole pipeline with every retirement compared against spike on
RVFI, with ideal memory and under random I$/D$ backpressure and latency.

Two bugs that testing found and this version fixes:

- a load still waiting on the D$ in MEM/WB was invisible to the hazard unit and to CSR
  serialisation, giving stale operands whenever memory latency exceeded one cycle. That is what
  `wb_pend_o` is for.
- `rs1_rdata` / `rs2_rdata` were not carried into MEM/WB, so RVFI could not report them.

**What integration does not reach.** An RV64I program exercises no AMO, no LR/SC, no faulting or
misaligned access, and no straddling access. Those paths are written and lint-clean but unverified
here. A unit testbench, or an arch-test run with the A extension, is what would close that.

## Known limitations

- **No unit testbench.** The paths above are the cost. A unit testbench for this module was written
  against an earlier interface and did not survive the move to the integrated design.
- **No Zicbom.** `decoded_op_t` defines `is_cbo` and `cbo_op`, but MEM does not act on them.
- **Forwarding is by address**, so a load through one mapping after a store through another of the
  same byte is not forwarded.
- **Same-hart writes do not break a reservation**, and a flush or SC always clears it. Both are
  permitted by the A extension.
- **One outstanding I2 request.** With a slower D$, throughput is one access per hit latency.
- **Critical path:** the external checks → `mem_ready_o` / `dmem_req_valid_o`, and I2 `rdata` →
  merge → extend → `wb_o`.

## Open questions

1. **What does `store_err_o` raise?** Imprecise by construction: a bus-error interrupt, a sticky
   CSR, or debug halt. Needs a ruling.
2. **I2 for split accesses.** Each beat of a straddling access carries the whole access's `size`;
   `be` is authoritative. Settle in INTERFACES.md §2.
3. **Interrupts on a completed non-idempotent read.** Its MMIO read has already happened; retire
   must retire such an instruction rather than replay it.
