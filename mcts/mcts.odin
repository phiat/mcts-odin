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
//   - Each Node carries a packed action list (actions/priors/child slices), all
//     sized to the policy length at first evaluation. PUCT scan is a single
//     tight loop over these arrays — no map hashes on the hot path.
//   - is_terminal and a perspective-raw terminal_value are cached on each
//     Node at creation, so the PUCT descent never re-asks the game.
//   - All tree-internal allocations (nodes, per-node slices) live in a
//     per-tree growing arena. destroy() frees the whole arena.
// ============================================================================

// API stability: stable. Field names are committed; default values from
// default_config() may shift on minor bumps.
Config :: struct {
	c_puct:              f32,
	lambda:              f32,  // 0 = pure value head, 1 = pure rollout
	dirichlet_alpha:     f32,  // 0 = no root noise
	dirichlet_weight:    f32,
	temperature:         f32,
	max_depth:           int,  // tree + rollout combined budget
	rollout_temperature: f32,

	// First-Play Urgency (FPU) reduction. Unvisited children get Q in the
	// side-to-move's frame:
	//
	//   Q_fpu = (1 - parent_Q_stored) - fpu_reduction * sqrt(sum_visited_priors)
	//
	// where parent_Q_stored is the parent's running Q (in player_at_parent's
	// frame; flipped to get the side-to-move's expectation) and
	// sum_visited_priors is the total prior weight already committed to
	// visited slots. This anchors unvisited Q to "what the parent expects from
	// here" — closer to parent_Q for the first few explorations, dropping as
	// more priors get committed — so PUCT can't funnel into the first-visited
	// slot just because Q=0 default looked catastrophically worse than Q=0.5
	// after first eval (see mcts-odin-caq for the degeneracy this fixes).
	//
	// Reasonable values:
	//   0.00 — fpu_q = parent_Q exactly. Most permissive of unvisited slots.
	//   0.25 — KataGo non-root default (recommended; current default).
	//   0.75 — KataGo root default if you also use Dirichlet noise there.
	//   > 1  — strongly pessimistic about unvisited slots (rarely useful).
	//
	// Note: mcts-odin <= 0.1.1 used q=0 for unvisited children (the AlphaGo
	// Zero convention). FPU=parent_Q replaces that behavior wholesale — there
	// is no fpu_reduction value that reproduces the old q=0 default. This is
	// a deliberate algorithm correction for v0.2.
	//
	// Regime caveat: FPU is most useful when priors are informative. Under
	// uniform priors at very low sim budgets (e.g. 200 sims across 81 legal
	// Go moves), FPU's correct spread distributes visits so thinly that an
	// accidental concentration on a single slot can play stronger games — a
	// concentration-vs-spread tradeoff where individual visits are precious.
	// Production setups with NN policies won't hit this regime; A/B harnesses
	// running uniform-eval at low sims may, and the result there reflects
	// workload degeneracy rather than algorithm quality.
	fpu_reduction: f32,

	pcr_sims:  []int,
	pcr_probs: []f32,
}

// API stability: stable.
default_config :: proc() -> Config {
	return Config {
		c_puct              = 1.0,
		lambda              = 0.0,
		dirichlet_alpha     = 0.0,
		dirichlet_weight    = 0.25,
		temperature         = 1.0,
		max_depth           = 100,
		rollout_temperature = 1.0,
		fpu_reduction       = 0.25,
	}
}

// One tree node. Carries no copy of the game state — state is reconstructed
// on demand by descending from root with do_move along the recorded action
// path, and unwound with undo_move on the way back.
//
// Hot fields (N, N_virt, Q) live in parallel arrays on the Tree (t.node_N,
// t.node_N_virt, t.node_Q) so the PUCT inner loop reads them with a much
// tighter cache footprint than chasing the full Node struct on every child.
//
// API stability: experimental. Layout may change before 1.0 — reach for
// the accessor procs in readout.odin rather than touching fields directly.
Node :: struct {
	first_eval_value: f32,
	has_eval:         bool,
	expanded:         bool,    // true once the evaluator's policy has been folded into actions/priors
	is_terminal:      bool,    // cached at node creation
	terminal_v_raw:   f32,     // terminal_value from this node's current_player perspective (cached)

	parent_idx:         int,
	action_from_parent: int,   // the action the parent applied to reach this node; -1 for root
	player_at_parent:   i32,   // perspective tracking; 0 or 1
	cp_at_node:         i32,   // current_player at this node's position, cached at creation
	depth:              int,

	// Packed slot list. Sized at expansion time to len(policy returned by
	// the evaluator) — typically equal to legal_actions count when the user
	// masks their policy to legal moves.
	//
	//   actions[k] -> the action id at slot k
	//   priors[k]  -> linear-space prior probability (Dirichlet-mixed at root)
	//   child[k]   -> child node index, or -1 if this slot has never been visited
	//
	// Stored in linear space (not log) so the PUCT inner loop reads them
	// directly without a math.exp per slot per call.
	actions: []int,
	priors:  []f32,
	child:   []int,
}

