package breakthrough

import "../../mcts"

// 8x8 Breakthrough (Dan Troyka, 2000). Players: 0 = Black, 1 = White.
// Black moves first.
//
// Setup: Black fills rows 0-1, White fills rows 6-7 (16 pawns each).
//
// Move: pick one of your pawns and move it one square forward —
//   - straight forward to an empty square, OR
//   - one square diagonally forward, either to an empty square or to a
//     square holding exactly one enemy pawn (which is captured).
// Backward, sideways, and straight-forward captures are illegal.
//
// "Forward" depends on the mover:
//   Black moves toward row 7 (positive row delta).
//   White moves toward row 0 (negative row delta).
//
// Win:
//   - any pawn reaches the opponent's back rank (row 7 for Black, row 0
//     for White); OR
//   - the opponent has zero pawns left (capture-out).
// No draws are possible.
//
// MCTS action space: from_cell (0..63) × direction (0..2) = 192 stable ids.
//   dir 0 = diagonal-left  (from mover's perspective)
//   dir 1 = straight forward
//   dir 2 = diagonal-right
// game.max_actions = 192.
//
// Move_Delta packing — zero per-move heap allocations:
//   hash: unused (0).
//   flags: bits  0..7    action id (0..191)
//          bit       8   captured_bit (1 if a piece was removed)
//          bit       9   prev_to_play (0 or 1)
//          bits 10..13   prev_winner+1 (0..2; 0=none, 1=Black, 2=White)
//          bits 16..31   prev_move_count
//          bits 32..39   prev_black_count (0..16)
//          bits 40..47   prev_white_count (0..16)

ROWS :: 8
COLS :: 8
N_CELLS :: ROWS * COLS
N_DIRS  :: 3
N_ACTIONS :: N_CELLS * N_DIRS // 192

EMPTY :: i8(-1)
BLACK :: i8(0)
WHITE :: i8(1)

State :: struct {
	cells:       [N_CELLS]i8,
	to_play:     i32,
	move_count:  i32,
	black_count: i32,
	white_count: i32,
	winner:      i32, // -1 none, 0 Black, 1 White
}

cell_idx :: proc "contextless" (r, c: int) -> int {
	return r * COLS + c
}

@(private)
in_bounds :: proc "contextless" (r, c: int) -> bool {
	return r >= 0 && r < ROWS && c >= 0 && c < COLS
}

