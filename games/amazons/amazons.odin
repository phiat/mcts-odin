package amazons

import "../../mcts"

// Amazons on a 6x6 board. Players: 0 (Black) and 1 (White).
// Black moves first.
//
// Starting position (B = Black, W = White, . = empty):
//
//   . . B . . .       (row 0)
//   . . . . . .
//   B . . . . .
//   . . . . . W
//   . . . . . .
//   . . . W . .       (row 5)
//
// A turn has two parts:
//   1. Move one of your two amazons like a chess queen — any number of
//      empty squares in any of 8 directions, must end on a different square.
//   2. From that new square, shoot an "arrow" like a queen — any number
//      of empty squares in any of 8 directions. The arrow stays as a
//      permanent blocker on the board.
//
// Loss: A player loses when they cannot make a legal move on their turn.
//
// What this demo exercises:
//
//   Two-stage moves with a permanently-growing set of blockers, and a
//   terminal condition decided by "can the current player move?" rather
//   than a board pattern or piece count. Action space per ply is large
//   early (~1000+) and shrinks as arrows fill the board.
//
// Action encoding: action = from*36*36 + to*36 + arrow, where each of
// from/to/arrow is the flat cell index r*6+c (0..35). Total action space
// is 46656 — most are illegal at any given moment; legal_actions enumerates
// only the legal triples.
//
// Move_Delta packing — zero per-move heap allocations:
//   hash: unused (0).
//   flags: bits  0..5   from  (0..35)
//          bits  6..11  to    (0..35)
//          bits 12..17  arrow (0..35)
//          bit     18   prev_to_play (0 or 1)
//          bits 19..20  prev_winner + 1 (0..2; 0=none, 1=Black, 2=White)
//          bits 21..36  prev_move_count (16 bits)
//          bit     37   prev_is_terminal (0 or 1)

BOARD     :: 6
N_CELLS   :: BOARD * BOARD                  // 36
N_ACTIONS :: N_CELLS * N_CELLS * N_CELLS    // 46656

EMPTY :: i8(-1)
BLACK :: i8(0)
WHITE :: i8(1)
ARROW :: i8(2)

@(private)
DIRS := [8][2]int{
	{-1, -1}, {-1, 0}, {-1, 1},
	{ 0, -1},          { 0, 1},
	{ 1, -1}, { 1, 0}, { 1, 1},
}

State :: struct {
	cells:      [N_CELLS]i8,
	to_play:    i32,
	move_count: i32,
	winner:     i32, // -1 in progress; 0 or 1 on game end
	is_term:    bool,
}

@(private)
in_bounds :: proc "contextless" (r, c: int) -> bool {
	return r >= 0 && r < BOARD && c >= 0 && c < BOARD
}

@(private)
cell_idx :: proc "contextless" (r, c: int) -> int {
	return r * BOARD + c
}

@(private)
decode_cell :: proc "contextless" (idx: int) -> (r, c: int) {
	r = idx / BOARD
	c = idx % BOARD
	return
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for i in 0 ..< N_CELLS {s.cells[i] = EMPTY}
	s.cells[cell_idx(0, 2)] = BLACK
	s.cells[cell_idx(2, 0)] = BLACK
	s.cells[cell_idx(5, 3)] = WHITE
	s.cells[cell_idx(3, 5)] = WHITE
	s.winner = -1
	s.is_term = false
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
	return s.is_term
}

// From to_play's POV: 1.0 = win, 0.0 = loss, 0.5 = draw/non-terminal.
// Amazons has no draws — terminal means current to_play cannot move and
// therefore loses, so this returns 0.0 at any reachable terminal state.
terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	if !s.is_term {return 0.5}
	if i32(s.winner) == s.to_play {return 1.0}
	return 0.0
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

