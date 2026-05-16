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
// Backed by the same packed slot storage as the sequential path.
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
	eval_slot:   int,  // -1 if terminal
}

// PUCT slot selection with virtual-loss correction. Differs from the sequential
// version only in that visit counts and Q values are blended with N_virt (the
// number of in-flight virtual-loss-affected simulations descending through the
// slot's child).
@(private = "file")
select_slot_puct_vloss :: proc(t: ^Tree, node_idx: int) -> int {
	node := &t.nodes[node_idx]
	total_visits := 0
	for k in 0 ..< len(node.actions) {
		ci := node.child[k]
		if ci >= 0 {total_visits += t.nodes[ci].N + t.nodes[ci].N_virt}
	}
	sqrt_total := math.sqrt(f32(total_visits) + 1.0)

	best_slot := 0
	best_score := f32(min(f32))
	for k in 0 ..< len(node.actions) {
		prior := math.exp(node.logP[k])
		q := f32(0); n := 0; nv := 0
		ci := node.child[k]
		if ci >= 0 {
			q = t.nodes[ci].Q
			n = t.nodes[ci].N
			nv = t.nodes[ci].N_virt
		}
		n_eff := f32(n + nv)
		q_eff := (q * f32(n)) / n_eff if n_eff > 0 else 0.0
		u := t.config.c_puct * prior * sqrt_total / (1.0 + n_eff)
		score := q_eff + u
		if score > best_score {best_score = score; best_slot = k}
	}
	return best_slot
}