// (dr, dc) for the mover's three forward directions. Black (0) advances +1
// in row, White (1) advances -1. dc is -1, 0, +1 for dir 0, 1, 2.
@(private)
forward_delta :: proc "contextless" (player: i32, dir: int) -> (dr, dc: int) {
	dr = 1 if player == 0 else -1
	dc = dir - 1
	return
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for i in 0 ..< N_CELLS {s.cells[i] = EMPTY}
	for c in 0 ..< COLS {
		s.cells[cell_idx(0, c)] = BLACK
		s.cells[cell_idx(1, c)] = BLACK
		s.cells[cell_idx(ROWS - 2, c)] = WHITE
		s.cells[cell_idx(ROWS - 1, c)] = WHITE
	}
	s.to_play = 0
	s.black_count = 16
	s.white_count = 16
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

is_terminal :: proc(state: rawptr) -> bool {
	s := cast(^State)state
	return s.winner >= 0
}

terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	if s.winner < 0 {return 0.5}
	return 1.0 if s.winner == s.to_play else 0.0
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

// Decompose an action id into (from_cell, dir).
@(private)
decode :: proc "contextless" (action: int) -> (from: int, dir: int) {
	from = action / N_DIRS
	dir  = action % N_DIRS
	return
}

// True if `action` is currently a legal move for the side to play.
@(private)
is_legal_action :: proc(s: ^State, action: int) -> bool {
	if action < 0 || action >= N_ACTIONS {return false}
	from, dir := decode(action)
	p := i8(s.to_play)
	if s.cells[from] != p {return false}
	r := from / COLS
	c := from % COLS
	dr, dc := forward_delta(s.to_play, dir)
	nr := r + dr
	nc := c + dc
	if !in_bounds(nr, nc) {return false}
	target := s.cells[cell_idx(nr, nc)]
	if dir == 1 {
		// Straight forward: destination must be empty.
		return target == EMPTY
	}
	// Diagonal: empty or enemy.
	return target == EMPTY || target != p
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if s.winner >= 0 {return}
	p := i8(s.to_play)
	for from in 0 ..< N_CELLS {
		if s.cells[from] != p {continue}
		for dir in 0 ..< N_DIRS {
			a := from * N_DIRS + dir
			if is_legal_action(s, a) {append(out, a)}
		}
	}
}

@(private)
pack_flags :: proc "contextless" (
	action: int, captured: bool,
	prev_to_play, prev_winner, prev_move_count, prev_black, prev_white: i32,
) -> u64 {
	flags := u64(action & 0xFF)
	if captured {flags |= u64(1) << 8}
	flags |= u64(prev_to_play & 1) << 9
	flags |= u64((prev_winner + 1) & 0xF) << 10
	flags |= u64(u32(prev_move_count) & 0xFFFF) << 16
	flags |= u64(prev_black & 0xFF) << 32
	flags |= u64(prev_white & 0xFF) << 40
	return flags
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (
	action: int, captured: bool,
	prev_to_play, prev_winner, prev_move_count, prev_black, prev_white: i32,
) {
	action = int(flags & 0xFF)
	captured = (flags >> 8) & 1 == 1
	prev_to_play = i32((flags >> 9) & 1)
	prev_winner = i32((flags >> 10) & 0xF) - 1
	prev_move_count = i32(u32(flags >> 16) & 0xFFFF)
	prev_black = i32((flags >> 32) & 0xFF)
	prev_white = i32((flags >> 40) & 0xFF)
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_to_play := s.to_play
	prev_winner := s.winner
	prev_move_count := s.move_count
	prev_black := s.black_count
	prev_white := s.white_count

	from, dir := decode(action)
	p := i8(s.to_play)
	r := from / COLS
	c := from % COLS
	dr, dc := forward_delta(s.to_play, dir)
	nr := r + dr
	nc := c + dc
	to := cell_idx(nr, nc)

	captured := s.cells[to] != EMPTY
	if captured {
		if s.cells[to] == BLACK {s.black_count -= 1}
		else                    {s.white_count -= 1}
	}

	s.cells[from] = EMPTY
	s.cells[to]   = p
	s.move_count += 1

	// Win check: back-rank reach or opponent capture-out.
	if p == BLACK && nr == ROWS - 1 {s.winner = 0}
	else if p == WHITE && nr == 0   {s.winner = 1}
	else if s.black_count == 0      {s.winner = 1}
	else if s.white_count == 0      {s.winner = 0}

	s.to_play = 1 - s.to_play

	return mcts.Move_Delta{
		hash  = 0,
		flags = pack_flags(action, captured,
			prev_to_play, prev_winner, prev_move_count, prev_black, prev_white),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action, captured, prev_to_play, prev_winner, prev_move_count, prev_black, prev_white :=
		unpack_flags(delta.flags)

	from, dir := decode(action)
	r := from / COLS
	c := from % COLS
	dr, dc := forward_delta(prev_to_play, dir)
	nr := r + dr
	nc := c + dc
	to := cell_idx(nr, nc)

	mover := i8(prev_to_play)
	opp   := i8(1 - prev_to_play)

	s.cells[to]   = opp if captured else EMPTY
	s.cells[from] = mover

	s.to_play = prev_to_play
	s.winner = prev_winner
	s.move_count = prev_move_count
	s.black_count = prev_black
	s.white_count = prev_white
}

game :: proc() -> mcts.Game {
	return mcts.Game{
		clone          = clone_state,
		free           = free_state,
		do_move        = do_move,
		undo_move      = undo_move,
		is_terminal    = is_terminal,
		terminal_value = terminal_value,
		legal_actions  = legal_actions,
		current_player = current_player,
		max_actions    = N_ACTIONS,
	}
}