// API stability: the struct is stable in that you `init` it by reference and
// pass it to every entry point. Fields are internal except for `working_state`,
// which is a stable read-only view of the tree's owned root state (use it for
// "is the game over?" checks between rounds; never mutate or free it).
Tree :: struct {
	nodes:     [dynamic]Node,

	// Hot fields in parallel slices, indexed by node index. Kept in lock-step
	// with `nodes`: every append/reserve on `nodes` does the same on all three.
	// PUCT reads child Q and N via these instead of `t.nodes[ci].{Q,N}`, which
	// would drag in the full Node struct on every random-access child probe.
	node_N:      [dynamic]int,
	node_N_virt: [dynamic]int,
	node_Q:      [dynamic]f32,

	config:    Config,
	game:      ^Game,
	rng_state: rand.Default_Random_State,

	// Index of the current root within `nodes`. Always 0 immediately after
	// init; can move when reuse_root is called between moves. Old root +
	// sibling subtrees stay allocated in the arena (memory reclaimed at
	// destroy). All public readouts and run_simulations entries operate
	// relative to root_idx.
	root_idx:    int,
	// True once Dirichlet noise has been mixed into the current root's
	// priors for this search round. Cleared by reuse_root so the next
	// run_simulations call re-applies noise to the new root.
	root_noised: bool,

	// The tree's single working state. Owned by the tree, freed via game.free
	// in destroy(). Mutated in-place during descents and restored at the end
	// of each simulation so it always equals the root state between sims.
	working_state: rawptr,

	// Persistent scratch for evaluator (action, prob) writes. Allocated once
	// at init time, sized to game.max_actions. Both expand_node and
	// fast_rollout reuse these instead of make/delete-ing per call.
	eval_a_buf: []int,
	eval_p_buf: []f32,

	// Per-tree growing arena for permanent allocations: nodes and per-node
	// slot arrays. destroy() frees it all in one shot.
	arena:     virtual.Arena,
	allocator: runtime.Allocator,

	// Per-tree scratch arena, reset at the top of each run_simulations call.
	// All transient allocations inside MCTS (descent paths, move-delta
	// stacks, policy noise, batched-eval scratch slices) live here, so we
	// never disturb the caller's context.temp_allocator.
	scratch_arena:     virtual.Arena,
	scratch_allocator: runtime.Allocator,
}

// init: initializes `t` in-place at its final address. Do NOT return Tree by
// value — t.allocator embeds a pointer into t.arena and moving the struct
// dangles it.
//
// root_state is consumed: the tree takes ownership and will free it via
// game.free when the tree is destroyed. Caller should not touch root_state
// after this returns.
//
// API stability: stable.
init :: proc(t: ^Tree, game: ^Game, root_state: rawptr, config: Config, seed: u64 = 0) {
	t^ = {}
	t.config = config
	t.game = game
	t.working_state = root_state
	_ = virtual.arena_init_growing(&t.arena, 8 << 20)
	t.allocator = virtual.arena_allocator(&t.arena)
	_ = virtual.arena_init_growing(&t.scratch_arena, 1 << 20)
	t.scratch_allocator = virtual.arena_allocator(&t.scratch_arena)

	t.nodes = make([dynamic]Node, 0, 64, t.allocator)
	t.node_N      = make([dynamic]int, 0, 64, t.allocator)
	t.node_N_virt = make([dynamic]int, 0, 64, t.allocator)
	t.node_Q      = make([dynamic]f32, 0, 64, t.allocator)
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
		cp_at_node         = cp,
		depth              = 0,
		is_terminal        = game.is_terminal(root_state),
	}
	if root.is_terminal {root.terminal_v_raw = game.terminal_value(root_state)}
	append(&t.nodes, root)
	append(&t.node_N, 0)
	append(&t.node_N_virt, 0)
	append(&t.node_Q, f32(0))
}

// API stability: stable.
destroy :: proc(t: ^Tree) {
	if t.game != nil && t.game.free != nil && t.working_state != nil {
		t.game.free(t.working_state)
	}
	virtual.arena_destroy(&t.scratch_arena)
	virtual.arena_destroy(&t.arena)
	t^ = {}
}

