# Changelog

All notable changes to this project will be documented here. Versions follow [SemVer](https://semver.org/) once 1.0 lands; pre-1.0 is `0.MINOR.PATCH-stage`.

## [0.7.0] — 2026-05-17

Minor release: a 2.67× single-thread throughput lift on the 9×9 Go bench (~108k → ~289k sims/s) from replacing per-call group flood-fill with incremental per-block liberty tracking. No existing API surface changed; test count 137 → 148.

### Changed

- **Go: incremental liberty tracking (`games/go/blocks.odin`, `games/go/board.odin`).** Replaces `get_group_and_liberties` flood-fill on the hot path with a union-find per cell (`parent[]` points directly at root — no path compression, keeps journaling trivial) + a circular `block_next[]` linked list for traversal + a compile-time-folded `blk_libs[root]` liberty bitset (`BOARD_SIZE_HINT`-aware: 2 u64 words for 9×9, 6 words for 19×19) + `blk_size[root]`. `do_move` journals every parent / block_next / blk_libs / blk_size mutation on four per-board stacks; `undo_move` pops in reverse to restore exact pre-move state. `is_legal_flat` does at most 4 bitset reads + a popcount per neighbor block, no flood-fill. `play_flat_unchecked` routes through `do_move` and drops the journal (forward-only path), keeping `b.blocks` in sync without duplicating the algorithm. 9×9 Go bench: 108k → 289,262 ± 5,381 sims/s (2.67×, vs. the 1.5–1.8× target). Closes mcts-odin-81j.9.

### Added

- **Do/undo round-trip tests** for the union-find replay cases (`tests/games/go/go_game_test.odin`): `do_undo_multi_group_merge` (placement joins 2 friendly groups), `do_undo_multi_group_capture` (one move captures 2 separate opp groups via shared liberty), `do_undo_three_friendly_merge` (placement bridges 3 friendly groups in a cross), and `do_undo_random_selfplay_50` (50 deterministic-LCG moves + full unwind, bit-for-bit board equality). Plus 7 `BlockIndex` tests in `tests/games/go/blocks_test.odin` covering rebuild + consistency-vs-flood-fill across empty / single / chain / separate-groups / post-capture / 30-move random / clone.

## [0.6.0] — 2026-05-17

Minor release: one new demo game. All additive — no existing API surface changed. Demo-game count goes 10 → 11; test suite 126 → 137.

### Added

- **Nine Men's Morris** (`games/morris/`) — classic 24-point board with three explicit game phases. First demo with **phase transitions that reshape `legal_actions` mid-game** (placement → sliding → flying), and first where **one MCTS action atomically contains a follow-up sub-action by the same player** (mill formation → opponent-piece removal). Includes the standard "cannot remove an opponent piece in a mill *unless* every opponent piece is in a mill" exception. Action encoding packs `(from, to, remove)` into a 15625-id space with `24` as the NONE sentinel; `legal_actions` enumerates only the real triples.

## [0.5.0] — 2026-05-16

Minor release: three new demo games + an onboarding guide. All additive — no existing API surface changed. Demo-game count goes 7 → 10; test suite 94 → 124.

### Added

- **Dots and Boxes** (`games/dots_and_boxes/`) — 4×4 dot grid / 3×3 = 9 boxes. First demo where **`to_play` does not flip every move**: closing a box gives the mover an extra turn, breaking the alternation invariant. Surfaces any latent assumption in the MCTS core that to_play parity tracks move count — exercised by `mcts_self_play_terminates`. Action space is 24 edge ids. Closes mcts-odin-ap2.

- **Amazons** (`games/amazons/`) — 6×6 board, 2 amazons per side (Walter Zamkauskas, 1988). First demo with **two-stage moves** (queen slide + arrow shot, encoded as `from*36*36 + to*36 + arrow`) and a **terminal condition decided by `has_legal_move()`** rather than a board pattern or piece count. The loser is whoever is `to_play` when `is_term` flips true. Action space is 46 656 — most illegal at any moment; `legal_actions` enumerates only the legal triples. Closes mcts-odin-5dy.

- **Quoridor** (`games/quoridor/`) — 5×5 board, 5 walls per side. First demo with a **heterogeneous action space** (25 pawn targets + 32 wall slots share one 57-wide id space) and **per-candidate BFS validation** for wall legality — every wall must preserve a path to goal row for both players. Pawn moves cover the full Quoridor rule set including jump-over-opponent and diagonal-slide-when-blocked. Closes mcts-odin-yau.

- **`docs/GETTING_STARTED.md`** — reading-and-running onboarding path. Five-minute orientation → run tic-tac-toe / tests / bench → read the algorithm (`mcts.odin` → `playout.odin` → `config.odin`) → table of demo games by complexity → evaluator/embedding pointers → the three load-bearing pitfalls (evaluator masking, do/undo exactness, `terminal_value` POV). Linked from README Quick start.

## [0.4.2] — 2026-05-16

Patch release: three perf cleanups + one Go-board data-structure swap. No stable-surface changes. Bench ~108k sims/s on 9×9 Go (single-thread, uniform evaluator) vs ~105k at v0.4.1.

### Changed

- **Go: PSK `seen_hashes` map → flat u64 set (+3-5% bench).** Replace the per-board `map[u64]struct{}` with an open-addressing flat hash set (linear probing, backward-shift deletion, no tombstones). Zobrist keys come out of `splitmix64` already well-mixed, so the probe index is just `key & mask` — no extra hash function. Sentinel is `u64(max(u64))`; real-key collision probability is 2^-64 and asserted against in `ODIN_DEBUG` builds. Per-call ns drops `Legal_Actions 6204 → 5852`, `Do_Move 687 → 630`, `Undo_Move 124 → 113`. Smaller bench win than the initial 25% estimate — Odin's `map[u64]` is faster than expected — but the flat set also kills per-insert allocations and simplifies clone/destroy. Closes mcts-odin-81j.2.

- **MCTS RNG: `core:math/rand` → inlined xoshiro256++.** Tree and Worker now hold `Xoshiro256pp` state (4×u64) plus a `NormalCache` for the polar Marsaglia sampler. `gamma_sample` / `sample_packed_action` take explicit RNG pointers instead of binding via `context.random_generator`. `use_tree_rng` removed. Bench-neutral on the default 9×9 Go workload (`dirichlet_alpha = 0`, `lambda = 0` → no RNG calls), but ~5-10ns saved per call on Dirichlet- or fast-rollout-heavy training configs. The random stream changes — no determinism tests check golden RNG outputs. Closes mcts-odin-81j.3.

- **Dirichlet sampler batched.** `add_dirichlet_noise` precomputes the Marsaglia-Tsang constants (`d`, `c`) once instead of per-sample, inlines the gamma inner loop, and folds normalization into the prior-mix step. On Dirichlet-enabled configs: ~100ns saved per root slot per noise call (~36 µs for 19×19 Go's 362 slots). Closes mcts-odin-81j.6.

## [0.4.1] — 2026-05-16

Patch release: a single Go-board perf win + a new profile harness. No stable-surface changes.

### Changed

- **Go: `is_legal_flat` rewritten — 2.3× bench speedup.** Replaced the clone-and-simulate path (board slice + `seen_hashes` map clone per candidate, then `play_flat_unchecked` and inspect) with an in-place test: capture detection flood-fills opp neighbour groups once, suicide is decided from friendly-group liberty counts, and the would-be PSK hash is computed incrementally (`current_hash XOR placed XOR captured stones`). 9×9 Go bench goes 45.3k → 105k sims/s (single-thread, uniform evaluator). Per-call `legal_actions` cost drops 33µs → 6µs in the profile harness. Closes mcts-odin-81j.8 (step 1).

### Added

- **`bench/profile/`** — wrapped-vtable timing harness. Drops timers around every Game-vtable entry point and the evaluator, then reports ms / %wall / calls / ns-per-call per bucket. The residual after measured buckets is the MCTS-core cost (PUCT, expand, create_node, backup). Used to anchor v0.5 perf picks in measurement rather than static-analysis guesses; closes mcts-odin-81j.7.
- **`multi_group_merge_with_surviving_liberty`** test — regression coverage for the suicide-check path in the new `is_legal_flat`, where two friendly groups meet at the placed stone and one provides the surviving liberty. Go suite goes 25 → 26 tests (total 93 → 94).

## [0.4.0] — 2026-05-16

Minor release: three new demo games (Hex, Breakthrough, Gomoku) wrap up the v0.4 roadmap (`mcts-odin-coj`). All additive — no existing API surface changed. Demo-game count goes 4 → 7; test suite 64 → 93.

### Added

- **Hex** (`games/hex/`) — 9×9 board (Piet Hein 1942 / John Nash 1948). First demo with **hexagonal-grid topology**: each cell has 6 neighbours via the skewed-rhombus convention. Win detection is connectivity-based — BFS from the placed stone over same-color cells, checking edge contact. No draws (Hex theorem). Closes mcts-odin-59x.

- **Breakthrough** (`games/breakthrough/`) — 8×8 board (Dan Troyka, 2000). First demo with **piece movement**: 16 pawns per side, each moves one square forward (straight to empty or diagonal to empty/enemy). Win by reaching the opponent's back rank or capturing all enemy pawns. Action encoding is `from_cell × direction` (192 stable ids) with `forward_delta(player, dir)` mapping to player-aware row deltas. Closes mcts-odin-8ah.

- **Gomoku** (`games/gomoku/`) — 15×15 board, Free ruleset. First demo with **large branching factor** (225 actions at the opening) — exercises MCTS scaling under uniform priors. Win by 5-or-more in a row in any of the 4 directions; overlines count. Closes mcts-odin-iqd.

All three use zero-allocation Move_Delta packing — flags pack action + prev_to_play + prev_winner + prev_move_count + per-game state bits.

### Tests

`scripts/test.sh` now runs seven suites. New tests cover opening invariants, do/undo round-trips, all four win-direction patterns where applicable, and full MCTS self-play to termination for each game.

## [0.3.0] — 2026-05-16

Minor release: OS-thread parallel MCTS lands. Additive — no existing API surface changed.

### Added

- **`mcts.run_simulations_threaded`** — third search driver. N OS threads each run descent / eval / backup concurrently against the same tree. Atomics on N / N_virt / Q + a coarse expand mutex around node creation keep shared state consistent; virtual loss decouples the descents. The evaluator is called concurrently from every worker, so its `user_data` must be thread-safe. Determinism is dropped (different thread interleavings → different per-node visit counts), but the total visit count is exact (atomic claim counter). Closes mcts-odin-79j.

  Scaling on a slow-evaluator microbench (9×9 Go, 50 µs per call, this WSL2 box): `n=2: 1.93x`, `n=4: 3.81x`, `n=8: 7.15x` vs. sequential. Cheap-evaluator workloads (microsecond-scale) won't see this — the mutex + CAS contention matches or exceeds the work.

- **`bench/threaded/`** — standalone scaling bench for `run_simulations_threaded` with a configurable per-call spin to model NN evaluator latency. Build: `odin run bench/threaded -o:speed -no-bounds-check`.

- **Test coverage**: 4 new tests — `ttt_threaded_one_worker_runs`, `ttt_threaded_multi_worker_total_visits`, `ttt_threaded_self_play_terminates`, `c4_threaded_stress` (8 workers × 1000 sims on Connect Four, validates child-visit sum and Q-bounds under contention). Suite count 60 → 64.

### Changed (internal)

- **`create_node` now takes the working state as an argument** rather than reading `t.working_state` directly. Sequential and batched callers pass `t.working_state` (no behaviour change); threaded callers pass their per-worker clone. Private internal — not part of the stable surface.

### Docs

- README "Sequential vs batched" section becomes "Sequential, batched, threaded" with the third driver documented inline.
- `docs/EMBEDDING.md §9` (Threading) rewritten from "not yet" into a usage section covering the evaluator-thread-safety contract, the cheap-vs-expensive evaluator tradeoff, the dropped-determinism caveat, and the measured scaling numbers.

## [0.2.1] — 2026-05-16

A patch release: one new demo game, one bench bug fix, one documentation example. No stable-surface changes.

### Added

- **Reversi (Othello) demo game** in `games/reversi/`. 8×8, standard opening, eight-direction flip cascade, PASS_ACTION = 64, two-pass termination. Zero-allocation `Move_Delta` packing: the flipped-cell set fits in a `u64` bitmask in `hash`, prev-state bits ride in `flags`. 7 tests pass under the memory tracker. Brings the demo-game count to four. Closes mcts-odin-dun.
- **NN evaluator skeleton** at `examples/nn_evaluator_skeleton.odin`. Runnable template covering both sequential and batched evaluator paths with a mocked forward pass. Shows legal-move masking, numerically-stable softmax over masked logits, and the `user_data` pattern for carrying model handles. Replace `mock_nn_forward` with your ONNX / libtorch / Python-FFI call and the surrounding code is unchanged. Linked from `README.md` and `EMBEDDING.md §3`. Closes mcts-odin-m70.

### Fixed

- **`bench/bench.odin` trials degraded across runs.** `uniform_evaluator` allocated a small `[dynamic]int` on `context.temp_allocator` 51,200 times per trial; the MCTS core never resets that arena, so trial 5 was running at ~40% of trial 1's rate due to paging. Added `defer free_all(context.temp_allocator)` at the top of `run_trial`. That uncovered a secondary bug — main's `rates` slice was on the same arena, so the per-trial reset was freeing it underneath us and the printed mean/std were reading freed memory. Moved `rates` to the default allocator. Bumped warmups 1 → 2 since trial 1 still showed a cold-page warmup cost. Local re-run: **45,286 ± 2,071 sims/s** (4.6% std, was 28%). Closes mcts-odin-brj.

### Docs

- **Upstream role flip complete.** `docs/UPSTREAM.md` updated — autogodin removed its own `odin/alpha_go/mcts.odin` and now consumes mcts-odin via FFI. The "watch for upstream MCTS drift" chore is retired; mcts-odin is the canonical home of the algorithm. Closes mcts-odin-w39.4 and the bootstrap epic mcts-odin-w39.

## [0.2.0] — 2026-05-16

A minor release with one substantive algorithm change. **Behaviour-affecting**: callers who pin 0.1.x and upgrade will see different per-game play even with the same seed.

### Changed (algorithm)

- **First-Play Urgency (FPU) replaces the q=0 default for unvisited children.** PUCT used to default unvisited children's Q to 0; under a uniform evaluator (or any near-uniform prior + value≈0.5) this caused every sim to funnel into the first-touched slot — the visited slot's Q=0.5 dwarfed any exploration bonus until √N_total ≥ ~41. New formula (Leela / KataGo style):

  ```
  q_fpu = (1 - parent_Q_stored) - fpu_reduction * sqrt(sum_visited_priors)
  ```

  New `Config.fpu_reduction` knob, default `0.25` (KataGo non-root). The same shape applies to the leaf-parallel variant (`select_slot_puct_vloss`). Closes mcts-odin-caq.

  This replaces the q=0 default wholesale — there is no `fpu_reduction` value that reproduces the old AlphaGo Zero default. The change is documented inline on `Config`.

### Added

- **`Config.fpu_reduction: f32`** (additive struct field, default `0.25`).
- **Tree introspection dumps** (`mcts.dump_tree_dot`, `mcts.dump_tree_json`) in `mcts/debug.odin`. Both return caller-owned strings; pipe to Graphviz or parse with `core:encoding/json`. Documented in `EMBEDDING.md §8`. API stability: experimental. Closes mcts-odin-7gf.

### Bench

```
mcts-odin (default):    22,611 ± 114 sims/s    (2.67x autogodin cpp, 7.91x autogodin odin)
```

The 1.6-2× jump over 0.1.1's 14,052 is mostly a measurement artifact: pre-FPU MCTS was spending all its time deep in the slot-0 corner subtree, so each sim traversed less depth per backup. With FPU the tree is broader/shallower and more representative of well-conditioned MCTS work. The bench has higher variance now because the tree shape depends on board state.

### Migration

If you relied on mcts-odin's 0.1.x play being reproducible against an external A/B harness (e.g. autogodin's cross-language A/B), expect different per-game outcomes. Set `cfg.fpu_reduction = 0` for a less aggressive FPU (unvisited q = parent_Q exactly, no reduction) but you cannot get back the q=0 default — that has been removed.

## [0.1.1] — 2026-05-16

A patch release with two real bug fixes in the stable API plus accumulated internal perf and documentation. No stable-surface changes.

### Fixed

- **`select_action` was silently non-reproducible at temperature > 0.** The categorical-sampling path iterated a `map[int]f32` (returned by `get_action_probabilities`); Odin's map iteration order is undefined, so even with a fixed RNG seed the sampled action could vary across runs. Rewrote to iterate the root's packed slot list in deterministic order. Closes mcts-odin (reviewer finding F4).
- **`get_child_max_subtree_depths` leaked onto caller's `context.temp_allocator`.** Violated the documented "MCTS never touches caller's temp_allocator" invariant. Switched to `t.scratch_allocator` like every other transient allocation. (reviewer finding F5)

### Changed (internal)

- **SoA hot fields on the Tree.** `Node.N`, `Node.N_virt`, and `Node.Q` moved into parallel `[dynamic]` slices on the `Tree` (`t.node_N`, `t.node_N_virt`, `t.node_Q`). The PUCT inner loop reads ~12 hot bytes per child probe instead of the full ~100-byte Node struct. Bench: 13,605 → 13,837 sims/s, 4.7× tighter variance. Closes mcts-odin-z24.3.
- **`cp_at_node` cached on Node.** `terminal_value_for_node` and several expand/backup sites no longer depend on `working_state`'s position — robustness against future callers. Closes mcts-odin-gyk.
- **Go adapter: one alloc per do_move instead of two.** Captures stack hoisted onto `GoBoard.captures`; `Adapter_Delta` drops its embedded `[dynamic]CaptureRecord`. Closes mcts-odin-6v6.
- **`BOARD_SIZE_HINT` comptime board-size scaffolding** in `games/go/board.odin`. `#config(BOARD_SIZE_HINT, 0)` + `#force_inline contextless` `n_cells`/`board_dim` helpers fold to constants when set. Bench: ~+37% with `-define:BOARD_SIZE_HINT=9` on clean trials. Closes mcts-odin-d4n.

### Added

- **API stability contract.** `docs/EMBEDDING.md §9` documents the stable surface (committed for 0.x) vs experimental surface (may shift before 1.0). Every exported decl in `mcts/*.odin` now carries an `API stability: stable | experimental` doc marker. Versioning policy documented. Closes mcts-odin-il0.
- **Sibling-import via `-collection:`.** `docs/EMBEDDING.md §1` documents three import paths — collection-based (recommended), relative path, vendor copy — verified end-to-end with a `/tmp` smoke test. Closes mcts-odin-dsg.
- **`docs/UPSTREAM.md`.** Records the autogodin sync policy + the 2026-05-16 sync state (MCTS algorithm: no drift since extraction). Notes the role flip — autogodin is integrating mcts-odin as an Odin dep and removing its own MCTS Odin code.

### Bench

```
mcts-odin (default):   14,052 ± 48  sims/s    (1.66x autogodin cpp, 4.91x autogodin odin)
mcts-odin (HINT=9):    ~19,000      sims/s    on clean CPU (build with -define:BOARD_SIZE_HINT=9)
```



## [0.1.0] — 2026-05-16

Initial release. Extracted from [autogodin](https://github.com/phiat/autogodin) and reshaped into a stand-alone, game-agnostic Odin MCTS package.

### Added

- **Generic MCTS core** (`mcts/`)
  - `Game` vtable over opaque `rawptr` state. Two-player perfect-info zero-sum is the primary target; multi-player is a future extension.
  - `Tree` / `Node` / `Config`. Packed slot storage (`actions[k]`/`logP[k]`/`child[k]`) — no `map[int]*` on the hot path.
  - `run_simulations` — sequential AlphaZero-style playout: PUCT, Dirichlet root noise, optional fast rollouts (`lambda` mix), PCR (categorical-mix of per-move sim counts).
  - `run_simulations_batched` — leaf-parallel with virtual loss; batched evaluator gets a slice of cloned leaf states per call.
  - `select_action`, `get_action_probabilities`, `get_child_visit_counts`, `get_child_q_values`, `get_child_first_eval_values`, `get_root_policy_priors`, `get_child_max_subtree_depths`.
  - Per-tree growing arena owns nodes and per-node slot arrays; per-tree scratch arena holds simulation-transient allocations and is `free_all`-reset at each `run_simulations` entry.
  - Working-state model: nodes carry no state copy; the tree mutates a single working state with `do_move`/`undo_move` along each descent.

- **Reference games**
  - `games/tictactoe/` — solved-game sanity demo.
  - `games/connect_four/` — 7×6 column-drop demo.
  - `games/go/` — 9×9/19×19 with Zobrist-incremental positional superko, KataGo-aligned no-suicide, Tromp-Taylor area scoring.

- **Tests** — 43 cases across three suites, run clean under Odin's memory tracker.
- **Bench** — `bench/bench.odin` replicates the autogodin micro-bench (9×9, 1600 sims/move × 32 moves, uniform evaluator). Single-thread, `-o:speed -no-bounds-check`: **~13,300 sims/s** (≈1.57× autogodin's C++ baseline, ≈4.6× autogodin's prior Odin port).
- **Docs** — `README.md`, `docs/EMBEDDING.md`.
- **CI** — GitHub Actions workflow pinned to Odin `dev-2026-05`.

### Performance levers landed for 0.1

- `do_move`/`undo_move` lifted into the `Game` vtable; MCTS threads a single working state instead of cloning at every node creation.
- Children/priors stored as packed slot arrays.
- Per-Tree evaluator scratch buffers (`eval_a_buf`, `eval_p_buf`) sized to `game.max_actions`, reused for every evaluator call.
- Per-Tree scratch arena for transient allocations; caller's `context.temp_allocator` untouched.
- Cached `is_terminal` and raw `terminal_value` on each node at creation time.
- Subtree reuse across moves: `mcts.reuse_root(action)` re-roots the tree at the kept child subtree (or allocates a synthetic root if the slot was unexpanded). Depths renormalised so `max_depth` stays meaningful. Prior visit counts and Q values inform PUCT immediately on the next search round.
- Node pool reserve: `t.nodes` capacity reserved up front at each `run_simulations` entry, avoiding the doubling-realloc chain as the tree grows.
- Branchless PUCT scan: `select_slot_puct` / `select_slot_puct_vloss` use CMOV-friendly ternary argmax with no data-dependent control flow in the inner loop.
- Linear-space priors on `Node.priors[k]` (renamed from `Node.logP[k]`). Drops the `math.exp` from the PUCT inner loop; Dirichlet noise mixes directly in prior space.

### Bench (9×9 Go, 1600 sims/move × 32 moves, uniform evaluator, single-thread)

```
mcts-odin:  13,602 ± 87 sims/s    (1.61x autogodin cpp, 4.76x autogodin odin)
```

### Known limitations

- Single-threaded (leaf-parallelism is algorithmic only, not OS-thread parallel).
- Bench includes only an in-process Odin evaluator; numbers vs autogodin aren't strictly apples-to-apples (theirs marshals via Python).
