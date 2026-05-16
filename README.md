# mcts-odin

A generic, optimized Monte Carlo Tree Search package for [Odin](https://odin-lang.org/). AlphaZero-style PUCT with Dirichlet root noise + FPU (First-Play Urgency), optional fast rollouts, leaf-parallel batched playouts with virtual loss, and PCR (progressive computation reduction).

Games plug in by implementing a small `Game` vtable; the core knows nothing about Go, chess, or any specific game. Ships with **tic-tac-toe**, **Connect Four**, **Reversi**, **Hex**, and a **Go** (9×9 / 19×19) reference implementation.

## Status

v0.3.0 + Hex on `main`. Core + five demo games + 73 passing tests under Odin's memory tracker.

### Throughput

9×9 Go, 1600 sims/move × 32 moves, uniform-policy evaluator, single-thread, `-o:speed -no-bounds-check`:

```
mcts-odin (default):   22,611 ± 114 sims/s    (2.67x autogodin cpp, 7.91x autogodin odin)
```

For reference, [autogodin](https://github.com/phiat/autogodin)'s comparable bench (same workload, evaluator marshalled through a Python callback) reports `cpp: 8,470` and `odin: 2,859` sims/s. The numbers aren't strictly comparable — mcts-odin's bench runs the evaluator inline in Odin without FFI — but the cumulative gap reflects the do/undo lift, packed slot storage, SoA hot fields, linear-space priors (no PUCT-loop `math.exp`), per-Tree scratch arena, subtree reuse, branchless argmax, `BOARD_SIZE_HINT`-friendly hot-path helpers, and FPU producing a broader/shallower tree (fewer do_move/undo_move steps per sim).

## Quick start

```odin
package main

import "mcts"
import ttt "games/tictactoe"

main :: proc() {
    g     := ttt.game()             // mcts.Game vtable
    state := ttt.new_state()         // tree takes ownership

    cfg := mcts.default_config()
    tree: mcts.Tree
    mcts.init(&tree, &g, state, cfg, seed = 42)
    defer mcts.destroy(&tree)

    mcts.run_simulations(&tree, 1000, my_evaluator, &g)
    action := mcts.select_action(&tree, temperature = 0.0)
}
```

`my_evaluator` is your value/policy function — see [`examples/tictactoe_selfplay.odin`](examples/tictactoe_selfplay.odin) for a complete runnable example with a uniform evaluator, and [`examples/nn_evaluator_skeleton.odin`](examples/nn_evaluator_skeleton.odin) for the policy/value plumbing pattern a real NN-backed evaluator needs (sequential and batched).

**Evaluator must mask to legal moves.** The MCTS hot path does not re-check legality before calling `do_move` on the chosen slot — a nonzero prior for an illegal action will be silently selected and produce undefined behaviour (panic / no-op / corrupted state, depending on how the game implements `do_move`). NN-backed evaluators must mask their logits to legal moves before normalisation.

## Architecture

```
┌──────────────────────── Tree ───────────────────────┐
│                                                     │
│  working_state ───┐                                 │
│  (owned by tree)  │   single state mutated in       │
│                   │   place via do_move / undo_move │
│                   ▼                                 │
│           ┌─── nodes[] ────┐                        │
│           │ Node 0 (root)  │       Hot fields in    │
│           │  ├─ actions[]  │       parallel SoA on  │
│           │  ├─ priors[]   │       the Tree:        │
│           │  └─ child[]    │         node_N[]       │
│           ├────────────────┤         node_N_virt[]  │
│           │ Node 1, 2, …   │         node_Q[]       │
│           │ (packed slots) │                        │
│           └────────────────┘                        │
│                                                     │
│  arena            permanent: nodes, slot arrays     │
│  scratch_arena    per-run: descent paths, deltas    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

Three deliberate choices drive the throughput:

- **No per-node state copies.** Nodes are pure tree bookkeeping; the tree threads `working_state` through `do_move` on the way down and `undo_move` on the way up. A Go-board clone is several times costlier than a do/undo pair, and a deep tree creates thousands of nodes.
- **Packed slot storage.** Per-node `actions[k] / priors[k] / child[k]` are tightly packed slices, sized at first expansion. Hot fields (`N`, `N_virt`, `Q`) live in parallel arrays on the `Tree`, indexed by node index — the PUCT inner loop reads ~12 bytes per child rather than chasing a full Node struct on every random-access probe.
- **Two arenas per tree.** A growing arena owns nodes and slot arrays for the lifetime of the tree; a separate scratch arena is `free_all`-reset at the top of every `run_simulations` call. The caller's `context.temp_allocator` is never touched.

## Sequential, batched, threaded

```odin
// Sequential — one evaluator call per leaf. Fine for CPU-side policies,
// uniform priors, or any fast in-process value function.
mcts.run_simulations(&tree, 1600, my_evaluator, &g)

// Batched — leaf-parallel with virtual loss; the evaluator gets a slice
// of cloned leaf states per call. Use when the evaluator is expensive
// (e.g. a GPU NN forward pass) and benefits from large batch sizes.
mcts.run_simulations_batched(&tree, 1600, batch_size = 16,
                              my_batched_evaluator, &g)

// OS-thread parallel — N worker threads each run descent / eval / backup
// concurrently. Atomics on N / N_virt / Q + a coarse expand mutex keep the
// shared tree consistent; virtual loss decouples the descents. The supplied
// evaluator is called concurrently from every worker, so its user_data must
// be thread-safe. Determinism is dropped — repeated runs with the same seed
// produce different node visit counts.
mcts.run_simulations_threaded(&tree, 1600, n_threads = 8, my_evaluator, &g)
```

Near-linear scaling on slow evaluators (50 µs/call benchmark, 9×9 Go):
`n=2: 1.93x`, `n=4: 3.81x`, `n=8: 7.15x`. For cheap evaluators (uniform-policy,
microseconds per call) the mutex and CAS-loop contention can erase the
speedup — use the sequential or batched paths there.

All three paths share the same tree, the same Game vtable, and the same readouts (`select_action`, visit counts, Q values, priors).

## The Game vtable

```odin
Game :: struct {
    clone:           proc(state: rawptr) -> rawptr,
    free:            proc(state: rawptr),
    do_move:         proc(state: rawptr, action: int) -> Move_Delta,
    undo_move:       proc(state: rawptr, delta: Move_Delta),
    is_terminal:     proc(state: rawptr) -> bool,
    terminal_value:  proc(state: rawptr) -> f32,  // [0, 1] from side-to-move
    legal_actions:   proc(state: rawptr, out: ^[dynamic]int),
    current_player:  proc(state: rawptr) -> i32,  // 0 or 1 for two-player games
    max_actions:     int,                          // upper bound on action-id
}
```

The MCTS core uses `do_move`/`undo_move` on a single working state per tree — it never clones the state at internal nodes. This is the key performance lever: a Go-board clone (board + Zobrist history map) is several times costlier than a `do_move`/`undo_move` pair, and a deep tree creates thousands of nodes.

See [`docs/EMBEDDING.md`](docs/EMBEDDING.md) for the full contract, evaluator signatures (sequential + batched), subtree reuse (`mcts.reuse_root(action)`), tuning knobs, and memory model.

## Layout

```
mcts/             generic MCTS core (game-agnostic)
  game.odin         Game vtable + Move_Delta
  mcts.odin         Tree / Node / Config + init / destroy + shared driver helpers
  playout.odin      Evaluator type, sequential run_simulations + fast_rollout
  batched.odin      leaf-parallel run_simulations_batched (virtual loss)
  threaded.odin     OS-thread parallel run_simulations_threaded (atomics + expand mutex)
  readout.odin      select_action + visit/Q/priors readouts
  debug.odin        dump_tree_dot / dump_tree_json (experimental)
  rng.odin          gamma sampler + categorical helper
games/
  tictactoe/        3×3 solved-game sanity demo
  connect_four/     7×6 column-drop demo
  reversi/          8×8 Reversi (Othello) with zero-alloc Move_Delta packing
  hex/              9×9 Hex with hex-grid topology and BFS win detection
  go/               9×9 / 19×19 with Zobrist PSK, KataGo no-suicide, Tromp-Taylor scoring
tests/            four test suites (run with: ./scripts/test.sh)
examples/
  tictactoe_selfplay.odin       full self-play loop
  nn_evaluator_skeleton.odin    sequential + batched NN evaluator template
bench/
  bench.odin                    9×9 Go throughput micro-bench vs autogodin baselines
  threaded/                     thread-scaling bench under a slow evaluator
scripts/          build / test helpers
docs/             EMBEDDING.md (full contract) + UPSTREAM.md (sync log)
```

## Build

```bash
./scripts/build.sh           # build/libmcts_odin.so
./scripts/test.sh            # all four suites, fails on leaks
odin test tests/games/connect_four
odin test tests/games/reversi
odin test tests/games/hex
odin test tests/games/go
odin run examples/tictactoe_selfplay.odin -file
odin run examples/nn_evaluator_skeleton.odin -file
odin run bench/threaded -o:speed -no-bounds-check
```

Optimization knobs:

```bash
ODIN_OPT="-o:speed -no-bounds-check" ./scripts/build.sh
```

## Why this exists

Most MCTS implementations are tied to a specific game (chess, Go, board engines). The handful of game-agnostic ones live in Python, JAX, or C++. As of mid-2026 nothing similar exists in the Odin ecosystem — and Odin's combination of manual memory control, slice-based hot paths, and inline ASM/SIMD friendliness makes it a natural fit for the inner loop of a search.

The core algorithm is a direct descendant of the MCTS in [ericjang/autogo](https://github.com/ericjang/autogo) (C++) via [autogodin](https://github.com/phiat/autogodin) (Odin port). This repo lifts the algorithm into a stand-alone, game-agnostic package.

## License

MIT. See [LICENSE](LICENSE).
