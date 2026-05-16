package quoridor

import "../../mcts"

// 5x5 Quoridor. Players: 0 (Black) and 1 (White). Black moves first.
//
// Setup:
//   - Black pawn at (0, 2), goal row 4.
//   - White pawn at (4, 2), goal row 0.
//   - Each player starts with WALLS_PER_PLAYER = 5 walls.
//
// A turn is either:
//   (a) Move your pawn — one step in any orthogonal direction. If the
//       opponent is in that direction, you may jump over them to the
//       square behind, or step diagonally past them if the square behind
//       is blocked by a wall or the board edge.
//   (b) Place a 2-cell wall on the lattice between cells. Walls block
//       passage. You cannot place a wall that would cut off either
//       player from their goal row (validated by BFS per candidate).
//
// Win: First pawn to reach the opposite edge row wins.
//
// What this demo exercises:
//
//   Heterogeneous actions (pawn moves and wall placements share one
//   action space) and per-candidate BFS path validation. This is the
//   first demo where legal_actions must run shortest-path search for
//   some candidates — analogous in shape to Go's PSK probe but with a
//   different cost structure.
//
// Action encoding (max_actions = 57):
//   0..24  : pawn move to cell idx (target_r * 5 + target_c). Most are
//            illegal at any given moment; legal_actions filters.
//   25..40 : place horizontal wall, wall_id = action - 25.
//            wr = wall_id / 4, wc = wall_id % 4. (wr, wc in 0..3.)
//   41..56 : place vertical wall, wall_id = action - 41.
//            wr = wall_id / 4, wc = wall_id % 4. (wr, wc in 0..3.)
//
// Wall geometry:
//   - Horizontal wall at slot (wr, wc) blocks two vertical edges:
//       (wr, wc)↔(wr+1, wc) and (wr, wc+1)↔(wr+1, wc+1).
//   - Vertical wall at slot (wr, wc) blocks two horizontal edges:
//       (wr, wc)↔(wr, wc+1) and (wr+1, wc)↔(wr+1, wc+1).
//
// Move_Delta packing — zero per-move heap allocations:
//   hash: unused (0).
//   flags: bits  0..6   action (0..56)
//          bits  7..11  prev_pawn_cell (0..24, only used for pawn moves)
//          bit     12   prev_to_play (0 or 1)
//          bits 13..14  prev_winner + 1 (0..2)
//          bits 15..30  prev_move_count (16 bits)
//          bit     31   prev_is_term (0 or 1)
//          bits 32..35  prev_walls_left[mover] (0..15, captures the
//                       walls_left value BEFORE this move, regardless
//                       of move type — restored unconditionally on undo)

BOARD             :: 5
N_CELLS           :: BOARD * BOARD                     // 25
WALL_DIM          :: BOARD - 1                          // 4
N_WALL_SLOTS      :: WALL_DIM * WALL_DIM                // 16
N_PAWN_ACTIONS    :: N_CELLS                            // 25
H_WALL_OFFSET     :: N_PAWN_ACTIONS                     // 25
V_WALL_OFFSET     :: N_PAWN_ACTIONS + N_WALL_SLOTS      // 41
N_ACTIONS         :: N_PAWN_ACTIONS + 2 * N_WALL_SLOTS  // 57
WALLS_PER_PLAYER  :: 5

@(private)
DIRS4 := [4][2]int{
	{-1, 0}, { 1, 0}, { 0,  1}, { 0, -1},
}

State :: struct {
	pawns:        [2][2]i8,             // [player][row, col]
	walls_h:      [WALL_DIM][WALL_DIM]i8,
	walls_v:      [WALL_DIM][WALL_DIM]i8,
	walls_left:   [2]i8,
	to_play:      i32,
	move_count:   i32,
	winner:       i32,                  // -1 in progress; 0 or 1 on win
	is_term:      bool,
}

@(private)
in_bounds :: proc "contextless" (r, c: int) -> bool {
	return r >= 0 && r < BOARD && c >= 0 && c < BOARD
}

@(private)
goal_row :: proc "contextless" (player: int) -> int {
	return BOARD - 1 if player == 0 else 0
}

new_state :: proc(allocator := context.allocator) -> rawptr {
	s := new(State, allocator)
	s.pawns[0] = {0, 2}
	s.pawns[1] = {4, 2}
	s.walls_left = {WALLS_PER_PLAYER, WALLS_PER_PLAYER}
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
	if s.winner == s.to_play {return 1.0}
	return 0.0
}

current_player :: proc(state: rawptr) -> i32 {
	s := cast(^State)state
	return s.to_play
}

