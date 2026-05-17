package morris

import "../../mcts"

// Nine Men's Morris (classic ruleset). Players: 0 and 1. Player 0 moves first.
//
// Board: 24 points arranged on three concentric squares connected by
// mid-edge spokes. The standard numbering used throughout:
//
//   0 ---- 1 ---- 2
//   |      |      |
//   |  8 - 9 - 10 |
//   |  |   |   |  |
//   |  | 16-17-18 |
//   |  | |     | |
//   7 15 23   19 11 3
//   |  | |     | |
//   |  | 22-21-20 |
//   |  |   |   |  |
//   |  14--13--12 |
//   |      |      |
//   6 ---- 5 ---- 4
//
// Three game phases:
//   Phase 1 (placement): each player drops 9 men one at a time onto empty
//     points. The phase ends when both players have placed all 9.
//   Phase 2 (sliding): once a player has placed all 9, they may slide one
//     of their men to an empty adjacent point.
//   Phase 3 (flying): once a player is reduced to exactly 3 men, that
//     player may move from any of their points to ANY empty point.
//
// Forming a "mill" (3-in-a-row on one of the 16 board lines) at the end
// of any move allows the mover to REMOVE one opponent piece. Restriction:
// cannot remove an opponent piece that is itself in a mill UNLESS every
// remaining opponent piece is in a mill.
//
// Loss conditions (checked after a move):
//   - opponent's on-board count drops below 3 (after placement complete)
//   - opponent has no legal move
//
// What this demo exercises that no other demo does:
//
//   1. Explicit game phases that reshape the action space mid-game. The
//      legal_actions cardinality and structure shift based on game state
//      (placement vs. sliding vs. flying), not just board state. This is
//      a real MCTS edge case — engine consumers building staged games
//      (training/placement/endgame) get a reference here.
//   2. Sub-action within a single move. Forming a mill triggers a piece-
//      removal sub-decision by the same player as part of the same atomic
//      MCTS action. Dots and Boxes grants an extra full *turn* on box
//      close; here the removal is folded into the move itself.
//
// Action encoding (max_actions = 15625):
//   action = from * 625 + to * 25 + remove
//   where from, to, remove ∈ 0..24 and 24 is the NONE sentinel.
//   - Phase 1 placement: from = NONE, to = target point (0..23),
//     remove = NONE or a legal opp piece.
//   - Phase 2/3 movement: from = source (0..23), to = target (0..23),
//     remove = NONE or a legal opp piece.
//
// Move_Delta packing — zero per-move heap allocations:
//   hash: unused (0).
//   flags: bits  0..13  action (0..15624)
//          bit     14   prev_to_play
//          bits 15..16  prev_winner + 1 (0..2)
//          bits 17..32  prev_move_count (16 bits)
//          bit     33   prev_is_term

N_POINTS  :: 24
NONE      :: 24
N_ACTIONS :: 25 * 25 * 25   // 15625
N_MILLS   :: 16
START_MEN :: 8              // 9 men per player (0..8); placed count is i8

EMPTY :: i8(-1)

// Adjacency: for each point, the list of board-connected neighbours.
// Padded with -1 to a fixed length so the table is a 2-D array.
@(private)
ADJ := [N_POINTS][4]int{
	{ 1,  7, -1, -1}, // 0
	{ 0,  2,  9, -1}, // 1
	{ 1,  3, -1, -1}, // 2
	{ 2,  4, 11, -1}, // 3
	{ 3,  5, -1, -1}, // 4
	{ 4,  6, 13, -1}, // 5
	{ 5,  7, -1, -1}, // 6
	{ 0,  6, 15, -1}, // 7
	{ 9, 15, -1, -1}, // 8
	{ 1,  8, 10, 17}, // 9
	{ 9, 11, -1, -1}, // 10
	{ 3, 10, 12, 19}, // 11
	{11, 13, -1, -1}, // 12
	{ 5, 12, 14, 21}, // 13
	{13, 15, -1, -1}, // 14
	{ 7,  8, 14, 23}, // 15
	{17, 23, -1, -1}, // 16
	{ 9, 16, 18, -1}, // 17
	{17, 19, -1, -1}, // 18
	{11, 18, 20, -1}, // 19
	{19, 21, -1, -1}, // 20
	{13, 20, 22, -1}, // 21
	{21, 23, -1, -1}, // 22
	{15, 16, 22, -1}, // 23
}

