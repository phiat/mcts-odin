# Changelog

All notable changes to this project will be documented here. Versions follow [SemVer](https://semver.org/) once 1.0 lands; pre-1.0 is `0.MINOR.PATCH-stage`.

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
