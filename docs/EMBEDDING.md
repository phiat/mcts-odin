# Embedding mcts-odin

How to drop the package into your own Odin project, and how to expose it through C/Python if you need to.

## 1. Get the source into your project

There's no Odin package manager. Three options, all tested:

**Sibling clone + collection (recommended).** Clone `mcts-odin` next to your project and register it as an Odin collection at build time. Inside your code, the import names are stable regardless of where the checkout lives:

```odin
import "mcts:mcts"                    // the core
import ttt "mcts:games/tictactoe"     // a demo game (optional)
```

```bash
odin run . -collection:mcts=/path/to/mcts-odin
```

This is what `autogodin` uses to vendor mcts-odin as a dep without copying source.

**Sibling clone + relative path.** Same on-disk layout, but `import` with relative paths. Simpler, breaks if you ever move things:

```
my-project/
  src/main.odin           import "../../mcts-odin/mcts"
mcts-odin/
  mcts/
```

**Vendor copy.** Copy `mcts/` (and any `games/` you want) into your project's `vendor/` tree and import with normal paths. Pin a commit hash in your README.

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

See [`examples/nn_evaluator_skeleton.odin`](../examples/nn_evaluator_skeleton.odin) for a runnable template covering both paths (sequential + batched) with a mocked forward pass. It demonstrates legal-move masking, numerically-stable softmax over masked logits, and the `user_data` pattern for carrying model handles / scratch buffers through the evaluator — the parts that don't change when you swap the mock for ONNX Runtime, a Python FFI callback, or libtorch.

## 4. Exposing through C / Python

The package is pure Odin. If you need a C-ABI or a Python ctypes wrapper, build a thin shim package in your own project that:

1. Wraps `mcts.Tree`, your game state, and your evaluator behind opaque `rawptr` handles.
2. Exports `proc "c"` entry points with stable link names (e.g., `mygame_new`, `mygame_play`, `mygame_mcts_run`).
3. Uses `runtime.default_context()` at the top of each export to give the Odin runtime a context.

This is intentionally left out of `mcts-odin` itself so the package stays a pure Odin library. For a worked example, see how `autogodin`'s `odin/alpha_go/exports.odin` exposes its own MCTS + GoBoard to Python via ctypes — the same pattern works on top of `import "mcts"`.

## 5. Subtree reuse across moves

The naive self-play loop builds a fresh tree for every move:

```odin
for !game_over {
    clone := my_game.clone(state)
    tree: mcts.Tree
    mcts.init(&tree, &g, clone, cfg, seed)
    mcts.run_simulations(&tree, 1000, evaluator, ud)
    action := mcts.select_action(&tree, 0.0)
    mcts.destroy(&tree)
    _ = my_game.do_move(state, action)
}
```

That discards all the visits and Q values accumulated under the played action. With `mcts.reuse_root` you keep them:

```odin
tree: mcts.Tree
mcts.init(&tree, &g, my_game.new_state(), cfg, seed)
defer mcts.destroy(&tree)

for !my_game.is_terminal(tree.working_state) {
    mcts.run_simulations(&tree, 1000, evaluator, ud)
    action := mcts.select_action(&tree, 0.0)
    mcts.reuse_root(&tree, action)   // re-roots tree at the kept subtree
}
```

`reuse_root` applies the move to the tree's working state and re-roots at the kept subtree (or at a synthetic fresh node if you pick an action the tree never expanded). Dirichlet noise is automatically re-applied to the new root on the next `run_simulations`. Old root + sibling subtrees stay in the arena and are reclaimed at `destroy()` — fine for bounded-length games.

## 6. Tuning

| Knob | Effect | Reasonable default |
|---|---|---|
| `c_puct` | Exploration weight in PUCT | 1.0–1.5 |
| `lambda` | Mix between NN value (0) and rollout (1) | 0 if you have an NN; 1 for pure rollouts |
| `dirichlet_alpha` | Root noise strength (0 disables) | 0.3 for chess-sized action spaces |
| `dirichlet_weight` | Fraction of root prior replaced by noise | 0.25 |
| `temperature` | Output sampling temperature (in `select_action`) | 1.0 for exploration; 0.0 for argmax |
| `max_depth` | Tree+rollout combined budget | 100 |
| `pcr_sims` / `pcr_probs` | Categorical mix of per-move sim counts | empty = use the `num_simulations` arg verbatim |

## 7. Memory model

- Each tree owns two arenas: a *permanent* arena holding nodes and per-node slot arrays (freed on `destroy`), and a *scratch* arena reset at every `run_simulations` entry.
- The tree holds one working game state — the root state you passed to `init`. MCTS mutates it in place during descent and restores it via `undo_move` on the way up. `destroy(&tree)` calls `game.free` on that single state.
- For batched search, the leaf state is captured as a `game.clone` snapshot at descent end, freed after the batched evaluator + backup. Snapshot lifetime is one batch.
- The evaluator's scratch buffers (`out_actions`, `out_probs`) are owned by the tree (`eval_a_buf`/`eval_p_buf`, sized to `game.max_actions`). They're valid only for the duration of the evaluator call — do not retain pointers.
- Caller's `context.temp_allocator` is **not** disturbed by MCTS. All transient allocations land on the tree's scratch arena.

## 8. Debug introspection

Two helpers in `mcts/debug.odin` dump the tree rooted at `t.root_idx` for visualization or test fixtures. Both walk reachable nodes only and return a caller-owned `string`.

