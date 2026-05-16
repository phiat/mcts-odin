package breakthrough_tests

import "core:testing"
import bt "../../../games/breakthrough"
import "../../../mcts"

@(test)
opening_position :: proc(t: ^testing.T) {
	state := bt.new_state()
	defer bt.free_state(state)
	s := cast(^bt.State)state
	testing.expect_value(t, s.to_play, i32(0))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect_value(t, s.black_count, i32(16))
	testing.expect_value(t, s.white_count, i32(16))
	for c in 0 ..< bt.COLS {
		testing.expect_value(t, s.cells[bt.cell_idx(0, c)], bt.BLACK)
		testing.expect_value(t, s.cells[bt.cell_idx(1, c)], bt.BLACK)
		testing.expect_value(t, s.cells[bt.cell_idx(bt.ROWS - 2, c)], bt.WHITE)
		testing.expect_value(t, s.cells[bt.cell_idx(bt.ROWS - 1, c)], bt.WHITE)
	}
}

// Row-1 pawns are the only Black pieces with legal moves at the opening
// (row-0 pawns are blocked by row-1). Edge pawns have 2 legal moves
// (straight + one diagonal); the 6 interior pawns have 3.
//   Total = 6*3 + 2*2 = 22.
@(test)
opening_legal_moves :: proc(t: ^testing.T) {
	state := bt.new_state()
	defer bt.free_state(state)
	legal := make([dynamic]int, 0, 64, context.temp_allocator)
	defer delete(legal)
	bt.legal_actions(state, &legal)
	testing.expect_value(t, len(legal), 22)
}

@(test)
do_undo_round_trip :: proc(t: ^testing.T) {
	state := bt.new_state()
	defer bt.free_state(state)
	s := cast(^bt.State)state
	before := s^

	// Black plays the row-1 column-0 pawn straight forward. Encoding:
	// from = cell_idx(1, 0); dir = 1; action = from*3 + dir.
	from := bt.cell_idx(1, 0)
	a := from * 3 + 1
	d := bt.do_move(state, a)
	testing.expect_value(t, s.cells[bt.cell_idx(1, 0)], bt.EMPTY)
	testing.expect_value(t, s.cells[bt.cell_idx(2, 0)], bt.BLACK)
	testing.expect_value(t, s.to_play, i32(1))

	bt.undo_move(state, d)
	testing.expect_value(t, s.cells[bt.cell_idx(1, 0)], bt.BLACK)
	testing.expect_value(t, s.cells[bt.cell_idx(2, 0)], bt.EMPTY)
	testing.expect_value(t, s.to_play, before.to_play)
	testing.expect_value(t, s.move_count, before.move_count)
}

// Capture exercise: hand-craft a position with a Black pawn at (3,3) and a
// White pawn at (4,4). White's turn. White's diagonal-left move from
// (4,4) → (3,3) should capture the Black pawn.
@(test)
diagonal_capture :: proc(t: ^testing.T) {
	state := bt.new_state()
	defer bt.free_state(state)
	s := cast(^bt.State)state

	// Wipe the standard starting position; we want a clean slate.
	for i in 0 ..< bt.N_CELLS {s.cells[i] = bt.EMPTY}
	s.cells[bt.cell_idx(3, 3)] = bt.BLACK
	s.cells[bt.cell_idx(4, 4)] = bt.WHITE
	s.black_count = 1
	s.white_count = 1
	s.to_play = 1 // White

	// White moves (4,4) → (3,3). White's "diagonal-left" is dr=-1, dc=-1
	// → forward_delta(1, dir=0) yields (-1, -1).
	from := bt.cell_idx(4, 4)
	a := from * 3 + 0
	d := bt.do_move(state, a)
	testing.expect_value(t, s.cells[bt.cell_idx(4, 4)], bt.EMPTY)
	testing.expect_value(t, s.cells[bt.cell_idx(3, 3)], bt.WHITE)
	testing.expect_value(t, s.black_count, i32(0))
	testing.expect_value(t, s.white_count, i32(1))
	// White wins by capture-out (Black has 0 pawns).
	testing.expect_value(t, s.winner, i32(1))

	bt.undo_move(state, d)
	testing.expect_value(t, s.cells[bt.cell_idx(4, 4)], bt.WHITE)
	testing.expect_value(t, s.cells[bt.cell_idx(3, 3)], bt.BLACK)
	testing.expect_value(t, s.black_count, i32(1))
	testing.expect_value(t, s.winner, i32(-1))
}

