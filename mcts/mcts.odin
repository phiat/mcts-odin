package mcts

import "base:runtime"
import "core:math/rand"
import "core:mem/virtual"

// ============================================================================
// Tree / Node / Config — generic MCTS data structures.
//
// State is opaque (rawptr). The game vtable is the only thing that interprets
// it. PUCT scoring, Dirichlet noise, action selection, virtual loss — all of
// it lives here, none of it cares which game is running.
//
// Storage layout:
//   - The Tree owns a single `working_state`. Simulations mutate it on the way
//     down (do_move) and restore it on the way up (undo_move). No per-node
//     state pointer; nodes are pure tree-bookkeeping and never carry a copy
//     of the game state.
//   - Each Node carries a packed action list (actions/logP/child slices), all
//     sized to the policy length at first evaluation. PUCT scan is a single
//     tight loop over these arrays — no map hashes on the hot path.
//   - is_terminal and a perspective-raw terminal_value are cached on each
//     Node at creation, so the PUCT descent never re-asks the game.
//   - All tree-internal allocations (nodes, per-node slices) live in a
//     per-tree growing arena. destroy() frees the whole arena.
// ============================================================================

Config :: struct {
	c_puct:              f32,
	lambda:              f32,  // 0 = pure value head, 1 = pure rollout
	dirichlet_alpha:     f32,  // 0 = no root noise
	dirichlet_weight:    f32,
	temperature:         f32,
	max_depth:           int,  // tree + rollout combined budget
	rollout_temperature: f32,

	pcr_sims:  []int,
	pcr_probs: []f32,
}

default_config :: proc() -> Config {
	return Config {
		c_puct              = 1.0,
		lambda              = 0.0,
		dirichlet_alpha     = 0.0,
		dirichlet_weight    = 0.25,
		temperature         = 1.0,
		max_depth           = 100,
		rollout_temperature = 1.0,
	}
}

// One tree node. Carries no copy of the game state — state is reconstructed
// on demand by descending from root with do_move along the recorded action
// path, and unwound with undo_move on the way back.
Node :: struct {
	N:                int,
	N_virt:           int,
	Q:                f32,
	first_eval_value: f32,
	has_eval:         bool,
	expanded:         bool,    // true once the evaluator's policy has been folded into actions/logP
	is_terminal:      bool,    // cached at node creation
	terminal_v_raw:   f32,     // terminal_value from this node's current_player perspective (cached)

	parent_idx:         int,
	action_from_parent: int,   // the action the parent applied to reach this node; -1 for root
	player_at_parent:   i32,   // perspective tracking; 0 or 1
	depth:              int,

	// Packed slot list. Sized at expansion time to len(policy returned by
	// the evaluator) — typically equal to legal_actions count when the user
	// masks their policy to legal moves.
	//
	//   actions[k] -> the action id at slot k
	//   logP[k]    -> log-prior (Dirichlet-mixed at the root)
	//   child[k]   -> child node index, or -1 if this slot has never been visited
	actions: []int,
	logP:    []f32,
	child:   []int,
}

Tree :: struct {
	nodes:     [dynamic]Node,
	config:    Config,
	game:      ^Game,
	rng_state: rand.Default_Random_State,

	// The tree's single working state. Owned by the tree, freed via game.free
	// in destroy(). Mutated in-place during descents and restored at the end
	// of each simulation so it always equals the root state between sims.
	working_state: rawptr,

	// Persistent scratch for evaluator (action, prob) writes. Allocated once
	// at init time, sized to game.max_actions. Both expand_node and
	// fast_rollout reuse these instead of make/delete-ing per call.
	eval_a_buf: []int,
	eval_p_buf: []f32,

	// Per-tree growing arena. Nodes and per-node slot arrays come from here.
	// destroy() frees it all in one shot.
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
}

// init: initializes `t` in-place at its final address. Do NOT return Tree by
// value — t.allocator embeds a pointer into t.arena and moving the struct
// dangles it.
//
// root_state is consumed: the tree takes ownership and will free it via
// game.free when the tree is destroyed. Caller should not touch root_state
// after this returns.
init :: proc(t: ^Tree, game: ^Game, root_state: rawptr, config: Config, seed: u64 = 0) {
	t^ = {}
	t.config = config
	t.game = game
	t.working_state = root_state
	_ = virtual.arena_init_growing(&t.arena, 8 << 20)
	t.allocator = virtual.arena_allocator(&t.arena)

	t.nodes = make([dynamic]Node, 0, 64, t.allocator)
	t.eval_a_buf = make([]int, game.max_actions, t.allocator)
	t.eval_p_buf = make([]f32, game.max_actions, t.allocator)
	t.rng_state = rand.create(seed if seed != 0 else 0xC0FFEE_DECADE)

	// Root perspective = the player NOT to move at root, so that values get
	// flipped correctly on the way up: a value reported from side-to-move's
	// view at the child becomes (1 - v) when looking back from the parent's.
	cp := game.current_player(root_state)
	root := Node {
		parent_idx         = -1,
		action_from_parent = -1,
		player_at_parent   = 1 - cp,
		depth              = 0,
		is_terminal        = game.is_terminal(root_state),
	}
	if root.is_terminal {root.terminal_v_raw = game.terminal_value(root_state)}
	append(&t.nodes, root)
}

destroy :: proc(t: ^Tree) {
	if t.game != nil && t.game.free != nil && t.working_state != nil {
		t.game.free(t.working_state)
	}
	virtual.arena_destroy(&t.arena)
	t^ = {}
}

// Create a child node. The caller is responsible for having applied do_move
// to t.working_state before this call, so we can read is_terminal /
// terminal_value / current_player off the working state directly.
//
// NOTE: appending to t.nodes may reallocate; never hold a ^Node across this
// call. The returned index stays valid.
@(private)
create_node :: proc(t: ^Tree, parent_idx: int, action: int, player_at_parent: i32) -> int {
	idx := len(t.nodes)
	depth := t.nodes[parent_idx].depth + 1 if parent_idx >= 0 else 0
	n := Node {
		parent_idx         = parent_idx,
		action_from_parent = action,
		player_at_parent   = player_at_parent,
		depth              = depth,
		is_terminal        = t.game.is_terminal(t.working_state),
	}
	if n.is_terminal {n.terminal_v_raw = t.game.terminal_value(t.working_state)}
	append(&t.nodes, n)
	return idx
}

// Bind t's RNG state into the current context so transitive callees pick it up.
@(private)
use_tree_rng :: proc(t: ^Tree) {
	context.random_generator = rand.default_random_generator(&t.rng_state)
}

tree_size :: proc(t: ^Tree) -> int {
	return len(t.nodes)
}

// Resolve a node's cached terminal value to the perspective of its
// player_at_parent. Only meaningful when node.is_terminal is true.
@(private)
terminal_value_for_node :: proc(t: ^Tree, node_idx: int) -> f32 {
	node := &t.nodes[node_idx]
	cp := t.game.current_player(t.working_state)
	v := node.terminal_v_raw
	if cp != node.player_at_parent {v = 1.0 - v}
	return v
}
