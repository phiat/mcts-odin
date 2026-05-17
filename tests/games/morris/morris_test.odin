package morris_tests

import "core:testing"
import mr "../../../games/morris"
import "../../../mcts"

@(test)
terminal_value_nonterminal_is_draw :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	testing.expect_value(t, mr.is_terminal(state), false)
	testing.expect_value(t, mr.terminal_value(state), f32(0.5))
}

@(test)
opening_position :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state
	testing.expect_value(t, s.to_play, i32(0))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect_value(t, s.is_term, false)
	testing.expect_value(t, s.placed[0], i8(0))
	testing.expect_value(t, s.placed[1], i8(0))
	testing.expect_value(t, s.on_board[0], i8(0))
	testing.expect_value(t, s.on_board[1], i8(0))
	for p in 0 ..< mr.N_POINTS {
		testing.expect_value(t, s.points[p], i8(-1))
	}
}

// Opening: every empty point is a legal placement, no mill possible from
// a single stone, so 24 actions and all have remove == NONE.
@(test)
opening_legal_moves :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	legal := make([dynamic]int, 0, 64, context.temp_allocator)
	defer delete(legal)
	mr.legal_actions(state, &legal)
	testing.expect_value(t, len(legal), 24)
	for a in legal {
		// from must be NONE (placement), remove must be NONE (no mill yet).
		from := a / 625
		remove := a % 25
		testing.expect_value(t, from, mr.NONE)
		testing.expect_value(t, remove, mr.NONE)
	}
}

@(test)
placement_do_undo :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state
	before := s^

	// Place player 0 at point 0. action = NONE*625 + 0*25 + NONE = 24*625 + 24 = 15024.
	a := mr.NONE * 625 + 0 * 25 + mr.NONE
	d := mr.do_move(state, a)
	testing.expect_value(t, s.points[0], i8(0))
	testing.expect_value(t, s.placed[0], i8(1))
	testing.expect_value(t, s.on_board[0], i8(1))
	testing.expect_value(t, s.to_play, i32(1))

	mr.undo_move(state, d)
	testing.expect_value(t, s^, before)
}

// Forming a mill in phase 1: place stones to make 0,1,2 a complete row.
// The move that completes the mill MUST include a removal (or NONE only
// if no opp piece exists).
@(test)
mill_grants_removal :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state

	// Hand-set up: player 0 at points 0 and 1; player 1 at points 3 and 5.
	// Player 0 places at point 2 → completes mill (0,1,2) → must remove a
	// player-1 piece (neither of which is in a mill).
	s.points[0] = 0
	s.points[1] = 0
	s.points[3] = 1
	s.points[5] = 1
	s.placed[0] = 2
	s.on_board[0] = 2
	s.placed[1] = 2
	s.on_board[1] = 2
	s.to_play = 0

	legal := make([dynamic]int, 0, 64, context.temp_allocator)
	defer delete(legal)
	mr.legal_actions(state, &legal)

	// Every action that places at point 2 must include remove ∈ {3, 5}.
	saw_remove_3 := false
	saw_remove_5 := false
	for a in legal {
		from := a / 625
		to := (a / 25) % 25
		remove := a % 25
		if from == mr.NONE && to == 2 {
			testing.expect(t, remove == 3 || remove == 5, "mill-forming move must remove an opp piece")
			if remove == 3 {saw_remove_3 = true}
			if remove == 5 {saw_remove_5 = true}
		}
	}
	testing.expect(t, saw_remove_3 && saw_remove_5)
}

// The "unless" clause: when ALL opponent pieces are in mills, the mover
// may remove a piece that is also in a mill.
@(test)
remove_in_mill_when_all_opp_in_mills :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state

	// Player 1 has formed two mills: (8,9,10) and (16,17,18). Player 0 has
	// pieces at 0 and 1, and is about to place at 2 to form mill (0,1,2).
	// All player-1 pieces are in mills → the removal of any P1 piece is
	// legal, including those in mills.
	s.points[0] = 0
	s.points[1] = 0
	s.points[8] = 1
	s.points[9] = 1
	s.points[10] = 1
	s.points[16] = 1
	s.points[17] = 1
	s.points[18] = 1
	s.placed[0] = 2
	s.on_board[0] = 2
	s.placed[1] = 6
	s.on_board[1] = 6
	s.to_play = 0

	legal := make([dynamic]int, 0, 64, context.temp_allocator)
	defer delete(legal)
	mr.legal_actions(state, &legal)

	// Among actions that place at point 2, the removal set should cover
	// all six P1 pieces (since every one is in a mill but the "all opp in
	// mills" exception applies).
	removals: map[int]bool
	defer delete(removals)
	for a in legal {
		from := a / 625
		to := (a / 25) % 25
		remove := a % 25
		if from == mr.NONE && to == 2 && remove != mr.NONE {
			removals[remove] = true
		}
	}
	expected := [6]int{8, 9, 10, 16, 17, 18}
	for p in expected {
		testing.expect(t, removals[p], "must allow removal of in-mill piece when all opp in mills")
	}
}