// Is moving from (r, c) one step in direction (dr, dc) blocked by a wall?
// Caller ensures (r+dr, c+dc) is in bounds. Opponent pawn is NOT considered.
@(private)
step_blocked :: proc "contextless" (s: ^State, r, c, dr, dc: int) -> bool {
	switch {
	case dr == -1 && dc == 0:
		// North: edge (r-1, c) ↔ (r, c). Blocked by h-wall at (r-1, c) or (r-1, c-1).
		if c < WALL_DIM && s.walls_h[r - 1][c] == 1 {return true}
		if c - 1 >= 0 && s.walls_h[r - 1][c - 1] == 1 {return true}
		return false
	case dr == 1 && dc == 0:
		// South: edge (r, c) ↔ (r+1, c). Blocked by h-wall at (r, c) or (r, c-1).
		if c < WALL_DIM && s.walls_h[r][c] == 1 {return true}
		if c - 1 >= 0 && s.walls_h[r][c - 1] == 1 {return true}
		return false
	case dc == 1 && dr == 0:
		// East: edge (r, c) ↔ (r, c+1). Blocked by v-wall at (r, c) or (r-1, c).
		if r < WALL_DIM && s.walls_v[r][c] == 1 {return true}
		if r - 1 >= 0 && s.walls_v[r - 1][c] == 1 {return true}
		return false
	case dc == -1 && dr == 0:
		// West: edge (r, c) ↔ (r, c-1). Blocked by v-wall at (r, c-1) or (r-1, c-1).
		if r < WALL_DIM && s.walls_v[r][c - 1] == 1 {return true}
		if r - 1 >= 0 && s.walls_v[r - 1][c - 1] == 1 {return true}
		return false
	}
	return false
}

// Enumerate every legal pawn-target cell for the given player from their
// current pawn position. Returns count; targets[0..count) holds cell idxs.
@(private)
pawn_targets :: proc(s: ^State, player: int, targets: ^[10]int) -> int {
	n := 0
	pr := int(s.pawns[player][0])
	pc := int(s.pawns[player][1])
	or := int(s.pawns[1 - player][0])
	oc := int(s.pawns[1 - player][1])

	for d in 0 ..< 4 {
		dr := DIRS4[d][0]
		dc := DIRS4[d][1]
		nr := pr + dr
		nc := pc + dc
		if !in_bounds(nr, nc) {continue}
		if step_blocked(s, pr, pc, dr, dc) {continue}

		if nr == or && nc == oc {
			// Opponent adjacent — try jump first.
			jr := nr + dr
			jc := nc + dc
			can_jump := in_bounds(jr, jc) && !step_blocked(s, nr, nc, dr, dc)
			if can_jump {
				targets[n] = jr * BOARD + jc
				n += 1
			} else {
				// Diagonal slide. Try the two perpendicular directions.
				for d2 in 0 ..< 4 {
					dr2 := DIRS4[d2][0]
					dc2 := DIRS4[d2][1]
					// Only consider perpendicular dirs.
					if dr2 == dr && dc2 == dc {continue}
					if dr2 == -dr && dc2 == -dc {continue}
					sr := nr + dr2
					sc := nc + dc2
					if !in_bounds(sr, sc) {continue}
					if step_blocked(s, nr, nc, dr2, dc2) {continue}
					targets[n] = sr * BOARD + sc
					n += 1
				}
			}
		} else {
			targets[n] = nr * BOARD + nc
			n += 1
		}
	}
	return n
}

// BFS: can `player` reach their goal row using current wall layout?
// Opponent's pawn is NOT a blocker for this check (standard Quoridor rule).
can_reach_goal :: proc(s: ^State, player: int) -> bool {
	target_row := goal_row(player)
	pr := int(s.pawns[player][0])
	pc := int(s.pawns[player][1])
	if pr == target_row {return true}

	visited: [N_CELLS]bool
	queue: [N_CELLS]int
	head, tail := 0, 0
	start := pr * BOARD + pc
	visited[start] = true
	queue[tail] = start
	tail += 1

	for head < tail {
		idx := queue[head]
		head += 1
		r := idx / BOARD
		c := idx % BOARD
		if r == target_row {return true}
		for d in 0 ..< 4 {
			dr := DIRS4[d][0]
			dc := DIRS4[d][1]
			nr := r + dr
			nc := c + dc
			if !in_bounds(nr, nc) {continue}
			if step_blocked(s, r, c, dr, dc) {continue}
			ni := nr * BOARD + nc
			if visited[ni] {continue}
			visited[ni] = true
			queue[tail] = ni
			tail += 1
		}
	}
	return false
}

@(private)
wall_geometry_legal_h :: proc "contextless" (s: ^State, wr, wc: int) -> bool {
	if s.walls_h[wr][wc] == 1 {return false}
	if wc - 1 >= 0 && s.walls_h[wr][wc - 1] == 1 {return false}
	if wc + 1 < WALL_DIM && s.walls_h[wr][wc + 1] == 1 {return false}
	if s.walls_v[wr][wc] == 1 {return false}
	return true
}

@(private)
wall_geometry_legal_v :: proc "contextless" (s: ^State, wr, wc: int) -> bool {
	if s.walls_v[wr][wc] == 1 {return false}
	if wr - 1 >= 0 && s.walls_v[wr - 1][wc] == 1 {return false}
	if wr + 1 < WALL_DIM && s.walls_v[wr + 1][wc] == 1 {return false}
	if s.walls_h[wr][wc] == 1 {return false}
	return true
}

