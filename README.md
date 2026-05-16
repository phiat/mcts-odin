# mcts-odin

A generic, optimized, clean MCTS package for [Odin](https://odin-lang.org/). AlphaZero-style PUCT with Dirichlet root noise, optional fast rollouts, leaf-parallel batched playouts with virtual loss, and PCR (progressive computation reduction).

Games plug in by implementing a small `Game` vtable; the core knows nothing about Go, chess, or any specific game. Ships with a Go (9×9 / 19×19) reference implementation and a tic-tac-toe sanity game.

## Status

v0.1-dev. Generic MCTS core + tic-tac-toe demo + 10 passing tests. Go and Connect Four demos are planned but not shipped yet. See `bd ready` for the current work queue.

## Quick start

```odin
package main

import "mcts"
import "games/tictactoe"

main :: proc() {
    game  := tictactoe.game()           // mcts.Game vtable
    state := tictactoe.new_state()
    defer tictactoe.free_state(state)

    cfg := mcts.default_config()
    tree: mcts.Tree
    mcts.init(&tree, &game, state, cfg, seed = 42)
    defer mcts.destroy(&tree)

    mcts.run_simulations(&tree, 1000, uniform_evaluator, nil)
    action := mcts.select_action(&tree, temperature = 0.0)
}
```

## The Game vtable

```odin
Game :: struct {
    clone:           proc(state: rawptr) -> rawptr,
    free:            proc(state: rawptr),
    do_move:         proc(state: rawptr, action: int) -> Move_Delta,
    undo_move:       proc(state: rawptr, delta: Move_Delta),
    is_terminal:     proc(state: rawptr) -> bool,
    terminal_value:  proc(state: rawptr) -> f32,  // [0, 1] from side-to-move perspective
    legal_actions:   proc(state: rawptr, out: ^[dynamic]int),
    current_player:  proc(state: rawptr) -> i32,  // 0 or 1 for two-player games
    max_actions:     int,                          // upper bound on action-id, for buffer sizing
}
```

Games that can't undo cheaply may leave `undo_move = nil`; MCTS falls back to clone-on-descent.

## Layout

```
mcts/             generic MCTS core (game-agnostic)
  game.odin         Game vtable + Move_Delta
  mcts.odin         Tree / Node / Config + init / destroy
  playout.odin      Evaluator type, sequential run_simulations + fast_rollout
  batched.odin      leaf-parallel run_simulations_batched (virtual loss)
  readout.odin      select_action + visit/Q/priors readouts
  rng.odin          gamma sampler + categorical helper
games/tictactoe/  tic-tac-toe sanity game
games/go/         (planned) Go board reference impl
tests/            test suite (run with: odin test tests)
examples/         small runnable examples
bench/            performance benchmarks
scripts/          build / test helpers
docs/             EMBEDDING.md and friends
```

## Build

```bash
./scripts/build.sh   # build/libmcts_odin.so
./scripts/test.sh    # odin test tests, fails on leaks
```

For embedding the package in your own Odin/Python project, see [`docs/EMBEDDING.md`](docs/EMBEDDING.md).

## License

MIT. See [LICENSE](LICENSE).
