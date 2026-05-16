# Getting started

A reading-and-running path for someone new to this project — and, by way
of it, to MCTS. Goes from "what does this do" to "I can wire a new game
in" in under an hour.

You will need [Odin](https://odin-lang.org/docs/install/) installed.
This project tracks the `dev-2026-05` nightly (the same release CI pins);
older nightlies may not compile. Everything else is in this repo.

## Five-minute orientation

Skim, in this order:

1. **`README.md`** — top section only. What the library is, the `Game`
   vtable shape, the quick-start snippet. Stop at "Architecture" for now.
2. **`mcts/game.odin`** — ~80 lines. The vtable a new game implements.
   This is the entire contract between the algorithm and a game. If you
   understand this file, you understand how the rest plugs together.

Now you know what you're looking at. Run it.

## Hands-on, in order

### 1. Watch MCTS play tic-tac-toe

```bash
odin run examples/tictactoe_selfplay.odin -file -o:speed
```

Prints each move with a board snapshot. You're literally watching the
algorithm pick lines that win or draw at every turn — tic-tac-toe is a
solved game and MCTS at 1000 sims/move plays it perfectly.

Then read the source (~80 lines). It shows the full integration pattern:
a uniform evaluator, the `Game` vtable, `mcts.init`, `run_simulations`,
`select_action`. Every other consumer is a variation on this template.

### 2. Run the test suite

```bash
./scripts/test.sh
```

~140 tests across the algorithm core and 10 demo games. Confirms your
build works and shows the breadth of games the same MCTS core drives
without modification.

### 3. Run the throughput bench

```bash
odin build bench -out:bench/bench -o:speed -no-bounds-check
./bench/bench
```

9×9 Go, 1600 sims/move × 32 moves, uniform-policy evaluator. Shows
sims-per-second on your machine. Useful as a regression check if you
touch the hot path.

## Learning MCTS itself

The algorithm is small. Read in this order — each file adds one layer.

1. **`mcts/mcts.odin`** — `Tree`, `init`, `destroy`. The data structure.
   Hot fields are SoA-packed for cache locality; the comments explain
   what each field is for.
2. **`mcts/playout.odin`** — `run_simulations` and one simulation's
   four phases: **select** (PUCT descent), **expand** (add a child
   node), **simulate** (evaluator call), **backprop** (push the value
   back up the path). This is the algorithm.
3. **`mcts/config.odin`** — every knob with defaults: `c_puct`, Dirichlet
   noise, FPU (First-Play Urgency), virtual loss, PCR (progressive
   computation reduction). Best place to learn AlphaZero-style PUCT by
   changing one value at a time and re-running the tic-tac-toe demo.

That's the core of the algorithm. The rest of `mcts/` is variants
(batched leaf-parallel playouts, threaded workers, action readouts) that
share the same `select / expand / simulate / backprop` shape.

## Plug in your own game

Once the algorithm makes sense, look at how a non-trivial game is wired
up. Order of increasing complexity:

| Game | Why look at it |
| --- | --- |
| `games/tictactoe/` | Simplest possible `Game` — start here. |
| `games/connect_four/` | Cleanest small-board win-line game. |
| `games/dots_and_boxes/` | The mover sometimes keeps the turn — breaks the "to_play flips every move" assumption. |
| `games/amazons/` | Two-stage moves (slide + arrow shot). |
| `games/quoridor/` | Heterogeneous action space; legal_actions runs BFS. |
| `games/go/` | The most-optimised demo — incremental Zobrist, packed bitboards, PSK. |

To wire a new game, implement the eight `Game` vtable procs from
`mcts/game.odin`:

```
clone, free, do_move, undo_move,
is_terminal, terminal_value,
legal_actions, current_player
```

Plus `max_actions`. The MCTS core calls only these — it knows nothing
else about your game.

## When you want a real evaluator

The demos use a uniform-policy evaluator (every legal move equally
likely). A real engine plugs in a neural net or a learned policy.

See **`examples/nn_evaluator_skeleton.odin`** — runnable template, no
real model. Shows both the sequential and batched evaluator signatures
the MCTS core expects, and the masking-to-legal-moves contract every
real evaluator must honour.

## Embedding from another language

If you want to call MCTS from Python / C / TypeScript instead of writing
Odin, see **`docs/EMBEDDING.md`** — the library ships as a shared object
(`scripts/build.sh` produces `build/libmcts_odin.so`) with a C-ABI
surface designed for FFI.

## Common pitfalls

- **Evaluator must mask to legal moves.** The MCTS hot path does not
  re-check legality before calling `do_move` on the chosen slot — a
  nonzero prior for an illegal action will be silently selected and
  produce a panic or corrupted state. NN-backed evaluators must mask
  their logits to legal actions before normalising.
- **`do_move` / `undo_move` must be exact inverses.** The do/undo
  round-trip test is the load-bearing invariant — every demo game has
  one and you should too. If undo doesn't restore *all* state
  (including caches like `is_term` or incremental hashes), the tree
  will silently produce garbage.
- **`terminal_value` is from `to_play`'s POV.** `1.0` = current player
  won, `0.0` = current player lost, `0.5` = draw or non-terminal. Easy
  to flip; check the demos if unsure.

## Where to go next

- **`README.md`** Architecture section, then "Throughput" — the
  optimisation choices and what each one bought.
- **`CHANGELOG.md`** — every release entry calls out the perf delta.
  Good for seeing what kinds of changes move the needle.
- **`docs/EMBEDDING.md`** — full FFI surface.
- **`AGENTS.md`** — if you're using an AI coding agent on this repo.
