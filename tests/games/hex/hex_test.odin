package hex_tests

import "core:testing"
import hx "../../../games/hex"
import "../../../mcts"

@(test)
opening_position :: proc(t: ^testing.T) {
	state := hx.new_state()
	defer hx.free_state(state)
	s := cast(^hx.State)state
	testing.expect_value(t, s.to_play, i32(0))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect_value(t, s.move_count, i32(0))
	for i in 0 ..< hx.N_CELLS {
		testing.expect_value(t, s.cells[i], hx.EMPTY)
	}
}

@(test)
opening_legal_moves :: proc(t: ^testing.T) {
	state := hx.new_state()
	defer hx.free_state(state)
	legal := make([dynamic]int, 0, hx.N_CELLS, context.temp_allocator)
	defer delete(legal)
	hx.legal_actions(state, &legal)
	testing.expect_value(t, len(legal), hx.N_CELLS)
}

@(test)
do_undo_round_trip :: proc(t: ^testing.T) {
	state := hx.new_state()
	defer hx.free_state(state)
	s := cast(^hx.State)state
	before := s^

	d := hx.do_move(state, hx.cell_idx(4, 4))
	testing.expect_value(t, s.cells[hx.cell_idx(4, 4)], hx.RED)
	testing.expect_value(t, s.to_play, i32(1))
	testing.expect_value(t, s.move_count, i32(1))

	hx.undo_move(state, d)
	testing.expect_value(t, s.cells[hx.cell_idx(4, 4)], hx.EMPTY)
	testing.expect_value(t, s.to_play, before.to_play)
	testing.expect_value(t, s.move_count, before.move_count)
	testing.expect_value(t, s.winner, before.winner)
}

// Red's win: connect top edge (r=0) to bottom edge (r=SIZE-1).
// Build the chain at column 4: (0,4) → (1,4) → ... → (SIZE-1, 4).
// Place alternately Red and (any) Blue moves; Blue plays harmlessly on row 0.
@(test)
red_vertical_win :: proc(t: ^testing.T) {
	state := hx.new_state()
	defer hx.free_state(state)
	s := cast(^hx.State)state

	// Manually set up: Red has stones on every row of column 4.
	// Place the final Red stone via do_move and verify it triggers win.
	for r in 0 ..< hx.SIZE - 1 {s.cells[hx.cell_idx(r, 4)] = hx.RED}
	s.to_play = 0 // Red to play
	s.move_count = 8
	s.winner = -1

	d := hx.do_move(state, hx.cell_idx(hx.SIZE - 1, 4))
	testing.expect_value(t, s.winner, i32(0))
	testing.expect(t, hx.is_terminal(state))

	// Value from terminal-state side-to-move (now Blue, who lost).
	testing.expect_value(t, hx.terminal_value(state), f32(0.0))

	// Undo restores non-terminal state.
	hx.undo_move(state, d)
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect(t, !hx.is_terminal(state))
}

// Blue's win: connect left edge (c=0) to right edge (c=SIZE-1).
// Build the chain at row 4.
@(test)
blue_horizontal_win :: proc(t: ^testing.T) {
	state := hx.new_state()
	defer hx.free_state(state)
	s := cast(^hx.State)state

	for c in 0 ..< hx.SIZE - 1 {s.cells[hx.cell_idx(4, c)] = hx.BLUE}
	s.to_play = 1 // Blue to play
	s.move_count = 8
	s.winner = -1

	_ = hx.do_move(state, hx.cell_idx(4, hx.SIZE - 1))
	testing.expect_value(t, s.winner, i32(1))
	testing.expect(t, hx.is_terminal(state))
}

// A diagonal chain in the rhombus adjacency must connect via the (r-1,c+1)
// and (r+1,c-1) neighbour directions. Set up Red stones at (0,8), (1,7),
// (2,6), ..., (8,0) — touches both top (r=0) and bottom (r=SIZE-1) edges and
// every consecutive pair is in DIRS.
@(test)
diagonal_chain_wins :: proc(t: ^testing.T) {
	state := hx.new_state()
	defer hx.free_state(state)
	s := cast(^hx.State)state

	for k in 0 ..< hx.SIZE - 1 {
		s.cells[hx.cell_idx(k, hx.SIZE - 1 - k)] = hx.RED
	}
	s.to_play = 0
	s.move_count = 8
	s.winner = -1

	_ = hx.do_move(state, hx.cell_idx(hx.SIZE - 1, 0))
	testing.expect_value(t, s.winner, i32(0))
}

// Two disjoint Red groups — neither touches both edges — must NOT trigger
// a win when a third Red stone goes down between them but still doesn't
// bridge to both edges.
@(test)
disjoint_groups_no_false_win :: proc(t: ^testing.T) {
	state := hx.new_state()
	defer hx.free_state(state)
	s := cast(^hx.State)state

	// Red at (0,4), (1,4), (2,4) — touches top but not bottom.
	s.cells[hx.cell_idx(0, 4)] = hx.RED
	s.cells[hx.cell_idx(1, 4)] = hx.RED
	s.cells[hx.cell_idx(2, 4)] = hx.RED
	s.to_play = 0
	s.move_count = 3
	s.winner = -1

	// Place another Red stone far away; should not complete a chain.
	d := hx.do_move(state, hx.cell_idx(8, 0))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect(t, !hx.is_terminal(state))
	hx.undo_move(state, d)
}

@(test)
mcts_runs_one_simulation :: proc(t: ^testing.T) {
	g := hx.game()
	state := hx.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 1, uniform_evaluator, &g)
	testing.expect(t, mcts.get_root_visit_count(&tree) == 1)
}

@(test)
mcts_self_play_terminates_with_winner :: proc(t: ^testing.T) {
	// A full Hex self-play game must terminate with a winner — the Hex
	// theorem guarantees no draws and the board has 81 cells, so 81 moves
	// is the absolute upper bound. In practice it ends sooner.
	g := hx.game()
	state := hx.new_state()
	defer hx.free_state(state)
	cfg := mcts.default_config()

	moves := 0
	for !hx.is_terminal(state) && moves < hx.N_CELLS + 1 {
		clone := hx.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = u64(7 + moves))
		mcts.run_simulations(&tree, 30, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)
		_ = hx.do_move(state, action)
		moves += 1
	}
	testing.expect(t, hx.is_terminal(state))
	s := cast(^hx.State)state
	testing.expect(t, s.winner == 0 || s.winner == 1)
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
