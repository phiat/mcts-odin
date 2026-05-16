package dots_and_boxes

import "../../mcts"

// 4x4 dot grid (3x3 = 9 boxes) Dots and Boxes. Players: 0 and 1.
// Player 0 moves first.
//
// Setup: empty 4x4 dot grid, 24 edges undrawn, 9 boxes unclaimed.
//
// Move: pick one of the 24 undrawn edges and draw it.
//   - If your edge completes the fourth side of one or two boxes, you
//     claim those boxes AND take another turn immediately.
//   - Otherwise the turn passes to your opponent.
//
// Win: when all 24 edges are drawn, the player with the most claimed
// boxes wins. 9 boxes total → no ties possible.
//
// What this demo exercises that the others don't:
//
//   The extra-turn mechanic breaks the alternation invariant. In all
//   other demo games `to_play` flips on every do_move; here it conditionally
//   stays the same. MCTS descents can take same-player back-to-back moves,
//   which is the load-bearing reason this demo exists — it surfaces any
//   latent assumption in the core that to_play parity tracks move count.
//
// MCTS action space: 24 edge ids.
//   - Action 0..11  → horizontal edges, action = r*3 + c where
//     r in 0..3, c in 0..2.  Edge h(r,c) connects dot(r,c)-dot(r,c+1).
//   - Action 12..23 → vertical edges, action = 12 + r*4 + c where
//     r in 0..2, c in 0..3.  Edge v(r,c) connects dot(r,c)-dot(r+1,c).
//
// Move_Delta packing — zero per-move heap allocations:
//   hash: unused (0).
//   flags: bits  0..4   action id (0..23)
//          bits  5..7   number of boxes closed by this move (0, 1, or 2)
//          bits  8..11  closed box 1 index (0..8), or 0xF if none
//          bits 12..15  closed box 2 index (0..8), or 0xF if none
//          bit      16  prev_to_play (0 or 1)
//          bit      17  prev_winner is set (0 or 1)
//          bits 18..19  prev_winner + 1 (0..2; 0=none, 1=Black, 2=White)
//          bits 20..27  prev_score_0 (0..9)
//          bits 28..35  prev_score_1 (0..9)
//          bits 36..51  prev_move_count

ROWS_DOTS  :: 4
COLS_DOTS  :: 4
ROWS_BOXES :: 3
COLS_BOXES :: 3
N_BOXES    :: ROWS_BOXES * COLS_BOXES // 9

N_H_EDGES :: ROWS_DOTS * (COLS_DOTS - 1)         // 4*3 = 12
N_V_EDGES :: (ROWS_DOTS - 1) * COLS_DOTS         // 3*4 = 12
N_ACTIONS :: N_H_EDGES + N_V_EDGES               // 24

BOX_UNCLAIMED :: i8(-1)

State :: struct {
	// edges_h[r][c] = drawn? (0 or 1). r in 0..3, c in 0..2.
	edges_h: [ROWS_DOTS][COLS_DOTS - 1]i8,
	// edges_v[r][c] = drawn? (0 or 1). r in 0..2, c in 0..3.
	edges_v: [ROWS_DOTS - 1][COLS_DOTS]i8,
	// boxes[r][c] = owner (-1 unclaimed, 0 or 1). r,c in 0..2.
	boxes:      [ROWS_BOXES][COLS_BOXES]i8,
	to_play:    i32,
	move_count: i32,
	score:      [2]i32,
	edges_drawn: i32, // for cheap is_terminal
	winner:     i32, // -1 none yet, 0 or 1 once all edges drawn
}

@(private)
box_idx :: proc "contextless" (br, bc: int) -> int {
	return br * COLS_BOXES + bc
}

@(private)
decode :: proc "contextless" (action: int) -> (is_horizontal: bool, r, c: int) {
	if action < N_H_EDGES {
		is_horizontal = true
		r = action / (COLS_DOTS - 1)
		c = action % (COLS_DOTS - 1)
		return
	}
	is_horizontal = false
	rest := action - N_H_EDGES
	r = rest / COLS_DOTS
	c = rest % COLS_DOTS
	return
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	for r in 0 ..< ROWS_BOXES {
		for c in 0 ..< COLS_BOXES {s.boxes[r][c] = BOX_UNCLAIMED}
	}
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
	return s.edges_drawn == N_ACTIONS
}

