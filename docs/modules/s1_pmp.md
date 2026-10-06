# `s1_pmp`

| | |
|---|---|
| **Status** | WIP (unit-verified; used by `s1_mem_stage`) |
| **Authorship** | see the file header (`Author(s)` / `Modified By`) — CODING_STANDARD.md §5 |
| **Project** | R-02 (load/store unit, store buffer, PMP and atomics) |
| **Spec** | privileged spec §3.7; SPEC §11 |
| **Source** | `rtl/core/s1_pmp.sv` |
| **Testbench** | `verif/unit/tb_s1_pmp.sv`: 121 067 checks |

## Purpose

One access in, one allow/deny out. The lowest-numbered matching PMP entry decides and must cover
every byte of the access; with no match, M-mode passes and S/U fail.

It is a separate module for two reasons. The data path is not the only caller — instruction fetch
needs the same check on the instruction address, with X instead of R or W — and a check that can be
unit-tested on its own is worth more than one buried in a pipeline stage. It lived inside
`s1_mem_stage` first, and was pulled out in review for exactly those two reasons.

## Interface contract

| Signal | Dir | Width | Meaning | Contract |
|---|---|---|---|---|
| `addr_i` | in | `XLEN` | first byte of the access | no alignment assumed |
| `size_i` | in | 3 | log2 bytes | the access covers `[addr_i, addr_i + 2**size_i)` |
| `rd_i` | in | 1 | the access needs R | |
| `wr_i` | in | 1 | the access needs W | an AMO sets both |
| `ex_i` | in | 1 | the access needs X | the fetch path; `s1_mem_stage` ties it low |
| `priv_i` | in | `priv_lvl_e` | effective mode | `mstatus.MPRV` already applied by the caller |
| `pmpcfg_i` | in | `REGIONS` × 8 | the `pmpcfg` CSRs | WARL legalisation — granularity, locked-entry writes — is the CSR file's job |
| `pmpaddr_i` | in | `REGIONS` × (`PLEN`-2) | the `pmpaddr` CSRs | as the CSR file holds them, i.e. address >> 2 |
| `allow_o` | out | 1 | the access is permitted | |

**Latency:** none. Purely combinational, so a caller can place it beside its own address
generation.
**Reset state:** no state.

## Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `REGIONS` | `PMP_N` (16) | 0–64 (elaboration error above 64) | implemented entries. **0 means nothing is restricted**, including for S and U — the configuration a core without PMP is built with |

## Behaviour

For each entry, lowest-numbered first:

| `pmpcfg[4:3]` | mode | range |
|---|---|---|
| `00` | OFF | never matches |
| `01` | TOR | `[pmpaddr[i-1] << 2, pmpaddr[i] << 2)`; for entry 0 the base is 0 |
| `10` | NA4 | 4 bytes at `pmpaddr << 2` |
| `11` | NAPOT | base and size from the trailing ones of `pmpaddr` |

An entry **matches** when any byte of the access falls in its range. The first matching entry
decides, and the access is allowed only if **every** byte is in that entry's range — a request
straddling two entries is denied even when both would permit it on their own. That is the privileged
spec's rule, and it is the one people get wrong.

Permissions: M-mode is bound only by a locked entry (`pmpcfg[7]`). Below M, every permission the
access asks for must be granted by the deciding entry. `pmpcfg[6:5]` are reserved and have no
behaviour here.

Bounds are compared at `XLEN+2` bits, so a NAPOT entry covering the whole address space still has a
top above its base.

## Exceptions and errors

None. It reports a verdict; turning a denial into `EXC_LOAD_ACCESS_FAULT` or
`EXC_STORE_ACCESS_FAULT` is the caller's job, because only the caller knows what kind of access it
was.

## Verification status

| Layer | Status | Where |
|---|---|---|
| Lint | clean, no waivers | `make lint` |
| Unit test | **121 067 checks**; four instances at `REGIONS` 0, 1, 4 and 16 | `verif/unit/tb_s1_pmp.sv` |
| Mutation | 11 hand-inserted bugs, 11 caught | table below |
| Integration | via `tb_s1_mem_stage` (891 978 checks) | `verif/unit/tb_s1_mem_stage.sv` |
| Co-simulation, arch tests | not yet | needs the rest of the core |

The model decides byte by byte and derives a NAPOT range by **counting trailing ones** in
`pmpaddr`; the RTL derives it with **mask arithmetic**. Neither shares code with the other, so a
mistake in one shows up as a mismatch.

