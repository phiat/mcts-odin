package dots_and_boxes_tests

import "core:testing"
import db "../../../games/dots_and_boxes"
import "../../../mcts"

@(test)
opening_position :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state
	testing.expect_value(t, s.to_play, i32(0))
	testing.expect_value(t, s.winner, i32(-1))
	testing.expect_value(t, s.edges_drawn, i32(0))
	testing.expect_value(t, s.score[0], i32(0))
	testing.expect_value(t, s.score[1], i32(0))
}

@(test)
opening_legal_moves :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	legal := make([dynamic]int, 0, 32, context.temp_allocator)
	defer delete(legal)
	db.legal_actions(state, &legal)
	testing.expect_value(t, len(legal), 24)
}

@(test)
do_undo_round_trip :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state
	before := s^

	// Draw the top edge of box (0, 0) — horizontal h(0, 0), action 0.
	d := db.do_move(state, 0)
	testing.expect_value(t, s.edges_h[0][0], i8(1))
	testing.expect_value(t, s.edges_drawn, i32(1))
	testing.expect_value(t, s.to_play, i32(1)) // turn passed; no box closed

	db.undo_move(state, d)
	testing.expect_value(t, s^, before)
}

// Three edges around box (0,0) do not close it. The fourth — drawn by player 0
// — closes the box and gives player 0 an extra turn.
@(test)
extra_turn_on_box_close :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state

	// Box (0,0) edges: top=h(0,0)=action 0, bottom=h(1,0)=action 3,
	//                  left=v(0,0)=action 12, right=v(0,1)=action 13.
	// Three non-closing moves drawn by alternating players.
	db.do_move(state, 0)  // P0 → P1
	testing.expect_value(t, s.to_play, i32(1))
	db.do_move(state, 3)  // P1 → P0
	testing.expect_value(t, s.to_play, i32(0))
	db.do_move(state, 12) // P0 → P1
	testing.expect_value(t, s.to_play, i32(1))

	// Player 1 closes box (0,0) with the right edge → keeps the turn.
	db.do_move(state, 13)
	testing.expect_value(t, s.to_play, i32(1))
	testing.expect_value(t, s.score[1], i32(1))
	testing.expect_value(t, s.boxes[0][0], i8(1))
}

// A single edge can close TWO boxes when both sides are already at three edges.
@(test)
double_box_close_one_move :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state

	// Goal: close boxes (0,0) and (0,1) simultaneously by drawing the
	// shared vertical edge v(0,1) (= action 13).
	//
	// Box (0,0) needs 3 edges: top h(0,0), bottom h(1,0), left v(0,0)
	// Box (0,1) needs 3 edges: top h(0,1), bottom h(1,1), right v(0,2)
	//
	// Action encodings:
	//   h(0,0)=0, h(1,0)=3, h(0,1)=1, h(1,1)=4, v(0,0)=12, v(0,2)=14
	//   shared edge v(0,1)=13
	//
	// We don't care about turn order or who closes — for this test, do the
	// six setup moves in any sequence that's legal (none of them close a
	// box, so turns alternate).
	db.do_move(state, 0)
	db.do_move(state, 3)
	db.do_move(state, 12)
	db.do_move(state, 1)
	db.do_move(state, 4)
	db.do_move(state, 14)
	prev_to_play := s.to_play

	// Sanity: neither box closed yet.
	testing.expect_value(t, s.boxes[0][0], i8(-1))
	testing.expect_value(t, s.boxes[0][1], i8(-1))

	// The closing edge.
	db.do_move(state, 13)
	testing.expect_value(t, s.boxes[0][0], i8(prev_to_play))
	testing.expect_value(t, s.boxes[0][1], i8(prev_to_play))
	testing.expect_value(t, s.score[prev_to_play], i32(2))
	testing.expect_value(t, s.to_play, prev_to_play) // extra turn on close
}

