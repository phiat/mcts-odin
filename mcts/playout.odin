package mcts

import "core:math"
import "core:math/rand"

// ============================================================================
// Single-threaded AlphaZero-style playout.
//
// Threads working_state through the tree: descent applies do_move, return
// applies undo_move. Nodes never store a state copy — they store the action
// that gets to them from their parent, and rely on the tree's working_state
// being positioned correctly during evaluation.
//
// Evaluator contract:
//   - state is the position to evaluate (do NOT mutate or free it).
//   - out_actions / out_probs are caller-allocated, length >= game.max_actions.
//     Write up to that many (action, prior) pairs.
//   - out_value^ receives the value estimate in [0, 1] from the side-to-move's
//     perspective (1.0 = win for side to move).
//   - Return the number of (action, prob) pairs written.
//
// Returning 0 is legal at terminal states; otherwise it means "no moves" and
// MCTS will treat the position as a leaf with the supplied value.
// ============================================================================

Evaluator :: #type proc(
	state:       rawptr,
	out_actions: []int,
	out_probs:   []f32,
	out_value:   ^f32,
	user_data:   rawptr,
) -> int

// PUCT score selector. Operates on the packed slot list at `node_idx`.
// Returns the slot index (NOT the action id); caller maps it through actions[].
@(private)
select_slot_puct :: proc(t: ^Tree, node_idx: int) -> int {
	node := &t.nodes[node_idx]
	total_visits := 0
	for k in 0 ..< len(node.actions) {
		ci := node.child[k]
		if ci >= 0 {total_visits += t.nodes[ci].N}
	}
	sqrt_total := math.sqrt(f32(total_visits) + 1.0)

	best_slot := 0
	best_score := f32(min(f32))
	for k in 0 ..< len(node.actions) {
		prior := math.exp(node.logP[k])
		q := f32(0)
		n := 0
		ci := node.child[k]
		if ci >= 0 {
			q = t.nodes[ci].Q
			n = t.nodes[ci].N
		}
		u := t.config.c_puct * prior * sqrt_total / (1.0 + f32(n))
		score := q + u
		if score > best_score {
			best_score = score
			best_slot = k
		}
	}
	return best_slot
}

// Expand a leaf: call the evaluator on t.working_state, allocate the packed
// slot arrays in the tree arena, fill logP, mark expanded. Returns v_theta
// from working_state's current_player perspective (caller flips if needed).
@(private)
expand_node :: proc(t: ^Tree, node_idx: int, evaluator: Evaluator, user_data: rawptr) -> f32 {
	cap_n := t.game.max_actions
	a_buf := make([]int, cap_n, context.temp_allocator)
	p_buf := make([]f32, cap_n, context.temp_allocator)
	defer delete(a_buf, context.temp_allocator)
	defer delete(p_buf, context.temp_allocator)

	v: f32
	n := evaluator(t.working_state, a_buf, p_buf, &v, user_data)

	actions := make([]int, n, t.allocator)
	logP    := make([]f32, n, t.allocator)
	child   := make([]int, n, t.allocator)
	for k in 0 ..< n {
		actions[k] = a_buf[k]
		logP[k]    = log_safe(p_buf[k])
		child[k]   = -1
	}
	t.nodes[node_idx].actions = actions
	t.nodes[node_idx].logP    = logP
	t.nodes[node_idx].child   = child
	t.nodes[node_idx].expanded = true
	return v
}

// Recursive simulation. Returns U from node_idx's player_at_parent perspective.
//
// PRECONDITION: t.working_state is positioned at node_idx's state on entry.
// POSTCONDITION: t.working_state is restored to node_idx's state on return.
@(private)
perform_playout :: proc(t: ^Tree, node_idx: int, evaluator: Evaluator, user_data: rawptr) -> f32 {
	player_perspective := t.nodes[node_idx].player_at_parent

	U: f32

	if t.nodes[node_idx].is_terminal {
		U = terminal_value_for_node(t, node_idx)
	} else if t.nodes[node_idx].N == 0 {
		v_theta := expand_node(t, node_idx, evaluator, user_data)

		cp := t.game.current_player(t.working_state)
		if cp != player_perspective {v_theta = 1.0 - v_theta}

		t.nodes[node_idx].first_eval_value = v_theta
		t.nodes[node_idx].has_eval = true

		if t.config.lambda > 0 {
			remaining := t.config.max_depth - t.nodes[node_idx].depth
			if remaining > 0 {
				z_L := fast_rollout(t, player_perspective, remaining, evaluator, user_data)
				U = (1.0 - t.config.lambda) * v_theta + t.config.lambda * z_L
			} else {
				U = v_theta
			}
		} else {
			U = v_theta
		}
	} else {
		slot := select_slot_puct(t, node_idx)
		action := t.nodes[node_idx].actions[slot]

		// Capture parent's current_player BEFORE applying the move so we can
		// stamp it as the new child's player_at_parent. After do_move the
		// working state's current_player has flipped.
		cp_parent := t.game.current_player(t.working_state)
		delta := t.game.do_move(t.working_state, action)

		if t.nodes[node_idx].child[slot] < 0 {
			child_idx := create_node(t, node_idx, action, cp_parent)
			t.nodes[node_idx].child[slot] = child_idx
		}

		child_idx := t.nodes[node_idx].child[slot]
		child_value := perform_playout(t, child_idx, evaluator, user_data)

		t.game.undo_move(t.working_state, delta)
		U = 1.0 - child_value
	}

	t.nodes[node_idx].N += 1
	t.nodes[node_idx].Q = t.nodes[node_idx].Q + (U - t.nodes[node_idx].Q) / f32(t.nodes[node_idx].N)
	return U
}

