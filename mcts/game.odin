package mcts

// Game is the vtable a host game implements so the generic MCTS core can drive
// it. State is opaque (rawptr); the core never inspects it. All procs take the
// state pointer that MCTS is currently working with.
//
// API stability: stable. Struct and field names are committed.
//
// Two-player zero-sum games are the primary target. current_player returns 0
// or 1; values are reported in [0, 1] from the side-to-move's perspective and
// flipped on the way up the tree. N-player support is a future extension and
// will require widening current_player's range and the backup convention.
Game :: struct {
	// Allocate a deep copy of state. The clone must be independently mutable.
	clone: proc(state: rawptr) -> rawptr,

	// Release a state allocated by clone (or by the host's own new_state proc).
	free: proc(state: rawptr),

	// Apply action in place. Returns a Move_Delta that undo_move can consume
	// to restore the prior state bit-for-bit. Move_Delta is opaque to MCTS —
	// the host is free to encode whatever it needs (captured pieces, hash, etc).
	//
	// MCTS guarantees action was returned by a prior legal_actions call on the
	// same state, so do_move does NOT need to re-check legality.
	do_move: proc(state: rawptr, action: int) -> Move_Delta,

	// Reverse do_move. After undo_move(delta), state must be observably
	// identical to its value immediately before the matching do_move.
	//
	// Required — there is currently no clone-on-descent fallback. A nil
	// undo_move will crash on the first descent step. Games whose state is
	// genuinely irreversible can pack everything needed for restoration into
	// Move_Delta.extra (heap allocation) at the cost of one alloc per move.
	undo_move: proc(state: rawptr, delta: Move_Delta),

	// True if the position is terminal (no further moves; outcome decided).
	is_terminal: proc(state: rawptr) -> bool,

	// Outcome from the side-to-move's perspective: 1.0 = win, 0.0 = loss,
	// 0.5 = draw. Only called when is_terminal returns true.
	terminal_value: proc(state: rawptr) -> f32,

	// Append legal action ids to `out`. MCTS owns `out` and clears it
	// before each call; the host just appends.
	legal_actions: proc(state: rawptr, out: ^[dynamic]int),

	// 0 or 1. MCTS uses this to track perspective for value backups.
	current_player: proc(state: rawptr) -> i32,

	// Upper bound on any action id this game emits, used to size buffers.
	// Action ids must lie in [0, max_actions); they do not need to be dense.
	max_actions: int,
}

// Important contract: evaluators (mcts.Evaluator and mcts.Evaluator_Batched)
// MUST mask their policy to legal actions only. MCTS does not re-check
// legality before calling do_move on the slot selected by PUCT — a nonzero
// prior for an illegal action will be silently chosen, and what happens next
// is whatever your do_move does on an illegal action (panic, no-op, corrupt
// state). NN evaluators must zero out illegal positions before normalising.

// Opaque delta returned by do_move. The host is the only entity that
// interprets the bytes — MCTS just hands it back to undo_move.
//
// We give the host two scalar slots (suitable for hash + small flag) and a
// pointer slot (for variable-length data like a captures stack allocated in
// the tree arena). If your game needs more, allocate a struct and store the
// pointer in extra.
//
// API stability: stable. The three-slot layout is committed; new slots only
// arrive in a 1.0 or behind a sentinel field.
Move_Delta :: struct {
	hash:  u64,
	flags: u64,
	extra: rawptr,
}
