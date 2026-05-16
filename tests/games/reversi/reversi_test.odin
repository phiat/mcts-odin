package reversi_tests

import "core:testing"
import rv "../../../games/reversi"
import "../../../mcts"

@(test)
opening_position :: proc(t: ^testing.T) {
	state := rv.new_state()
	defer rv.free_state(state)
	s := cast(^rv.State)state
	testing.expect_value(t, s.cells[rv.cell_idx(3, 3)], rv.WHITE)
	testing.expect_value(t, s.cells[rv.cell_idx(3, 4)], rv.BLACK)
	testing.expect_value(t, s.cells[rv.cell_idx(4, 3)], rv.BLACK)
	testing.expect_value(t, s.cells[rv.cell_idx(4, 4)], rv.WHITE)
	testing.expect_value(t, s.to_play, i32(0)) // Black moves first
}

@(test)
opening_legal_moves :: proc(t: ^testing.T) {
	state := rv.new_state()
	defer rv.free_state(state)
	legal := make([dynamic]int, 0, 4, context.temp_allocator)
	defer delete(legal)
	rv.legal_actions(state, &legal)
	// Standard Reversi opening: Black has exactly 4 legal moves —
	// the four cells diagonally adjacent to a White center stone.
	testing.expect_value(t, len(legal), 4)
	// Specifically: d3 (3,3 -> nope, that's white) ... actual openings are
	// c4 (3,2)? No, the four legal Black moves are: d2(1,3)? Let me check.
	// Black needs to bracket a White stone. White stones are at (3,3) and
	// (4,4). To bracket (3,3), Black needs to place s.t. one of the 8
	// neighbours of (3,3) is the placed stone AND there's a Black on the
	// other side of a White. The only way at start: place at (2,3) to
	// bracket (3,3) with (4,3) (Black) -> flips (3,3). Similarly the
	// symmetric three.
	expected := [4]int{
		rv.cell_idx(2, 3),
		rv.cell_idx(3, 2),
		rv.cell_idx(4, 5),
		rv.cell_idx(5, 4),
	}
	for a in legal {
		ok := false
		for e in expected {if e == a {ok = true; break}}
		testing.expectf(t, ok, "unexpected legal action %d at opening", a)
	}
}

@(test)
do_undo_round_trip :: proc(t: ^testing.T) {
	state := rv.new_state()
	defer rv.free_state(state)
	before := (cast(^rv.State)state)^

	// Black plays (2,3) — should flip (3,3) to Black.
	d := rv.do_move(state, rv.cell_idx(2, 3))
	mid := cast(^rv.State)state
	testing.expect_value(t, mid.cells[rv.cell_idx(2, 3)], rv.BLACK)
	testing.expect_value(t, mid.cells[rv.cell_idx(3, 3)], rv.BLACK) // flipped
	testing.expect_value(t, mid.to_play, i32(1))

	rv.undo_move(state, d)
	after := (cast(^rv.State)state)^
	testing.expect_value(t, after.cells[rv.cell_idx(2, 3)], rv.EMPTY)
	testing.expect_value(t, after.cells[rv.cell_idx(3, 3)], rv.WHITE) // restored
	testing.expect_value(t, after.to_play, i32(0))
	testing.expect_value(t, after.consecutive_passes, before.consecutive_passes)
	testing.expect_value(t, after.move_count, before.move_count)
}

@(test)
two_passes_terminates :: proc(t: ^testing.T) {
	state := rv.new_state()
	defer rv.free_state(state)
	s := cast(^rv.State)state
	// Force a position with no legal moves for either side by emptying the
	// board except for one corner stone. With only one Black stone, neither
	// player can ever flip — both must pass.
	for i in 0 ..< rv.N_CELLS {s.cells[i] = rv.EMPTY}
	s.cells[0] = rv.BLACK
	s.to_play = 0
	testing.expect(t, !rv.is_terminal(state))

	_ = rv.do_move(state, rv.PASS_ACTION)
	testing.expect_value(t, s.consecutive_passes, i32(1))
	testing.expect(t, !rv.is_terminal(state))

	_ = rv.do_move(state, rv.PASS_ACTION)
	testing.expect_value(t, s.consecutive_passes, i32(2))
	testing.expect(t, rv.is_terminal(state))
}

