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
//   - Each Node carries a packed action list (actions/logP/child slices), all
//     sized to the policy length at first evaluation. PUCT scan is a single
//     tight loop over these arrays — no map hashes on the hot path.
//   - All tree-internal allocations (nodes, per-node slices, cloned states)
//     live in a per-tree growing arena. destroy() frees the whole arena.
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

// Single tree node. State pointer is owned by the tree's arena and freed when
// the tree is destroyed. parent_idx is -1 for the root.
Node :: struct {
	N:                int,
	N_virt:           int,
	Q:                f32,
	first_eval_value: f32,
	has_eval:         bool,
	expanded:         bool,  // true once the evaluator's policy has been folded into actions/logP

	parent_idx:       int,
	player_at_parent: i32,   // perspective tracking; 0 or 1
	depth:            int,

	state:            rawptr,

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

	// Per-tree growing arena. Nodes, per-node slot arrays, game-state clones —
	// all allocated through this. destroy() frees it all in one shot.
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
	_ = virtual.arena_init_growing(&t.arena, 8 << 20)
	t.allocator = virtual.arena_allocator(&t.arena)

	t.nodes = make([dynamic]Node, 0, 64, t.allocator)
	t.rng_state = rand.create(seed if seed != 0 else 0xC0FFEE_DECADE)

	// Root perspective = the player NOT to move at root, so that values get
	// flipped correctly on the way up. Matches autogodin's convention:
	//   player_at_parent for the root = opposite of root.current_player.
	cp := game.current_player(root_state)
	root := Node {
		parent_idx       = -1,
		player_at_parent = 1 - cp,
		depth            = 0,
		state            = root_state,
	}
	append(&t.nodes, root)
}

destroy :: proc(t: ^Tree) {
	// Game states that live in the tree need explicit free if the game holds
	// outside-arena resources (e.g. its own heap maps). Walk and free.
	if t.game != nil && t.game.free != nil {
		for &node in t.nodes {
			if node.state != nil {t.game.free(node.state)}
		}
	}
	virtual.arena_destroy(&t.arena)
	t^ = {}
}

// Create a child node. state ownership transfers to the tree.
//
// NOTE: appending to t.nodes may reallocate; never hold a ^Node across this
// call. The returned index stays valid.
@(private)
create_node :: proc(t: ^Tree, state: rawptr, parent_idx: int, player_at_parent: i32) -> int {
	idx := len(t.nodes)
	depth := t.nodes[parent_idx].depth + 1 if parent_idx >= 0 else 0
	append(&t.nodes, Node {
		parent_idx       = parent_idx,
		player_at_parent = player_at_parent,
		depth            = depth,
		state            = state,
	})
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