// Straight-forward into an enemy must NOT capture (illegal).
@(test)
straight_forward_capture_illegal :: proc(t: ^testing.T) {
	state := bt.new_state()
	defer bt.free_state(state)
	s := cast(^bt.State)state
	for i in 0 ..< bt.N_CELLS {s.cells[i] = bt.EMPTY}
	s.cells[bt.cell_idx(3, 3)] = bt.BLACK // Black pawn ahead of White
	s.cells[bt.cell_idx(4, 3)] = bt.WHITE
	s.black_count = 1
	s.white_count = 1
	s.to_play = 1 // White

	from := bt.cell_idx(4, 3)
	straight := from * 3 + 1
	legal := make([dynamic]int, 0, 8, context.temp_allocator)
	defer delete(legal)
	bt.legal_actions(state, &legal)
	for a in legal {
		testing.expectf(t, a != straight, "straight-forward capture should be illegal, got action %d", a)
	}
}

// Back-rank reach wins: Black at (6, 4) reaching (7, 4) wins.
@(test)
black_reaches_back_rank :: proc(t: ^testing.T) {
	state := bt.new_state()
	defer bt.free_state(state)
	s := cast(^bt.State)state
	for i in 0 ..< bt.N_CELLS {s.cells[i] = bt.EMPTY}
	s.cells[bt.cell_idx(6, 4)] = bt.BLACK
	s.black_count = 1
	s.white_count = 1
	s.cells[bt.cell_idx(0, 0)] = bt.WHITE // keep white_count > 0 so the win is by reach, not capture-out
	s.to_play = 0

	from := bt.cell_idx(6, 4)
	a := from * 3 + 1
	_ = bt.do_move(state, a)
	testing.expect_value(t, s.winner, i32(0))
	testing.expect(t, bt.is_terminal(state))
}

// And the mirror — White at (1, 4) reaching (0, 4) wins.
@(test)
white_reaches_back_rank :: proc(t: ^testing.T) {
	state := bt.new_state()
	defer bt.free_state(state)
	s := cast(^bt.State)state
	for i in 0 ..< bt.N_CELLS {s.cells[i] = bt.EMPTY}
	s.cells[bt.cell_idx(1, 4)] = bt.WHITE
	s.cells[bt.cell_idx(7, 0)] = bt.BLACK
	s.black_count = 1
	s.white_count = 1
	s.to_play = 1

	from := bt.cell_idx(1, 4)
	a := from * 3 + 1
	_ = bt.do_move(state, a)
	testing.expect_value(t, s.winner, i32(1))
}

@(test)
mcts_runs_one_simulation :: proc(t: ^testing.T) {
	g := bt.game()
	state := bt.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	mcts.run_simulations(&tree, 1, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 1)
}

// Full MCTS self-play game. Breakthrough has no draws and is bounded by
// piece count: at most 32 captures, plus eventually a back-rank reach.
// Cap at 200 moves as a sanity ceiling.
@(test)
mcts_self_play_terminates :: proc(t: ^testing.T) {
	g := bt.game()
	state := bt.new_state()
	defer bt.free_state(state)
	cfg := mcts.default_config()

	moves := 0
	for !bt.is_terminal(state) && moves < 200 {
		clone := bt.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = u64(11 + moves))
		mcts.run_simulations(&tree, 30, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)

		legal := make([dynamic]int, 0, 64, context.temp_allocator)
		defer delete(legal)
		bt.legal_actions(state, &legal)
		found := false
		for a in legal {if a == action {found = true; break}}
		testing.expectf(t, found, "MCTS picked illegal action %d at move %d", action, moves)

		_ = bt.do_move(state, action)
		moves += 1
	}
	testing.expect(t, bt.is_terminal(state))
	s := cast(^bt.State)state
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