// Random-policy rollout from t.working_state. Applies do_move along the way
// and undoes ALL of them on return via the deferred unwind, so working_state
// ends back where it started.
@(private)
fast_rollout :: proc(
	t: ^Tree,
	player_perspective: i32,
	remaining_depth: int,
	evaluator: Evaluator,
	user_data: rawptr,
) -> f32 {
	cap_n := t.game.max_actions
	a_buf := make([]int, cap_n, context.temp_allocator)
	p_buf := make([]f32, cap_n, context.temp_allocator)
	defer delete(a_buf, context.temp_allocator)
	defer delete(p_buf, context.temp_allocator)

	deltas := make([dynamic]Move_Delta, 0, remaining_depth, context.temp_allocator)
	defer {
		#reverse for d in deltas {t.game.undo_move(t.working_state, d)}
		delete(deltas)
	}

	depth := 0
	value: f32
	for !t.game.is_terminal(t.working_state) && depth < remaining_depth {
		n := evaluator(t.working_state, a_buf, p_buf, &value, user_data)
		if n == 0 {break}
		action := sample_packed_action(a_buf[:n], p_buf[:n], t.config.rollout_temperature)
		d := t.game.do_move(t.working_state, action)
		append(&deltas, d)
		depth += 1
	}

	if t.game.is_terminal(t.working_state) {
		v := t.game.terminal_value(t.working_state)
		cp := t.game.current_player(t.working_state)
		if cp != player_perspective {v = 1.0 - v}
		return v
	}
	_ = evaluator(t.working_state, a_buf, p_buf, &value, user_data)
	cp := t.game.current_player(t.working_state)
	if cp != player_perspective {value = 1.0 - value}
	return value
}

// Sample Dirichlet noise over the root's slot list and mix it into logP.
// alpha and weight come from t.config. No-op if root has no slots yet.
@(private)
add_dirichlet_noise :: proc(t: ^Tree, alpha, weight: f32) {
	root := &t.nodes[0]
	n := len(root.actions)
	if n == 0 {return}

	noise := make([]f32, n, context.temp_allocator)
	defer delete(noise, context.temp_allocator)
	sum := f32(0)
	for k in 0 ..< n {
		noise[k] = gamma_sample(alpha)
		sum += noise[k]
	}
	for k in 0 ..< n {noise[k] /= sum}

	for k in 0 ..< n {
		prior := math.exp(root.logP[k])
		noisy := (1.0 - weight) * prior + weight * noise[k]
		root.logP[k] = log_safe(noisy)
	}
}

// Run num_simulations playouts from the root, applying PCR if configured.
// On entry/exit, t.working_state is at the root state.
run_simulations :: proc(t: ^Tree, num_simulations: int, evaluator: Evaluator, user_data: rawptr = nil) {
	use_tree_rng(t)
	n_sims := num_simulations
	if len(t.config.pcr_sims) > 0 {
		r := rand.float32()
		cum := f32(0)
		pick := len(t.config.pcr_sims) - 1
		for i in 0 ..< len(t.config.pcr_probs) {
			cum += t.config.pcr_probs[i]
			if r < cum {pick = i; break}
		}
		n_sims = t.config.pcr_sims[pick]
	}

	if !t.nodes[0].expanded {
		_ = expand_node(t, 0, evaluator, user_data)
		if t.config.dirichlet_alpha > 0 {
			add_dirichlet_noise(t, t.config.dirichlet_alpha, t.config.dirichlet_weight)
		}
	}

	for _ in 0 ..< n_sims {
		perform_playout(t, 0, evaluator, user_data)
	}
}
