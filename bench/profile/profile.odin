package main

import "core:fmt"
import "core:slice"
import "core:time"
import "../../mcts"
import gg "../../games/go"

// Wrapped-vtable profile of the 9x9 Go bench.
//
// Drops timers around every Game vtable entry point and the evaluator,
// then accumulates ns + call counts per bucket. The residual ("MCTS core")
// is wall-clock minus the sum of measured buckets — that's the cost of
// PUCT, expand, create_node, backup, and bookkeeping inside mcts/*.
//
// Per-call time.tick_now() overhead is ~20-40 ns. Over a 32-move trial we
// take ~30M timestamps; total instrumentation cost is in the 1-2% range.
// Percentages are reliable; absolute throughput here will be 3-5% lower
// than the main bench. That's expected.
//
// Build: `odin run bench/profile -o:speed -no-bounds-check`.

Row :: struct {
	name:  string,
	ns:    i64,
	count: i64,
}

Bucket :: enum {
	Do_Move,
	Undo_Move,
	Is_Terminal,
	Legal_Actions,
	Current_Player,
	Eval,
}

prof: struct {
	ns:    [Bucket]i64,
	count: [Bucket]i64,
}

inner: mcts.Game

@(disabled = false)
prof_add :: #force_inline proc(start: time.Tick, b: Bucket) {
	prof.ns[b] += i64(time.duration_nanoseconds(time.tick_since(start)))
	prof.count[b] += 1
}

w_do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	t := time.tick_now()
	r := inner.do_move(state, action)
	prof_add(t, .Do_Move)
	return r
}

w_undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	t := time.tick_now()
	inner.undo_move(state, delta)
	prof_add(t, .Undo_Move)
}

w_is_terminal :: proc(state: rawptr) -> bool {
	t := time.tick_now()
	r := inner.is_terminal(state)
	prof_add(t, .Is_Terminal)
	return r
}

w_legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	t := time.tick_now()
	inner.legal_actions(state, out)
	prof_add(t, .Legal_Actions)
}

w_current_player :: proc(state: rawptr) -> i32 {
	t := time.tick_now()
	r := inner.current_player(state)
	prof_add(t, .Current_Player)
	return r
}

w_terminal_value :: proc(state: rawptr) -> f32 {
	// Rare and trivial; lump it into Is_Terminal's bucket if hit.
	return inner.terminal_value(state)
}

uniform_evaluator :: proc(
	state:       rawptr,
	out_actions: []int,
	out_probs:   []f32,
	out_value:   ^f32,
	user_data:   rawptr,
) -> int {
	t := time.tick_now()
	defer prof_add(t, .Eval)

	g := cast(^mcts.Game)user_data
	tmp := make([dynamic]int, 0, g.max_actions, context.temp_allocator)
	defer delete(tmp)
	g.legal_actions(state, &tmp)

	n := len(tmp)
	if n == 0 {out_value^ = 0.0; return 0}
	uniform := f32(1) / f32(n)
	for i in 0 ..< n {
		out_actions[i] = tmp[i]
		out_probs[i] = uniform
	}
	out_value^ = 0.0
	return n
}

run_trial :: proc(g: ^mcts.Game, sims_per_move, moves_per_trial: int, seed: u64) -> i64 {
	defer free_all(context.temp_allocator)

	state := gg.new_state(9, 7.5)
	cfg := mcts.default_config()
	cfg.c_puct = 1.0
	cfg.max_depth = 100

	start := time.tick_now()
	for move in 0 ..< moves_per_trial {
		clone := g.clone(state)
		tree: mcts.Tree
		mcts.init(&tree, g, clone, cfg, seed = seed + u64(move))
		mcts.run_simulations(&tree, sims_per_move, uniform_evaluator, g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)

		_ = g.do_move(state, action)
		if g.is_terminal(state) {break}
	}
	end := time.tick_now()
	g.free(state)
	return i64(time.duration_nanoseconds(time.tick_diff(start, end)))
}

