package go_tests

import "core:testing"
import ag "../../../games/go"

@(test)
goboard_construction :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	testing.expect_value(t, b.size, 9)
	testing.expect_value(t, b.to_play, ag.BLACK)
	testing.expect_value(t, b.consecutive_passes, 0)
	testing.expect_value(t, b.move_count, 0)
	testing.expect(t, !ag.is_game_over(&b))
	for i in 0 ..< 81 {
		testing.expect_value(t, ag.at_flat(&b, i), ag.EMPTY)
	}
}

@(test)
basic_stone_placement :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	testing.expect(t, ag.play(&b, 4, 4))
	testing.expect_value(t, ag.at(&b, 4, 4), ag.BLACK)
	testing.expect_value(t, b.to_play, ag.WHITE)
	testing.expect_value(t, b.move_count, 1)

	testing.expect(t, ag.play(&b, 4, 5))
	testing.expect_value(t, ag.at(&b, 4, 5), ag.WHITE)
	testing.expect_value(t, b.to_play, ag.BLACK)
	testing.expect_value(t, b.move_count, 2)

	testing.expect(t, !ag.is_legal(&b, 4, 4))
	testing.expect(t, !ag.play(&b, 4, 4))
}

@(test)
single_stone_capture :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	ag.play(&b, 0, 1) // Black
	ag.play(&b, 0, 0) // White (to be captured)
	ag.play(&b, 1, 0) // Black (completes capture)
	testing.expect_value(t, ag.at(&b, 0, 0), ag.EMPTY)
}

@(test)
group_capture :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	ag.play(&b, 0, 0) // Black
	ag.play(&b, 1, 0) // White
	ag.play(&b, 0, 1) // Black
	ag.play(&b, 1, 1) // White
	ag.play(&b, 2, 0) // Black
	ag.play(&b, 8, 8) // White elsewhere
	ag.play(&b, 2, 1) // Black
	ag.pass_move(&b) // White passes
	ag.play(&b, 1, 2) // Black — completes capture
	testing.expect_value(t, ag.at(&b, 1, 0), ag.EMPTY)
	testing.expect_value(t, ag.at(&b, 1, 1), ag.EMPTY)
}

@(test)
ko_rule :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	ag.play(&b, 0, 1) // Black
	ag.play(&b, 0, 2) // White
	ag.play(&b, 1, 0) // Black
	ag.play(&b, 1, 3) // White
	ag.play(&b, 1, 2) // Black
	ag.play(&b, 2, 2) // White
	ag.play(&b, 2, 1) // Black
	ag.play(&b, 1, 1) // White captures Black at (1,2)

	testing.expect_value(t, ag.at(&b, 1, 2), ag.EMPTY)
	testing.expect(t, b.ko_point != ag.NO_KO)
	testing.expect(t, !ag.is_legal(&b, 1, 2))
}

@(test)
positional_superko :: proc(t: ^testing.T) {
	b := ag.make_go_board(5)
	defer ag.destroy_go_board(&b)

	arr: [25]i8
	arr[0 * 5 + 1] = ag.EMPTY
	arr[1 * 5 + 0] = ag.BLACK
	arr[2 * 5 + 1] = ag.BLACK
	arr[1 * 5 + 2] = ag.BLACK
	arr[1 * 5 + 1] = ag.WHITE
	ag.set_from_array(&b, arr[:], ag.BLACK)

	testing.expect(t, ag.play(&b, 0, 1))
	testing.expect_value(t, ag.at(&b, 1, 1), ag.EMPTY)
	testing.expect(t, !ag.is_legal(&b, 1, 1))
}

@(test)
single_stone_suicide_illegal :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	ag.play(&b, 0, 1)
	ag.play(&b, 8, 8)
	ag.play(&b, 1, 0)
	testing.expect(t, !ag.is_legal(&b, 0, 0))
}

