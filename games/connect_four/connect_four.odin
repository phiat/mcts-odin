package connect_four

import "../../mcts"

// 7×6 Connect Four. Players: 0 = Yellow, 1 = Red. Cells: -1 empty, 0 = Yellow, 1 = Red.
//
// Actions are column indices 0..6 (drop). game.max_actions = 7.
// Cells are indexed as cells[row * COLS + col], row 0 is the bottom.

COLS :: 7
ROWS :: 6
N_CELLS :: COLS * ROWS

State :: struct {
	cells:          [N_CELLS]i8,
	column_height:  [COLS]i8,   // next empty row in each column, 0..6
	to_play:        i32,        // 0 or 1
	total_moves:    i32,
	winner:         i32,        // -1 if no winner yet
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for i in 0 ..< N_CELLS {s.cells[i] = -1}
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

// Returns true if there is a run of 4 of player `p` through cell (row, col)
// along direction (dr, dc).
@(private)
run_of_four :: proc(s: ^State, row, col: int, dr, dc: int, p: i8) -> bool {
	count := 1
	// Walk in +dir.
	r, c := row + dr, col + dc
	for r >= 0 && r < ROWS && c >= 0 && c < COLS && s.cells[r * COLS + c] == p {
		count += 1
		r += dr; c += dc
	}
	// Walk in -dir.
	r, c = row - dr, col - dc
	for r >= 0 && r < ROWS && c >= 0 && c < COLS && s.cells[r * COLS + c] == p {
		count += 1
		r -= dr; c -= dc
	}
	return count >= 4
}

// Returns the winner if the piece just placed at (row, col) created a
// 4-in-a-row through that cell. Otherwise -1.
@(private)
check_win_through :: proc(s: ^State, row, col: int) -> i32 {
	p := s.cells[row * COLS + col]
	if p < 0 {return -1}
	// Horizontal, vertical, two diagonals.
	if run_of_four(s, row, col, 0, 1, p) {return i32(p)}
	if run_of_four(s, row, col, 1, 0, p) {return i32(p)}
	if run_of_four(s, row, col, 1, 1, p) {return i32(p)}
	if run_of_four(s, row, col, 1, -1, p) {return i32(p)}
	return -1
}

is_terminal :: proc(state: rawptr) -> bool {
	s := cast(^State)state
	return s.winner >= 0 || s.total_moves == i32(N_CELLS)
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
	for c in 0 ..< COLS {
		if s.column_height[c] < i8(ROWS) {append(out, c)}
	}
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

// Move delta. We pack into Move_Delta.flags:
//   bits 0-2: action (column 0..6)
//   bit 3: 1 if this move set winner from -1 to something
//   bits 16-23: previous to_play (always 0 or 1)
//   bits 32-63: previous total_moves (i32 widened)
do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_winner := s.winner
	prev_to_play := s.to_play
	prev_total_moves := s.total_moves

	row := int(s.column_height[action])
	s.cells[row * COLS + action] = i8(s.to_play)
	s.column_height[action] += 1
	s.total_moves += 1
	w := check_win_through(s, row, action)
	if w >= 0 {s.winner = w}
	s.to_play = 1 - s.to_play

	flags: u64 = u64(action) & 0x7
	flags |= u64(prev_to_play) << 16
	flags |= u64(u32(prev_total_moves)) << 32
	if prev_winner < 0 && s.winner >= 0 {flags |= 1 << 3}
	return mcts.Move_Delta{flags = flags}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action := int(delta.flags & 0x7)
	prev_to_play := i32((delta.flags >> 16) & 0xFF)
	prev_total_moves := i32(u32(delta.flags >> 32))
	set_winner_flag := (delta.flags & (1 << 3)) != 0

	s.column_height[action] -= 1
	row := int(s.column_height[action])
	s.cells[row * COLS + action] = -1
	s.total_moves = prev_total_moves
	s.to_play = prev_to_play
	if set_winner_flag {s.winner = -1}
}

// Returns the Game vtable for Connect Four.
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
		max_actions    = COLS,
	}
}
