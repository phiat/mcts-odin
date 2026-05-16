package go_game

// Go vtable wrapping GoBoard for the generic mcts package.
//
// PASS action convention: in the MCTS-facing action space, the pass move is
// `size * size` — one past the last cell. The internal board uses PASS_ACTION
// (= -1) as its pass sentinel. The adapter procs below translate between the
// two so legal_actions / do_move / undo_move always see non-negative ids on the
// MCTS side and the canonical sentinel on the board side.
//
// Players: BLACK -> 0, WHITE -> 1 (MCTS convention).
//
// Move_Delta packing: do_move allocates a single Adapter_Delta carrying the
// board-level MoveDelta, stashes the pointer in Move_Delta.extra, and undo_move
// frees it. Captures live on the GoBoard's own reusable stack
// (b.captures); the delta indexes into it via capture_start/capture_count, so
// the adapter is one heap alloc per move, not two.

import "../../mcts"

// Bundle that lives behind Move_Delta.extra. Captures index into b.captures —
// no per-move dynamic array allocation here.
Adapter_Delta :: struct {
	delta: MoveDelta,
}

new_state :: proc(size: int = 9, komi: f32 = KOMI_DEFAULT, allocator := context.allocator) -> rawptr {
	b := new(GoBoard, allocator)
	b^ = make_go_board(size, komi, allocator)
	return rawptr(b)
}

free_state :: proc(state: rawptr) {
	if state == nil {return}
	b := cast(^GoBoard)state
	alloc := b.allocator
	destroy_go_board(b)
	free(b, alloc)
}

clone_state :: proc(state: rawptr) -> rawptr {
	src := cast(^GoBoard)state
	dst := new(GoBoard, src.allocator)
	dst^ = clone_go_board(src, src.allocator)
	return rawptr(dst)
}

// MCTS pass id for this state's size.
pass_id :: proc(b: ^GoBoard) -> int {
	return n_cells(b)
}

is_terminal :: proc(state: rawptr) -> bool {
	b := cast(^GoBoard)state
	return is_game_over(b)
}

// terminal_value is from the CURRENT to_play's perspective. At a Go terminal
// state both players have passed; to_play has flipped past the final mover.
// We map the winner color to a value in [0, 1]:
//   draw -> 0.5
//   winner == to_play -> 1.0
//   else -> 0.0
terminal_value :: proc(state: rawptr) -> f32 {
	b := cast(^GoBoard)state
	w := get_winner(b)
	if w == 0 {return 0.5}
	return 1.0 if w == b.to_play else 0.0
}

// Drain legal board moves into `out` and append the PASS action at the end.
// Pass is `b.size * b.size` per the package contract.
legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	b := cast(^GoBoard)state
	if is_game_over(b) {return}
	n := n_cells(b)
	for i in 0 ..< n {
		if is_legal_flat(b, i) {
			append(out, i)
		}
	}
	append(out, n) // PASS action id = size*size
}

current_player :: proc(state: rawptr) -> i32 {
	b := cast(^GoBoard)state
	return 0 if b.to_play == BLACK else 1
}

mcts_do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	b := cast(^GoBoard)state
	internal_action := PASS_ACTION if action == n_cells(b) else action

	ad := new(Adapter_Delta)
	ad.delta = do_move(b, internal_action, &b.captures)
	return mcts.Move_Delta {
		hash  = ad.delta.prev_current_hash,
		flags = 0,
		extra = rawptr(ad),
	}
}

mcts_undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	if delta.extra == nil {return}
	b := cast(^GoBoard)state
	ad := cast(^Adapter_Delta)delta.extra
	undo_move(b, ad.delta, &b.captures)
	free(ad)
}

// Returns the Game vtable for Go. The `size` argument sets `max_actions` to
// `size*size + 1` (board cells plus pass) — this MUST match the size you
// pass to `new_state` for any state you intend to run through this vtable.
// Mismatch is silent and dangerous: the MCTS core sizes its evaluator
// scratch buffers from `max_actions` at `Tree.init` time, so a state with
// more legal actions than the vtable's `max_actions` will produce
// out-of-bounds writes when an evaluator fills the buffers. Default 9×9.
game :: proc(size: int = 9) -> mcts.Game {
	return mcts.Game {
		clone          = clone_state,
		free           = free_state,
		do_move        = mcts_do_move,
		undo_move      = mcts_undo_move,
		is_terminal    = is_terminal,
		terminal_value = terminal_value,
		legal_actions  = legal_actions,
		current_player = current_player,
		max_actions    = size * size + 1,
	}
}
