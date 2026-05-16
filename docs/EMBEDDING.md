# Embedding mcts-odin

How to drop the package into your own Odin project, and how to expose it through C/Python if you need to.

## 1. Get the source into your project

There's no Odin package manager. Two options:

**Sibling clone.** Clone `mcts-odin` next to your project and import with relative paths:

```
my-project/
  src/main.odin           import "../../mcts-odin/mcts"
mcts-odin/
  mcts/
```

**Vendor.** Copy `mcts/` (and any `games/` you want) into your project's `vendor/` tree and import with normal paths. Pin a commit hash in your README.

Either way, only the `mcts/` directory is mandatory. `games/`, `tests/`, `examples/`, and `bench/` are optional and exist for development/demo.

## 2. Implement the `Game` vtable

The whole API surface for plugging in a new game is in [`mcts/game.odin`](../mcts/game.odin):

```odin
Game :: struct {
    clone:           proc(state: rawptr) -> rawptr,
    free:            proc(state: rawptr),
    do_move:         proc(state: rawptr, action: int) -> Move_Delta,
    undo_move:       proc(state: rawptr, delta: Move_Delta),  // may be nil
    is_terminal:     proc(state: rawptr) -> bool,
    terminal_value:  proc(state: rawptr) -> f32,             // [0, 1] from side-to-move
    legal_actions:   proc(state: rawptr, out: ^[dynamic]int),
    current_player: proc(state: rawptr) -> i32,              // 0 or 1
    max_actions:     int,                                     // for buffer sizing
}
```

Conventions:

- **State is opaque.** MCTS only sees `rawptr`. Allocate however you like.
- **`current_player` and player ids.** Two-player zero-sum games return 0 or 1. Value backups flip on each ply, so consistency is what matters, not the specific labels.
- **`terminal_value` perspective.** Always from `current_player`'s point of view. In a position where the side to move has just been checkmated / lost, return `0.0`. Draw is `0.5`.
- **`do_move` doesn't validate.** MCTS only calls it with actions returned by `legal_actions`, so you can skip legality checks on the hot path.
- **`Move_Delta` is yours.** MCTS hands the delta back to `undo_move` unchanged. Pack whatever state you need to reverse the move (e.g., captures, hash, prior to-move). Three slots are provided: `hash: u64`, `flags: u64`, `extra: rawptr`.

See [`games/tictactoe/tictactoe.odin`](../games/tictactoe/tictactoe.odin) for a ~100-line worked example.

## 3. Drive the search

```odin
import "mcts"

g := my_game.game()
state := my_game.new_state()

cfg := mcts.default_config()
cfg.c_puct = 1.5
cfg.dirichlet_alpha = 0.3
cfg.dirichlet_weight = 0.25

tree: mcts.Tree
mcts.init(&tree, &g, state, cfg, seed = 42)
defer mcts.destroy(&tree)

mcts.run_simulations(&tree, 1000, my_evaluator, my_user_data)
action := mcts.select_action(&tree, temperature = 0.0)
```

The evaluator is a single proc:

```odin
my_evaluator :: proc(
    state:       rawptr,
    out_actions: []int,
    out_probs:   []f32,
    out_value:   ^f32,
    user_data:   rawptr,
) -> int {
    // write up to game.max_actions entries to out_actions/out_probs,
    // set out_value^ to a value in [0, 1] from side-to-move's perspective,
    // return the number of entries written.
}
```

For NN-backed search, use the batched variant — same surface, but states come in batches:

```odin
mcts.run_simulations_batched(&tree, 1000, batch_size = 32, my_batched_evaluator, my_user_data)
```

## 4. Exposing through C / Python

The package is pure Odin. If you need a C-ABI or a Python ctypes wrapper, build a thin shim package in your own project that:

1. Wraps `mcts.Tree`, your game state, and your evaluator behind opaque `rawptr` handles.
2. Exports `proc "c"` entry points with stable link names (e.g., `mygame_new`, `mygame_play`, `mygame_mcts_run`).
3. Uses `runtime.default_context()` at the top of each export to give the Odin runtime a context.

This is intentionally left out of `mcts-odin` itself so the package stays a pure Odin library. For a worked example, see how `autogodin`'s `odin/alpha_go/exports.odin` exposes its own MCTS + GoBoard to Python via ctypes — the same pattern works on top of `import "mcts"`.

## 5. Tuning

| Knob | Effect | Reasonable default |
|---|---|---|
| `c_puct` | Exploration weight in PUCT | 1.0–1.5 |
| `lambda` | Mix between NN value (0) and rollout (1) | 0 if you have an NN; 1 for pure rollouts |
| `dirichlet_alpha` | Root noise strength (0 disables) | 0.3 for chess-sized action spaces |
| `dirichlet_weight` | Fraction of root prior replaced by noise | 0.25 |
| `temperature` | Output sampling temperature (in `select_action`) | 1.0 for exploration; 0.0 for argmax |
| `max_depth` | Tree+rollout combined budget | 100 |
| `pcr_sims` / `pcr_probs` | Categorical mix of per-move sim counts | empty = use the `num_simulations` arg verbatim |

## 6. Memory model

- The tree owns an internal growing arena; all node and per-node allocations (priors, child indices, cloned states) come from it.
- `mcts.destroy(&tree)` walks every node calling `game.free` on its state, then drops the arena. If your `clone` allocates outside the tree arena (e.g., on `context.allocator`), make sure `free` matches.
- The evaluator's scratch buffers (`out_actions`, `out_probs`) come from the tree's `context.temp_allocator` — they're valid only for the duration of the evaluator call.

## 7. Threading

Not yet. The current MCTS is single-threaded; leaf-parallelism is *algorithmic* (one tree, batched evaluator), not OS-thread parallelism. True root-parallel or tree-parallel MCTS is a future extension.
