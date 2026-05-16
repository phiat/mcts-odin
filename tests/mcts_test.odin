package tests

import "core:strings"
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
	testing.expect(t, strings.contains(s, "digraph mcts"))
	testing.expect(t, strings.contains(s, "n0 [label="))
	testing.expect(t, strings.contains(s, " -> "))
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
	testing.expect(t, strings.contains(s, "\"root_idx\":0"))
	testing.expect(t, strings.contains(s, "\"nodes\":["))
}

// Regression for mcts-odin-caq: under uniform-policy evaluator + value=0.5 +
// c_puct=1.0 + low sims, PUCT used to funnel all sims into slot 0 because
// the q=0 default for unvisited children couldn't overcome a visited slot's
// Q=0.5. FPU (default fpu_reduction=0.25) anchors unvisited q to parent_Q
// minus a small reduction, restoring proper spread.
@(test)
ttt_fpu_spreads_visits_under_uniform_eval :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config() // fpu_reduction = 0.25
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)

	visits := mcts.get_child_visit_counts(&tree)
	defer delete(visits)

	n_slots_visited := 0
	for _, v in visits {if v > 0 {n_slots_visited += 1}}
	// Pre-FPU behaviour was 1 (all sims on slot 0). With FPU we expect proper
	// spread across most of the 9 root actions.
	testing.expectf(t, n_slots_visited >= 6,
		"expected FPU to spread visits across >= 6 of 9 root slots, got %d", n_slots_visited)
}

// `lambda` mixes a fast policy rollout into the leaf value (AlphaGo-style):
//   U = (1 - λ) * v_theta + λ * z_rollout
// The rollout walks the game tree from the leaf using the same evaluator's
// policy until terminal or max_depth, then undoes every move so working_state
// is restored. Coverage was previously zero; these tests pin the contract.

@(test)
ttt_lambda_pure_rollout_runs :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	cfg.lambda = 1.0
	cfg.rollout_temperature = 1.0
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 7)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 200)

	q := mcts.get_root_q_value(&tree)
	testing.expectf(t, q >= 0.0 && q <= 1.0, "root Q out of bounds with lambda=1: %f", q)
}

@(test)
ttt_lambda_mixed_runs :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	cfg.lambda = 0.5
	cfg.rollout_temperature = 1.0
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 11)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)

	q := mcts.get_root_q_value(&tree)
	testing.expectf(t, q >= 0.0 && q <= 1.0, "root Q out of bounds with lambda=0.5: %f", q)

	// Picked action must be a legal root action — proves do_move/undo_move
	// balanced across the lambda-mixed playouts.
	action := mcts.select_action(&tree, 0.0)
	testing.expectf(t, action >= 0 && action < 9, "lambda=0.5 picked illegal-shaped action %d", action)
}

@(test)
ttt_lambda_self_play_terminates :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	defer ttt.free_state(state)
	cfg := mcts.default_config()
	cfg.lambda = 0.5
	cfg.rollout_temperature = 1.0

	// If rollouts mis-balance do/undo, working_state corrupts and we either
	// crash, pick illegal actions, or fail to terminate. TTT bounds the
	// game at 9 moves; cap at 12 to leave some slack.
	moves := 0
	for !ttt.is_terminal(state) && moves < 12 {
		clone := ttt.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = u64(100 + moves))
		mcts.run_simulations(&tree, 60, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)
		_ = ttt.do_move(state, action)
		moves += 1
	}
	testing.expect(t, ttt.is_terminal(state))
}

// run_simulations_threaded — OS-thread parallel MCTS with virtual loss and
// atomic backups. Workers share the same Tree; descents are decoupled by
// virtual loss; backups commit through atomics. Determinism is dropped — the
// visit count is exact (atomic counter), but per-node visits/Q vary across
// runs.

@(test)
ttt_threaded_one_worker_runs :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 19)
	defer mcts.destroy(&tree)
	mcts.run_simulations_threaded(&tree, 100, 1, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 100)
}

