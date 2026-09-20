# `s1_wb_stage`

| | |
|---|---|
| **Status** | WIP (unit-verified; not yet integrated) |
| **Owner** | @EmanNasar001 |
| **Backup** | _(assign at the T-02 design review)_ |
| **Project** | T-02 (core backend), against the completion buffer R-01 will build |
| **Spec** | SPEC §6, §7.5, §8.1, §9.1, §9.2, §28.2; INTERFACES.md §1.4a |
| **Source** | `rtl/core/s1_wb_stage.sv` |
| **Testbench** | `verif/unit/tb_s1_wb_stage.sv` (models in `verif/common/s1_wb_stage_model.svh`): 3 600 488 checks |

## Purpose

Stage five. It takes the MEM/WB completion `s1_mem_stage` produces (#18) and turns it into two
things: the write that resolves the instruction's completion-buffer entry, and the answer ID gets
when it asks for that instruction's destination register in the same cycle.

It is small on purpose. Almost everything SPEC §7.5 appears to put here happens somewhere else, and
which things those are is the part of this module worth reviewing — see *Where §7.5's four bullets
actually land* below.

## Interface contract

### Ports

| Signal | Dir | Width | Meaning | Contract |
|---|---|---|---|---|
| `flush_i` | in | 1 | retire flush | discards the completion presented in the same cycle, and the bypass with it |
| `wb_valid_i` | in | 1 | a completion is presented | **no `ready`**: the entry was allocated in ID, so WB cannot refuse and never stalls MEM |
| `wb_i` | in | `mem_wb_t` | MEM/WB register (#18) | sampled only when `wb_valid_i`; every field is used (see below) |
| `cb_we_o` | out | 1 | write the entry `cb_idx_o` names | 1 only for a completion the main pipe owns and that a flush did not remove |
| `cb_idx_o` | out | `CB_IDX_W` | which entry | `wb_i.cb_idx`; meaningful only with `cb_we_o` |
| `cb_upd_o` | out | `wb_upd_t` | what to write into it | meaningful only with `cb_we_o`; a pure function of `wb_i`, so the buffer stores it and re-derives nothing |
| `fwd_raddr_i` | in | `N_READ` × `REG_ADDR_W` | ID's operand register numbers | read-only: **no output but `fwd_hit_o` depends on these** |
| `fwd_hit_o` | out | `N_READ` × 1 | this port's operand is the value below | 0 for x0, for a trapping instruction, and during a flush |
| `fwd_data_o` | out | `XLEN` | the value | one bus for all ports — there is only ever one completion |

**Handshake:** none in either direction. MEM cannot be refused and the completion buffer cannot
refuse WB; `cb_we_o` is a write strobe, not a request.
**Latency:** zero. The module is combinational, and *that is the contract*: the entry is written at
the end of the cycle the completion arrives, so the bypass and the write are the same event.
**Backpressure:** none exists. This is checked, not assumed — the testbench asserts on every case
that a completion the main pipe owns is either written or flushed in the cycle it is offered.
**Reset state:** no reset. With `wb_valid_i` low the outputs are `cb_we_o = 0` and every
`fwd_hit_o` 0, whatever is on `wb_i`.

### `wb_upd_t` (new in `s1_pkg`)

| Field | Contents |
|---|---|
| `done`, `norollback` | both 1. `cb_we_o` is asserted only for an instruction the main pipe has resolved, and a resolved main-pipe instruction cannot fault again (SPEC §9.1) |
| `rd`, `rd_we`, `result` | the architectural register write, **already gated**: 0 / 0 / 0 unless the instruction really updates a register |
| `next_pc` | RVFI `pc_wdata`, from EX |
| `exc`, `exccode`, `exctval` | passed through from MEM |
| `csr` | `{we, addr, wdata}`; `we` is suppressed by an exception, `addr` and `wdata` pass through |
| `sb_alloc` | passed through unchanged — deliberately, see *Behaviour* |
| `rvfi` | `{addr, rmask, wmask, rdata, wdata}` repacked from MEM's `mem_*` group and carried unchanged; the masks are MEM's and WB does not re-derive them |

## Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `N_READ` | 2 | ≥ 1 (elaboration error below) | ID operand read ports the bypass answers. 2 is `rs1`/`rs2`; a third would be for an FMA-style third operand |

## Behaviour

```
  wb_valid_i ──┬─► resolved? ──► cb_we_o ──► completion buffer entry cb_idx_o
   flush_i ────┘     │
                     └─► writes a register? ──┬─► cb_upd_o.rd / rd_we / result
     wb_i ───────────────────────────────────┐└─► fwd_hit_o[k] = (fwd_raddr_i[k] == rd)
                                             └──► everything else, passed through
```

Three questions decide everything the module does.

**1. Is this entry the main pipe's to write?** An MXIF candidate travels the main pipe as a
placeholder. It carries `complete = 0`, and from the moment it is offloaded its entry belongs to the
MXIF port, which marks it done and clears its rollback when the coprocessor answers
(INTERFACES.md §1.4a). Offload happens at the head — *after* WB. So WB must leave that entry
completely alone: the `rd` and `rd_we` the decoder put in it at ID are the live copy, and writing
the placeholder's fields over them would lose the register the coprocessor is going to write.

The exception is a candidate that trapped on the way down, from a fetch or address fault carried
from IF or EX. It will never be offered to a coprocessor, so nobody else will ever resolve it, and
WB does.

**2. Does it update an architectural register?** Three independent reasons it may not: it has no
destination, it trapped (SPEC §9.2 step 6 skips steps 1–3), or the destination is x0. All three
produce `rd = 0`, `rd_we = 0`, `result = 0` and no bypass hit.

x0 is dropped *here* rather than at retire because the bypass is fed from the same signal. Retire
writing x0 is harmless — the register file discards it — but a bypass that answers with it turns
`addi x0, x1, 1` into a corrupted operand for the next reader of x0, and that reader is entitled to
zero. Zeroing `rd` and `result` alongside `rd_we` also makes RVFI's "`rd_wdata` is 0 when `rd_addr`
is 0" structural instead of something retire has to remember.

A pending CSR write is suppressed by the same rule and for the same reason: a CSR write that
survived its instruction's trap would be architectural state from an instruction that never
executed.

**3. Is the store-buffer entry passed through?** Yes, ungated, and this is the one place the module
deliberately does *not* apply rule 2. MEM allocates a store-buffer entry only for an access that
already passed every check, so `sb_alloc` and `exc` are mutually exclusive at the source. Gating it
here would look defensive and would be a leak: the entry is allocated in MEM, never committed at
retire, never drained, and the buffer is one slot smaller for the rest of time. If the two are ever
seen together, the bug is upstream and should be found there.

**The bypass covers exactly one cycle.** The entry is written at the end of this cycle, so from the
next one the completion buffer's own bypass — SPEC §8.1's fourth source — answers for it. Until
then nothing else can, because the value exists only on this port. Without it, every consumer of a
load or a multi-cycle result would stall a cycle for a value already in hand.

### Where §7.5's four bullets actually land

§7.5 lists four things under "WB / retire". Read against §6 and §9.2, only the second is WB's:

| §7.5 says | Where it happens | Why |
|---|---|---|
| "Register file writeback for main-pipe instructions" | **retire** (§9.2 step 1) | §6 decision 2: *all* architectural state updates happen at the retire pointer. WB writes the result into the entry and answers the bypass from it; the register file is written when the entry retires |
| "Completion buffer update" | **WB** — this module | |
| "Retire pointer advance" | **retire** (§9.2), R-01 | |
| "RVFI trace emission" | **retire** (§28.2), R-05 | WB carries the RVFI memory group into the entry so retire has it; it does not drive the port |

§7.5's first bullet reads as a five-stage-textbook line that survived the move to
commit-at-retire. It is listed as an open question below rather than silently contradicted.

## Exceptions and errors

WB raises nothing of its own. It is the point where an exception stops being something the pipeline
carries and becomes something the entry records: `exc`, `exccode` and `exctval` pass through, the
entry is marked `done` so the head can retire and take the trap, and the register and CSR writes
that would have accompanied the instruction are suppressed. The store-buffer flag is not (above).

## Verification status

| Layer | Status | Where |
|---|---|---|
| Lint | clean, no waivers | `make lint` |
| Unit test | **3 600 488 checks**; runs three instances at `N_READ` 1, 2 and 3 | `verif/unit/tb_s1_wb_stage.sv` |
| Mutation | 20 hand-inserted bugs, 20 caught | table below |
| Integration, co-simulation, arch tests | not yet | needs #18, R-01's completion buffer and the rest of the core |

The testbench plays MEM (drives MEM/WB), the completion buffer (checks the write port), retire
(drives `flush_i`) and ID (drives the operand read addresses and checks the bypass). The reference
model is written independently of the RTL: a test case is an abstract statement of what the
instruction did, and it is rendered twice — once into the `mem_wb_t` MEM would have built, once into
the completion-buffer write SPEC §9.1 and §9.2 require. The two renderings share no code.

- **Exhaustive over the control space.** All 256 combinations of `wb_valid_i`, `flush_i`,
  `complete`, `exc`, `rd_we`, `rd == x0`, `csr_we` and `sb_alloc`, 96 times each with independent
  random payloads, every output checked on all three instances. Every other test is a named corner
  of that space.
- **Exhaustive over the bypass.** Every destination register against every read address, 32 × 32,
  on every read port.
- **Directed.** One completion of each class — ALU, load, store, branch, JAL, CSR, MXIF candidate,
  and an instruction that writes nothing — with the fields that matter to that class checked by
  name. x0 written and not forwarded; a trap suppressing the register and CSR writes while still
  resolving the entry; an MXIF candidate's entry left untouched, and the same candidate resolved
  once it has faulted; flush discarding a completion and the next one going through; a
  store-buffer entry surviving an exception on the same completion; every completion-buffer index
  addressable.
- **Every case.** A completion the main pipe owns is written or flushed in the cycle it is offered
  — the property that stands in for a liveness check in a module with no handshake. `wb_i` is
  ignored entirely while `wb_valid_i` is low. The completion-buffer write is independent of the
  operand read addresses, checked by re-applying the same case with different ones. All three
  `N_READ` instances agree on every shared output.
- **Random soak.** 120 000 cases: random instruction class, 12% of them trapping, 15% of the
  writers targeting x0, 15% no completion at all, 10% flushed, operand reads biased one in three
  towards the destination. The last run: register writes 45 946, no register write 48 757, x0
  13 062, traps 15 156 (8 005 of them suppressing a register write, 2 600 a CSR write), MXIF
  candidates 6 752 (2 620 of them faulted), flushed 16 931, idle 32 228, store-buffer allocations
  15 433, bypass one port 20 638 / both ports 6 496 / neither 18 812.

Mutants, each a lint-clean copy of `s1_wb_stage.sv` with one change:

| Mutant | Bug injected | Caught by |
|---|---|---|
| x0 forwarded | `rd != 0` dropped from the write condition | `upd.rd_we` |
| trap writes rd | `~exc` dropped from the write condition | `upd.rd` |
| CSR survives trap | `~exc` dropped from `csr.we` | `upd.csr.we` |
| CSR write gated on rd_we | `csr.we` also requires a register write | `upd.csr.we` |
| flush gates only the bypass | flush suppresses forwarding but not the entry write | `cb_we` |
| bypass ignores flush | forwarding survives the flush that dropped the entry | `fwd_hit[0]` |
| bypass ignores rd_we | forwarding for an instruction that writes no register | `fwd_hit[1]` |
| resolved uses xor not or | `complete ^ exc` instead of `|` — a trapping instruction is dropped | `cb_we` |
| faulted candidate dropped | an MXIF candidate that trapped is left unresolved for ever | `cb_we` |
| sb_alloc gated on exc | the defensive gate that strands a store-buffer entry | `upd.sb_alloc` |
| rd leaks when not writing | `rd` passed through when the instruction writes nothing | `upd.rd` |
| result leaks when not writing | `result` passed through likewise | `upd.result` |
| done from complete | `done` taken from `complete`, so a faulted candidate is never done | `upd.done` |
| norollback cleared | main-pipe instruction marked rollback-able (SPEC §9.1) | `upd.norollback` |
| RVFI masks swapped | `rmask` and `wmask` exchanged | `upd.rvfi.rmask` |
| RVFI data swapped | `rdata` and `wdata` exchanged | `upd.rvfi.rdata` |
| mtval and pc_wdata swapped | `exctval` and `next_pc` exchanged | `upd.next_pc` |
| wrong entry addressed | `cb_idx` off by one | `cb_idx` |
| entry addressed by rd | `cb_idx` xored with the destination | `cb_idx` |
| every port answers port 0 | every `fwd_hit_o` compares `fwd_raddr_i[0]` | `fwd_hit[1]` |

**A testbench bug worth repeating.** The first version drew each operand read address as
`(($urandom % 100) < 35) ? rd : REG_ADDR_W'($urandom)`. Verilator 5.036 hoists a `$urandom` call
out of a conditional expression, and consecutive read addresses came out equal 95% of the time
instead of 37% — so the two-port case the bypass most needs, one port hitting while the other
misses, was generated 1 781 times in 120 000 rather than 20 638. Every check passed throughout; the
testbench had simply stopped testing what it claimed to. Anything random in these files is now drawn
into a named variable before it is used. `tb_s1_mem_stage` (#18) has the same pattern in `rand_ins`
(instruction class, width and address) and in `pmp_fuzz`; its coverage bins are all still hit, but
the distribution behind them should be re-measured before that number is quoted as a soak result.

## Known limitations

- **One completion per cycle, from the main pipe only.** MUL, DIV and the MXIF port also complete
  into the buffer (SPEC §6, §8.2) and nothing here arbitrates for them. Whoever builds R-01 must
  decide between a second write port and an arbiter in front of this one; if it is an arbiter, this
  module's completion must win unconditionally, because `wb_valid_i` has no `ready` and MEM cannot
  be told to wait.
- **`cb_upd_o` is a subset of `cb_entry_t`, not the entry.** `valid`, `pc`, `instr`, `is_mxif`,
  `mxif_id` and `unit` are ID's and are not touched here. `wb_upd_t` exists because R-01 owns
  `cb_entry_t` and this module should not pre-empt its shape.
- **Combinational, and on MEM's critical path.** `s1_mem_stage` already lists
  `I2 rdata → merge → extend → wb_o` as a critical path; this module adds the x0/exception gate and
  the bypass comparators on top of it. If it does not meet timing, the fix is not to register this
  module — that would cost a forwarding bubble on every load — but to register MEM's extend stage
  and accept the extra cycle there.
- **The bypass does not know about age.** It answers for one completion, so there is nothing to
  arbitrate. The moment a second completion source exists, the operand mux must prefer the younger
  one and that comparison has to live somewhere.
- Tested at `XLEN = 64`, `CB_DEPTH = 8`, `N_READ` 1, 2 and 3.

## Open questions

1. **SPEC §7.5's first bullet is wrong, or §6's second decision is.** "Register file writeback for
   main-pipe instructions" at WB cannot coexist with "all architectural state updates happen at the
   retire pointer" and §9.2 step 1. This module implements the §6/§9.2 reading. If that is right,
   §7.5 should say "result writeback into the completion buffer entry" — a one-line spec fix, and
   worth making before three more people read it the other way.
2. **Does retire need to distinguish "no register write" from "wrote x0"?** WB erases the
   difference, which is what RVFI wants. If the debug module ever wants to show the instruction's
   nominal destination, the entry needs the ungated `rd` as well.
3. **Who marks an MXIF candidate's entry when the coprocessor rejects it?** §9.2 says the rejection
   becomes an illegal-instruction trap, but the entry is at the head by then and has already passed
   WB. R-01's offload path has to write it, not this module — confirm when the MXIF port lands.
4. **`wb_upd_t` should be folded into whatever R-01 names.** It is deliberately not a `cb_entry_t`
   and should not become one by accident.
