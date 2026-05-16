package tictactoe

import "../../mcts"

// 3×3 tic-tac-toe. Players: 0 = X, 1 = O. Cells: -1 empty, 0 = X, 1 = O.
//
// Actions are flat cell indices 0..8. game.max_actions = 9.

State :: struct {
	cells:      [9]i8,
	to_play:    i32,  // 0 or 1
	move_count: i32,
	winner:     i32,  // -1 if no winner yet
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for i in 0 ..< 9 {s.cells[i] = -1}
	s.winner = -1
	return rawptr(s)
}

free_state :: proc(state: rawptr) {
	if state == nil {return}
	free(cast(^State)state)
}

clone_state :: proc(state: rawptr) -> rawptr {
	src := cast(^State)state
	dst := new(State)
	dst^ = src^
	return rawptr(dst)
}

// Winning lines as triples of cell indices. Used by do_move and undo_move.
@(private)
LINES := [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8},   // rows
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8},   // cols
	{0, 4, 8}, {2, 4, 6},              // diagonals
}

// Returns the player at `cells[a]` if cells a,b,c are all the same non-empty
// piece; otherwise returns -1.
@(private)
line_winner :: proc(s: ^State, a, b, c: int) -> i32 {
	v := s.cells[a]
	if v < 0 {return -1}
	if s.cells[b] == v && s.cells[c] == v {return i32(v)}
	return -1
}

// Returns the winner if the move at `cell` (just placed by player p) created
// a 3-in-a-row through that cell. Otherwise -1.
@(private)
check_win_through :: proc(s: ^State, cell: int) -> i32 {
	for line in LINES {
		if line[0] == cell || line[1] == cell || line[2] == cell {
			w := line_winner(s, line[0], line[1], line[2])
			if w >= 0 {return w}
		}
	}
	return -1
}

is_terminal :: proc(state: rawptr) -> bool {
	s := cast(^State)state
	return s.winner >= 0 || s.move_count == 9
}

// In [0, 1] from side-to-move's perspective. Side-to-move is the LOSER on a
// won board (the winner just moved and to_play flipped to the opponent).
terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	if s.winner < 0 {return 0.5}             // draw
	return 1.0 if s.winner == s.to_play else 0.0
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if s.winner >= 0 {return}
	for i in 0 ..< 9 {
		if s.cells[i] < 0 {append(out, i)}
	}
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

// Move delta. We pack into Move_Delta.flags:
//   bit 0: 1 if this move set winner from -1 to something
//   bits 8-15: the action index (so undo knows which cell to clear)
//   bits 16-31: the previous to_play value (always 0 or 1, but we keep it explicit)
//   bits 32-63: the previous move_count (i32 widened)
do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_winner := s.winner
	prev_to_play := s.to_play
	prev_move_count := s.move_count

	s.cells[action] = i8(s.to_play)
	s.move_count += 1
	w := check_win_through(s, action)
	if w >= 0 {s.winner = w}
	s.to_play = 1 - s.to_play

	flags: u64 = u64(action) << 8
	flags |= u64(prev_to_play) << 16
	flags |= u64(u32(prev_move_count)) << 32
	if prev_winner < 0 && s.winner >= 0 {flags |= 1}
	return mcts.Move_Delta{flags = flags}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action := int((delta.flags >> 8) & 0xFF)
	prev_to_play := i32((delta.flags >> 16) & 0xFFFF)
	prev_move_count := i32(u32(delta.flags >> 32))
	set_winner_flag := (delta.flags & 1) != 0

	s.cells[action] = -1
	s.move_count = prev_move_count
	s.to_play = prev_to_play
	if set_winner_flag {s.winner = -1}
}

// Returns the Game vtable for tic-tac-toe.
game :: proc() -> mcts.Game {
	return mcts.Game {
		clone          = clone_state,
		free           = free_state,
		do_move        = do_move,
		undo_move      = undo_move,
		is_terminal    = is_terminal,
		terminal_value = terminal_value,
		legal_actions  = legal_actions,
		current_player = current_player,
		max_actions    = 9,
	}
}

