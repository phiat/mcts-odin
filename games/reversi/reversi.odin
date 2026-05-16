package reversi

import "../../mcts"

// 8x8 Reversi (Othello). Players: 0 = Black (moves first), 1 = White.
// Cells: -1 empty, 0 = Black, 1 = White.
//
// MCTS action space: cells 0..63 in row-major order + PASS_ACTION = 64.
// game.max_actions = 65.
//
// A move bracketed in any of the 8 directions flips all enemy stones in
// between to the mover's color. A player must pass only when no legal move
// exists. Two consecutive passes ends the game; otherwise the game ends when
// the board is full. Winner = whoever has more stones at end (ties = draw).
//
// Move_Delta packing — zero per-move heap allocations:
//   hash:  u64 flip bitmask. Bit i set => cell i was flipped by this move.
//          The played cell itself is also marked so undo_move can clear it.
//   flags: u64 with fields packed
//            bits  0..6   action id (0..64, pass = 64)
//            bit      7   prev_to_play (0 or 1)
//            bits  8..9   prev_consecutive_passes (0..2)
//            bits 16..31  prev_move_count
//   extra: nil

ROWS :: 8
COLS :: 8
N_CELLS :: ROWS * COLS
PASS_ACTION :: N_CELLS

EMPTY :: i8(-1)
BLACK :: i8(0)
WHITE :: i8(1)

State :: struct {
	cells:               [N_CELLS]i8,
	to_play:             i32,
	consecutive_passes:  i32,
	move_count:          i32,
}

// Eight unit directions from a cell.
@(private)
DIRS :: [8][2]int{{-1, -1}, {-1, 0}, {-1, 1}, {0, -1}, {0, 1}, {1, -1}, {1, 0}, {1, 1}}

@(private)
opponent :: proc "contextless" (p: i32) -> i32 {
	return 1 - p
}

@(private)
in_bounds :: proc "contextless" (r, c: int) -> bool {
	return r >= 0 && r < ROWS && c >= 0 && c < COLS
}