// Create a child node. The caller is responsible for having applied do_move
// to `state` before this call so is_terminal / terminal_value / current_player
// can be read off it directly. `state` is t.working_state for the
// single-threaded paths; for run_simulations_threaded each worker passes its
// own per-worker clone instead.
//
// NOTE: appending to t.nodes may reallocate; never hold a ^Node across this
// call. The returned index stays valid. Threaded callers must hold the
// expand mutex — t.nodes and the SoA hot arrays are not multi-writer safe.
@(private)
create_node :: proc(t: ^Tree, state: rawptr, parent_idx: int, action: int, player_at_parent: i32) -> int {
	idx := len(t.nodes)
	depth := t.nodes[parent_idx].depth + 1 if parent_idx >= 0 else 0
	n := Node {
		parent_idx         = parent_idx,
		action_from_parent = action,
		player_at_parent   = player_at_parent,
		cp_at_node         = t.game.current_player(state),
		depth              = depth,
		is_terminal        = t.game.is_terminal(state),
	}
	if n.is_terminal {n.terminal_v_raw = t.game.terminal_value(state)}
	append(&t.nodes, n)
	append(&t.node_N, 0)
	append(&t.node_N_virt, 0)
	append(&t.node_Q, f32(0))
	return idx
}

// Bind t's RNG state into the current context so transitive callees pick it up.
@(private)
use_tree_rng :: proc(t: ^Tree) {
	context.random_generator = rand.default_random_generator(&t.rng_state)
}

// API stability: stable.
tree_size :: proc(t: ^Tree) -> int {
	return len(t.nodes)
}

// Resolve a node's cached terminal value to the perspective of its
// player_at_parent. Only meaningful when node.is_terminal is true.
//
// Uses the node's cached cp_at_node so callers no longer need to position
// working_state at this node before invoking.
@(private)
terminal_value_for_node :: proc(t: ^Tree, node_idx: int) -> f32 {
	node := &t.nodes[node_idx]
	v := node.terminal_v_raw
	if node.cp_at_node != node.player_at_parent {v = 1.0 - v}
	return v
}

// Re-root the tree at the child reached by `action` from the current root.
// Applies game.do_move(working_state, action) so working_state is positioned
// at the new root. Subtree depths are renormalised so the new root's depth
// is 0 (preserving the max_depth budget used by fast_rollout).
//
// If the action's slot was previously expanded, that subtree is kept; the
// old root and sibling subtrees become unreachable but stay in the arena
// (memory reclaimed at destroy()). If the action was unexplored or matches
// no slot, a fresh root node is allocated at the post-move position.
//
// Returns true if an existing subtree was reused, false on a synthetic root.
//
// API stability: stable.
reuse_root :: proc(t: ^Tree, action: int) -> bool {
	root := &t.nodes[t.root_idx]
	reused_idx := -1
	for k in 0 ..< len(root.actions) {
		if root.actions[k] == action {
			reused_idx = root.child[k]
			break
		}
	}

	t.game.do_move(t.working_state, action)
	t.root_noised = false

	if reused_idx < 0 {
		// Brand-new root for the post-move position; perspective = opposite
		// of side-to-move, matching init's convention.
		idx := len(t.nodes)
		cp := t.game.current_player(t.working_state)
		n := Node {
			parent_idx         = -1,
			action_from_parent = -1,
			player_at_parent   = 1 - cp,
			cp_at_node         = cp,
			depth              = 0,
			is_terminal        = t.game.is_terminal(t.working_state),
		}
		if n.is_terminal {n.terminal_v_raw = t.game.terminal_value(t.working_state)}
		append(&t.nodes, n)
		append(&t.node_N, 0)
		append(&t.node_N_virt, 0)
		append(&t.node_Q, f32(0))
		t.root_idx = idx
		return false
	}

	// Renormalise subtree depths: subtract reused root's old depth from every
	// reachable node so the new root sits at depth 0.
	offset := t.nodes[reused_idx].depth
	if offset > 0 {
		stack := make([dynamic]int, 0, 64, t.scratch_allocator)
		defer delete(stack)
		append(&stack, reused_idx)
		for len(stack) > 0 {
			cur := pop(&stack)
			t.nodes[cur].depth -= offset
			for k in 0 ..< len(t.nodes[cur].actions) {
				ci := t.nodes[cur].child[k]
				if ci >= 0 {append(&stack, ci)}
			}
		}
	}

	t.nodes[reused_idx].parent_idx = -1
	t.nodes[reused_idx].action_from_parent = -1
	t.root_idx = reused_idx
	return true
}
