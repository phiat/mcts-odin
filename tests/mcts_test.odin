package tests

import "core:testing"
import "../mcts"
import ttt "../games/tictactoe"

// Uniform-policy, value=0.5 evaluator. Drains legal_actions from the game
// and assigns each action equal prior. The simplest possible evaluator;
// turns MCTS into UCB-style pure exploration.
@(private = "file")
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
	if n == 0 {out_value^ = 0.5; return 0}
	uniform := 1.0 / f32(n)
	for i in 0 ..< n {
		out_actions[i] = tmp[i]
		out_probs[i] = uniform
	}
	out_value^ = 0.5
	return n
}

@(test)
ttt_tree_init :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	testing.expect_value(t, mcts.tree_size(&tree), 1)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 0)
}

@(test)
ttt_single_simulation :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 1, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 1)
	testing.expect(t, mcts.tree_size(&tree) >= 1)
}

@(test)
ttt_many_simulations :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	cfg.c_puct = 1.0
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)

	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 200)
	testing.expect(t, mcts.tree_size(&tree) > 1)
}

@(test)
ttt_action_probs_sum_to_one :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	probs := mcts.get_action_probabilities(&tree, 1.0)
	defer delete(probs)
	sum := f32(0)
	for _, p in probs {
		sum += p
		testing.expect(t, p >= 0)
		testing.expect(t, p <= 1)
	}
	testing.expectf(t, abs(sum - 1.0) < 0.01, "sum=%f", sum)
}

@(test)
ttt_temperature_zero_argmax :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	probs := mcts.get_action_probabilities(&tree, 0.0)
	defer delete(probs)
	ones := 0
	for _, p in probs {if p == 1.0 {ones += 1}}
	testing.expect_value(t, ones, 1)
}

@(test)
ttt_select_action_legal :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	a := mcts.select_action(&tree, 0.0)
	testing.expect(t, a >= 0 && a < 9)
}

@(test)
ttt_q_in_bounds :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	rq := mcts.get_root_q_value(&tree)
	testing.expect(t, rq >= 0)
	testing.expect(t, rq <= 1)
	cq := mcts.get_child_q_values(&tree)
	defer delete(cq)
	for _, q in cq {
		testing.expect(t, q >= 0)
		testing.expect(t, q <= 1)
	}
}

@(test)
ttt_dirichlet_noise :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	cfg.dirichlet_alpha = 0.3
	cfg.dirichlet_weight = 0.25
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 100, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 100)
}

@(private = "file")
batched_uniform_evaluator :: proc(
	states:      []rawptr,
	out_actions: [][]int,
	out_probs:   [][]f32,
	out_counts:  []int,
	out_values:  []f32,
	user_data:   rawptr,
) {
	for i in 0 ..< len(states) {
		v: f32
		out_counts[i] = uniform_evaluator(states[i], out_actions[i], out_probs[i], &v, user_data)
		out_values[i] = v
	}
}

@(test)
ttt_batched_smoke :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations_batched(&tree, 100, 8, batched_uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 100)
}

// Tic-tac-toe is solved: with optimal play, the game is a draw from the empty
// board. MCTS with enough sims should NOT pick a losing first move. We don't
// require it to find optimal play exactly under a uniform evaluator (no value
// signal), but we DO require sane behaviour: actions are legal, Q values are
// reasonable, no crashes.
@(test)
ttt_reuse_root_with_existing_subtree :: proc(t: ^testing.T) {
	// Build a tree, pick an action, reuse the subtree under it, run more sims.
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 7)
	defer mcts.destroy(&tree)

	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	action := mcts.select_action(&tree, 0.0)
	visits_before := mcts.get_child_visit_counts(&tree)
	defer delete(visits_before)

	// The kept slot's visit count becomes the new root's existing N.
	prior_visits := visits_before[action]
	testing.expect(t, prior_visits > 0)

	reused := mcts.reuse_root(&tree, action)
	testing.expect(t, reused)

	mcts.run_simulations(&tree, 100, uniform_evaluator, &g)
	testing.expect(t, mcts.get_root_visit_count(&tree) >= prior_visits + 100)
}

@(test)
ttt_reuse_root_synthetic :: proc(t: ^testing.T) {
	// Calling reuse_root for an action that wasn't expanded should still work,
	// just by allocating a fresh root.
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 11)
	defer mcts.destroy(&tree)

	// 1 sim: only one slot at root gets a child; the other 8 remain unexplored.
	mcts.run_simulations(&tree, 1, uniform_evaluator, &g)

	visits := mcts.get_child_visit_counts(&tree)
	defer delete(visits)
	unexplored_action := -1
	for a in 0 ..< 9 {
		if _, ok := visits[a]; !ok {unexplored_action = a; break}
	}
	testing.expect(t, unexplored_action >= 0)

	reused := mcts.reuse_root(&tree, unexplored_action)
	testing.expect(t, !reused)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 0)

	mcts.run_simulations(&tree, 50, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 50)
}

@(test)
ttt_self_play_runs_to_completion :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	defer ttt.free_state(state)

	cfg := mcts.default_config()

	for !ttt.is_terminal(state) {
		// Fresh tree per move (subtree reuse is z24.5).
		clone := ttt.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = 42)
		mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)

		// Selected action must be a current legal move.
		legal := make([dynamic]int, 0, 9, context.temp_allocator)
		defer delete(legal)
		ttt.legal_actions(state, &legal)
		found := false
		for a in legal {if a == action {found = true; break}}
		testing.expectf(t, found, "selected action %d not in legal moves", action)

		_ = ttt.do_move(state, action)
	}

	// Some outcome was reached.
	testing.expect(t, ttt.is_terminal(state))
}

@(test)
ttt_dump_tree_dot_well_formed :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 7)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 30, uniform_evaluator, &g)

	s := mcts.dump_tree_dot(&tree)
	defer delete(s)
	testing.expect(t, len(s) > 0)
	// digraph header + node label + at least one edge
	testing.expect(t, contains(s, "digraph mcts"))
	testing.expect(t, contains(s, "n0 [label="))
	testing.expect(t, contains(s, " -> "))
}

@(test)
ttt_dump_tree_json_well_formed :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 7)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 30, uniform_evaluator, &g)

	s := mcts.dump_tree_json(&tree)
	defer delete(s)
	testing.expect(t, len(s) > 0)
	testing.expect(t, s[0] == '{')
	testing.expect(t, s[len(s)-1] == '}')
	testing.expect(t, contains(s, "\"root_idx\":0"))
	testing.expect(t, contains(s, "\"nodes\":["))
}

@(private = "file")
contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {return true}
	if len(needle) > len(haystack) {return false}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i+len(needle)] == needle {return true}
	}
	return false
}