cell_idx :: proc "contextless" (r, c: int) -> int {
	return r * COLS + c
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for i in 0 ..< N_CELLS {s.cells[i] = EMPTY}
	// Standard Reversi opening: four stones at the center, diagonal pattern.
	s.cells[cell_idx(3, 3)] = WHITE
	s.cells[cell_idx(3, 4)] = BLACK
	s.cells[cell_idx(4, 3)] = BLACK
	s.cells[cell_idx(4, 4)] = WHITE
	s.to_play = 0 // Black moves first
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

// Returns the set of cells flipped in direction (dr,dc) starting from (r,c)
// for a move by player `p`. Writes the cell indices into `out` and returns
// the count. Zero means the direction doesn't bracket.
@(private)
flip_dir :: proc(s: ^State, r0, c0, dr, dc: int, p: i8, out: ^[N_CELLS]int, start: int) -> int {
	opp := i8(1) - p
	r, c := r0 + dr, c0 + dc
	count := 0
	for in_bounds(r, c) && s.cells[cell_idx(r, c)] == opp {
		out[start + count] = cell_idx(r, c)
		count += 1
		r += dr
		c += dc
	}
	// Bracketed only if we end on our own color (at least one opponent
	// stone in between).
	if count == 0 {return 0}
	if !in_bounds(r, c) {return 0}
	if s.cells[cell_idx(r, c)] != p {return 0}
	return count
}

@(private)
has_any_flip :: proc(s: ^State, r0, c0: int, p: i8) -> bool {
	for d in DIRS {
		dr, dc := d[0], d[1]
		opp := i8(1) - p
		r, c := r0 + dr, c0 + dc
		seen_opp := false
		for in_bounds(r, c) && s.cells[cell_idx(r, c)] == opp {
			seen_opp = true
			r += dr
			c += dc
		}
		if seen_opp && in_bounds(r, c) && s.cells[cell_idx(r, c)] == p {
			return true
		}
	}
	return false
}

// True if `action` (cell index in 0..63) is a legal placement for the
// current to_play. PASS_ACTION is legal only when no normal action is.
is_legal :: proc(s: ^State, action: int) -> bool {
	if action == PASS_ACTION {
		return !has_any_legal_placement(s)
	}
	if action < 0 || action >= N_CELLS {return false}
	if s.cells[action] != EMPTY {return false}
	r, c := action / COLS, action % COLS
	return has_any_flip(s, r, c, i8(s.to_play))
}

@(private)
has_any_legal_placement :: proc(s: ^State) -> bool {
	p := i8(s.to_play)
	for i in 0 ..< N_CELLS {
		if s.cells[i] != EMPTY {continue}
		r, c := i / COLS, i % COLS
		if has_any_flip(s, r, c, p) {return true}
	}
	return false
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if is_terminal_internal(s) {return}
	any_normal := false
	p := i8(s.to_play)
	for i in 0 ..< N_CELLS {
		if s.cells[i] != EMPTY {continue}
		r, c := i / COLS, i % COLS
		if has_any_flip(s, r, c, p) {
			append(out, i)
			any_normal = true
		}
	}
	// Pass is legal only when there's no normal move available — but the
	// game still has cells/turns left (not yet terminal).
	if !any_normal {append(out, PASS_ACTION)}
}

@(private)
is_terminal_internal :: proc(s: ^State) -> bool {
	return s.consecutive_passes >= 2
}

is_terminal :: proc(state: rawptr) -> bool {
	return is_terminal_internal(cast(^State)state)
}

// Score from current to_play's perspective. 1.0 = win, 0.0 = loss, 0.5 = draw.
terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	black, white := 0, 0
	for i in 0 ..< N_CELLS {
		switch s.cells[i] {
		case BLACK: black += 1
		case WHITE: white += 1
		}
	}
	if black == white {return 0.5}
	winner: i32 = 0 if black > white else 1
	return 1.0 if winner == s.to_play else 0.0
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

@(private)
pack_flags :: proc "contextless" (action: int, prev_to_play: i32, prev_passes: i32, prev_count: i32) -> u64 {
	return u64(action & 0x7F) |
		(u64(prev_to_play & 1) << 7) |
		(u64(prev_passes & 0x3) << 8) |
		(u64(u32(prev_count)) << 16)
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (action: int, prev_to_play: i32, prev_passes: i32, prev_count: i32) {
	action = int(flags & 0x7F)
	prev_to_play = i32((flags >> 7) & 1)
	prev_passes = i32((flags >> 8) & 0x3)
	prev_count = i32((flags >> 16) & 0xFFFF)
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_to_play := s.to_play
	prev_passes := s.consecutive_passes
	prev_count := s.move_count

	if action == PASS_ACTION {
		s.consecutive_passes += 1
		s.move_count += 1
		s.to_play = opponent(s.to_play)
		return mcts.Move_Delta {
			hash  = 0,
			flags = pack_flags(action, prev_to_play, prev_passes, prev_count),
		}
	}

	p := i8(s.to_play)
	r0, c0 := action / COLS, action % COLS
	flip_buf: [N_CELLS]int
	total := 0
	flip_bitmask := u64(0)

	for d in DIRS {
		n := flip_dir(s, r0, c0, d[0], d[1], p, &flip_buf, total)
		if n > 0 {
			for k in 0 ..< n {
				idx := flip_buf[total + k]
				s.cells[idx] = p
				flip_bitmask |= u64(1) << u64(idx)
			}
			total += n
		}
	}
	// Place the new stone; mark in the bitmask so undo can clear it.
	s.cells[action] = p
	flip_bitmask |= u64(1) << u64(action)

	s.consecutive_passes = 0
	s.move_count += 1
	s.to_play = opponent(s.to_play)
	return mcts.Move_Delta {
		hash  = flip_bitmask,
		flags = pack_flags(action, prev_to_play, prev_passes, prev_count),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action, prev_to_play, prev_passes, prev_count := unpack_flags(delta.flags)

	if action != PASS_ACTION {
		// Clear the played stone first.
		s.cells[action] = EMPTY
		flip_bitmask := delta.hash & ~(u64(1) << u64(action))
		// Flip every recorded cell back to the opponent's colour.
		opp := EMPTY
		switch prev_to_play {
		case 0: opp = WHITE
		case 1: opp = BLACK
		}
		bm := flip_bitmask
		for bm != 0 {
			i := lsb_index(bm)
			s.cells[i] = opp
			bm &= bm - 1 // clear lowest bit
		}
	}

	s.to_play = prev_to_play
	s.consecutive_passes = prev_passes
	s.move_count = prev_count
}

@(private)
lsb_index :: proc "contextless" (x: u64) -> int {
	// Count trailing zeros via the standard "x & -x" isolation trick, then
	// a small lookup. For 8x8 boards N=64; a portable loop is fine.
	if x == 0 {return -1}
	low := x & (~x + 1)
	idx := 0
	for low > 1 {
		low >>= 1
		idx += 1
	}
	return idx
}

// Returns the mcts.Game vtable.
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
		max_actions    = N_CELLS + 1, // 64 cells + PASS
	}
}