@(test)
double_close_do_undo :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state

	db.do_move(state, 0)
	db.do_move(state, 3)
	db.do_move(state, 12)
	db.do_move(state, 1)
	db.do_move(state, 4)
	db.do_move(state, 14)
	before := s^

	d := db.do_move(state, 13)
	db.undo_move(state, d)
	testing.expect_value(t, s^, before)
}

@(test)
illegal_redraw_rejected :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state

	db.do_move(state, 0)
	legal := make([dynamic]int, 0, 32, context.temp_allocator)
	defer delete(legal)
	db.legal_actions(state, &legal)
	testing.expect_value(t, len(legal), 23)
	for a in legal {testing.expect(t, a != 0)}
	_ = s
}

// Random legal play to completion; verify all 24 edges drawn and exactly
// 9 boxes claimed in total. No ties on 9-box boards.
@(test)
self_play_terminates :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state

	// Deterministic order: just iterate 0..24 and play whichever is still legal.
	for a in 0 ..< 24 {
		if !db.is_terminal(state) {db.do_move(state, a)}
	}
	testing.expect(t, db.is_terminal(state))
	testing.expect_value(t, s.edges_drawn, i32(24))
	testing.expect_value(t, s.score[0] + s.score[1], i32(9))
	testing.expect(t, s.winner == 0 || s.winner == 1)
}

@(test)
deep_do_undo_round_trip :: proc(t: ^testing.T) {
	state := db.new_state()
	defer db.free_state(state)
	s := cast(^db.State)state
	before := s^

	deltas: [dynamic]mcts.Move_Delta
	defer delete(deltas)

	// Play 12 edges in order.
	for a in 0 ..< 12 {
		d := db.do_move(state, a)
		append(&deltas, d)
	}

	// Unwind.
	#reverse for d in deltas {db.undo_move(state, d)}
	testing.expect_value(t, s^, before)
}

@(test)
mcts_runs :: proc(t: ^testing.T) {
	g := db.game()
	state := db.new_state()
	defer db.free_state(state)

	cfg := mcts.default_config()
	cfg.c_puct = 1.0

	tree: mcts.Tree
	mcts.init(&tree, &g, db.clone_state(state), cfg, seed = 7)
	defer mcts.destroy(&tree)

	uniform :: proc(
		state: rawptr,
		out_actions: []int,
		out_probs: []f32,
		out_value: ^f32,
		user_data: rawptr,
	) -> int {
		gg := cast(^mcts.Game)user_data
		tmp := make([dynamic]int, 0, gg.max_actions, context.temp_allocator)
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

	mcts.run_simulations(&tree, 200, uniform, &g)
	a := mcts.select_action(&tree, 0.0)
	testing.expect(t, a >= 0 && a < 24)
}

// Stress: MCTS self-play to completion. The interesting MCTS-side thing
// being tested here is that the core handles same-player back-to-back
// moves correctly when descents hit boxes-closed states.
@(test)
mcts_self_play_terminates :: proc(t: ^testing.T) {
	g := db.game()
	state := db.new_state()
	defer db.free_state(state)

	uniform :: proc(
		state: rawptr,
		out_actions: []int,
		out_probs: []f32,
		out_value: ^f32,
		user_data: rawptr,
	) -> int {
		gg := cast(^mcts.Game)user_data
		tmp := make([dynamic]int, 0, gg.max_actions, context.temp_allocator)
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
	for !g.is_terminal(state) {
		clone := g.clone(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, mcts.default_config(), seed = u64(101 + moves))
		mcts.run_simulations(&tree, 100, uniform, &g)
		a := mcts.select_action(&tree, 0.0)
		mcts.destroy(&tree)
		_ = g.do_move(state, a)
		moves += 1
		testing.expect(t, moves < 100, "self-play should terminate well within 24 edges + extra-turn moves")
	}
	testing.expect(t, g.is_terminal(state))
}
