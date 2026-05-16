package hex

import "../../mcts"

// 9x9 Hex (Piet Hein 1942 / John Nash 1948). Players: 0 = Red, 1 = Blue.
// Red moves first.
//
// Red owns the TOP and BOTTOM edges (rows 0 and SIZE-1) and wins by
// connecting them with an unbroken chain of Red stones. Blue owns the LEFT
// and RIGHT edges (cols 0 and SIZE-1) and wins by connecting those.
//
// Stones are never moved or captured. Draws are impossible — the Hex
// theorem guarantees exactly one player has completed their connection
// when the board fills, and in practice a player wins long before that.
//
// MCTS action space: cells 0..SIZE*SIZE-1 in row-major order. No pass.
// game.max_actions = N_CELLS.
//
// The board is a parallelogram of hexagonal cells. Adjacency follows the
// standard "skewed-rhombus" convention: each cell (r, c) borders the six
// neighbours
//
//   (r-1, c)   (r-1, c+1)
//   (r,   c-1)        (r,   c+1)
//   (r+1, c-1) (r+1, c)
//
// Edges are clipped at the board border.
//
// Move_Delta packing — zero per-move heap allocations:
//   hash:  unused (0).
//   flags: bits  0..6   action id (0..80)
//          bit      7   prev_to_play (0 or 1)
//          bit      8   prev_winner_was_set (1 if winner != -1 going in)
//          bits 16..31  prev_move_count
//          bit     63   prev_winner_value (only meaningful if bit 8 set)

SIZE :: 9
N_CELLS :: SIZE * SIZE

EMPTY :: i8(-1)
RED   :: i8(0)
BLUE  :: i8(1)

State :: struct {
	cells:      [N_CELLS]i8,
	to_play:    i32,
	move_count: i32,
	winner:     i32, // -1 none, 0 Red, 1 Blue
}

@(private)
DIRS :: [6][2]int{{-1, 0}, {-1, 1}, {0, -1}, {0, 1}, {1, -1}, {1, 0}}

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

// Score from current to_play's perspective: 1.0 = win, 0.0 = loss.
// Hex has no draws, so 0.5 is never returned.
terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	if s.winner < 0 {return 0.5}
	return 1.0 if s.winner == s.to_play else 0.0
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if s.winner >= 0 {return}
	for i in 0 ..< N_CELLS {
		if s.cells[i] == EMPTY {append(out, i)}
	}
}

// Flood-fill from the cell at `action` over same-color cells. Returns true
// if the placement completes a winning chain for the player who just played.
// For Red: must touch both row 0 and row SIZE-1. For Blue: both col 0 and
// col SIZE-1. The scan uses a fixed-size visited bitmask and a stack on
// the C frame — no heap allocations.
@(private)
check_win :: proc(s: ^State, action: int, p: i8) -> bool {
	visited: [N_CELLS]bool
	stack: [N_CELLS]int
	top := 0
	stack[top] = action
	top += 1
	visited[action] = true

	touches_low  := false // r==0 (Red) or c==0 (Blue)
	touches_high := false // r==SIZE-1 (Red) or c==SIZE-1 (Blue)

	for top > 0 {
		top -= 1
		i := stack[top]
		r := i / SIZE
		c := i % SIZE
		if p == RED {
			if r == 0          {touches_low  = true}
			if r == SIZE - 1   {touches_high = true}
		} else {
			if c == 0          {touches_low  = true}
			if c == SIZE - 1   {touches_high = true}
		}
		if touches_low && touches_high {return true}
		for d in DIRS {
			nr := r + d[0]
			nc := c + d[1]
			if !in_bounds(nr, nc) {continue}
			ni := cell_idx(nr, nc)
			if visited[ni] {continue}
			if s.cells[ni] != p {continue}
			visited[ni] = true
			stack[top] = ni
			top += 1
		}
	}
	return false
}

@(private)
pack_flags :: proc "contextless" (action: int, prev_to_play: i32, prev_move_count: i32, prev_winner: i32) -> u64 {
	flags := u64(action & 0x7F)
	flags |= u64(prev_to_play & 1) << 7
	if prev_winner >= 0 {
		flags |= u64(1) << 8
		flags |= u64(prev_winner & 1) << 63
	}
	flags |= u64(u32(prev_move_count)) << 16
	return flags
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (action: int, prev_to_play: i32, prev_move_count: i32, prev_winner: i32) {
	action = int(flags & 0x7F)
	prev_to_play = i32((flags >> 7) & 1)
	if (flags >> 8) & 1 == 1 {
		prev_winner = i32((flags >> 63) & 1)
	} else {
		prev_winner = -1
	}
	prev_move_count = i32(u32(flags >> 16) & 0xFFFF)
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_to_play := s.to_play
	prev_move_count := s.move_count
	prev_winner := s.winner

	p := i8(s.to_play)
	s.cells[action] = p
	s.move_count += 1
	if check_win(s, action, p) {
		s.winner = s.to_play
	}
	s.to_play = 1 - s.to_play

	return mcts.Move_Delta{
		hash  = 0,
		flags = pack_flags(action, prev_to_play, prev_move_count, prev_winner),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action, prev_to_play, prev_move_count, prev_winner := unpack_flags(delta.flags)
	s.cells[action] = EMPTY
	s.to_play = prev_to_play
	s.move_count = prev_move_count
	s.winner = prev_winner
}

// Returns the mcts.Game vtable.
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
