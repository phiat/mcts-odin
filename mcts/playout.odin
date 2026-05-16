package mcts

import "core:math"

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
//
// IMPORTANT: the evaluator MUST emit only legal actions. MCTS does not
// re-check legality before calling game.do_move on the chosen slot — a
// nonzero prior for an illegal action will be silently selected and produce
// undefined behaviour (panic / no-op / corrupted state, depending on how the
// game implements do_move). NN-backed evaluators must mask their logits to
// legal moves before normalisation.
// ============================================================================

// API stability: stable.
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
	node_N_arr := t.node_N
	node_Q_arr := t.node_Q

	// One pass for {total_visits, sum_visited_priors}. Both feed the inner
	// loop: sqrt_total is the standard PUCT exploration term; sum_visited
	// drives the FPU reduction for unvisited slots.
	total_visits := 0
	sum_visited_priors := f32(0)
	for k in 0 ..< len(node.actions) {
		ci := node.child[k]
		if ci >= 0 {
			total_visits += node_N_arr[ci]
			sum_visited_priors += node.priors[k]
		}
	}
	sqrt_total := math.sqrt(f32(total_visits) + 1.0)

	// FPU (First-Play Urgency): unvisited children get Q in the side-to-move's
	// frame, reduced by sqrt(sum_visited_priors). This prevents the
	// "uniform-evaluator + low sims" funneling into slot 0 (see
	// mcts-odin-caq). node_Q is stored in player_at_parent's frame; flip to
	// get side-to-move's expectation. parent_Q_self < 0 (would only happen
	// pre-first-backup, which can't reach this path) is harmless — clipping
	// to 0 isn't worth the branch.
	parent_Q_self := 1.0 - node_Q_arr[node_idx]
	fpu_q := parent_Q_self - t.config.fpu_reduction * math.sqrt(sum_visited_priors)

	// Branchless argmax: pick winners with ternaries which Odin lowers to CMOV
	// on x86, removing a data-dependent branch from each iteration of the tight
	// inner loop. Likewise, fold the ci>=0 child-presence check into a single
	// mask so the body has no control flow at all.
	//
	// Reads child N/Q from parallel SoA slices on the Tree — touches only the
	// 4 + 8 = 12 hot bytes per child, not the full ~100-byte Node struct.
	best_slot := 0
	best_score := f32(min(f32))
	c_puct := t.config.c_puct
	for k in 0 ..< len(node.actions) {
		prior := node.priors[k]
		ci := node.child[k]
		has_child := ci >= 0
		// Index a valid node either way (root @0 always exists); mask the
		// Q/N contributions to fpu_q / 0 when no child is present.
		safe_ci := ci if has_child else 0
		q := node_Q_arr[safe_ci] if has_child else fpu_q
		n := node_N_arr[safe_ci] if has_child else 0
		u := c_puct * prior * sqrt_total / (1.0 + f32(n))
		score := q + u
		is_better := score > best_score
		best_score = score if is_better else best_score
		best_slot  = k     if is_better else best_slot
	}
	return best_slot
}