terminal_value :: proc(state: rawptr) -> f32 {
	s := cast(^State)state
	if s.edges_drawn != N_ACTIONS {return 0.5}
	// 9 boxes, no ties — but defensive 0.5 on equality just in case.
	if s.score[s.to_play] > s.score[1 - s.to_play] {return 1.0}
	if s.score[s.to_play] < s.score[1 - s.to_play] {return 0.0}
	return 0.5
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

@(private)
edge_drawn :: proc "contextless" (s: ^State, is_horizontal: bool, r, c: int) -> bool {
	if is_horizontal {return s.edges_h[r][c] == 1}
	return s.edges_v[r][c] == 1
}

@(private)
set_edge :: proc "contextless" (s: ^State, is_horizontal: bool, r, c: int, v: i8) {
	if is_horizontal {s.edges_h[r][c] = v} else {s.edges_v[r][c] = v}
}

// Count how many of a box's four edges are currently drawn. A box at
// (br, bc) has top=h(br,bc), bottom=h(br+1,bc), left=v(br,bc), right=v(br,bc+1).
@(private)
box_edge_count :: proc "contextless" (s: ^State, br, bc: int) -> int {
	n := 0
	if s.edges_h[br]    [bc]     == 1 {n += 1}
	if s.edges_h[br + 1][bc]     == 1 {n += 1}
	if s.edges_v[br]    [bc]     == 1 {n += 1}
	if s.edges_v[br]    [bc + 1] == 1 {n += 1}
	return n
}

// Return the (br, bc) of the two boxes adjacent to a given edge, or -1 for
// missing sides (edge on the perimeter).
@(private)
boxes_for_edge :: proc "contextless" (is_horizontal: bool, r, c: int) -> (br1, bc1, br2, bc2: int) {
	br1, bc1, br2, bc2 = -1, -1, -1, -1
	if is_horizontal {
		// h(r, c) is the top of box (r, c) and the bottom of box (r-1, c).
		if r < ROWS_BOXES {br1 = r;   bc1 = c}
		if r > 0          {br2 = r-1; bc2 = c}
		return
	}
	// v(r, c) is the left of box (r, c) and the right of box (r, c-1).
	if c < COLS_BOXES {br1 = r; bc1 = c}
	if c > 0          {br2 = r; bc2 = c-1}
	return
}

@(private)
is_legal_action :: proc(s: ^State, action: int) -> bool {
	if action < 0 || action >= N_ACTIONS {return false}
	if s.edges_drawn == N_ACTIONS {return false}
	is_h, r, c := decode(action)
	return !edge_drawn(s, is_h, r, c)
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if s.edges_drawn == N_ACTIONS {return}
	for a in 0 ..< N_ACTIONS {
		if is_legal_action(s, a) {append(out, a)}
	}
}

@(private)
pack_flags :: proc "contextless" (
	action: int, n_closed: int, box1, box2: int,
	prev_to_play, prev_winner, prev_score_0, prev_score_1, prev_move_count: i32,
) -> u64 {
	flags := u64(action & 0x1F)
	flags |= u64(n_closed & 0x7) << 5
	flags |= u64(box1 & 0xF) << 8
	flags |= u64(box2 & 0xF) << 12
	flags |= u64(prev_to_play & 1) << 16
	flags |= u64((prev_winner + 1) & 0x3) << 18
	flags |= u64(prev_score_0 & 0xFF) << 20
	flags |= u64(prev_score_1 & 0xFF) << 28
	flags |= u64(u32(prev_move_count) & 0xFFFF) << 36
	return flags
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (
	action, n_closed, box1, box2: int,
	prev_to_play, prev_winner, prev_score_0, prev_score_1, prev_move_count: i32,
) {
	action = int(flags & 0x1F)
	n_closed = int((flags >> 5) & 0x7)
	b1 := int((flags >> 8) & 0xF)
	b2 := int((flags >> 12) & 0xF)
	box1 = -1 if b1 == 0xF else b1
	box2 = -1 if b2 == 0xF else b2
	prev_to_play = i32((flags >> 16) & 1)
	prev_winner = i32((flags >> 18) & 0x3) - 1
	prev_score_0 = i32((flags >> 20) & 0xFF)
	prev_score_1 = i32((flags >> 28) & 0xFF)
	prev_move_count = i32(u32(flags >> 36) & 0xFFFF)
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	prev_to_play := s.to_play
	prev_winner := s.winner
	prev_score_0 := s.score[0]
	prev_score_1 := s.score[1]
	prev_move_count := s.move_count

	is_h, r, c := decode(action)
	set_edge(s, is_h, r, c, 1)
	s.edges_drawn += 1
	s.move_count += 1

	// Check the up-to-two boxes adjacent to this edge; mark any newly closed.
	mover := i8(s.to_play)
	br1, bc1, br2, bc2 := boxes_for_edge(is_h, r, c)
	n_closed := 0
	box1_flat := -1
	box2_flat := -1
	if br1 >= 0 && box_edge_count(s, br1, bc1) == 4 {
		s.boxes[br1][bc1] = mover
		s.score[s.to_play] += 1
		box1_flat = box_idx(br1, bc1)
		n_closed += 1
	}
	if br2 >= 0 && box_edge_count(s, br2, bc2) == 4 {
		s.boxes[br2][bc2] = mover
		s.score[s.to_play] += 1
		if n_closed == 0 {box1_flat = box_idx(br2, bc2)} else {box2_flat = box_idx(br2, bc2)}
		n_closed += 1
	}

	// Extra-turn rule: closer keeps the turn. Otherwise pass.
	if n_closed == 0 {s.to_play = 1 - s.to_play}

	if s.edges_drawn == N_ACTIONS {
		if s.score[0] > s.score[1] {s.winner = 0}
		else if s.score[1] > s.score[0] {s.winner = 1}
		else {s.winner = -1} // unreachable on 9 boxes; defensive
	}

	return mcts.Move_Delta{
		hash  = 0,
		flags = pack_flags(action, n_closed, box1_flat, box2_flat,
			prev_to_play, prev_winner, prev_score_0, prev_score_1, prev_move_count),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action, n_closed, box1, box2, prev_to_play, prev_winner, prev_score_0, prev_score_1, prev_move_count :=
		unpack_flags(delta.flags)

	// Un-close any boxes this move closed.
	if box1 >= 0 {
		br := box1 / COLS_BOXES
		bc := box1 % COLS_BOXES
		s.boxes[br][bc] = BOX_UNCLAIMED
	}
	if box2 >= 0 {
		br := box2 / COLS_BOXES
		bc := box2 % COLS_BOXES
		s.boxes[br][bc] = BOX_UNCLAIMED
	}
	_ = n_closed

	is_h, r, c := decode(action)
	set_edge(s, is_h, r, c, 0)
	s.edges_drawn -= 1

	s.to_play = prev_to_play
	s.winner = prev_winner
	s.score[0] = prev_score_0
	s.score[1] = prev_score_1
	s.move_count = prev_move_count
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