```odin
dot := mcts.dump_tree_dot(&tree)
defer delete(dot)
// pipe through `dot -Tpng > tree.png` or any Graphviz layout engine

js := mcts.dump_tree_json(&tree)
defer delete(js)
// parse with core:encoding/json or capture as a regression fixture
```

`dot` labels show `#idx[*]` (the `*` marks terminal), `N`, `Q`, and `d` (depth); edges are labeled with the action id. `json` is a single object with `root_idx` and `nodes[]`; each node carries the full bookkeeping fields plus a `children[]` list of `(slot, action, prior, child_idx)`.

Both helpers are marked experimental — the field set may change before 1.0. Not on the hot path; use between `run_simulations` calls.

## 9. Threading

```odin
// N OS threads each run descent / eval / backup concurrently against the
// same Tree. Atomics on N / N_virt / Q + a coarse expand mutex around node
// creation keep shared state consistent. Virtual loss decouples the
// descents so workers don't pile onto the same leaf.
mcts.run_simulations_threaded(&tree, num_sims, n_threads, my_evaluator, my_user_data)
```

The evaluator is called concurrently from every worker. Anything it touches via `user_data` must be thread-safe — most NN evaluators serialise on the model / GPU boundary, but if yours doesn't you'll need a lock there.

**When to use it:** evaluators that take real time per call (≥10 µs of CPU work or a GPU forward pass). On microsecond-scale evaluators the lock + CAS contention can match or exceed the work, so the speedup degrades. Measured scaling on a slow-evaluator bench (9×9 Go, 50 µs per call): `n=2: 1.93x`, `n=4: 3.81x`, `n=8: 7.15x` vs. sequential.

**Determinism:** dropped. Different thread interleavings produce different per-node visit counts and Q values even with the same seed. The total visit count is exact (atomic claim counter), so `get_root_visit_count` is reliable across runs. Use the sequential or batched paths if you need reproducible play.

Root expansion + Dirichlet noise happen as a single-threaded prelude before the workers spawn, so the workers all enter with a fully-initialised root. Workers each clone `t.working_state` and operate on their own copy — `t.working_state` is left at the root for the duration of the threaded call.

## 10. API stability

The package is pre-1.0. Below is what consumers can rely on vs. what may still move.

### Stable (the contract you can pin against)

These are the API shapes we don't intend to break on `0.x` patch/minor bumps. We may grow them additively (new fields with defaults, new optional args) but the existing surface is committed.

| Symbol | Notes |
|---|---|
| `mcts.VERSION` | Package version string. |
| `mcts.Game` | Struct & field names. Add a new field only at the end and behind a sentinel. |
| `mcts.Move_Delta` | `{hash: u64, flags: u64, extra: rawptr}` — game implementations pack their reverse-move state into these slots. |
| `mcts.Evaluator`, `mcts.Evaluator_Batched` | Proc signatures. |
| `mcts.Config` | Struct & field names. Defaults from `default_config()` may shift. |
| `mcts.init`, `mcts.destroy` | Primary lifecycle. |
| `mcts.run_simulations`, `mcts.run_simulations_batched`, `mcts.run_simulations_threaded` | The three search drivers — sequential, leaf-parallel batched, OS-thread parallel. |
| `mcts.reuse_root` | Subtree reuse contract documented in §5. |
| `mcts.select_action`, `mcts.get_action_probabilities` | Move-selection readouts. |
| `mcts.tree_size`, `mcts.get_root_visit_count`, `mcts.get_root_q_value` | Cheap diagnostics. |
| `mcts.default_config` | Returns a `Config` populated with the recommended defaults. |
| `Tree.working_state` field (read-only) | Convenience: the tree's owned root state. Use it for "is the game over?" checks between rounds. Never mutate or free it. |

### Experimental (shape may change before 1.0)

These work today but the *shape* might shift — e.g. `map[int]X` returns may switch to flat `[]X` slices keyed by slot, struct internals may be reorganised. If you depend on these, expect to refactor at 1.0.

| Symbol | Why experimental |
|---|---|
| `mcts.Node` struct | Internal bookkeeping. Hot fields already moved out into `Tree` slices once; could move again. |
| `mcts.Tree` struct (fields other than `working_state`) | Internal layout. Reach for the accessor procs instead. |
| `mcts.get_child_visit_counts`, `get_child_q_values`, `get_child_first_eval_values`, `get_root_policy_priors`, `get_child_max_subtree_depths` | All return `map[int]X`. Allocates a map per call; awkward for fast inner-loops. Likely to grow flat-slice equivalents (or be replaced) before 1.0. |

### Internal (do not access from consuming code)

Everything in `mcts/` not listed above. Identifiers marked `@(private)` are unconditional internals; the package-private structs we don't list above (`Pending_Leaf`, slot-selection procs, RNG helpers) are also off-limits.

### Versioning policy

Pre-1.0 follows `0.MINOR.PATCH`:
- **PATCH** (0.1.0 → 0.1.1): bug fixes, internal perf changes, doc updates. Stable surface untouched.
- **MINOR** (0.1.x → 0.2.0): additive changes to stable surface; experimental surface may break. Migration notes in `CHANGELOG.md`.
- **1.0.0**: experimental surface either promoted or removed. From 1.0 forward we follow strict SemVer.
