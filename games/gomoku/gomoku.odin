package gomoku

import "../../mcts"

// 15x15 Free Gomoku (Five-in-a-Row). Players: 0 = Black (moves first), 1 = White.
//
// Rules (Free Gomoku — no swap2, no opening restrictions, no overlines
// penalty):
//   - Place one stone of your colour on any empty cell.
//   - First to form a run of FIVE OR MORE same-colour stones in any of
//     the four directions (horizontal, vertical, or either diagonal) wins.
//   - If the board fills with no five-in-a-row, the game is a draw (rare
//     at 15x15; possible in principle).
//
// Stones never move and are never removed. No passes, no captures.
//
// MCTS action space: cells 0..SIZE*SIZE-1 in row-major order. No pass.
// game.max_actions = N_CELLS = 225.
//
// Move_Delta packing — zero per-move heap allocations:
//   hash:  unused (0).
//   flags: bits  0..7    action id (0..224)
//          bit       8   prev_to_play (0 or 1)
//          bits  9..11   prev_terminal_state + 1 (0..3: 0=running, 1=draw, 2=Black, 3=White)
//          bits 16..31   prev_move_count

SIZE :: 15
N_CELLS :: SIZE * SIZE
WIN_LEN :: 5

EMPTY :: i8(-1)
BLACK :: i8(0)
WHITE :: i8(1)

// Four scan directions: horizontal, vertical, diagonal-down-right,
// diagonal-down-left. Each direction is checked symmetrically (forward and
// backward from the placed stone) by counting in both signs.
@(private)
DIRS :: [4][2]int{{0, 1}, {1, 0}, {1, 1}, {1, -1}}

State :: struct {
	cells:      [N_CELLS]i8,
	to_play:    i32,
	move_count: i32,
	winner:     i32, // -1 none (running OR draw); use draw flag to distinguish
	is_draw:    bool,
}

cell_idx :: proc "contextless" (r, c: int) -> int {
	return r * SIZE + c
}

@(private)
in_bounds :: proc "contextless" (r, c: int) -> bool {
	return r >= 0 && r < SIZE && c >= 0 && c < SIZE
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for i in 0 ..< N_CELLS {s.cells[i] = EMPTY}
	s.to_play = 0
	s.winner = -1
	s.is_draw = false
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
	return s.winner >= 0 || s.is_draw
}

terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	if s.is_draw {return 0.5}
	if s.winner < 0 {return 0.5}
	return 1.0 if s.winner == s.to_play else 0.0
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if is_terminal(s) {return}
	for i in 0 ..< N_CELLS {
		if s.cells[i] == EMPTY {append(out, i)}
	}
}

// True if the placement at (r0, c0) of colour `p` completes a run of
// WIN_LEN or more same-colour stones in any of the four directions. Scans
// outward from the placed stone in both signs of each direction, counting
// consecutive same-colour stones — O(WIN_LEN) per direction, no allocations.
@(private)
check_win :: proc(s: ^State, r0, c0: int, p: i8) -> bool {
	for d in DIRS {
		dr, dc := d[0], d[1]
		count := 1 // the just-placed stone
		// Forward.
		r, c := r0 + dr, c0 + dc
		for in_bounds(r, c) && s.cells[cell_idx(r, c)] == p {
			count += 1
			r += dr
			c += dc
		}
		// Backward.
		r, c = r0 - dr, c0 - dc
		for in_bounds(r, c) && s.cells[cell_idx(r, c)] == p {
			count += 1
			r -= dr
			c -= dc
		}
		if count >= WIN_LEN {return true}
	}
	return false
}

@(private)
pack_flags :: proc "contextless" (
	action: int, prev_to_play: i32, prev_move_count: i32,
	prev_winner: i32, prev_is_draw: bool,
) -> u64 {
	flags := u64(action & 0xFF)
	flags |= u64(prev_to_play & 1) << 8
	term_code: u64 = 0
	if prev_is_draw {
		term_code = 1
	} else if prev_winner == 0 {
		term_code = 2
	} else if prev_winner == 1 {
		term_code = 3
	}
	flags |= term_code << 9
	flags |= u64(u32(prev_move_count) & 0xFFFF) << 16
	return flags
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (
	action: int, prev_to_play: i32, prev_move_count: i32,
	prev_winner: i32, prev_is_draw: bool,
) {
	action = int(flags & 0xFF)
	prev_to_play = i32((flags >> 8) & 1)
	term_code := (flags >> 9) & 0x7
	switch term_code {
	case 0: prev_winner = -1; prev_is_draw = false
	case 1: prev_winner = -1; prev_is_draw = true
	case 2: prev_winner = 0;  prev_is_draw = false
	case 3: prev_winner = 1;  prev_is_draw = false
	}
	prev_move_count = i32(u32(flags >> 16) & 0xFFFF)
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_to_play := s.to_play
	prev_move_count := s.move_count
	prev_winner := s.winner
	prev_is_draw := s.is_draw

	p := i8(s.to_play)
	r := action / SIZE
	c := action % SIZE
	s.cells[action] = p
	s.move_count += 1
	if check_win(s, r, c, p) {
		s.winner = s.to_play
	} else if s.move_count == i32(N_CELLS) {
		s.is_draw = true
	}
	s.to_play = 1 - s.to_play

	return mcts.Move_Delta{
		hash  = 0,
		flags = pack_flags(action, prev_to_play, prev_move_count, prev_winner, prev_is_draw),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action, prev_to_play, prev_move_count, prev_winner, prev_is_draw := unpack_flags(delta.flags)
	s.cells[action] = EMPTY
	s.to_play = prev_to_play
	s.move_count = prev_move_count
	s.winner = prev_winner
	s.is_draw = prev_is_draw
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
		max_actions    = N_CELLS,
	}
}
