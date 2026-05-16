package main

import "core:fmt"
import "../mcts"
import ttt "../games/tictactoe"

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
	for i in 0 ..< n {out_actions[i] = tmp[i]; out_probs[i] = uniform}
	out_value^ = 0.5
	return n
}

print_board :: proc(state: rawptr) {
	s := cast(^ttt.State)state
	for r in 0 ..< 3 {
		for c in 0 ..< 3 {
			v := s.cells[r * 3 + c]
			ch := '.'
			if v == 0 {ch = 'X'} else if v == 1 {ch = 'O'}
			fmt.printf(" %c", ch)
		}
		fmt.println()
	}
	fmt.println()
}

main :: proc() {
	g := ttt.game()
	state := ttt.new_state()
	defer ttt.free_state(state)

	cfg := mcts.default_config()
	sims_per_move := 1000

	fmt.println("MCTS self-play — tic-tac-toe @", sims_per_move, "sims/move")
	fmt.println()
	print_board(state)

	for move := 1; !ttt.is_terminal(state); move += 1 {
		clone := ttt.clone_state(state)
		tree: mcts.Tree
		mcts.init(&tree, &g, clone, cfg, seed = u64(42 + move))
		mcts.run_simulations(&tree, sims_per_move, uniform_evaluator, &g)
		action := mcts.select_action(&tree, 0.0)
		root_q := mcts.get_root_q_value(&tree)
		mcts.destroy(&tree)

		who := "X" if ttt.current_player(state) == 0 else "O"
		fmt.printf("move %d (%s) -> cell %d, Q=%.3f\n", move, who, action, root_q)
		_ = ttt.do_move(state, action)
		print_board(state)
	}

	s := cast(^ttt.State)state
	if s.winner < 0 {
		fmt.println("result: draw")
	} else {
		winner := "X" if s.winner == 0 else "O"
		fmt.printf("result: %s wins\n", winner)
	}
}
