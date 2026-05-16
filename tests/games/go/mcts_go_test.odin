package go_tests

import "core:testing"
import "../../../mcts"
import go "../../../games/go"

// Uniform-policy, value=0.5 evaluator. Drains legal_actions from the game
// and assigns each action equal prior.
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
go_mcts_tree_init :: proc(t: ^testing.T) {
	g := go.game(9)
	state := go.new_state(9)
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)
	testing.expect_value(t, mcts.tree_size(&tree), 1)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 0)
}

@(test)
go_mcts_runs :: proc(t: ^testing.T) {
	g := go.game(9)
	state := go.new_state(9)
	cfg := mcts.default_config()
	tree: mcts.Tree
	mcts.init(&tree, &g, state, cfg, seed = 1)
	defer mcts.destroy(&tree)

	mcts.run_simulations(&tree, 50, uniform_evaluator, &g)
	testing.expect_value(t, mcts.get_root_visit_count(&tree), 50)
	testing.expect(t, mcts.tree_size(&tree) > 1)
}
