# Upstream sync log

mcts-odin's MCTS algorithm is a direct descendant of [autogodin](https://github.com/phiat/autogodin)'s `odin/alpha_go/mcts.odin`, which is itself a port of [ericjang/autogo](https://github.com/ericjang/autogo)'s C++ MCTS. This file tracks what we've inherited and what (if anything) we've consciously diverged from.

## Sync policy

At the start of any focused session, diff against `/home/phiat/lab/may/autogodin/odin/alpha_go/{mcts.odin,go_game.odin}` and look for algorithm-relevant drift:

- PUCT formula
- Virtual loss / leaf-parallel structure
- Dirichlet root noise
- PCR (progressive computation reduction)
- Backup convention (value flipping, perspective handling)
- Evaluator contract

If any of those shift, surface the diff to the user with a recommendation — port-as-is, port-adapted, or skip-as-autogodin-specific. **Do not auto-apply.** The tracking issue is `mcts-odin-w39.4`.

## Last sync — 2026-05-16

Diffed against autogodin commits up through `71bf891` (HEAD on `main`).

### Algorithm: no drift

Autogodin's last MCTS algorithm change was `f8f0308` ("MCTS uses working_board + do/undo_move") on 2026-05-16 — the do/undo lift we extracted. PUCT formula, Dirichlet sampler, virtual loss, PCR, and backup convention are byte-equivalent to ours.

### Cross-language correctness validated upstream

Autogodin commit `0427050` (ydh.4) shipped a 100-game self-play A/B between Odin-MCTS and C++-MCTS at 200 sims/move with a shared uniform-policy evaluator. Result: **50/50/0, Wilson 95% CI [0.404, 0.596]** (brackets 0.5). Combined with the byte-identical Zobrist fingerprint from `random_games_dual`, this closes the GoBoard + MCTS-semantics parity contract between Odin and C++. We inherit this validation by extraction lineage — our algorithm is the same algorithm, just reorganized.

### Our deliberate divergences (all perf, no semantic drift)

These exist in mcts-odin but not autogodin. None are candidates for backport into mcts-odin (we already have them); listing for context.

- **Packed slot storage.** Children/priors stored as packed `[]int / []f32` slices per node instead of `map[int]int` / `map[int]f32`. ~2x faster PUCT scan, no per-call map allocation.
- **SoA hot fields on the Tree.** `N`, `N_virt`, `Q` in parallel `[dynamic]` slices on the Tree, not embedded in `Node`. ~12 hot bytes per child probe instead of ~100.
- **Linear-space priors.** Priors stored as raw probabilities, not `log`. PUCT inner loop skips `math.exp` per slot.
- **Per-tree scratch arena.** Transient MCTS allocations go to `t.scratch_allocator` (a per-tree growing arena), not `context.temp_allocator`. The caller's temp_allocator is never touched. Autogodin still `free_all(context.temp_allocator)`s at the top of `run_simulations`.
- **Subtree reuse.** `mcts.reuse_root(action)` re-roots at the kept child subtree. Requires `root_noised` tracking so Dirichlet noise isn't re-applied on the new root. Autogodin does not have this yet.
- **Branchless PUCT scan.** CMOV-friendly ternary argmax; no data-dependent branches in the inner loop.

### Optional port candidate

- **`autogodin-ydh.7`: `BOARD_SIZE_HINT` comptime scaffolding** for `go_game.odin`. Adds `#config(BOARD_SIZE_HINT, 0)` and `#force_inline` `n_cells` / `board_dim` helpers that fold to compile-time constants when `BOARD_SIZE_HINT > 0`. Pure Go-board optimization — no MCTS implications. Worth porting to our `games/go/board.odin` since the demo bench is the visible perf number. Filed as a follow-up issue.

## Role flipped — 2026-05-16

Autogodin has removed `odin/alpha_go/mcts.odin`. The surviving `odin/alpha_go/` files (`go_adapter.odin`, `exports.odin`, `go_game.odin`, `alpha_go.odin`) only consume mcts-odin via FFI — no algorithm code remains upstream.

Consequences:

- The "watch for upstream MCTS drift" chore (`mcts-odin-w39.4`) is closed with reason "role flipped". This file's "Last sync" sections stop accruing.
- The flow has inverted: **autogodin files beads into this DB** for FFI shape, parity tests, downstream tuning. See `bd memories autogodin` for the channel.
- mcts-odin is now the canonical home of the algorithm. The 2026-05-16 sync section above is the final point-in-time snapshot of the historical relationship.

## Reverse direction (post-integration)

Autogodin's `odin/alpha_go/go_game.odin` is **not** going away — autogodin keeps its own GoBoard. Our `games/go/board.odin` is intentionally a separate, demo-quality copy with no obligation to match line-for-line. Optimizations on either side (e.g. `BOARD_SIZE_HINT`) can be cherry-picked across when worth it, but neither is canonical.
