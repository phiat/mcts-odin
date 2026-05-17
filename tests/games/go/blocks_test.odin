package go_tests

import "core:testing"
import ag "../../../games/go"

// =========================================================================
// BlockIndex tests — verifies the Phase 1 data structure for mcts-odin-81j.9
// builds correctly from flood-fill and survives clone. No hot-path
// integration yet; these are scaffolding tests for the future incremental
// implementation.
// =========================================================================

@(test)
block_index_empty_board :: proc(t: ^testing.T) {
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	bi := ag.block_index_make(81); defer ag.block_index_destroy(&bi)
	ag.block_index_rebuild(&bi, &b)

	testing.expect(t, ag.block_index_consistency_check(&b, &bi), "empty-board consistency")
}

@(test)
block_index_single_stone :: proc(t: ^testing.T) {
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	bi := ag.block_index_make(81); defer ag.block_index_destroy(&bi)

	ag.play(&b, 4, 4)
	ag.block_index_rebuild(&bi, &b)
	testing.expect(t, ag.block_index_consistency_check(&b, &bi), "single-stone consistency")
	testing.expect_value(t, ag.block_root(&bi, 4 * 9 + 4), u16(4 * 9 + 4))
}

@(test)
block_index_two_stone_chain :: proc(t: ^testing.T) {
	// B at (4,4) and (4,5) form one block.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	bi := ag.block_index_make(81); defer ag.block_index_destroy(&bi)

	ag.play(&b, 4, 4) // B
	ag.play(&b, 0, 0) // W
	ag.play(&b, 4, 5) // B
	ag.play(&b, 0, 1) // W
	ag.block_index_rebuild(&bi, &b)
	testing.expect(t, ag.block_index_consistency_check(&b, &bi), "two-stone chain consistency")
	r := ag.block_root(&bi, 4 * 9 + 4)
	testing.expect_value(t, ag.block_root(&bi, 4 * 9 + 5), r)
}

@(test)
block_index_separate_groups :: proc(t: ^testing.T) {
	// Two B groups that DO NOT touch.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	bi := ag.block_index_make(81); defer ag.block_index_destroy(&bi)

	ag.play(&b, 4, 3) // B
	ag.play(&b, 0, 0) // W
	ag.play(&b, 4, 5) // B (not adjacent to (4,3))
	ag.play(&b, 0, 1) // W
	ag.block_index_rebuild(&bi, &b)
	testing.expect(t, ag.block_index_consistency_check(&b, &bi), "separate groups consistency")
	testing.expect(t, ag.block_root(&bi, 4 * 9 + 3) != ag.block_root(&bi, 4 * 9 + 5))
}

@(test)
block_index_after_capture :: proc(t: ^testing.T) {
	// After a capture, the captured stone is EMPTY — block index should
	// reflect that, and surrounding blocks should have updated liberties.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	bi := ag.block_index_make(81); defer ag.block_index_destroy(&bi)

	ag.play(&b, 8, 8) // B (dummy)
	ag.play(&b, 0, 0) // W in corner
	ag.play(&b, 0, 1) // B
	ag.play(&b, 7, 7) // W dummy
	ag.play(&b, 1, 0) // B — captures W at (0,0)
	ag.block_index_rebuild(&bi, &b)
	testing.expect(t, ag.block_index_consistency_check(&b, &bi), "post-capture consistency")
	testing.expect_value(t, ag.block_root(&bi, 0), ag.NO_PARENT) // (0,0) now empty
}

@(test)
block_index_long_selfplay :: proc(t: ^testing.T) {
	// 30 moves, rebuild + check at each step. Catches off-by-one or
	// stale-state issues that single-position tests miss.
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	bi := ag.block_index_make(81); defer ag.block_index_destroy(&bi)

	rng: u64 = 0xfeedface_1337c0de
	for step in 0 ..< 30 {
		if ag.is_game_over(&b) {break}
		rng = rng * 6364136223846793005 + 1442695040888963407
		// Find any legal move.
		moves: [82]int
		count := 0
		for i in 0 ..< 81 {
			if ag.is_legal_flat(&b, i) {moves[count] = i; count += 1}
		}
		moves[count] = ag.PASS_ACTION; count += 1
		choice := int((rng >> 33) % u64(count))
		caps: [dynamic]ag.CaptureRecord; defer delete(caps)
		ag.do_move(&b, moves[choice], &caps)

		ag.block_index_rebuild(&bi, &b)
		ok := ag.block_index_consistency_check(&b, &bi)
		testing.expect(t, ok, "block index consistency after random move")
		if !ok {
			testing.expectf(t, false, "failed at step %d", step)
			break
		}
		_ = step
	}
}

@(test)
block_index_clone_roundtrip :: proc(t: ^testing.T) {
	b := ag.make_go_board(9); defer ag.destroy_go_board(&b)
	bi := ag.block_index_make(81); defer ag.block_index_destroy(&bi)

	ag.play(&b, 4, 4)
	ag.play(&b, 0, 0)
	ag.play(&b, 4, 5)
	ag.block_index_rebuild(&bi, &b)

	cloned := ag.block_index_clone(&bi); defer ag.block_index_destroy(&cloned)
	testing.expect(t, ag.block_index_consistency_check(&b, &cloned), "cloned index consistency")
}
