package mcts

import "core:fmt"
import "core:strings"

// ============================================================================
// Tree introspection helpers — Graphviz dot + JSON dumps of the search tree
// rooted at t.root_idx. Both walk every reachable node from root and emit a
// representation suitable for visualization, debugging exotic PUCT settings,
// or capturing a tree state in a test fixture.
//
// Not on the hot path — meant for inspection between run_simulations calls.
//
// API stability: experimental. Field set in either format may change before
// 1.0 as we learn what callers actually need.
// ============================================================================

// Graphviz dot. Each node's label shows index, N, Q (3 decimals), and depth;
// terminal nodes get a `*` suffix. Each edge is labeled with the action id
// taken from the parent. Pipe the result through `dot -Tpng > tree.png` or
// any other Graphviz layout engine.
//
// Caller owns the returned string and must `delete(s, allocator)` when done.
// Skips unreachable subtrees from before a reuse_root call.
dump_tree_dot :: proc(t: ^Tree, allocator := context.allocator) -> string {
	sb, _ := strings.builder_make(allocator)
	fmt.sbprintln(&sb, "digraph mcts {")
	fmt.sbprintln(&sb, `  node [shape=record, fontname="monospace"];`)
	dump_walk_dot(t, t.root_idx, &sb)
	fmt.sbprintln(&sb, "}")
	return strings.to_string(sb)
}

@(private = "file")
dump_walk_dot :: proc(t: ^Tree, node_idx: int, sb: ^strings.Builder) {
	n := &t.nodes[node_idx]
	terminal_mark := "*" if n.is_terminal else ""
	fmt.sbprintf(sb, "  n%d [label=\"#%d%s\\nN=%d Q=%.3f\\nd=%d\"];\n",
		node_idx, node_idx, terminal_mark,
		t.node_N[node_idx], t.node_Q[node_idx], n.depth)
	for k in 0 ..< len(n.actions) {
		ci := n.child[k]
		if ci < 0 {continue}
		fmt.sbprintf(sb, "  n%d -> n%d [label=\"%d\"];\n",
			node_idx, ci, n.actions[k])
		dump_walk_dot(t, ci, sb)
	}
}

// JSON. Returns a single object with `root_idx` and `nodes`: an array of
// per-node records. Each record carries the bookkeeping fields plus a
// `children` list (slot, action, prior, child_idx — child_idx is -1 if the
// slot was never expanded).
//
// Caller owns the returned string and must `delete(s, allocator)` when done.
dump_tree_json :: proc(t: ^Tree, allocator := context.allocator) -> string {
	sb, _ := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "{{\"root_idx\":%d,\"nodes\":[", t.root_idx)
	first := true
	dump_walk_json(t, t.root_idx, &sb, &first)
	fmt.sbprint(&sb, "]}")
	return strings.to_string(sb)
}

@(private = "file")
dump_walk_json :: proc(t: ^Tree, node_idx: int, sb: ^strings.Builder, first: ^bool) {
	n := &t.nodes[node_idx]
	if !first^ {fmt.sbprint(sb, ",")}
	first^ = false
	fmt.sbprintf(sb,
		"{{\"idx\":%d,\"parent_idx\":%d,\"action_from_parent\":%d," +
		"\"player_at_parent\":%d,\"cp_at_node\":%d,\"depth\":%d," +
		"\"is_terminal\":%t,\"expanded\":%t,\"has_eval\":%t," +
		"\"first_eval_value\":%.6f,\"N\":%d,\"N_virt\":%d,\"Q\":%.6f," +
		"\"children\":[",
		node_idx, n.parent_idx, n.action_from_parent,
		n.player_at_parent, n.cp_at_node, n.depth,
		n.is_terminal, n.expanded, n.has_eval,
		n.first_eval_value, t.node_N[node_idx], t.node_N_virt[node_idx], t.node_Q[node_idx])
	for k in 0 ..< len(n.actions) {
		if k > 0 {fmt.sbprint(sb, ",")}
		fmt.sbprintf(sb, "{{\"slot\":%d,\"action\":%d,\"prior\":%.6f,\"child_idx\":%d}}",
			k, n.actions[k], n.priors[k], n.child[k])
	}
	fmt.sbprint(sb, "]}")
	for k in 0 ..< len(n.actions) {
		ci := n.child[k]
		if ci >= 0 {dump_walk_json(t, ci, sb, first)}
	}
}
