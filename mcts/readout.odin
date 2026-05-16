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
//
// API stability: stable. The map[int]f32 return shape is committed for now;
// a flat-slice equivalent may be added in 0.x but won't replace this.
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
			v := 0 if ci < 0 else t.node_N[ci]
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
		visits := 0 if ci < 0 else t.node_N[ci]
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
//
// Iterates the root's packed slot list (deterministic order) rather than the
// map returned by get_action_probabilities — map iteration order is undefined
// in Odin, which would silently make the sampled action non-reproducible even
// with a fixed seed.
//
// API stability: stable.
select_action :: proc(t: ^Tree, temperature: f32 = 1.0) -> int {
	use_tree_rng(t)
	root := &t.nodes[t.root_idx]
	n := len(root.actions)
	if n == 0 {return -1}

	if temperature == 0 {
		best_slot := 0
		best_visits := -1
		for k in 0 ..< n {
			ci := root.child[k]
			v := 0 if ci < 0 else t.node_N[ci]
			if v > best_visits {best_visits = v; best_slot = k}
		}
		return root.actions[best_slot]
	}

	any_child := false
	for k in 0 ..< n {
		if root.child[k] >= 0 {any_child = true; break}
	}
	if !any_child {
		return root.actions[int(rand.float32() * f32(n))]
	}

	work := make([]f32, n, t.scratch_allocator)
	defer delete(work, t.scratch_allocator)

	total := f32(0)
	for k in 0 ..< n {
		ci := root.child[k]
		visits := 0 if ci < 0 else t.node_N[ci]
		v := math.pow(f32(visits), 1.0 / temperature)
		work[k] = v
		total += v
	}
	if total == 0 {
		return root.actions[int(rand.float32() * f32(n))]
	}

	r := rand.float32()
	cum := f32(0)
	for k in 0 ..< n {
		cum += work[k] / total
		if r < cum {return root.actions[k]}
	}
	return root.actions[n - 1]
}

// API stability: stable.
get_root_visit_count :: proc(t: ^Tree) -> int {
	return t.node_N[t.root_idx]
}

// API stability: stable.
get_root_q_value :: proc(t: ^Tree) -> f32 {
	return t.node_Q[t.root_idx]
}

// API stability: experimental — the map[int]X return shape is awkward for
// inner-loop use and likely to gain a flat-slice variant (or be replaced)
// before 1.0. Today's tests cover the current shape.
get_child_visit_counts :: proc(t: ^Tree, allocator := context.allocator) -> map[int]int {
	root := &t.nodes[t.root_idx]
	out := make(map[int]int, len(root.actions), allocator)
	for k in 0 ..< len(root.actions) {
		ci := root.child[k]
		if ci >= 0 {out[root.actions[k]] = t.node_N[ci]}
	}
	return out
}

// API stability: experimental (see get_child_visit_counts).
get_child_q_values :: proc(t: ^Tree, allocator := context.allocator) -> map[int]f32 {
	root := &t.nodes[t.root_idx]
	out := make(map[int]f32, len(root.actions), allocator)
	for k in 0 ..< len(root.actions) {
		ci := root.child[k]
		if ci >= 0 {out[root.actions[k]] = t.node_Q[ci]}
	}
	return out
}

// API stability: experimental (see get_child_visit_counts).
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

// Root priors (post-Dirichlet if noise was added).
//
// API stability: experimental (see get_child_visit_counts).
get_root_policy_priors :: proc(t: ^Tree, allocator := context.allocator) -> map[int]f32 {
	root := &t.nodes[t.root_idx]
	out := make(map[int]f32, len(root.actions), allocator)
	for k in 0 ..< len(root.actions) {
		out[root.actions[k]] = root.priors[k]
	}
	return out
}

// For each root child, the deepest depth reached in its subtree.
//
// API stability: experimental (see get_child_visit_counts). This one is
// particularly debug-only and may be removed in favour of a generic tree dump.
get_child_max_subtree_depths :: proc(t: ^Tree, allocator := context.allocator) -> map[int]int {
	root := &t.nodes[t.root_idx]
	out := make(map[int]int, len(root.actions), allocator)
	stack := make([dynamic]int, 0, 64, t.scratch_allocator)
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