@(test)
ttt_threaded_multi_worker_total_visits :: proc(t: ^testing.T) {
	// 4 workers, 200 sims total. Atomic claim counter must yield exactly 200
	// completed sims — no double-count, no lost sim.
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 23)
	defer mcts.destroy(&tree)
	mcts.run_simulations_threaded(&tree, 200, 4, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 200)

	// Q must be in [0,1] — corrupted CAS loop would let it drift out.
	q := mcts.get_root_q_value(&tree)
	testing.expectf(t, q >= 0.0 && q <= 1.0, "root Q out of bounds: %f", q)

	// Sum of child visits must equal parent visits (minus the root self-visit
	// pattern: every sim that descends past root bumps root, then a child).
	visits := mcts.get_child_visit_counts(&tree)
	defer delete(visits)
	total_child := 0
	for _, v in visits {total_child += v}
	testing.expectf(t, total_child == 200,
		"child visits should sum to 200, got %d (lost/duplicated sims)", total_child)
}

@(test)
ttt_threaded_self_play_terminates :: proc(t: ^testing.T) {
	// End-to-end smoke: a TTT game using the threaded path for every move
	// completes without crashes, picks legal actions, and terminates.
	g := ttt.game()
	state := ttt.new_state()
	defer ttt.free_state(state)
	cfg := mcts.default_config()

	moves := 0
	for !ttt.is_terminal(state) && moves < 12 {
		clone := ttt.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = u64(200 + moves))
		mcts.run_simulations_threaded(&tree, 100, 4, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)
		_ = ttt.do_move(state, action)
		moves += 1
	}
	testing.expect(t, ttt.is_terminal(state))
}

// PCR (progressive computation reduction): if cfg.pcr_sims is set, the per-
// call sim count is sampled from pcr_sims weighted by pcr_probs — the
// caller's `num_simulations` argument is overridden. Surprising behaviour
// worth pinning.
@(test)
ttt_pcr_overrides_num_simulations :: proc(t: ^testing.T) {
	pcr_sims := [1]int{7}
	pcr_probs := [1]f32{1.0}

	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	cfg.pcr_sims = pcr_sims[:]
	cfg.pcr_probs = pcr_probs[:]
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 3)
	defer mcts.destroy(&tree)

	// Caller asks for 500 sims; PCR forces 7.
	mcts.run_simulations(&tree, 500, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 7)
}

// Three stable-API readouts had no coverage. This pins their shape and the
// allocator contract (caller-owned maps that must be deleted).
@(test)
ttt_remaining_readouts_well_formed :: proc(t: ^testing.T) {
	g := ttt.game()
	state := ttt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 13)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 100, uniform_evaluator, &g)

	priors := mcts.get_root_policy_priors(&tree)
	defer delete(priors)
	testing.expect_value(t, len(priors), 9) // 9 legal opening cells
	sum := f32(0)
	for _, p in priors {
		testing.expectf(t, p >= 0.0 && p <= 1.0, "prior out of [0,1]: %f", p)
		sum += p
	}
	testing.expectf(t, sum > 0.99 && sum < 1.01, "priors don't sum to ~1: %f", sum)

	first_evals := mcts.get_child_first_eval_values(&tree)
	defer delete(first_evals)
	for _, v in first_evals {
		testing.expectf(t, v >= 0.0 && v <= 1.0, "first_eval out of [0,1]: %f", v)
	}

	depths := mcts.get_child_max_subtree_depths(&tree)
	defer delete(depths)
	// At 100 sims on TTT the tree should reach depth >= 1 under at least one
	// child (in fact much more). Conservative check: depths are nonneg.
	max_d := 0
	for _, d in depths {
		testing.expect(t, d >= 0)
		if d > max_d {max_d = d}
	}
	testing.expectf(t, max_d >= 1, "expected at least one child subtree of depth >=1 after 100 sims, got max %d", max_d)
}

