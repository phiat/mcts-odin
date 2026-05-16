package amazons_tests

import "core:testing"
import az "../../../games/amazons"
import "../../../mcts"

// Document the vtable contract: terminal_value returns 0.5 on non-terminal
// states (the MCTS core relies on this — it only calls terminal_value after
// is_terminal returns true, but a misbehaving consumer that calls early
// should get the documented draw/non-terminal sentinel rather than UB).
@(test)
terminal_value_nonterminal_is_draw :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)
	testing.expect_value(t, az.is_terminal(state), false)
	testing.expect_value(t, az.terminal_value(state), f32(0.5))
}

@(test)
opening_position :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)
	s := cast(^az.State)state
	testing.expect_value(t, s.to_play, i32(0))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect_value(t, s.is_term, false)
	testing.expect_value(t, s.cells[0 * az.BOARD + 2], az.BLACK)
	testing.expect_value(t, s.cells[2 * az.BOARD + 0], az.BLACK)
	testing.expect_value(t, s.cells[5 * az.BOARD + 3], az.WHITE)
	testing.expect_value(t, s.cells[3 * az.BOARD + 5], az.WHITE)
}

@(test)
opening_legal_moves :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)
	legal := make([dynamic]int, 0, 4096, context.temp_allocator)
	defer delete(legal)
	az.legal_actions(state, &legal)
	testing.expect(t, len(legal) > 0, "opening must have legal moves")
}

@(test)
do_undo_round_trip :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)
	s := cast(^az.State)state
	before := s^

	legal := make([dynamic]int, 0, 4096, context.temp_allocator)
	defer delete(legal)
	az.legal_actions(state, &legal)
	testing.expect(t, len(legal) > 0)

	d := az.do_move(state, legal[0])
	testing.expect_value(t, s.move_count, i32(1))
	testing.expect_value(t, s.to_play, i32(1))

	az.undo_move(state, d)
	testing.expect_value(t, s^, before)
}

// Verify the arrow stays on the board and blocks future moves through it.
@(test)
arrow_blocks_cell :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)
	s := cast(^az.State)state

	legal := make([dynamic]int, 0, 4096, context.temp_allocator)
	defer delete(legal)
	az.legal_actions(state, &legal)

	az.do_move(state, legal[0])

	// Decode the action and check arrow cell.
	a := legal[0]
	arrow := a % az.N_CELLS
	testing.expect_value(t, s.cells[arrow], az.ARROW)
}

// Amazons rule: the arrow may be shot back to the from-square. Verify at
// least one legal action with from == arrow exists from the opening.
@(test)
arrow_can_return_to_origin :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)

	legal := make([dynamic]int, 0, 4096, context.temp_allocator)
	defer delete(legal)
	az.legal_actions(state, &legal)

	found := false
	for a in legal {
		from := a / (az.N_CELLS * az.N_CELLS)
		arrow := a % az.N_CELLS
		if from == arrow {
			found = true
			break
		}
	}
	testing.expect(t, found, "Amazons must allow arrow back to origin square")
}

@(test)
deep_do_undo_round_trip :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)
	s := cast(^az.State)state
	before := s^

	deltas: [dynamic]mcts.Move_Delta
	defer delete(deltas)

	for ply in 0 ..< 6 {
		legal := make([dynamic]int, 0, 4096, context.temp_allocator)
		az.legal_actions(state, &legal)
		if len(legal) == 0 {break}
		d := az.do_move(state, legal[ply % len(legal)])
		append(&deltas, d)
		delete(legal)
	}

	#reverse for d in deltas {az.undo_move(state, d)}
	testing.expect_value(t, s^, before)
}

// Deterministic self-play: pick legal[0] until terminal. Amazons must
// reach a terminal state with one winner.
@(test)
self_play_terminates :: proc(t: ^testing.T) {
	state := az.new_state()
	defer az.free_state(state)
	s := cast(^az.State)state

	moves := 0
	for !az.is_terminal(state) && moves < 200 {
		legal := make([dynamic]int, 0, 4096, context.temp_allocator)
		az.legal_actions(state, &legal)
		if len(legal) == 0 {break}
		az.do_move(state, legal[0])
		delete(legal)
		moves += 1
	}
	testing.expect(t, az.is_terminal(state))
	testing.expect(t, s.winner == 0 || s.winner == 1)

	// terminal_value at the terminal state is 0.0 from to_play's POV
	// (to_play is the loser, since they couldn't move).
	testing.expect_value(t, az.terminal_value(state), f32(0.0))
}

@(test)
mcts_runs :: proc(t: ^testing.T) {
	g := az.game()
	state := az.new_state()
	defer az.free_state(state)

	cfg := mcts.default_config()
	cfg.c_puct = 1.0

	tree: mcts.Tree
	mcts.init(&tree, &g, az.clone_state(state), cfg, seed = 7)
	defer mcts.destroy(&tree)

	uniform :: proc(
		state: rawptr,
		out_actions: []int,
		out_probs: []f32,
		out_value: ^f32,
		user_data: rawptr,
	) -> int {
		gg := cast(^mcts.Game)user_data
		tmp := make([dynamic]int, 0, 4096, context.temp_allocator)
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

	mcts.run_simulations(&tree, 50, uniform, &g)
	a := mcts.select_action(&tree, 0.0)
	testing.expect(t, a >= 0 && a < az.N_ACTIONS)
}

@(test)
mcts_self_play_terminates :: proc(t: ^testing.T) {
	g := az.game()
	state := az.new_state()
	defer az.free_state(state)

	uniform :: proc(
		state: rawptr,
		out_actions: []int,
		out_probs: []f32,
		out_value: ^f32,
		user_data: rawptr,
	) -> int {
		gg := cast(^mcts.Game)user_data
		tmp := make([dynamic]int, 0, 4096, context.temp_allocator)
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

	moves := 0
	for !g.is_terminal(state) && moves < 80 {
		clone := g.clone(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, mcts.default_config(), seed = u64(101 + moves))
		mcts.run_simulations(&tree, 30, uniform, &g)
		a := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)
		_ = g.do_move(state, a)
		moves += 1
	}
	testing.expect(t, g.is_terminal(state), "MCTS self-play must reach terminal state")
}