main :: proc() {
	sims_per_move := 1600
	moves_per_trial := 32

	inner = gg.game()
	g_wrapped := mcts.Game{
		clone           = inner.clone,
		free            = inner.free,
		do_move         = w_do_move,
		undo_move       = w_undo_move,
		is_terminal     = w_is_terminal,
		terminal_value  = w_terminal_value,
		legal_actions   = w_legal_actions,
		current_player  = w_current_player,
		max_actions     = inner.max_actions,
	}

	fmt.println("mcts-odin profile — 9x9 Go, uniform evaluator, single-thread")
	fmt.printf("config: %d sims/move x %d moves/trial = %d sims/trial\n\n",
		sims_per_move, moves_per_trial, sims_per_move * moves_per_trial)

	// Warmup.
	_ = run_trial(&g_wrapped, sims_per_move, moves_per_trial, 41)
	prof = {}

	// Measured trial.
	wall_ns := run_trial(&g_wrapped, sims_per_move, moves_per_trial, 100)
	wall_ms := f64(wall_ns) / 1e6

	// Eval wrapper times the whole evaluator body, which internally calls
	// Legal_Actions through the wrapped vtable. Don't double-count.
	eval_excl_legal := prof.ns[.Eval] - prof.ns[.Legal_Actions]
	sum_measured_ns := prof.ns[.Do_Move] + prof.ns[.Undo_Move] +
		prof.ns[.Is_Terminal] + prof.ns[.Current_Player] +
		prof.ns[.Legal_Actions] + eval_excl_legal
	residual_ns := wall_ns - sum_measured_ns

	rows := [?]Row{
		{"Legal_Actions",        prof.ns[.Legal_Actions],  prof.count[.Legal_Actions]},
		{"Do_Move",              prof.ns[.Do_Move],        prof.count[.Do_Move]},
		{"Undo_Move",            prof.ns[.Undo_Move],      prof.count[.Undo_Move]},
		{"Eval body (excl LA)",  eval_excl_legal,          prof.count[.Eval]},
		{"Is_Terminal",          prof.ns[.Is_Terminal],    prof.count[.Is_Terminal]},
		{"Current_Player",       prof.ns[.Current_Player], prof.count[.Current_Player]},
		{"MCTS core (residual)", residual_ns,              0},
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.ns > b.ns })

	fmt.printf("wall: %.1f ms\n\n", wall_ms)
	fmt.printf("%-22s %10s %8s %12s %10s\n", "bucket", "ms", "%wall", "calls", "ns/call")
	fmt.println("-----------------------------------------------------------------")
	for r in rows {
		ms := f64(r.ns) / 1e6
		pct := 100.0 * f64(r.ns) / f64(wall_ns)
		ns_per_call := f64(0)
		if r.count > 0 {ns_per_call = f64(r.ns) / f64(r.count)}
		if r.count > 0 {
			fmt.printf("%-22s %10.1f %7.1f%% %12d %10.0f\n",
				r.name, ms, pct, r.count, ns_per_call)
		} else {
			fmt.printf("%-22s %10.1f %7.1f%% %12s %10s\n",
				r.name, ms, pct, "-", "-")
		}
	}
	fmt.println()
	fmt.println("Notes:")
	fmt.println("  - 'Eval body' is evaluator-wrapper time MINUS its nested Legal_Actions.")
	fmt.println("  - 'MCTS core (residual)' = wall - sum(measured) ≈ PUCT scan + expand")
	fmt.println("    + create_node + backup + descent bookkeeping.")
	fmt.println("  - Per-call time.tick_now() overhead is ~20-40 ns. Cheapest buckets")
	fmt.println("    (Is_Terminal, Current_Player, Eval body) are dominated by tick cost;")
	fmt.println("    their ns/call should be read as 'tick overhead', not real work.")
}
