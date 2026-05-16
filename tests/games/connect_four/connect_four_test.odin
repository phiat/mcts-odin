package connect_four_tests

import "core:testing"
import "../../../mcts"
import c4 "../../../games/connect_four"

// Uniform-policy, value=0.5 evaluator.
@(private = "file")
uniform_evaluator :: proc(
	state:       rawptr,
	out_actions: []int,
	out_probs:   []f32,
	out_value:   ^f32,
	user_data:   rawptr,
) -> int {
	g := cast(^mcts.Game)user_data
	tmp := make([dynamic]int, 0, g.max_actions, context.temp_allocator)
	defer delete(tmp)
	g.legal_actions(state, &tmp)

	n := len(tmp)
	if n == 0 {out_value^ = 0.5; return 0}
	uniform := 1.0 / f32(n)
	for i in 0 ..< n {
		out_actions[i] = tmp[i]
		out_probs[i] = uniform
	}
	out_value^ = 0.5
	return n
}

@(test)
c4_construction :: proc(t: ^testing.T) {
	state := c4.new_state()
	defer c4.free_state(state)
	s := cast(^c4.State)state

	testing.expect_value(t, s.to_play, i32(0))
	testing.expect_value(t, s.total_moves, i32(0))
	testing.expect_value(t, s.winner, i32(-1))
	for i in 0 ..< c4.N_CELLS {
		testing.expect_value(t, s.cells[i], i8(-1))
	}

	legal := make([dynamic]int, 0, 7, context.temp_allocator)
	defer delete(legal)
	c4.legal_actions(state, &legal)
	testing.expect_value(t, len(legal), 7)
	testing.expect(t, !c4.is_terminal(state))
}

@(test)
c4_basic_drop :: proc(t: ^testing.T) {
	state := c4.new_state()
	defer c4.free_state(state)
	_ = c4.do_move(state, 3)
	s := cast(^c4.State)state

	testing.expect_value(t, s.cells[0 * c4.COLS + 3], i8(0))   // (row 0, col 3) = player 0
	testing.expect_value(t, s.column_height[3], i8(1))
	testing.expect_value(t, s.to_play, i32(1))
	testing.expect_value(t, s.total_moves, i32(1))
	testing.expect_value(t, s.winner, i32(-1))
}

@(test)
c4_horizontal_win :: proc(t: ^testing.T) {
	state := c4.new_state()
	defer c4.free_state(state)
	// Y plays col 0,1,2,3; R plays col 0,1,2 (stacked on top of Y's bottom row).
	// After: row 0 is Y Y Y Y _ _ _, row 1 is R R R _ _ _ _.
	_ = c4.do_move(state, 0)  // Y
	_ = c4.do_move(state, 0)  // R
	_ = c4.do_move(state, 1)  // Y
	_ = c4.do_move(state, 1)  // R
	_ = c4.do_move(state, 2)  // Y
	_ = c4.do_move(state, 2)  // R
	_ = c4.do_move(state, 3)  // Y wins on bottom row
	s := cast(^c4.State)state
	testing.expect_value(t, s.winner, i32(0))
	testing.expect(t, c4.is_terminal(state))
	// Side-to-move is the loser; terminal_value from their perspective is 0.
	testing.expect_value(t, c4.terminal_value(state), f32(0.0))
}