- **Directed.** No entries implemented. All entries OFF, for M and for U. NA4 inside, outside,
  exactly covering, straddling the top, straddling the bottom. TOR from entry 0 (base zero) and TOR
  bounded by the entry below, at both ends of the range. NAPOT at every size from 8 bytes to 1 MiB,
  checked at the first and last covered doubleword and just outside at both ends. NAPOT covering the
  whole address space. A locked entry binding M for W and X but not R, and the same entry unlocked.
  Each of R, W and X granted only by its own `pmpcfg` bit. The lowest matching entry deciding even
  when a later one is more permissive, and a non-matching lower entry being skipped. An access
  straddling two adjacent NA4 entries. No entry matching, for M and for U.
- **Every case** sweeps all eight R/W/X request combinations at both privilege levels.
- **Random.** 1 200 fuzzed maps × 24 accesses each, every entry randomised across OFF/TOR/NA4/NAPOT
  with random permissions and lock bits. All coverage bins hit: the last run saw 15 615 allows and
  13 185 denials, 14 316 execute requests, and every addressing mode and the lock bit on every
  entry.

Mutants, each a lint-clean copy of `s1_pmp.sv` with one change:

| Mutant | Bug injected | Caught by |
|---|---|---|
| highest matching entry wins | `!hit && any` becomes `hit \|\| any`, so the last match decides | `REGIONS=4` |
| partial coverage accepted | `all` computed with `\|\|` instead of `&&` | `REGIONS=1` |
| M ignores the lock bit | the `pmpcfg[7]` term dropped from the M-mode case | `REGIONS=1` |
| NAPOT one granule short | the `+1` dropped from the NAPOT top | `REGIONS=1` |
| no match denies M too | the default verdict becomes 0 instead of `priv == M` | `REGIONS=1` |
| TOR base from its own entry | `pmpaddr[i]` instead of `pmpaddr[i-1]` as the lower bound | `REGIONS=1` |
| NA4 is eight bytes | NA4 range 8 bytes wide | `REGIONS=1` |
| X checked against the R bit | execute permission read from `pmpcfg[0]` | `REGIONS=1` |
| W checked against the R bit | write permission read from `pmpcfg[0]` | `REGIONS=1` |
| access twice its size | `a_hi` computed one shift too far | `REGIONS=1` |
| NAPOT entries treated as OFF | the OFF test compares against `2'b11` | `REGIONS=1` |

Two mutants I first wrote were not fair tests and were replaced: dropping `!hit` or `all &&`
entirely leaves a signal unread, which `-Wall` rejects before the testbench runs, and forcing the
OFF test true changes nothing because an OFF entry already has `r_lo == r_hi`. All eleven above are
lint-clean, so the testbench catches them.

One testbench bug found and fixed while writing it: `8'h1F` is NAPOT (`A = 11`), not NA4
(`A = 10`), so a directed "straddling" case was actually covered by an 8-byte NAPOT region and was
correctly allowed. The model and the RTL agreed; only the hand-written expectation was wrong. NA4
with R|W|X is `8'h17`.

## Known limitations

- **No `mseccfg`.** `MML`, `MMWP` and `RLB` (Smepmp) are not implemented, so M-mode is bound only
  by the lock bit and there is no machine-mode lockdown. When Smepmp is added, the permission
  decision is the only part that changes.
- **Granularity is not enforced here.** If the CSR file permits a `pmpaddr` the implementation's `G`
  does not support, this module will honour it. WARL belongs with the CSRs.
- **No `pmpaddr` for TOR entry 0 below itself.** For entry 0 the base is 0, per spec. A TOR entry
  whose `pmpaddr` is below the entry below it describes an empty range and never matches, which is
  also per spec.
- **Combinational, and on the caller's critical path.** `REGIONS` × two `XLEN+2`-bit compares in
  parallel. In `s1_mem_stage` this sits beside the D$ request, which SPEC §11 intends; if it does
  not meet timing there, registering the verdict is the first thing to try.
- Tested at `XLEN = 64`, `PLEN = 40`, `REGIONS` 0, 1, 4 and 16.

## Open questions

1. **Should the fetch path share this instance or have its own?** Two instances cost two sets of
   comparators; one instance needs a mux on the address and the R/W/X request, and makes fetch and
   MEM contend. With `REGIONS = 16` the comparators are not cheap, so this is worth measuring rather
   than assuming. T-01 should decide.
2. **`size_i` is 3 bits, so the largest access is 128 bytes.** Enough for every scalar access and
   for a 64-byte cache block, but a `Zicbom` operation on a larger block, or a vector access checked
   in one go, would need more. Widening it is free; it is 3 bits because nothing needs 4 yet.