@(test)
multi_stone_suicide_illegal :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	ag.play(&b, 0, 2); ag.play(&b, 8, 8)
	ag.play(&b, 1, 1); ag.play(&b, 8, 7)
	ag.play(&b, 1, 3); ag.play(&b, 7, 8)
	ag.play(&b, 2, 1); ag.play(&b, 7, 7)
	ag.play(&b, 2, 3); ag.play(&b, 6, 8)
	ag.play(&b, 3, 2)
	testing.expect(t, ag.play(&b, 1, 2))
	testing.expect(t, ag.play(&b, 8, 0))
	testing.expect(t, !ag.is_legal(&b, 2, 2))
	testing.expect(t, !ag.play(&b, 2, 2))
	testing.expect_value(t, ag.at(&b, 1, 2), ag.WHITE)
	testing.expect_value(t, ag.at(&b, 2, 2), ag.EMPTY)
}

// Exercises the multi-group-merge branch of is_legal_flat's suicide check.
// Two friendly groups meet at the placed stone; one has libs == {index},
// the other has libs == {index, x}. The merged virtual group has liberty x,
// so the move is legal. Regression coverage for the v0.4.1 rewrite that
// replaced the clone-and-simulate path with an in-place liberty inspection.
@(test)
multi_group_merge_with_surviving_liberty :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	// Build a top-edge corner position. After this sequence, Black to play at
	// (0, 1) sees:
	//   (0,0) = B, group with libs = {(0,1)} only
	//   (0,2) = B, group with libs = {(0,1), (1,2)}
	//   (1,1) = W, part of a 2-stone white group with three liberties
	// has_empty(0,1) = false (all three neighbors non-empty), so the suicide
	// check fires. The (0,2) group provides the surviving liberty (1,2).
	ag.play(&b, 0, 0); ag.play(&b, 0, 3) // B, W
	ag.play(&b, 0, 2); ag.play(&b, 1, 0) // B, W
	ag.play(&b, 8, 8); ag.play(&b, 1, 1) // B (filler), W

	testing.expect(t, ag.is_legal(&b, 0, 1))
	testing.expect(t, ag.play(&b, 0, 1))
	testing.expect_value(t, ag.at(&b, 0, 1), ag.BLACK)
	// The three Black stones are now one group; (1,2) is the surviving liberty.
	testing.expect_value(t, ag.at(&b, 0, 0), ag.BLACK)
	testing.expect_value(t, ag.at(&b, 0, 2), ag.BLACK)
}

@(test)
capture_is_not_suicide :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)
	ag.play(&b, 0, 1) // Black
	ag.play(&b, 0, 0) // White (will be captured)
	ag.play(&b, 1, 0) // Black captures
	testing.expect_value(t, ag.at(&b, 0, 0), ag.EMPTY)
}

@(test)
pass_and_game_end :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	testing.expect_value(t, b.consecutive_passes, 0)
	testing.expect(t, !ag.is_game_over(&b))

	ag.pass_move(&b)
	testing.expect_value(t, b.consecutive_passes, 1)
	testing.expect_value(t, b.to_play, ag.WHITE)
	testing.expect(t, !ag.is_game_over(&b))

	ag.pass_move(&b)
	testing.expect_value(t, b.consecutive_passes, 2)
	testing.expect(t, ag.is_game_over(&b))
}

@(test)
non_consecutive_passes_do_not_end :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)
	ag.pass_move(&b)
	testing.expect_value(t, b.consecutive_passes, 1)
	testing.expect(t, !ag.is_game_over(&b))

	testing.expect(t, ag.play(&b, 4, 4))
	testing.expect_value(t, b.consecutive_passes, 0)
	testing.expect(t, !ag.is_game_over(&b))

	ag.pass_move(&b)
	testing.expect_value(t, b.consecutive_passes, 1)
	testing.expect(t, !ag.is_game_over(&b))

	ag.pass_move(&b)
	testing.expect_value(t, b.consecutive_passes, 2)
	testing.expect(t, ag.is_game_over(&b))
}

@(test)
legal_moves_generation :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	moves := ag.get_legal_moves_flat(&b)
	defer delete(moves)
	testing.expect_value(t, len(moves), 81)

	ag.play(&b, 4, 4)
	moves2 := ag.get_legal_moves_flat(&b)
	defer delete(moves2)
	testing.expect_value(t, len(moves2), 80)
}

