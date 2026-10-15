# `s1_wb`

| | |
|---|---|
| **Status** | WIP — integration-verified; no unit testbench |
| **Authorship** | see the file header (`Author(s)` / `Modified By`) — CODING_STANDARD.md §5 |
| **Project** | T-02 (core backend) |
| **Spec** | SPEC §7.5, §10.3, §28.2 |
| **Source** | `rtl/core/s1_wb.sv` |
| **Testbench** | the integration testbench that lands with `s1_core`; none of its own |

## Purpose

The WB stage, and **the architectural commit point**. Combinational: the MEM/WB register lives in
`s1_mem`, so by the time an instruction arrives here it is finished, and this stage decides what its
arrival does to architectural state.

Exactly one instruction commits per cycle, in program order, and everything that outlives it happens
here:

1. the register file write, unless it trapped or writes x0
2. the CSR write EX computed
3. the store-buffer entry is marked committed, so it may drain to memory
4. RVFI
5. `minstret`
6. on a trap: none of 1–3, and the pipeline is flushed to the trap vector

**Why commit here rather than in MEM.** A store that has passed MEM has been checked against PMA and
PMP, but it is still younger than nothing — it is the oldest instruction in the machine only once it
reaches WB. Buffer the store in MEM, release it here, and a trap taken by *this* instruction cannot
have already written memory.

Interrupts are taken here too, in place of a commit, so `mepc` names an instruction that has not
executed.

## Interface contract

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `wb_valid_i`, `wb_i` | in | 1, `mem_wb_t` | the finished instruction from MEM. **No ready** — MEM cannot be told to wait |
| `irq_valid_i`, `irq_code_i` | in | 1, 6 | already masked and prioritised by the CSR file |
| `sb_empty_i` | in | 1 | a `fence` holds the commit until memory has drained |
| `rf_wr_o` | out | `rf_wr_t` | the architectural register write |
| `csr_commit_o` | out | `csr_upd_t` | the CSR write EX computed |
| `instret_o` | out | 1 | `minstret` — retired, **not** trapped |
| `sb_commit_o`, `sb_commit_tag_o` | out | 1, `TAG_W` | release the store-buffer entry to drain |
| `flush_o`, `flush_cause_o` | out | 1, `flush_cause_e` | pipeline flush and why |
| `redirect_valid_o`, `redirect_pc_o` | out | 1, `XLEN` | where to resume |
| `trap_req_o`, `mret_o` | out | `trap_req_t`, 1 | the trap request to the CSR file |
| `trap_vec_i`, `mepc_i` | in | `XLEN` | what the CSR file answers with |
| `busy_o` | out | 1 | this stage is holding something; ID's CSR serialisation asks |
| `priv_i`, `order_i`, `rvfi_o` | in/out | — | the trace; `priv_i` is the mode the committing instruction ran in |
| `perf_load_retired_o`, `perf_store_retired_o` | out | 1 | perf events |

**Latency:** none. Combinational, because the MEM/WB register is `s1_mem`'s.
**Backpressure:** none in either direction.

## Behaviour

An instruction commits when it arrives, unless something older takes precedence:

| Condition | What happens |
|---|---|
| a trap on the committing instruction | no register, CSR or store-buffer write; `trap_req_o`; flush to `trap_vec_i` |
| an interrupt pending | taken **in place of** the commit, so `mepc` names an instruction that has not executed |
| `fence` and the store buffer is not empty | the commit is held |
| `mret` | `mret_o`; resume at `mepc_i` |
| otherwise | all six steps above |

x0 is never written, and a trapping instruction writes nothing — SPEC §9.2's rule, applied here
because this is the only place architectural state changes.

## Verification status

| Layer | Status |
|---|---|
| Lint | clean once the shared types are available |
| Unit test | **none** — this module has no unit testbench |
| Integration | every retirement compared against spike, over the whole pipeline |

Verified **through the integrated core**: an RV64I program and a C sorting workload run through the
whole pipeline with every retirement compared against spike on RVFI, with ideal memory and under
random I$/D$ backpressure and latency.

**What integration does not reach.** No trap is taken (`ecall`/`ebreak` are not in the programs), no
interrupt is raised, and `fence` is not held against a non-empty store buffer. Those paths are
written and lint-clean but unverified — which matters here more than in most modules, because the
trap path is the one that must *not* write architectural state.

## Known limitations

- **No unit testbench.** The trap, interrupt and fence paths are the cost. A unit testbench for this
  module was written against an earlier interface — one that wrote into a completion buffer rather
  than committing directly — and did not survive the move to the integrated in-order design.
- **One commit per cycle, in order.** There is no completion buffer, so a multi-cycle unit cannot
  complete out of order: EX stalls on `md_*` until it answers, and the result travels down EX/MEM
  like any other. That is a deliberate simplification of SPEC §9, not an oversight.
- **Interrupts are taken in place of a commit**, so an instruction already finished in MEM/WB is
  discarded and re-executed after `mret`. For a non-idempotent read that has already happened, that
  is a replay — see `s1_mem`'s open question on the same point.

## Open questions

1. **Who owns `flush_cause_e`?** It exists so fetch and the caches can tell a trap from an `mret`
   from a `fence.i`. If the debug module wants it too, it belongs in the package rather than here.
2. **`busy_o` is coarse.** ID's CSR serialisation stalls on it whenever this stage holds anything,
   not only when the CSR in question is in flight. SPEC §8.2 permits that — it says CSR writes
   serialise — but it is worth measuring before it is called fine.