// All 16 mills. Each row is the three points on one mill line.
@(private)
MILLS := [N_MILLS][3]int{
	// Outer ring
	{ 0,  1,  2}, { 6,  5,  4}, { 0,  7,  6}, { 2,  3,  4},
	// Middle ring
	{ 8,  9, 10}, {14, 13, 12}, { 8, 15, 14}, {10, 11, 12},
	// Inner ring
	{16, 17, 18}, {22, 21, 20}, {16, 23, 22}, {18, 19, 20},
	// Spokes
	{ 1,  9, 17}, { 7, 15, 23}, { 5, 13, 21}, { 3, 11, 19},
}

State :: struct {
	points:     [N_POINTS]i8, // -1 empty, 0 or 1 = owner
	placed:     [2]i8,        // cumulative men placed (0..9); phase 1 iff < 9
	on_board:   [2]i8,        // current piece count on board
	to_play:    i32,
	move_count: i32,
	winner:     i32, // -1 in progress; 0 or 1 on win
	is_term:    bool,
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for i in 0 ..< N_POINTS {s.points[i] = EMPTY}
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
	return s.is_term
}

terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	if !s.is_term {return 0.5}
	return 0.0 // current to_play is the loser (Morris has no draws by this ruleset)
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

// Is a specific mill complete in `color`?
@(private)
mill_complete :: proc "contextless" (s: ^State, m: int, color: i8) -> bool {
	a := MILLS[m][0]
	b := MILLS[m][1]
	c := MILLS[m][2]
	return s.points[a] == color && s.points[b] == color && s.points[c] == color
}

// Does point `p` participate in any mill of color `color`?
@(private)
in_mill :: proc "contextless" (s: ^State, p: int, color: i8) -> bool {
	for m in 0 ..< N_MILLS {
		if MILLS[m][0] != p && MILLS[m][1] != p && MILLS[m][2] != p {continue}
		if mill_complete(s, m, color) {return true}
	}
	return false
}

// Does the move-to point `to` complete any new mill? (Assumes the move has
// already been applied: points[to] holds the mover's color.)
@(private)
forms_mill_at :: proc "contextless" (s: ^State, to: int, color: i8) -> bool {
	for m in 0 ..< N_MILLS {
		if MILLS[m][0] != to && MILLS[m][1] != to && MILLS[m][2] != to {continue}
		if mill_complete(s, m, color) {return true}
	}
	return false
}

// Are every opp piece on the board currently part of some opp mill?
@(private)
all_opp_in_mills :: proc "contextless" (s: ^State, opp: i8) -> bool {
	for p in 0 ..< N_POINTS {
		if s.points[p] != opp {continue}
		if !in_mill(s, p, opp) {return false}
	}
	return true
}

// Pack/unpack action ids.
@(private)
encode :: proc "contextless" (from, to, remove: int) -> int {
	return from * 625 + to * 25 + remove
}

@(private)
decode :: proc "contextless" (action: int) -> (from, to, remove: int) {
	remove = action % 25
	to = (action / 25) % 25
	from = action / 625
	return
}