legal_actions :: proc(state: rawptr, out: ^[dynamic]int) {
	s := cast(^State)state
	if s.is_term {return}

	// Pawn moves.
	targets: [10]int
	n := pawn_targets(s, int(s.to_play), &targets)
	for i in 0 ..< n {
		append(out, targets[i])
	}

	// Walls (only if mover has any left).
	if s.walls_left[s.to_play] <= 0 {return}

	for wr in 0 ..< WALL_DIM {
		for wc in 0 ..< WALL_DIM {
			if wall_geometry_legal_h(s, wr, wc) {
				s.walls_h[wr][wc] = 1
				if can_reach_goal(s, 0) && can_reach_goal(s, 1) {
					append(out, H_WALL_OFFSET + wr * WALL_DIM + wc)
				}
				s.walls_h[wr][wc] = 0
			}
		}
	}
	for wr in 0 ..< WALL_DIM {
		for wc in 0 ..< WALL_DIM {
			if wall_geometry_legal_v(s, wr, wc) {
				s.walls_v[wr][wc] = 1
				if can_reach_goal(s, 0) && can_reach_goal(s, 1) {
					append(out, V_WALL_OFFSET + wr * WALL_DIM + wc)
				}
				s.walls_v[wr][wc] = 0
			}
		}
	}
}

@(private)
pack_flags :: proc "contextless" (
	action, prev_pawn_cell: int,
	prev_to_play, prev_winner, prev_move_count: i32,
	prev_is_term: bool,
	prev_walls_left: i8,
) -> u64 {
	flags := u64(action & 0x7F)
	flags |= u64(prev_pawn_cell & 0x1F) << 7
	flags |= u64(prev_to_play & 1) << 12
	flags |= u64((prev_winner + 1) & 0x3) << 13
	flags |= u64(u32(prev_move_count) & 0xFFFF) << 15
	if prev_is_term {flags |= u64(1) << 31}
	flags |= u64(prev_walls_left & 0xF) << 32
	return flags
}

@(private)
unpack_flags :: proc "contextless" (flags: u64) -> (
	action, prev_pawn_cell: int,
	prev_to_play, prev_winner, prev_move_count: i32,
	prev_is_term: bool,
	prev_walls_left: i8,
) {
	action = int(flags & 0x7F)
	prev_pawn_cell = int((flags >> 7) & 0x1F)
	prev_to_play = i32((flags >> 12) & 1)
	prev_winner = i32((flags >> 13) & 0x3) - 1
	prev_move_count = i32(u32(flags >> 15) & 0xFFFF)
	prev_is_term = ((flags >> 31) & 1) == 1
	prev_walls_left = i8((flags >> 32) & 0xF)
	return
}

do_move :: proc(state: rawptr, action: int) -> mcts.Move_Delta {
	s := cast(^State)state
	mover := int(s.to_play)
	prev_to_play := s.to_play
	prev_winner := s.winner
	prev_move_count := s.move_count
	prev_is_term := s.is_term
	prev_pawn_cell := int(s.pawns[mover][0]) * BOARD + int(s.pawns[mover][1])
	prev_walls_left := s.walls_left[mover]

	if action < N_PAWN_ACTIONS {
		s.pawns[mover][0] = i8(action / BOARD)
		s.pawns[mover][1] = i8(action % BOARD)
		if int(s.pawns[mover][0]) == goal_row(mover) {
			s.winner = i32(mover)
			s.is_term = true
		}
	} else if action < V_WALL_OFFSET {
		wid := action - H_WALL_OFFSET
		s.walls_h[wid / WALL_DIM][wid % WALL_DIM] = 1
		s.walls_left[mover] -= 1
	} else {
		wid := action - V_WALL_OFFSET
		s.walls_v[wid / WALL_DIM][wid % WALL_DIM] = 1
		s.walls_left[mover] -= 1
	}

	s.to_play = 1 - s.to_play
	s.move_count += 1

	return mcts.Move_Delta{
		hash  = 0,
		flags = pack_flags(action, prev_pawn_cell, prev_to_play, prev_winner,
			prev_move_count, prev_is_term, prev_walls_left),
	}
}

undo_move :: proc(state: rawptr, delta: mcts.Move_Delta) {
	s := cast(^State)state
	action, prev_pawn_cell, prev_to_play, prev_winner, prev_move_count, prev_is_term, prev_walls_left :=
		unpack_flags(delta.flags)

	mover := int(prev_to_play)
	if action < N_PAWN_ACTIONS {
		s.pawns[mover][0] = i8(prev_pawn_cell / BOARD)
		s.pawns[mover][1] = i8(prev_pawn_cell % BOARD)
	} else if action < V_WALL_OFFSET {
		wid := action - H_WALL_OFFSET
		s.walls_h[wid / WALL_DIM][wid % WALL_DIM] = 0
	} else {
		wid := action - V_WALL_OFFSET
		s.walls_v[wid / WALL_DIM][wid % WALL_DIM] = 0
	}
	s.walls_left[mover] = prev_walls_left

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
