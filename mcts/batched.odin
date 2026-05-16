package mcts

import "core:math"
import "core:math/rand"

// ============================================================================
// Leaf-parallel MCTS with virtual loss.
//
// Used when the evaluator is expensive (e.g. a neural net on GPU) and benefits
// from batching: the tree descends a batch of leaves before calling the
// evaluator once on all of them, applying virtual loss along each path so the
// next descent doesn't immediately repeat the same trajectory.
//
// Threads working_state through each descent: do_move on the way down,
// undo_move on the way back to root before starting the next batch member.
// The leaf state is captured as a CLONE (snapshot) at the moment the descent
// reaches a needs-eval leaf — that's the only point we materialize state for
// later use by the evaluator.
// ============================================================================

Evaluator_Batched :: #type proc(
	states:      []rawptr,
	out_actions: [][]int,    // pre-sliced views per state; length == game.max_actions each
	out_probs:   [][]f32,
	out_counts:  []int,      // host writes the number of (action, prob) pairs per state
	out_values:  []f32,
	user_data:   rawptr,
)

@(private = "file")
Pending_Leaf :: struct {
	path:        [dynamic]int,
	leaf_idx:    int,
	is_terminal: bool,
	terminal_U:  f32,
	eval_slot:   int,    // -1 if terminal; otherwise an index into the snapshot list
	snapshot:    rawptr, // clone captured at the leaf, nil if terminal
}

// Virtual-loss-aware PUCT. Identical to the sequential version except visit
// counts and Q values blend in N_virt (the number of in-flight descents
// through that child).
@(private = "file")
select_slot_puct_vloss :: proc(t: ^Tree, node_idx: int) -> int {
	node := &t.nodes[node_idx]
	total_visits := 0
	for k in 0 ..< len(node.actions) {
		ci := node.child[k]
		if ci >= 0 {total_visits += t.nodes[ci].N + t.nodes[ci].N_virt}
	}
	sqrt_total := math.sqrt(f32(total_visits) + 1.0)

	// Same branchless-argmax shape as select_slot_puct: ternaries lower to CMOV,
	// and child presence collapses to a mask so the inner loop has no
	// data-dependent control flow.
	best_slot := 0
	best_score := f32(min(f32))
	c_puct := t.config.c_puct
	for k in 0 ..< len(node.actions) {
		prior := node.priors[k]
		ci := node.child[k]
		has_child := ci >= 0
		safe_ci := ci if has_child else 0
		child := &t.nodes[safe_ci]
		q  := child.Q      if has_child else 0
		n  := child.N      if has_child else 0
		nv := child.N_virt if has_child else 0
		n_eff := f32(n + nv)
		q_eff := (q * f32(n)) / n_eff if n_eff > 0 else 0.0
		u := c_puct * prior * sqrt_total / (1.0 + n_eff)
		score := q_eff + u
		is_better := score > best_score
		best_score = score if is_better else best_score
		best_slot  = k     if is_better else best_slot
	}
	return best_slot
}

// One descent: walk from root to a leaf (terminal OR not-yet-expanded),
// applying do_move and recording the path of node indices + move deltas.
// At the leaf, either record the cached terminal U or capture a state
// snapshot for the batched evaluator, then unwind working_state via undo_move
// before returning. Returns the populated Pending_Leaf (path owned by caller's
// scope; deltas are temp-allocated and freed on unwind).
@(private = "file")
descend_one :: proc(t: ^Tree) -> Pending_Leaf {
	path := make([dynamic]int, 0, 8, t.scratch_allocator)
	deltas := make([dynamic]Move_Delta, 0, 8, t.scratch_allocator)

	append(&path, t.root_idx)
	current := t.root_idx

	pl := Pending_Leaf{eval_slot = -1, leaf_idx = -1}

	for {
		if t.nodes[current].is_terminal {
			pl.is_terminal = true
			pl.terminal_U = terminal_value_for_node(t, current)
			pl.leaf_idx = current
			break
		}
		if !t.nodes[current].expanded {
			pl.snapshot = t.game.clone(t.working_state)
			pl.leaf_idx = current
			break
		}

		slot := select_slot_puct_vloss(t, current)
		action := t.nodes[current].actions[slot]

		cp_parent := t.game.current_player(t.working_state)
		delta := t.game.do_move(t.working_state, action)
		append(&deltas, delta)

		if t.nodes[current].child[slot] < 0 {
			child_idx := create_node(t, current, action, cp_parent)
			t.nodes[current].child[slot] = child_idx
			append(&path, child_idx)

			if t.nodes[child_idx].is_terminal {
				pl.is_terminal = true
				pl.terminal_U = terminal_value_for_node(t, child_idx)
			} else {
				pl.snapshot = t.game.clone(t.working_state)
			}
			pl.leaf_idx = child_idx
			break
		}

		child_idx := t.nodes[current].child[slot]
		append(&path, child_idx)
		current = child_idx
	}

	for idx in path {t.nodes[idx].N_virt += 1}

	#reverse for d in deltas {t.game.undo_move(t.working_state, d)}

	pl.path = path
	return pl
}