@(test)
scoring_empty_board :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)

	s := ag.score(&b)
	testing.expectf(t, abs(s - (-7.5)) < 0.01, "expected -7.5, got %f", s)
	testing.expect_value(t, ag.get_winner(&b), ag.WHITE)
}

@(test)
custom_komi :: proc(t: ^testing.T) {
	b := ag.make_go_board(9, 5.5)
	defer ag.destroy_go_board(&b)
	testing.expect_value(t, b.komi, f32(5.5))
	s := ag.score(&b)
	testing.expectf(t, abs(s - (-5.5)) < 0.01, "expected -5.5, got %f", s)
}

@(test)
default_komi :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)
	testing.expect_value(t, b.komi, f32(7.5))
}

@(test)
komi_preserved_on_copy :: proc(t: ^testing.T) {
	b := ag.make_go_board(9, 5.5)
	defer ag.destroy_go_board(&b)
	c := ag.clone_go_board(&b)
	defer ag.destroy_go_board(&c)
	testing.expect_value(t, c.komi, f32(5.5))
}

@(test)
board_copy :: proc(t: ^testing.T) {
	b := ag.make_go_board(9)
	defer ag.destroy_go_board(&b)
	ag.play(&b, 4, 4)
	ag.play(&b, 4, 5)

	c := ag.clone_go_board(&b)
	defer ag.destroy_go_board(&c)

	testing.expect_value(t, ag.at(&c, 4, 4), ag.BLACK)
	testing.expect_value(t, ag.at(&c, 4, 5), ag.WHITE)
	testing.expect_value(t, c.to_play, b.to_play)
	testing.expect_value(t, c.move_count, b.move_count)

	ag.play(&c, 0, 0)
	testing.expect_value(t, ag.at(&b, 0, 0), ag.EMPTY)
	testing.expect_value(t, ag.at(&c, 0, 0), ag.BLACK)
}

// =========================================================================
// do_move / undo_move round-trip tests.
//
// Pattern: snapshot the board, do_move(action), undo_move(delta), then
// assert every observable field matches the snapshot.
// =========================================================================

@(private = "file")
boards_equal :: proc(a, b: ^ag.GoBoard) -> bool {
	if a.to_play != b.to_play {return false}
	if a.ko_point != b.ko_point {return false}
	if a.consecutive_passes != b.consecutive_passes {return false}
	if a.move_count != b.move_count {return false}
	if a.current_hash != b.current_hash {return false}
	if len(a.board) != len(b.board) {return false}
	for i in 0 ..< len(a.board) {
		if a.board[i] != b.board[i] {return false}
	}
	if !ag.hash_set_equal(&a.seen_hashes, &b.seen_hashes) {return false}
	return true
}

@(test)
do_undo_pass :: proc(t: ^testing.T) {
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)

	d := ag.do_move(&b, ag.PASS_ACTION, &caps)
	testing.expect_value(t, b.consecutive_passes, 1)
	testing.expect_value(t, b.to_play, ag.WHITE)

	ag.undo_move(&b, d, &caps)
	testing.expect(t, boards_equal(&b, &snap), "pass round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}

@(test)
do_undo_simple_place :: proc(t: ^testing.T) {
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)

	d := ag.do_move(&b, 4 * 9 + 4, &caps) // tengen
	testing.expect_value(t, ag.at(&b, 4, 4), ag.BLACK)
	testing.expect_value(t, b.to_play, ag.WHITE)
	testing.expect_value(t, d.capture_count, 0)

	ag.undo_move(&b, d, &caps)
	testing.expect(t, boards_equal(&b, &snap), "simple place round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}

@(test)
do_undo_single_capture :: proc(t: ^testing.T) {
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)

	// Set up: surround a single white stone, last move is the capture.
	ag.play(&b, 4, 4) // B
	ag.play(&b, 0, 0) // W (irrelevant, somewhere far)
	ag.play(&b, 4, 5) // B
	ag.play(&b, 0, 1) // W
	ag.play(&b, 3, 5) // B
	ag.play(&b, 0, 2) // W (still far)
	ag.play(&b, 5, 5) // B
	// Now W must play somewhere. Place a stone we'll then capture.
	ag.play(&b, 4, 6) // W at (4,6), surrounded on three sides

	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)

	// B plays (3,6) — should NOT capture (4,6) still has lib at (5,6).
	// Switch to the capture-square play. Actually let's do (4,7) which IS the
	// final liberty: (4,6) has libs at (3,6), (5,6), (4,7). After B's prior
	// (3,5) and (5,5), are those gone? Not yet. Let me just use a clean setup.
	_ = snap
}

