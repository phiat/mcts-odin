# Changelog

All notable changes to this project will be documented here. Versions follow [SemVer](https://semver.org/) once 1.0 lands; pre-1.0 is `0.MINOR.PATCH-stage`.

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
