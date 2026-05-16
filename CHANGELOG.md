# Changelog

All notable changes to this project will be documented here. Versions follow [SemVer](https://semver.org/) once 1.0 lands; pre-1.0 is `0.MINOR.PATCH-stage`.

## [0.1.0-dev] — unreleased

Initial extraction from [autogodin](https://github.com/phiat/autogodin), reshaped into a stand-alone, game-agnostic Odin MCTS package.

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

### Known limitations

- Single-threaded (leaf-parallelism is algorithmic only, not OS-thread parallel).
- Bench includes only an in-process Odin evaluator; numbers vs autogodin aren't strictly apples-to-apples (theirs marshals via Python).
- `math.exp(logP[k])` is still called every PUCT iteration. Caching the un-logged prior on the Node is a future win (tracked as a follow-up under `z24.x`).
