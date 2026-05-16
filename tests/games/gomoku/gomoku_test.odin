package gomoku_tests

import "core:testing"
import gk "../../../games/gomoku"
import "../../../mcts"

@(test)
opening_position :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	testing.expect_value(t, s.to_play, i32(0))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect_value(t, s.is_draw, false)
	testing.expect_value(t, s.move_count, i32(0))
	for i in 0 ..< gk.N_CELLS {
		testing.expect_value(t, s.cells[i], gk.EMPTY)
	}
}

@(test)
opening_legal_moves :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	legal := make([dynamic]int, 0, gk.N_CELLS, context.temp_allocator)
	defer delete(legal)
	gk.legal_actions(state, &legal)
	testing.expect_value(t, len(legal), gk.N_CELLS) // all 225 cells empty
}

@(test)
do_undo_round_trip :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	before := s^

	d := gk.do_move(state, gk.cell_idx(7, 7))
	testing.expect_value(t, s.cells[gk.cell_idx(7, 7)], gk.BLACK)
	testing.expect_value(t, s.to_play, i32(1))
	testing.expect_value(t, s.move_count, i32(1))

	gk.undo_move(state, d)
	testing.expect_value(t, s.cells[gk.cell_idx(7, 7)], gk.EMPTY)
	testing.expect_value(t, s.to_play, before.to_play)
	testing.expect_value(t, s.move_count, before.move_count)
}

// Black places stones at (7,4), (7,5), (7,6), (7,7) then completes 5-in-a-row
// at (7,8). The win must trigger on the final placement.
@(test)
horizontal_five_in_a_row :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	for c in 4 ..< 8 {s.cells[gk.cell_idx(7, c)] = gk.BLACK}
	s.to_play = 0
	s.move_count = 4
	s.winner = -1

	d := gk.do_move(state, gk.cell_idx(7, 8))
	testing.expect_value(t, s.winner, i32(0))
	testing.expect(t, gk.is_terminal(state))
	// Side-to-move is now White, who lost.
	testing.expect_value(t, gk.terminal_value(state), f32(0.0))

	gk.undo_move(state, d)
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect(t, !gk.is_terminal(state))
}

@(test)
vertical_five_in_a_row :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	for r in 4 ..< 8 {s.cells[gk.cell_idx(r, 7)] = gk.WHITE}
	s.to_play = 1
	s.move_count = 4
	s.winner = -1

	_ = gk.do_move(state, gk.cell_idx(8, 7))
	testing.expect_value(t, s.winner, i32(1))
}

// Diagonal down-right: (3,3), (4,4), (5,5), (6,6), placement at (7,7) wins.
@(test)
diagonal_five_in_a_row :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	for k in 3 ..< 7 {s.cells[gk.cell_idx(k, k)] = gk.BLACK}
	s.to_play = 0
	s.move_count = 4
	s.winner = -1

	_ = gk.do_move(state, gk.cell_idx(7, 7))
	testing.expect_value(t, s.winner, i32(0))
}

// Anti-diagonal: (3,7), (4,6), (5,5), (6,4), placement at (7,3) wins.
@(test)
anti_diagonal_five_in_a_row :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	s.cells[gk.cell_idx(3, 7)] = gk.WHITE
	s.cells[gk.cell_idx(4, 6)] = gk.WHITE
	s.cells[gk.cell_idx(5, 5)] = gk.WHITE
	s.cells[gk.cell_idx(6, 4)] = gk.WHITE
	s.to_play = 1
	s.move_count = 4
	s.winner = -1

	_ = gk.do_move(state, gk.cell_idx(7, 3))
	testing.expect_value(t, s.winner, i32(1))
}

// Six-in-a-row (Free Gomoku overlines) is also a win — the scan reports
// "5 or more". Set up six Black stones in a row by placing the last one
// in the middle of a gap.
@(test)
overline_six_is_win :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	// Stones at (7,2..5) and (7,7); place at (7,6) to complete six in a row.
	for c in 2 ..< 6 {s.cells[gk.cell_idx(7, c)] = gk.BLACK}
	s.cells[gk.cell_idx(7, 7)] = gk.BLACK
	s.to_play = 0
	s.move_count = 5
	s.winner = -1

	_ = gk.do_move(state, gk.cell_idx(7, 6))
	testing.expect_value(t, s.winner, i32(0))
}

// A run of FOUR same-colour stones must NOT trigger a win.
@(test)
four_in_a_row_is_not_win :: proc(t: ^testing.T) {
	state := gk.new_state()
	defer gk.free_state(state)
	s := cast(^gk.State)state
	for c in 4 ..< 7 {s.cells[gk.cell_idx(7, c)] = gk.BLACK}
	s.to_play = 0
	s.move_count = 3
	s.winner = -1

	d := gk.do_move(state, gk.cell_idx(7, 7))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect(t, !gk.is_terminal(state))
	gk.undo_move(state, d)
}

@(test)
mcts_runs_one_simulation :: proc(t: ^testing.T) {
	g := gk.game()
	state := gk.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 1, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 1)
}

// Full game smoke. 225 cells, so a sim-cap of 250 leaves slack. MCTS must
// pick a legal action every move and the game must terminate (with a
// winner or a draw — both are valid).
@(test)
mcts_self_play_terminates :: proc(t: ^testing.T) {
	g := gk.game()
	state := gk.new_state()
	defer gk.free_state(state)
	cfg := mcts.default_config()

	moves := 0
	for !gk.is_terminal(state) && moves < 250 {
		clone := gk.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = u64(101 + moves))
		mcts.run_simulations(&tree, 20, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)
		_ = gk.do_move(state, action)
		moves += 1
	}
	testing.expect(t, gk.is_terminal(state))
}

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
	uniform := f32(1) / f32(n)
	for i in 0 ..< n {
		out_actions[i] = tmp[i]
		out_probs[i] = uniform
	}
	out_value^ = 0.5
	return n
}
