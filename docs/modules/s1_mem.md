# `s1_mem`

| | |
|---|---|
| **Status** | WIP — unit- and integration-verified |
| **Authorship** | see the file header (`Author(s)` / `Modified By`) — CODING_STANDARD.md §5 |
| **Project** | R-02 (load/store unit, store buffer, PMP and atomics) |
| **Spec** | SPEC §7.4, §11, §14, §8.2; INTERFACES.md §1.5, §2, §9 (P1–P3); RISC-V A |
| **Source** | `rtl/core/s1_mem.sv` |
| **Testbench** | `verif/unit/tb_s1_mem.sv` (4,139,870 checks), plus the integration testbench that lands with `s1_core` |

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
| Unit test | `tb_s1_mem` — 4,139,870 checks over 13,425 instructions | `make test-unit TB=s1_mem` |
| Mutation | 21 of 21 lint-clean mutants caught | `rtl/core/s1_mem.sv` |
| Integration | every retirement compared against spike, over the whole pipeline | the integration testbench that lands with `s1_core` |
| Co-simulation, arch tests | not yet | |

**Unit test.** A cycle-accurate golden copy of this module would be a second implementation of the
same design, and would agree with it about any shared mistake. The unit testbench checks it against
**memory** instead, at the two levels this design actually promises:

| Model | Updated when | What it proves |
|---|---|---|
| `prog[]` | an access is accepted into MEM, in program order | every load, LR and AMO reads exactly this, whether the bytes came off the bus, out of the store buffer by forwarding, or from both |
| `phys[]` | a write request fires on I2 | it may lag `prog[]` — that lag **is** the store buffer — but the instant `sb_empty_o` goes high the two must agree byte for byte |

That second property is the one worth having: it says a drained buffer has really drained, which is
what `fence` rests on, and it catches a store that was dropped, duplicated, written to the wrong
address or written with the wrong byte enables — none of which a forwarding-only check would notice.

Each 4 KiB page in the testbench's map carries a different PMA, so one random stream reaches every
path: misaligned (beat-straddling) accesses, non-idempotent and strongly-ordered ordering stalls,
regions that refuse atomics, a PMP that denies writes, an unmapped hole, and a bus that errors on a
read, on a *straddling* read, or on a drained write. `oldest_tag_i` is wired exactly as `s1_core`
wires it, so the testbench cannot be kinder about ordering than the real core is.

Two properties are checked directly rather than through their data effect, because neither has one.
P1 — a non-idempotent read is never speculative — only changes *timing*, so the testbench asserts
the ordering rule itself: such a read may only be accepted when nothing older is still completing.
And `store_err_o` is imprecise by construction, so the write-error page is the one place the two
memory models are *meant* to diverge, and it is excluded from the byte comparison rather than
papered over.

It also checks the bus contract and the hang cases, not just the data: `dmem_rsp_ready_o` constant,
no second request outstanding, a response only when one is owed, a presented request frozen under
backpressure (R-C10), `wb_pend_o` exactly whenever MEM/WB holds something with no result yet, and a
watchdog that fails the run if `mem_valid_i` is held for 500 cycles without acceptance.

Because the stimulus is random, the coverage counts are **asserted, not printed** — "passed" and
"did not run" must not look alike. One run reaches:

| | | | |
|---|---|---|---|
| loads 5,145 | stores 5,058 | AMOs 604 | LR 452 |
| SC success 111 | SC failure 396 | straddling 971 | faults 1,276 |
| read bus errors 67 (8 of them straddling) | write bus errors 150 | forwarding hits 678 | buffer-full cycles 3,940 |

**Integration** then runs an RV64I program and a C sorting workload through the whole pipeline with
every retirement compared against spike on RVFI, under random I$/D$ backpressure and latency.

Two bugs that testing found and this version fixes:

- a load still waiting on the D$ in MEM/WB was invisible to the hazard unit and to CSR
  serialisation, giving stale operands whenever memory latency exceeded one cycle. That is what
  `wb_pend_o` is for.
- `rs1_rdata` / `rs2_rdata` were not carried into MEM/WB, so RVFI could not report them.

**What neither layer reaches.** The unit testbench answers `pma_i` / `pmp_allow_i` from its own map,
so it proves what MEM does with a checker's answer, not that the checkers are right — PMA belongs to
the generated decoder and PMP to R-02's checker, each with its own testbench. Zicbom is untested
because the module does not implement it. Flush is exercised for liveness and for "nothing completes
during a flush", but its data effects are not scoreboarded: a flush discards uncommitted stores, so
the program-order model stops describing the machine.

## Known limitations

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