@(test)
c4_diagonal_win :: proc(t: ^testing.T) {
	state := c4.new_state()
	defer c4.free_state(state)
	// Build a / diagonal for Y at (0,0), (1,1), (2,2), (3,3).
	// Sequence (Y=0, R=1):
	//   Y col 0  -> (0,0) = Y
	//   R col 1  -> (0,1) = R
	//   Y col 1  -> (1,1) = Y
	//   R col 2  -> (0,2) = R
	//   Y col 3  -> (0,3) = Y          (filler so we can stack red at col 2)
	//   R col 2  -> (1,2) = R
	//   Y col 2  -> (2,2) = Y
	//   R col 3  -> (1,3) = R
	//   Y col 3  -> oops, need (3,3); col 3 height is 2 after that
	//   R col 6  -> (0,6) = R filler
	//   Y col 3  -> (2,3) = Y
	//   R col 6  -> (1,6) = R filler
	//   Y col 3  -> (3,3) = Y wins
	_ = c4.do_move(state, 0)  // Y (0,0)
	_ = c4.do_move(state, 1)  // R (0,1)
	_ = c4.do_move(state, 1)  // Y (1,1)
	_ = c4.do_move(state, 2)  // R (0,2)
	_ = c4.do_move(state, 3)  // Y (0,3)
	_ = c4.do_move(state, 2)  // R (1,2)
	_ = c4.do_move(state, 2)  // Y (2,2)
	_ = c4.do_move(state, 6)  // R (0,6) filler
	_ = c4.do_move(state, 3)  // Y (1,3)
	_ = c4.do_move(state, 6)  // R (1,6) filler
	_ = c4.do_move(state, 3)  // Y (2,3)
	_ = c4.do_move(state, 6)  // R (2,6) filler
	_ = c4.do_move(state, 3)  // Y (3,3) — completes / diagonal
	s := cast(^c4.State)state
	testing.expect_value(t, s.winner, i32(0))
	testing.expect(t, c4.is_terminal(state))
}

@(test)
c4_column_full :: proc(t: ^testing.T) {
	state := c4.new_state()
	defer c4.free_state(state)
	// Drop 6 pieces into column 0 (filling it). Players alternate but no
	// vertical-4 from a single colour because they alternate.
	for _ in 0 ..< 6 {
		_ = c4.do_move(state, 0)
	}
	s := cast(^c4.State)state
	testing.expect_value(t, s.column_height[0], i8(6))

	legal := make([dynamic]int, 0, 7, context.temp_allocator)
	defer delete(legal)
	c4.legal_actions(state, &legal)
	found := false
	for a in legal {if a == 0 {found = true; break}}
	testing.expect(t, !found)
	testing.expect_value(t, len(legal), 6)
}

@(test)
c4_do_undo_round_trip :: proc(t: ^testing.T) {
	state := c4.new_state()
	defer c4.free_state(state)
	// Play a few moves, snapshot, do_move/undo_move, expect bit-identical state.
	_ = c4.do_move(state, 3)
	_ = c4.do_move(state, 4)
	_ = c4.do_move(state, 3)
	snapshot := (cast(^c4.State)state)^

	delta := c4.do_move(state, 2)
	c4.undo_move(state, delta)
	after := (cast(^c4.State)state)^

	testing.expect_value(t, after.to_play, snapshot.to_play)
	testing.expect_value(t, after.total_moves, snapshot.total_moves)
	testing.expect_value(t, after.winner, snapshot.winner)
	for i in 0 ..< c4.N_CELLS {
		testing.expect_value(t, after.cells[i], snapshot.cells[i])
	}
	for i in 0 ..< c4.COLS {
		testing.expect_value(t, after.column_height[i], snapshot.column_height[i])
	}
}

@(test)
c4_do_undo_winning_move :: proc(t: ^testing.T) {
	state := c4.new_state()
	defer c4.free_state(state)
	// Set up so Y wins on next col-3 drop, then undo and check winner reset.
	_ = c4.do_move(state, 0)  // Y
	_ = c4.do_move(state, 0)  // R
	_ = c4.do_move(state, 1)  // Y
	_ = c4.do_move(state, 1)  // R
	_ = c4.do_move(state, 2)  // Y
	_ = c4.do_move(state, 2)  // R
	snapshot := (cast(^c4.State)state)^
	delta := c4.do_move(state, 3)  // Y wins
	testing.expect_value(t, (cast(^c4.State)state).winner, i32(0))
	c4.undo_move(state, delta)
	after := (cast(^c4.State)state)^
	testing.expect_value(t, after.winner, snapshot.winner)
	testing.expect_value(t, after.to_play, snapshot.to_play)
	testing.expect_value(t, after.total_moves, snapshot.total_moves)
	for i in 0 ..< c4.N_CELLS {
		testing.expect_value(t, after.cells[i], snapshot.cells[i])
	}
}

@(test)
c4_mcts_runs :: proc(t: ^testing.T) {
	g := c4.game()
	state := c4.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 200, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 200)
	testing.expect(t, mcts.tree_size(&tree) > 1)
}
