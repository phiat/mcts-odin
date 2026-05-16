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
// Move_Delta packing: do_move allocates a fresh ^Adapter_Delta (struct holding
// the board-level MoveDelta plus a small captures slice) on context.allocator,
// stashes the pointer in Move_Delta.extra, and undo_move reads it back. Both
// allocations are released by undo_move. When MCTS runs in clone-on-descent
// mode (its default), it discards the Move_Delta — the allocation is leaked,
// which is acceptable for now since clone-on-descent already implies fresh
// per-node state.

import "../../mcts"

// Bundle that lives behind Move_Delta.extra. Owns its captures buffer.
Adapter_Delta :: struct {
	delta:    MoveDelta,
	captures: [dynamic]CaptureRecord,
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
	return b.size * b.size
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
	n := b.size * b.size
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
	internal_action := PASS_ACTION if action == b.size * b.size else action

	ad := new(Adapter_Delta)
	ad.captures = make([dynamic]CaptureRecord, 0, 4)
	ad.delta = do_move(b, internal_action, &ad.captures)
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
	undo_move(b, ad.delta, &ad.captures)
	delete(ad.captures)
	free(ad)
}

// Returns the Game vtable for Go. The caller picks the board size when
// constructing the initial state via new_state; max_actions is sized for the
// largest board you intend to use with this vtable (defaults to 9x9 + pass).
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