// Phase 2 movement is adjacency-restricted. Hand-set up a post-placement
// position and verify a piece cannot move to a non-adjacent empty point.
@(test)
phase_2_movement_is_adjacent_only :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state

	// Both players placed all 9. P0 has 4 pieces, P1 has 5. None form mills.
	s.placed[0] = 9
	s.placed[1] = 9
	s.points[0] = 0
	s.points[2] = 0
	s.points[4] = 0
	s.points[6] = 0
	s.points[8] = 1
	s.points[10] = 1
	s.points[12] = 1
	s.points[14] = 1
	s.points[18] = 1
	s.on_board[0] = 4
	s.on_board[1] = 5
	s.to_play = 0

	legal := make([dynamic]int, 0, 64, context.temp_allocator)
	defer delete(legal)
	mr.legal_actions(state, &legal)

	for a in legal {
		from := a / 625
		to := (a / 25) % 25
		// Adjacency: 0↔1, 0↔7. From point 0, allowed to ∈ {1, 7}.
		if from == 0 {
			testing.expect(t, to == 1 || to == 7, "P0 from 0 can only slide to 1 or 7 in phase 2")
		}
	}
}

// Phase 3 (flying): when a player has exactly 3 men, they may move from
// any of their points to ANY empty point.
@(test)
phase_3_flying :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state

	// P0 has exactly 3 men (qualifies for flying). P1 has 5.
	// Make sure none of P0's pieces are in a mill so we don't trip mill
	// logic, and make sure P0 has at least one empty far-away target.
	s.placed[0] = 9
	s.placed[1] = 9
	s.points[0] = 0
	s.points[2] = 0
	s.points[4] = 0
	s.points[8] = 1
	s.points[10] = 1
	s.points[12] = 1
	s.points[14] = 1
	s.points[18] = 1
	s.on_board[0] = 3
	s.on_board[1] = 5
	s.to_play = 0

	legal := make([dynamic]int, 0, 64, context.temp_allocator)
	defer delete(legal)
	mr.legal_actions(state, &legal)

	// In flying mode, P0 must have moves from 0 to non-adjacent empties
	// like 23 (which is not adjacent to 0). Adjacency to 0 is {1, 7}.
	found_flight := false
	for a in legal {
		from := a / 625
		to := (a / 25) % 25
		if from == 0 && to == 23 {found_flight = true; break}
	}
	testing.expect(t, found_flight, "phase 3 must allow flight to non-adjacent empties")
}

// Loss by reduction below 3 men (post-placement).
@(test)
loss_by_reduction_below_three :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state

	// Both placed; P0 has 3 men (0, 2, 4), P1 has 5 with two mill-candidates
	// at (8,9,_) waiting for one more. P1 to play; places at 10 to form
	// mill (8,9,10) and removes one of P0's 3 pieces → P0 drops to 2 →
	// P0 loses on the *next* check (P0 is now to_play).
	s.placed[0] = 9
	s.placed[1] = 8 // P1 places one more this move
	s.points[0] = 0
	s.points[2] = 0
	s.points[4] = 0
	s.points[8] = 1
	s.points[9] = 1
	s.points[18] = 1
	s.points[19] = 1
	s.points[20] = 1
	s.on_board[0] = 3
	s.on_board[1] = 5
	s.to_play = 1

	// Action: place at 10, remove P0 piece at point 0.
	a := mr.NONE * 625 + 10 * 25 + 0
	mr.do_move(state, a)

	testing.expect_value(t, s.is_term, true)
	testing.expect_value(t, s.winner, i32(1))
	testing.expect_value(t, s.on_board[0], i8(2))
}

@(test)
deep_do_undo_round_trip :: proc(t: ^testing.T) {
	state := mr.new_state()
	defer mr.free_state(state)
	s := cast(^mr.State)state
	before := s^

	deltas: [dynamic]mcts.Move_Delta
	defer delete(deltas)

	// Play several moves via legal_actions to exercise placement +
	// possible mill removals.
	for ply in 0 ..< 10 {
		legal := make([dynamic]int, 0, 64, context.temp_allocator)
		mr.legal_actions(state, &legal)
		if len(legal) == 0 {break}
		d := mr.do_move(state, legal[ply % len(legal)])
		append(&deltas, d)
		delete(legal)
	}

	#reverse for d in deltas {mr.undo_move(state, d)}
	testing.expect_value(t, s^, before)
}

@(test)
mcts_runs :: proc(t: ^testing.T) {
	g := mr.game()
	state := mr.new_state()
	defer mr.free_state(state)

	cfg := mcts.default_config()
	cfg.c_puct = 1.0

	tree: mcts.Tree
	mcts.init(&tree, &g, mr.clone_state(state), cfg, seed = 7)
	defer mcts.destroy(&tree)

	uniform :: proc(
		state: rawptr,
		out_actions: []int,
		out_probs: []f32,
		out_value: ^f32,
		user_data: rawptr,
	) -> int {
		gg := cast(^mcts.Game)user_data
		tmp := make([dynamic]int, 0, 64, context.temp_allocator)
		defer delete(tmp)
		gg.legal_actions(state, &tmp)
		n := len(tmp)
		if n == 0 {out_value^ = 0.5; return 0}
		u := f32(1) / f32(n)
		for i in 0 ..< n {
			out_actions[i] = tmp[i]
			out_probs[i] = u
		}
		out_value^ = 0.5
		return n
	}

	mcts.run_simulations(&tree, 100, uniform, &g)
	a := mcts.select_action(&tree, 0.0)
	testing.expect(t, a >= 0 && a < mr.N_ACTIONS)
}