@(test)
multi_direction_flip :: proc(t: ^testing.T) {
	// Construct a position where placing one Black stone flips in two
	// directions. White ring around (4,4), Black anchors at (4,1) and (1,4).
	// Black plays (4,4): no — (4,4) is occupied at start. Use a clean board.
	state := rv.new_state()
	defer rv.free_state(state)
	s := cast(^rv.State)state
	for i in 0 ..< rv.N_CELLS {s.cells[i] = rv.EMPTY}
	// Setup: row 4 has Black at (4,1), White at (4,2),(4,3),(4,4),(4,5),
	//        Black at (4,6). Col 4 has Black at (1,4), White at (2,4),(3,4).
	// Note: (4,4) lies in the East-West "white run" between Black anchors,
	// AND in the South direction of a White run with Black above. But we
	// need (4,4) to be EMPTY to play there. So shift to (5,4) instead:
	// Place row 5: Black at (5,2), White at (5,3),(5,4),(5,5), Black at (5,6).
	// Black plays (5,1)? Let me reset and just exercise a clean two-direction
	// flip on (3,5):
	//   White stones at (3,3) (3,4); Black at (3,2)  ->  (3,5) by Black
	//   flips (3,3),(3,4) horizontally.
	//   Add White at (2,5),(1,5) and Black at (0,5)   ->  (3,5) also flips
	//   (2,5),(1,5) vertically.
	for i in 0 ..< rv.N_CELLS {s.cells[i] = rv.EMPTY}
	s.cells[rv.cell_idx(3, 2)] = rv.BLACK
	s.cells[rv.cell_idx(3, 3)] = rv.WHITE
	s.cells[rv.cell_idx(3, 4)] = rv.WHITE
	s.cells[rv.cell_idx(0, 5)] = rv.BLACK
	s.cells[rv.cell_idx(1, 5)] = rv.WHITE
	s.cells[rv.cell_idx(2, 5)] = rv.WHITE
	s.to_play = 0 // Black to move
	s.consecutive_passes = 0
	s.move_count = 6

	d := rv.do_move(state, rv.cell_idx(3, 5))
	testing.expect_value(t, s.cells[rv.cell_idx(3, 5)], rv.BLACK)
	testing.expect_value(t, s.cells[rv.cell_idx(3, 4)], rv.BLACK) // E-W flip
	testing.expect_value(t, s.cells[rv.cell_idx(3, 3)], rv.BLACK) // E-W flip
	testing.expect_value(t, s.cells[rv.cell_idx(2, 5)], rv.BLACK) // N-S flip
	testing.expect_value(t, s.cells[rv.cell_idx(1, 5)], rv.BLACK) // N-S flip

	rv.undo_move(state, d)
	testing.expect_value(t, s.cells[rv.cell_idx(3, 5)], rv.EMPTY)
	testing.expect_value(t, s.cells[rv.cell_idx(3, 4)], rv.WHITE)
	testing.expect_value(t, s.cells[rv.cell_idx(3, 3)], rv.WHITE)
	testing.expect_value(t, s.cells[rv.cell_idx(2, 5)], rv.WHITE)
	testing.expect_value(t, s.cells[rv.cell_idx(1, 5)], rv.WHITE)
}

@(test)
mcts_runs_one_simulation :: proc(t: ^testing.T) {
	g := rv.game()
	state := rv.new_state()
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)

	mcts.run_simulations(&tree, 1, uniform_evaluator, &g)
	testing.expect(t, mcts.get_root_visit_count(&tree) == 1)
}

@(test)
mcts_self_play_runs_to_completion :: proc(t: ^testing.T) {
	g := rv.game()
	state := rv.new_state()
	defer rv.free_state(state)
	cfg := mcts.default_config()

	moves := 0
	for !rv.is_terminal(state) && moves < 200 {
		clone := rv.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = u64(42 + moves))
		mcts.run_simulations(&tree, 30, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)

		// Verify legality before applying.
		legal := make([dynamic]int, 0, 65, context.temp_allocator)
		defer delete(legal)
		rv.legal_actions(state, &legal)
		found := false
		for a in legal {if a == action {found = true; break}}
		testing.expectf(t, found, "selected action %d not in legal moves at move %d", action, moves)

		_ = rv.do_move(state, action)
		moves += 1
	}
	testing.expect(t, rv.is_terminal(state) || moves >= 200)
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