// Expand a leaf: call the evaluator on t.working_state, allocate the packed
// slot arrays in the tree arena, fill priors, mark expanded. Returns v_theta
// from working_state's current_player perspective (caller flips if needed).
@(private)
expand_node :: proc(t: ^Tree, node_idx: int, evaluator: Evaluator, user_data: rawptr) -> f32 {
	v: f32
	n := evaluator(t.working_state, t.eval_a_buf, t.eval_p_buf, &v, user_data)

	actions := make([]int, n, t.allocator)
	priors  := make([]f32, n, t.allocator)
	child   := make([]int, n, t.allocator)
	for k in 0 ..< n {
		actions[k] = t.eval_a_buf[k]
		priors[k]  = t.eval_p_buf[k]
		child[k]   = -1
	}
	t.nodes[node_idx].actions = actions
	t.nodes[node_idx].priors  = priors
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
	} else if t.node_N[node_idx] == 0 {
		v_theta := expand_node(t, node_idx, evaluator, user_data)

		if t.nodes[node_idx].cp_at_node != player_perspective {v_theta = 1.0 - v_theta}

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

		cp_parent := t.nodes[node_idx].cp_at_node
		delta := t.game.do_move(t.working_state, action)

		if t.nodes[node_idx].child[slot] < 0 {
			child_idx := create_node(t, t.working_state, node_idx, action, cp_parent)
			t.nodes[node_idx].child[slot] = child_idx
		}

		child_idx := t.nodes[node_idx].child[slot]
		child_value := perform_playout(t, child_idx, evaluator, user_data)

		t.game.undo_move(t.working_state, delta)
		U = 1.0 - child_value
	}

	t.node_N[node_idx] += 1
	t.node_Q[node_idx] += (U - t.node_Q[node_idx]) / f32(t.node_N[node_idx])
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
	deltas := make([dynamic]Move_Delta, 0, remaining_depth, t.scratch_allocator)
	defer {
		#reverse for d in deltas {t.game.undo_move(t.working_state, d)}
	}

	depth := 0
	value: f32
	for !t.game.is_terminal(t.working_state) && depth < remaining_depth {
		n := evaluator(t.working_state, t.eval_a_buf, t.eval_p_buf, &value, user_data)
		if n == 0 {break}
		action := sample_packed_action(&t.rng_state, t.eval_a_buf[:n], t.eval_p_buf[:n], t.config.rollout_temperature, t.scratch_allocator)
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
	_ = evaluator(t.working_state, t.eval_a_buf, t.eval_p_buf, &value, user_data)
	cp := t.game.current_player(t.working_state)
	if cp != player_perspective {value = 1.0 - value}
	return value
}

// Sample Dirichlet noise over the root's slot list and mix it into priors.
// alpha and weight come from t.config. No-op if root has no slots yet.
//
// Batched: the alpha-dependent Marsaglia-Tsang constants (`d`, `c`) are
// computed ONCE up front instead of in every per-slot gamma sample, and
// the inner gamma loop is inlined to skip the function-call/recursion
// overhead. Normalisation is folded into the prior-mix step so the noise
// buffer is touched exactly twice (fill+sum, then mix).
@(private)
add_dirichlet_noise :: proc(t: ^Tree, alpha, weight: f32) {
	root := &t.nodes[t.root_idx]
	n := len(root.actions)
	if n == 0 {return}

	noise := make([]f32, n, t.scratch_allocator)
	defer delete(noise, t.scratch_allocator)

	rng := &t.rng_state
	cache := &t.rng_normal_cache

	// For alpha < 1, Marsaglia-Tsang boosts via G(alpha+1) × U^(1/alpha).
	alpha_eff := alpha if alpha >= 1.0 else alpha + 1.0
	d := alpha_eff - 1.0 / 3.0
	c := 1.0 / math.sqrt(9.0 * d)
	use_boost := alpha < 1.0
	inv_alpha := f32(0)
	if use_boost {inv_alpha = 1.0 / alpha}

	sum := f32(0)
	for k in 0 ..< n {
		g: f32
		sample: for {
			x := xoshiro_normal(rng, cache)
			v := 1.0 + c * x
			if v <= 0.0 {continue sample}
			v = v * v * v
			u := xoshiro_next_f32(rng)
			if u < 1.0 - 0.0331 * x * x * x * x {g = d * v; break sample}
			if math.ln(u) < 0.5 * x * x + d * (1.0 - v + math.ln(v)) {g = d * v; break sample}
		}
		if use_boost {
			u := xoshiro_next_f32(rng)
			g *= math.pow(u, inv_alpha)
		}
		noise[k] = g
		sum += g
	}

	inv_sum := 1.0 / sum
	one_minus_weight := 1.0 - weight
	for k in 0 ..< n {
		root.priors[k] = one_minus_weight * root.priors[k] + weight * noise[k] * inv_sum
	}
}

// Run num_simulations playouts from the root, applying PCR if configured.
// On entry/exit, t.working_state is at the root state.
//
// API stability: stable.
run_simulations :: proc(t: ^Tree, num_simulations: int, evaluator: Evaluator, user_data: rawptr = nil) {
	free_all(t.scratch_allocator)
	n_sims := resolve_n_sims(t, num_simulations)

	if !t.nodes[t.root_idx].expanded && !t.nodes[t.root_idx].is_terminal {
		_ = expand_node(t, t.root_idx, evaluator, user_data)
	}
	maybe_add_root_dirichlet(t)

	for _ in 0 ..< n_sims {
		perform_playout(t, t.root_idx, evaluator, user_data)
	}
}