// Cheap terminal probe: a player can move iff some friendly amazon has
// at least one empty queen-direction neighbour. (If a friendly amazon can
// step one cell, the arrow can always be shot back to the origin, so a
// 1-step neighbour suffices to prove non-terminal.)
@(private)
has_legal_move :: proc "contextless" (s: ^State, player: i32) -> bool {
	color := i8(player)
	for r in 0 ..< BOARD {
		for c in 0 ..< BOARD {
			if s.cells[cell_idx(r, c)] != color {continue}
			for d in 0 ..< 8 {
				nr := r + DIRS[d][0]
				nc := c + DIRS[d][1]
				if in_bounds(nr, nc) && s.cells[cell_idx(nr, nc)] == EMPTY {
					return true
				}
			}
		}
	}
	return false
}

// Enumerate every legal (from, to, arrow) triple for the current player.
// The amazon is tentatively moved from→to so that arrow enumeration can
// "see" the original from-square as empty (Amazons allows shooting back).
legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if s.is_term {return}
	color := i8(s.to_play)

	for from in 0 ..< N_CELLS {
		if s.cells[from] != color {continue}
		fr, fc := decode_cell(from)

		for d in 0 ..< 8 {
			dr := DIRS[d][0]
			dc := DIRS[d][1]
			r := fr + dr
			c := fc + dc
			for in_bounds(r, c) && s.cells[cell_idx(r, c)] == EMPTY {
				to := cell_idx(r, c)
				s.cells[from] = EMPTY
				s.cells[to]   = color

				for ad in 0 ..< 8 {
					adr := DIRS[ad][0]
					adc := DIRS[ad][1]
					ar := r + adr
					ac := c + adc
					for in_bounds(ar, ac) && s.cells[cell_idx(ar, ac)] == EMPTY {
						arrow := cell_idx(ar, ac)
						action := from * (N_CELLS * N_CELLS) + to * N_CELLS + arrow
						append(out, action)
						ar += adr
						ac += adc
					}
				}

				s.cells[from] = color
				s.cells[to]   = EMPTY

				r += dr
				c += dc
			}
		}
	}
}

@(private)
pack_flags :: proc "contextless" (
	from, to, arrow: int,
	prev_to_play, prev_winner, prev_move_count: i32,
	prev_is_term: bool,
) -> u64 {
	flags := u64(from & 0x3F)
	flags |= u64(to & 0x3F) << 6
	flags |= u64(arrow & 0x3F) << 12
	flags |= u64(prev_to_play & 1) << 18
	flags |= u64((prev_winner + 1) & 0x3) << 19
	flags |= u64(u32(prev_move_count) & 0xFFFF) << 21
	if prev_is_term {flags |= u64(1) << 37}
	return flags
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (
	from, to, arrow: int,
	prev_to_play, prev_winner, prev_move_count: i32,
	prev_is_term: bool,
) {
	from = int(flags & 0x3F)
	to = int((flags >> 6) & 0x3F)
	arrow = int((flags >> 12) & 0x3F)
	prev_to_play = i32((flags >> 18) & 1)
	prev_winner = i32((flags >> 19) & 0x3) - 1
	prev_move_count = i32(u32(flags >> 21) & 0xFFFF)
	prev_is_term = ((flags >> 37) & 1) == 1
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_to_play := s.to_play
	prev_winner := s.winner
	prev_move_count := s.move_count
	prev_is_term := s.is_term

	arrow := action % N_CELLS
	to    := (action / N_CELLS) % N_CELLS
	from  := action / (N_CELLS * N_CELLS)

	color := i8(s.to_play)
	s.cells[from]  = EMPTY
	s.cells[to]    = color
	s.cells[arrow] = ARROW

	s.to_play = 1 - s.to_play
	s.move_count += 1

	if !has_legal_move(s, s.to_play) {
		s.is_term = true
		s.winner = 1 - s.to_play
	}

	return mcts.Move_Delta{
		hash  = 0,
		flags = pack_flags(from, to, arrow, prev_to_play, prev_winner, prev_move_count, prev_is_term),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	from, to, arrow, prev_to_play, prev_winner, prev_move_count, prev_is_term :=
		unpack_flags(delta.flags)

	color := i8(prev_to_play)
	s.cells[arrow] = EMPTY
	s.cells[to]    = EMPTY
	s.cells[from]  = color

	s.to_play = prev_to_play
	s.winner = prev_winner
	s.move_count = prev_move_count
	s.is_term = prev_is_term
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