// Drive num_simulations leaf-parallel playouts, calling `evaluator` in batches
// of up to leaf_batch_size states at a time. Identical algorithm to the
// sequential run_simulations except that:
//   - virtual loss is applied along each descent path until the corresponding
//     leaf has been evaluated and backed up
//   - the evaluator gets a slice of states and returns policies/values for all
//     of them in one call
run_simulations_batched :: proc(
	t: ^Tree,
	num_simulations:  int,
	leaf_batch_size:  int,
	evaluator:        Evaluator_Batched,
	user_data:        rawptr = nil,
) {
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

	// Expand the root via a 1-state batch call so the API stays single-callback.
	if !t.nodes[0].expanded {
		cap_n := t.game.max_actions
		states := []rawptr{t.nodes[0].state}
		a_buf := make([]int, cap_n, context.temp_allocator)
		p_buf := make([]f32, cap_n, context.temp_allocator)
		a_views := [][]int{a_buf[:]}
		p_views := [][]f32{p_buf[:]}
		counts := []int{0}
		values := []f32{0}
		evaluator(states, a_views, p_views, counts, values, user_data)
		n := counts[0]
		actions := make([]int, n, t.allocator)
		logP    := make([]f32, n, t.allocator)
		child   := make([]int, n, t.allocator)
		for k in 0 ..< n {
			actions[k] = a_buf[k]
			logP[k]    = log_safe(p_buf[k])
			child[k]   = -1
		}
		t.nodes[0].actions = actions
		t.nodes[0].logP    = logP
		t.nodes[0].child   = child
		t.nodes[0].expanded = true

		if t.config.dirichlet_alpha > 0 {
			add_dirichlet_noise(t, t.config.dirichlet_alpha, t.config.dirichlet_weight)
		}
	}

	completed := 0
	cap_n := t.game.max_actions
	for completed < n_sims {
		target := min(leaf_batch_size, n_sims - completed)
		pending := make([dynamic]Pending_Leaf, 0, target, context.temp_allocator)
		defer {
			for &p in pending {delete(p.path)}
			delete(pending)
		}
		eval_states := make([dynamic]rawptr, 0, target, context.temp_allocator)
		defer delete(eval_states)

		for _ in 0 ..< target {
			path := make([dynamic]int, 0, 8)
			node_idx := 0
			append(&path, node_idx)

			for {
				// Terminal — back up the value immediately, no evaluator call.
				if t.game.is_terminal(t.nodes[node_idx].state) {
					U := t.game.terminal_value(t.nodes[node_idx].state)
					cp := t.game.current_player(t.nodes[node_idx].state)
					persp := t.nodes[node_idx].player_at_parent
					if cp != persp {U = 1.0 - U}
					append(&pending, Pending_Leaf {
						path = path, leaf_idx = node_idx,
						is_terminal = true, terminal_U = U, eval_slot = -1,
					})
					for idx in path {t.nodes[idx].N_virt += 1}
					break
				}
				// Unexpanded — needs an evaluator call.
				if !t.nodes[node_idx].expanded {
					append(&pending, Pending_Leaf {
						path = path, leaf_idx = node_idx,
						is_terminal = false, eval_slot = len(eval_states),
					})
					append(&eval_states, t.nodes[node_idx].state)
					for idx in path {t.nodes[idx].N_virt += 1}
					break
				}

				// Expanded — descend on the best slot.
				slot := select_slot_puct_vloss(t, node_idx)
				action := t.nodes[node_idx].actions[slot]

				if t.nodes[node_idx].child[slot] < 0 {
					new_state := t.game.clone(t.nodes[node_idx].state)
					t.game.do_move(new_state, action)
					cp := t.game.current_player(t.nodes[node_idx].state)
					child_idx := create_node(t, new_state, node_idx, cp)
					t.nodes[node_idx].child[slot] = child_idx
					append(&path, child_idx)

					pl: Pending_Leaf
					pl.path = path
					pl.leaf_idx = child_idx
					pl.is_terminal = false
					pl.eval_slot = len(eval_states)
					if t.game.is_terminal(t.nodes[child_idx].state) {
						U := t.game.terminal_value(t.nodes[child_idx].state)
						cp_c := t.game.current_player(t.nodes[child_idx].state)
						persp := t.nodes[child_idx].player_at_parent
						if cp_c != persp {U = 1.0 - U}
						pl.is_terminal = true
						pl.terminal_U = U
						pl.eval_slot = -1
					} else {
						append(&eval_states, t.nodes[child_idx].state)
					}
					append(&pending, pl)
					for idx in path {t.nodes[idx].N_virt += 1}
					break
				}
				child_idx := t.nodes[node_idx].child[slot]
				append(&path, child_idx)
				node_idx = child_idx
			}
		}

		// Evaluate all non-terminal leaves in one shot.
		a_buf := make([][]int, len(eval_states), context.temp_allocator)
		p_buf := make([][]f32, len(eval_states), context.temp_allocator)
		counts := make([]int, len(eval_states), context.temp_allocator)
		values := make([]f32, len(eval_states), context.temp_allocator)
		// Per-state scratch backing the slice-of-slice views.
		a_storage := make([]int,  cap_n * len(eval_states), context.temp_allocator)
		p_storage := make([]f32, cap_n * len(eval_states), context.temp_allocator)
		for i in 0 ..< len(eval_states) {
			a_buf[i] = a_storage[i * cap_n : (i + 1) * cap_n]
			p_buf[i] = p_storage[i * cap_n : (i + 1) * cap_n]
		}
		if len(eval_states) > 0 {
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
					logP    := make([]f32, n, t.allocator)
					child   := make([]int, n, t.allocator)
					for k in 0 ..< n {
						actions[k] = a_buf[pl.eval_slot][k]
						logP[k]    = log_safe(p_buf[pl.eval_slot][k])
						child[k]   = -1
					}
					t.nodes[pl.leaf_idx].actions = actions
					t.nodes[pl.leaf_idx].logP    = logP
					t.nodes[pl.leaf_idx].child   = child
					t.nodes[pl.leaf_idx].expanded = true
				}
				cp := t.game.current_player(t.nodes[pl.leaf_idx].state)
				persp := t.nodes[pl.leaf_idx].player_at_parent
				U = (1.0 - v_theta) if cp != persp else v_theta
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