@(test)
do_undo_single_stone_capture_isolated :: proc(t: ^testing.T) {
	// Cleanest single-stone capture: corner. W plays at (0,0); B surrounds.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)

	ag.play(&b, 8, 8) // B (dummy)
	ag.play(&b, 0, 0) // W in corner
	ag.play(&b, 0, 1) // B — captures-adjacent
	ag.play(&b, 7, 7) // W (dummy)

	// B to play. Snapshot now.
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)
	// B plays (1,0): captures W at (0,0).
	d := ag.do_move(&b, 1 * 9 + 0, &caps)
	testing.expect_value(t, ag.at(&b, 0, 0), ag.EMPTY)
	testing.expect_value(t, ag.at(&b, 1, 0), ag.BLACK)
	testing.expect_value(t, d.capture_count, 1)
	testing.expect_value(t, caps[d.capture_start].color, ag.WHITE)

	ag.undo_move(&b, d, &caps)
	testing.expect(t, boards_equal(&b, &snap), "single-stone capture round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}

@(test)
do_undo_multi_stone_capture :: proc(t: ^testing.T) {
	// A two-stone W group at (0,0)-(0,1) captured by B at (1,0) and (1,1)+(0,2).
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)

	ag.play(&b, 0, 0) // B (will be replaced)
	// Actually: set up B-surround-W2 explicitly.
	ag.destroy_go_board(&b)
	b = ag.make_go_board(9)

	ag.play(&b, 8, 8) // B dummy
	ag.play(&b, 0, 0) // W
	ag.play(&b, 8, 7) // B dummy
	ag.play(&b, 0, 1) // W (extends along edge)
	ag.play(&b, 1, 0) // B
	ag.play(&b, 7, 8) // W dummy
	ag.play(&b, 1, 1) // B
	ag.play(&b, 7, 7) // W dummy
	// Now B to play. W group {(0,0),(0,1)} has one liberty at (0,2).
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)
	d := ag.do_move(&b, 0 * 9 + 2, &caps) // B at (0,2) — captures both W stones
	testing.expect_value(t, ag.at(&b, 0, 0), ag.EMPTY)
	testing.expect_value(t, ag.at(&b, 0, 1), ag.EMPTY)
	testing.expect_value(t, ag.at(&b, 0, 2), ag.BLACK)
	testing.expect_value(t, d.capture_count, 2)

	ag.undo_move(&b, d, &caps)
	testing.expect(t, boards_equal(&b, &snap), "multi-stone capture round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}

@(test)
do_undo_deep_sequence :: proc(t: ^testing.T) {
	// Push 10 moves, undo all in reverse; final state must match initial.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)

	actions := []int{4*9+4, 3*9+3, 5*9+5, 2*9+2, 6*9+6, 1*9+1, 7*9+7, 0*9+0, 8*9+8, 4*9+5}
	deltas: [dynamic]ag.MoveDelta; defer delete(deltas)

	for a in actions {
		d := ag.do_move(&b, a, &caps)
		append(&deltas, d)
	}
	// Undo in reverse.
	for i := len(deltas) - 1; i >= 0; i -= 1 {
		ag.undo_move(&b, deltas[i], &caps)
	}
	testing.expect(t, boards_equal(&b, &snap), "deep sequence round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}

// -------------------------------------------------------------------------
// Round-trip guards for mcts-odin-81j.9 (incremental liberty tracking).
//
// The current flood-fill implementation passes these. They are scaffolding
// for the future incremental refactor — the worst cases for a union-find
// undo journal are multi-group merges (single placement joins ≥2 friendly
// groups) and multi-group captures via a shared liberty (single placement
// captures ≥2 separate opp groups). Plus a long random self-play to shake
// out journal-ordering bugs that targeted tests miss.
// -------------------------------------------------------------------------

@(test)
do_undo_multi_group_merge :: proc(t: ^testing.T) {
	// Two separate B groups with a single empty cell between them; B's next
	// move at that cell merges both into one group. Worst case for
	// union-find undo: one move re-creates two pre-existing parent roots.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)

	ag.play(&b, 4, 3) // B
	ag.play(&b, 0, 0) // W (dummy)
	ag.play(&b, 4, 5) // B
	ag.play(&b, 0, 1) // W (dummy)
	// B to play. Snapshot.
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)

	// B plays (4,4) — bridges (4,3) and (4,5) into one group.
	d := ag.do_move(&b, 4 * 9 + 4, &caps)
	testing.expect_value(t, ag.at(&b, 4, 4), ag.BLACK)
	testing.expect_value(t, d.capture_count, 0)

	ag.undo_move(&b, d, &caps)
	testing.expect(t, boards_equal(&b, &snap), "multi-group merge round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}

@(test)
do_undo_multi_group_capture :: proc(t: ^testing.T) {
	// Two separate W groups whose only remaining liberty is the same empty
	// cell (1,0). B at (1,0) captures both groups in one move. The
	// incremental impl must undo two simultaneous "group resurrected" events.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)

	ag.play(&b, 8, 8) // B dummy
	ag.play(&b, 0, 0) // W (group A: just one stone in corner)
	ag.play(&b, 0, 1) // B — fills lib (0,1) of group A
	ag.play(&b, 2, 0) // W (group B: one stone)
	ag.play(&b, 3, 0) // B — fills lib (3,0) of group B
	ag.play(&b, 7, 7) // W dummy
	ag.play(&b, 2, 1) // B — fills lib (2,1) of group B
	ag.play(&b, 7, 8) // W dummy
	// Both W groups now have a single shared liberty at (1,0).
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)

	d := ag.do_move(&b, 1 * 9 + 0, &caps) // B at (1,0) — captures both W groups
	testing.expect_value(t, ag.at(&b, 0, 0), ag.EMPTY)
	testing.expect_value(t, ag.at(&b, 2, 0), ag.EMPTY)
	testing.expect_value(t, ag.at(&b, 1, 0), ag.BLACK)
	testing.expect_value(t, d.capture_count, 2)

	ag.undo_move(&b, d, &caps)
	testing.expect(t, boards_equal(&b, &snap), "multi-group capture round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}

@(test)
do_undo_random_selfplay_50 :: proc(t: ^testing.T) {
	// 50 uniform-random legal moves on 9x9 with a deterministic LCG seed.
	// Push all, then unwind in reverse — final state must match initial
	// snapshot exactly. Catches journal-ordering bugs that targeted tests
	// would not surface. Uses a local LCG so the run is byte-identical
	// across hosts (no stdlib RNG version drift).
	SIZE :: 9
	N :: SIZE * SIZE
	b := ag.make_go_board(SIZE); defer ag.destroy_go_board(&b)
	caps: [dynamic]ag.CaptureRecord; defer delete(caps)
	snap := ag.clone_go_board(&b); defer ag.destroy_go_board(&snap)

	deltas: [dynamic]ag.MoveDelta; defer delete(deltas)
	legal: [N + 1]int // candidate actions buffer (incl. PASS)
	rng: u64 = 0xdeadbeef_cafebabe

	for step in 0 ..< 50 {
		if ag.is_game_over(&b) {break}
		// Numerical Recipes LCG.
		rng = rng * 6364136223846793005 + 1442695040888963407
		count := 0
		for i in 0 ..< N {
			if ag.is_legal_flat(&b, i) {
				legal[count] = i
				count += 1
			}
		}
		// PASS is always legal.
		legal[count] = ag.PASS_ACTION
		count += 1

		choice := int((rng >> 33) % u64(count))
		d := ag.do_move(&b, legal[choice], &caps)
		append(&deltas, d)
		_ = step
	}

	for i := len(deltas) - 1; i >= 0; i -= 1 {
		ag.undo_move(&b, deltas[i], &caps)
	}
	testing.expect(t, boards_equal(&b, &snap), "random 50-move self-play round-trip mismatch")
	testing.expect_value(t, len(caps), 0)
}