// Drive num_simulations leaf-parallel playouts, calling `evaluator` in batches
// of up to leaf_batch_size states at a time. Virtual loss is applied along
// each descent path until the corresponding leaf has been evaluated and
// backed up. The evaluator receives a slice of cloned leaf states; it must
// not retain or free them.
run_simulations_batched :: proc(
	t: ^Tree,
	num_simulations:  int,
	leaf_batch_size:  int,
	evaluator:        Evaluator_Batched,
	user_data:        rawptr = nil,
) {
	use_tree_rng(t)
	free_all(t.scratch_allocator)
	if num_simulations > 0 {
		want := len(t.nodes) + min(num_simulations, 1 << 20)
		if cap(t.nodes) < want {reserve(&t.nodes, want)}
	}
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

	cap_n := t.game.max_actions

	// Expand the root via a 1-state batch call so the API stays single-callback.
	if !t.nodes[t.root_idx].expanded && !t.nodes[t.root_idx].is_terminal {
		states := []rawptr{t.working_state}
		a_views := [][]int{t.eval_a_buf}
		p_views := [][]f32{t.eval_p_buf}
		counts := []int{0}
		values := []f32{0}
		evaluator(states, a_views, p_views, counts, values, user_data)
		n := counts[0]
		actions := make([]int, n, t.allocator)
		priors  := make([]f32, n, t.allocator)
		child   := make([]int, n, t.allocator)
		for k in 0 ..< n {
			actions[k] = t.eval_a_buf[k]
			priors[k]  = t.eval_p_buf[k]
			child[k]   = -1
		}
		t.nodes[t.root_idx].actions = actions
		t.nodes[t.root_idx].priors  = priors
		t.nodes[t.root_idx].child   = child
		t.nodes[t.root_idx].expanded = true
	}
	if !t.root_noised && t.config.dirichlet_alpha > 0 {
		add_dirichlet_noise(t, t.config.dirichlet_alpha, t.config.dirichlet_weight)
		t.root_noised = true
	}

	completed := 0
	for completed < n_sims {
		target := min(leaf_batch_size, n_sims - completed)
		pending := make([dynamic]Pending_Leaf, 0, target, t.scratch_allocator)
		eval_states := make([dynamic]rawptr, 0, target, t.scratch_allocator)
		defer {
			for &p in pending {
				if p.snapshot != nil {t.game.free(p.snapshot)}
			}
		}

		for _ in 0 ..< target {
			pl := descend_one(t)
			// Both dynamic arrays are sized to exactly `target` at the top of
			// this gather; we append at most once per loop iteration so a grow
			// would mean a future change broke that invariant.
			assert(len(eval_states) < target, "eval_states grew past its cap")
			assert(len(pending) < target, "pending grew past its cap")
			if !pl.is_terminal {
				pl.eval_slot = len(eval_states)
				append(&eval_states, pl.snapshot)
			}
			append(&pending, pl)
		}

		// Batched evaluation. Per-state scratch slices view into one shared backing buffer.
		n_eval := len(eval_states)
		a_buf  := make([][]int, n_eval, t.scratch_allocator)
		p_buf  := make([][]f32, n_eval, t.scratch_allocator)
		counts := make([]int,   n_eval, t.scratch_allocator)
		values := make([]f32,   n_eval, t.scratch_allocator)
		a_storage := make([]int, cap_n * n_eval, t.scratch_allocator)
		p_storage := make([]f32, cap_n * n_eval, t.scratch_allocator)
		for i in 0 ..< n_eval {
			a_buf[i] = a_storage[i * cap_n : (i + 1) * cap_n]
			p_buf[i] = p_storage[i * cap_n : (i + 1) * cap_n]
		}
		if n_eval > 0 {
			evaluator(eval_states[:], a_buf, p_buf, counts, values, user_data)
		}

		for &pl in pending {
			U: f32
			if pl.is_terminal {
				U = pl.terminal_U
			} else {
				n := counts[pl.eval_slot]
				v_theta := values[pl.eval_slot]
				if !t.nodes[pl.leaf_idx].expanded {
					actions := make([]int, n, t.allocator)
					priors  := make([]f32, n, t.allocator)
					child   := make([]int, n, t.allocator)
					for k in 0 ..< n {
						actions[k] = a_buf[pl.eval_slot][k]
						priors[k]  = p_buf[pl.eval_slot][k]
						child[k]   = -1
					}
					t.nodes[pl.leaf_idx].actions = actions
					t.nodes[pl.leaf_idx].priors  = priors
					t.nodes[pl.leaf_idx].child   = child
					t.nodes[pl.leaf_idx].expanded = true
				}
				// v_theta is from snapshot's side-to-move perspective; flip if that
				// differs from this leaf's player_at_parent.
				cp_snap := t.game.current_player(pl.snapshot)
				persp := t.nodes[pl.leaf_idx].player_at_parent
				U = (1.0 - v_theta) if cp_snap != persp else v_theta
				if !t.nodes[pl.leaf_idx].has_eval {
					t.nodes[pl.leaf_idx].first_eval_value = U
					t.nodes[pl.leaf_idx].has_eval = true
				}
			}
			#reverse for idx in pl.path {
				t.nodes[idx].N_virt -= 1
				t.nodes[idx].N += 1
				t.nodes[idx].Q += (U - t.nodes[idx].Q) / f32(t.nodes[idx].N)
				U = 1.0 - U
			}
			completed += 1
		}
	}
}
