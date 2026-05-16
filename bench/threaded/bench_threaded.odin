package main

import "core:fmt"
import "core:time"
import "../../mcts"
import gg "../../games/go"

// Scaling bench for run_simulations_threaded. With a cheap evaluator the
// expand-mutex contention and Q CAS-loop cost can erase or invert the
// speedup; with an artificially-slowed evaluator (~50 µs per call) the
// speedup should approach linear in n_threads until cores run out.
//
// Build: `odin run bench/threaded -o:speed -no-bounds-check`.

CHEAP :: 0    // ns of artificial work per evaluator call
SLOW  :: 50_000 // ~50 µs per call — stand-in for a CPU NN forward

slow_evaluator :: proc(
	state:       rawptr,
	out_actions: []int,
	out_probs:   []f32,
	out_value:   ^f32,
	user_data:   rawptr,
) -> int {
	cfg := cast(^Bench_Cfg)user_data
	g := cfg.game
	tmp := make([dynamic]int, 0, g.max_actions, context.temp_allocator)
	defer delete(tmp)
	g.legal_actions(state, &tmp)
	n := len(tmp)
	if n == 0 {out_value^ = 0.5; return 0}
	uniform := f32(1) / f32(n)
	for i in 0 ..< n {
		out_actions[i] = tmp[i]
		out_probs[i] = uniform
	}
	out_value^ = 0.5

	// Artificial spin to model a real NN forward. Wall-clock is what matters
	// for the speedup story; the spin keeps the CPU busy so threading scales.
	if cfg.spin_ns > 0 {
		start := time.tick_now()
		target := time.Duration(cfg.spin_ns)
		for time.tick_diff(start, time.tick_now()) < target {
			// busy
		}
	}
	return n
}

Bench_Cfg :: struct {
	game:    ^mcts.Game,
	spin_ns: i64,
}

run_one :: proc(g: ^mcts.Game, spin_ns: i64, sims: int, n_threads: int) -> (elapsed_ns: i64) {
	defer free_all(context.temp_allocator)

	state := gg.new_state(9, 7.5)
	cfg := mcts.default_config()
	cfg.c_puct = 1.0
	cfg.max_depth = 100

	tree: mcts.Tree
	mcts.init(&tree, g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)

	bcfg := Bench_Cfg{game = g, spin_ns = spin_ns}

	start := time.tick_now()
	if n_threads == 0 {
		mcts.run_simulations(&tree, sims, slow_evaluator, &bcfg)
	} else {
		mcts.run_simulations_threaded(&tree, sims, n_threads, slow_evaluator, &bcfg)
	}
	end := time.tick_now()
	elapsed_ns = i64(time.duration_nanoseconds(time.tick_diff(start, end)))
	return
}

main :: proc() {
	g := gg.game()
	sims := 800

	fmt.println("mcts-odin threaded scaling bench — 9x9 Go, slow evaluator")
	fmt.printf("config: %d sims, %d ns per evaluator call\n\n", sims, SLOW)

	// Warm up so first measurement isn't paying cold-page costs.
	_ = run_one(&g, SLOW, sims, 0)

	// Sequential baseline.
	base_ns := run_one(&g, SLOW, sims, 0)
	base_rate := f64(sims) / (f64(base_ns) / 1e9)
	fmt.printf("sequential:  %7.3f sec  %7.0f sims/s\n",
		f64(base_ns) / 1e9, base_rate)

	thread_counts := [4]int{1, 2, 4, 8}
	for n in thread_counts {
		ns := run_one(&g, SLOW, sims, n)
		rate := f64(sims) / (f64(ns) / 1e9)
		speedup := rate / base_rate
		fmt.printf("threaded n=%d: %7.3f sec  %7.0f sims/s  (%.2fx sequential)\n",
			n, f64(ns) / 1e9, rate, speedup)
	}

}
