package mcts

import "core:math"
import "core:math/rand"

// ============================================================================
// Action selection + tree introspection.
//
// All map-returning readouts allocate with the caller's allocator (default:
// context.allocator). They're convenience views over the packed slot storage
// in the root node — fine for once-per-move use, not the hot path.
// ============================================================================

// Visit-count-based action probabilities at the root.
//   temperature == 0 -> argmax: one slot gets 1.0, rest get 0.0
//   temperature  > 0 -> proportional to N(a)^(1/T)
// If the root has no children yet, falls back to uniform over its action slots.
get_action_probabilities :: proc(
	t: ^Tree,
	temperature: f32 = 1.0,
	allocator := context.allocator,
) -> map[int]f32 {
	root := &t.nodes[t.root_idx]
	n := len(root.actions)

	out := make(map[int]f32, n, allocator)
	if n == 0 {return out}

	any_child := false
	for k in 0 ..< n {
		if root.child[k] >= 0 {any_child = true; break}
	}
	if !any_child {
		uniform := 1.0 / f32(n)
		for k in 0 ..< n {out[root.actions[k]] = uniform}
		return out
	}

	if temperature == 0 {
		best_slot := 0
		best_visits := -1
		for k in 0 ..< n {
			ci := root.child[k]
			v := 0 if ci < 0 else t.nodes[ci].N
			if v > best_visits {best_visits = v; best_slot = k}
		}
		for k in 0 ..< n {
			out[root.actions[k]] = 1.0 if k == best_slot else 0.0
		}
		return out
	}

	total := f32(0)
	for k in 0 ..< n {
		ci := root.child[k]
		visits := 0 if ci < 0 else t.nodes[ci].N
		val := math.pow(f32(visits), 1.0 / temperature)
		out[root.actions[k]] = val
		total += val
	}
	if total == 0 {
		uniform := 1.0 / f32(n)
		for k in 0 ..< n {out[root.actions[k]] = uniform}
		return out
	}
	for action, v in out {out[action] = v / total}
	return out
}

// Sample an action from the visit-count distribution. temperature == 0 is
// deterministic argmax; temperature > 0 samples categorically.
select_action :: proc(t: ^Tree, temperature: f32 = 1.0) -> int {
	use_tree_rng(t)
	probs := get_action_probabilities(t, temperature)
	defer delete(probs)

	if temperature == 0 {
		best_action := -1
		best_p := f32(-1)
		for action, p in probs {
			if p > best_p {best_p = p; best_action = action}
		}
		return best_action
	}

	r := rand.float32()
	cum := f32(0)
	last_action := -1
	for action, p in probs {
		last_action = action
		cum += p
		if r < cum {return action}
	}
	return last_action
}

get_root_visit_count :: proc(t: ^Tree) -> int {
	return t.nodes[t.root_idx].N
}

get_root_q_value :: proc(t: ^Tree) -> f32 {
	return t.nodes[t.root_idx].Q
}

get_child_visit_counts :: proc(t: ^Tree, allocator := context.allocator) -> map[int]int {
	root := &t.nodes[t.root_idx]
	out := make(map[int]int, len(root.actions), allocator)
	for k in 0 ..< len(root.actions) {
		ci := root.child[k]
		if ci >= 0 {out[root.actions[k]] = t.nodes[ci].N}
	}
	return out
}

get_child_q_values :: proc(t: ^Tree, allocator := context.allocator) -> map[int]f32 {
	root := &t.nodes[t.root_idx]
	out := make(map[int]f32, len(root.actions), allocator)
	for k in 0 ..< len(root.actions) {
		ci := root.child[k]
		if ci >= 0 {out[root.actions[k]] = t.nodes[ci].Q}
	}
	return out
}

get_child_first_eval_values :: proc(t: ^Tree, allocator := context.allocator) -> map[int]f32 {
	root := &t.nodes[t.root_idx]
	out := make(map[int]f32, len(root.actions), allocator)
	for k in 0 ..< len(root.actions) {
		ci := root.child[k]
		if ci >= 0 && t.nodes[ci].has_eval {
			out[root.actions[k]] = t.nodes[ci].first_eval_value
		}
	}
	return out
}

// Root priors (exponentiated logP — i.e., post-Dirichlet if noise was added).
get_root_policy_priors :: proc(t: ^Tree, allocator := context.allocator) -> map[int]f32 {
	root := &t.nodes[t.root_idx]
	out := make(map[int]f32, len(root.actions), allocator)
	for k in 0 ..< len(root.actions) {
		out[root.actions[k]] = math.exp(root.logP[k])
	}
	return out
}

// For each root child, the deepest depth reached in its subtree.
get_child_max_subtree_depths :: proc(t: ^Tree, allocator := context.allocator) -> map[int]int {
	root := &t.nodes[t.root_idx]
	out := make(map[int]int, len(root.actions), allocator)
	stack := make([dynamic]int, 0, 64, context.temp_allocator)
	defer delete(stack)
	for k in 0 ..< len(root.actions) {
		ci := root.child[k]
		if ci < 0 {continue}
		max_depth := t.nodes[ci].depth
		clear(&stack)
		append(&stack, ci)
		for len(stack) > 0 {
			cur := pop(&stack)
			if t.nodes[cur].depth > max_depth {max_depth = t.nodes[cur].depth}
			for j in 0 ..< len(t.nodes[cur].actions) {
				cj := t.nodes[cur].child[j]
				if cj >= 0 {append(&stack, cj)}
			}
		}
		out[root.actions[k]] = max_depth
	}
	return out
}
