package main

import "core:fmt"
import "core:math"
import "core:time"
import "../mcts"
import gg "../games/go"

// Replicates autogodin's MCTS throughput micro-bench:
//   - 9x9 empty start, komi 7.5
//   - 1600 simulations per move
//   - 32 moves per trial
//   - 51,200 simulations per trial
//   - Uniform-policy evaluator (no NN), value = 0
//   - Single-threaded, deterministic argmax action selection
//
// Autogodin baseline (May 2026, single-thread, no GPU):
//   cpp:   8,470 ± 42 sims/s
//   odin:  2,859 ± 290 sims/s
//
// We're aiming to match or beat cpp by skipping the per-leaf clone (do/undo
// is in the Game vtable; MCTS threads working_state instead of cloning).

uniform_evaluator :: proc(
	state:       rawptr,
	out_actions: []int,
	out_probs:   []f32,
	out_value:   ^f32,
	user_data:   rawptr,
) -> int {
	g := cast(^mcts.Game)user_data
	tmp := make([dynamic]int, 0, g.max_actions, context.temp_allocator)
	defer delete(tmp)
	g.legal_actions(state, &tmp)

	n := len(tmp)
	if n == 0 {out_value^ = 0.0; return 0}
	uniform := 1.0 / f32(n)
	for i in 0 ..< n {
		out_actions[i] = tmp[i]
		out_probs[i] = uniform
	}
	out_value^ = 0.0
	return n
}

run_trial :: proc(g: ^mcts.Game, sims_per_move, moves_per_trial: int, seed: u64) -> (elapsed_ns: i64, total_sims: int) {
	// The MCTS core never touches the caller's temp_allocator, but
	// uniform_evaluator allocates a small [dynamic]int there 51,200 times
	// per trial. Without this reset, the arena grows ~33 MB/trial and later
	// trials degrade from paging.
	defer free_all(context.temp_allocator)

	state := gg.new_state(9, 7.5)
	cfg := mcts.default_config()
	cfg.c_puct = 1.0
	cfg.max_depth = 100

	start := time.tick_now()
	for move in 0 ..< moves_per_trial {
		// Fresh tree per move (subtree reuse is z24.5, not yet landed).
		clone := g.clone(state)
		tree: mcts.Tree
		mcts.init(&tree, g, clone, cfg, seed = seed + u64(move))
		mcts.run_simulations(&tree, sims_per_move, uniform_evaluator, g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)

		_ = g.do_move(state, action)
		total_sims += sims_per_move

		if g.is_terminal(state) {break}
	}
	end := time.tick_now()
	g.free(state)
	elapsed_ns = i64(time.duration_nanoseconds(time.tick_diff(start, end)))
	return
}

main :: proc() {
	sims_per_move := 1600
	moves_per_trial := 32
	warmups := 2
	trials := 5

	g := gg.game()

	fmt.println("mcts-odin bench — 9x9 Go, uniform evaluator, single-thread")
	fmt.printf("config: %d sims/move x %d moves/trial = %d sims/trial\n",
		sims_per_move, moves_per_trial, sims_per_move * moves_per_trial)
	fmt.printf("warmup: %d  trials: %d\n\n", warmups, trials)

	for i in 0 ..< warmups {
		run_trial(&g, sims_per_move, moves_per_trial, u64(42 + i))
	}

	// Not on temp_allocator — run_trial resets that arena per trial.
	rates := make([]f64, trials)
	defer delete(rates)

	for i in 0 ..< trials {
		ns, sims := run_trial(&g, sims_per_move, moves_per_trial, u64(100 + i))
		rate := f64(sims) / (f64(ns) / 1e9)
		rates[i] = rate
		fmt.printf("trial %d: %.3f sec, %d sims, %.0f sims/s\n",
			i + 1, f64(ns) / 1e9, sims, rate)
	}

	mean := f64(0)
	for r in rates {mean += r}
	mean /= f64(trials)
	var := f64(0)
	for r in rates {var += (r - mean) * (r - mean)}
	std := math.sqrt_f64(var / f64(trials))

	fmt.println()
	fmt.printf("mean: %.0f sims/s, std: %.0f, 95%%CI ≈ ±%.0f\n",
		mean, std, 1.96 * std / math.sqrt_f64(f64(trials)))
	fmt.println()
	fmt.println("autogodin baseline (May 2026, single-thread):")
	fmt.println("  cpp:   8,470 ± 42 sims/s")
	fmt.println("  odin:  2,859 ± 290 sims/s")
	speedup_vs_cpp := mean / 8470.0
	speedup_vs_odin := mean / 2859.0
	fmt.printf("\nvs cpp:  %.2fx\n", speedup_vs_cpp)
	fmt.printf("vs odin: %.2fx\n", speedup_vs_odin)
}