// Does the current player have any legal move (post-placement only)?
// Used both for terminal-check and for legal_actions short-circuit. In
// phase 1 there is always a legal placement as long as an empty point
// exists, so this is only meaningful when placed[me] == 9.
@(private)
has_legal_move_phase23 :: proc "contextless" (s: ^State, me: i8) -> bool {
	flying := s.on_board[me] == 3
	for from in 0 ..< N_POINTS {
		if s.points[from] != me {continue}
		if flying {
			for to in 0 ..< N_POINTS {
				if s.points[to] == EMPTY {return true}
			}
			return false // no empty point at all
		}
		for k in 0 ..< 4 {
			to := ADJ[from][k]
			if to < 0 {break}
			if s.points[to] == EMPTY {return true}
		}
	}
	return false
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if s.is_term {return}
	me := i8(s.to_play)
	opp := 1 - me

	// Decide phase for the mover.
	phase_1 := s.placed[me] < 9
	flying  := !phase_1 && s.on_board[me] == 3

	// Enumerate candidate (from, to) pairs.
	enum_one :: proc(s: ^State, me, opp: i8, from, to: int, out: ^[dynamic]int) {
		// Tentatively apply the move so forms_mill_at sees the resulting
		// position. Save what we'll mutate.
		prev_from := i8(EMPTY)
		if from != NONE {prev_from = s.points[from]}
		prev_to := s.points[to]

		if from != NONE {s.points[from] = EMPTY}
		s.points[to] = me

		if forms_mill_at(s, to, me) {
			// Mill formed — emit one action per legal removal.
			all_in_mills := all_opp_in_mills(s, opp)
			any_emitted := false
			for r in 0 ..< N_POINTS {
				if s.points[r] != opp {continue}
				if !all_in_mills && in_mill(s, r, opp) {continue}
				append(out, encode(from, to, r))
				any_emitted = true
			}
			// Defensive: if no opp pieces exist (shouldn't happen mid-game),
			// fall through to the no-removal emit so the move is still legal.
			if !any_emitted {
				append(out, encode(from, to, NONE))
			}
		} else {
			append(out, encode(from, to, NONE))
		}

		// Restore.
		s.points[to] = prev_to
		if from != NONE {s.points[from] = prev_from}
	}

	if phase_1 {
		for to in 0 ..< N_POINTS {
			if s.points[to] != EMPTY {continue}
			enum_one(s, me, opp, NONE, to, out)
		}
		return
	}

	if flying {
		for from in 0 ..< N_POINTS {
			if s.points[from] != me {continue}
			for to in 0 ..< N_POINTS {
				if s.points[to] != EMPTY {continue}
				enum_one(s, me, opp, from, to, out)
			}
		}
		return
	}

	// Phase 2: slide to adjacent empty points only.
	for from in 0 ..< N_POINTS {
		if s.points[from] != me {continue}
		for k in 0 ..< 4 {
			to := ADJ[from][k]
			if to < 0 {break}
			if s.points[to] != EMPTY {continue}
			enum_one(s, me, opp, from, to, out)
		}
	}
}

@(private)
pack_flags :: proc "contextless" (
	action: int,
	prev_to_play, prev_winner, prev_move_count: i32,
	prev_is_term: bool,
) -> u64 {
	flags := u64(action & 0x3FFF)
	flags |= u64(prev_to_play & 1) << 14
	flags |= u64((prev_winner + 1) & 0x3) << 15
	flags |= u64(u32(prev_move_count) & 0xFFFF) << 17
	if prev_is_term {flags |= u64(1) << 33}
	return flags
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (
	action: int,
	prev_to_play, prev_winner, prev_move_count: i32,
	prev_is_term: bool,
) {
	action = int(flags & 0x3FFF)
	prev_to_play = i32((flags >> 14) & 1)
	prev_winner = i32((flags >> 15) & 0x3) - 1
	prev_move_count = i32(u32(flags >> 17) & 0xFFFF)
	prev_is_term = ((flags >> 33) & 1) == 1
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	mover := i8(s.to_play)
	opp := 1 - mover
	prev_to_play := s.to_play
	prev_winner := s.winner
	prev_move_count := s.move_count
	prev_is_term := s.is_term

	from, to, remove := decode(action)

	if from == NONE {
		s.placed[mover] += 1
		s.on_board[mover] += 1
	} else {
		s.points[from] = EMPTY
	}
	s.points[to] = mover

	if remove != NONE {
		s.points[remove] = EMPTY
		s.on_board[opp] -= 1
	}

	s.to_play = 1 - s.to_play
	s.move_count += 1

	// Win-loss check on the NEW to_play (the player about to move).
	new_me := i8(s.to_play)
	placement_done := s.placed[new_me] == 9
	if placement_done && s.on_board[new_me] < 3 {
		s.is_term = true
		s.winner = i32(mover)
	} else if placement_done && !has_legal_move_phase23(s, new_me) {
		s.is_term = true
		s.winner = i32(mover)
	}

	return mcts.Move_Delta{
		hash  = 0,
		flags = pack_flags(action, prev_to_play, prev_winner, prev_move_count, prev_is_term),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action, prev_to_play, prev_winner, prev_move_count, prev_is_term := unpack_flags(delta.flags)
	mover := i8(prev_to_play)
	opp := 1 - mover

	from, to, remove := decode(action)

	if remove != NONE {
		s.points[remove] = opp
		s.on_board[opp] += 1
	}
	s.points[to] = EMPTY
	if from == NONE {
		s.placed[mover] -= 1
		s.on_board[mover] -= 1
	} else {
		s.points[from] = mover
	}

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
