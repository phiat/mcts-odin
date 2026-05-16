package main

import "core:fmt"
import "core:math"
import "../mcts"
import ttt "../games/tictactoe"

// ============================================================================
// Neural-net evaluator skeleton — runnable template, no real model.
//
// This example shows the policy/value plumbing a real NN-backed evaluator
// needs, using a mocked "forward pass" so it builds and runs out of the box.
// The mock returns a flat-ish softmax over a logit vector and a fixed value;
// replace `mock_nn_forward` with your real model call (ONNX Runtime, Python
// FFI callback, TensorRT, libtorch, ...).
//
// Two patterns are shown:
//
//   sequential_nn_evaluator  — one forward per leaf, plugged into
//                              mcts.run_simulations. Use this when each
//                              forward is cheap (CPU model, small NN) and the
//                              latency cost of un-batched calls is fine.
//
//   batched_nn_evaluator     — N leaves descended with virtual loss, one
//                              forward over the whole batch. Use this when
//                              the forward is expensive (GPU NN) and you
//                              want to amortize launch overhead.
//
// The evaluator contract is in `mcts/playout.odin` (Evaluator) and
// `mcts/batched.odin` (Evaluator_Batched). The constraints worth repeating
// here:
//
//   1. Mask to legal actions. MCTS does not re-check legality before calling
//      do_move on the chosen slot. A nonzero prior for an illegal action
//      will be selected and produce undefined behaviour.
//
//   2. out_value is from the side-to-move's perspective. 1.0 = win for side
//      to move at this state. Networks trained AlphaZero-style usually
//      already emit this; if yours emits "value for player 0", flip it on
//      player 1.
//
//   3. user_data is opaque to MCTS — pass a pointer to whatever context your
//      forward needs (model handle, input/output buffers, the Game vtable).
// ============================================================================

POLICY_DIM :: 9 // tic-tac-toe: 9 cells.

// What your real evaluator probably wants in user_data: a model handle and
// some pre-allocated scratch buffers so the hot path doesn't allocate.
NN_Context :: struct {
	game:        ^mcts.Game,
	// model:      ^MyModelHandle,   // your ONNX / libtorch / Python handle
	// input_buf:  []f32,             // pre-allocated NCHW or similar
	// logits_buf: []f32,             // POLICY_DIM
}

// Stand-in for your real forward pass. Takes a state, writes `out_logits`
// (length POLICY_DIM, unmasked, raw NN output) and `out_value` (side-to-move
// perspective, [0, 1]).
//
// In practice this is where you encode `state` into your input tensor, run
// the model, and copy logits + value out. The mock just returns flat logits
// and a draw-ish value — you get the wiring without the model dependency.
mock_nn_forward :: proc(state: rawptr, out_logits: []f32, out_value: ^f32) {
	for i in 0 ..< POLICY_DIM {out_logits[i] = 0.0}
	out_value^ = 0.5
}

// Numerically stable softmax-with-legal-mask. Sets prob = 0 for illegal
// actions before normalising, so the prior distribution lives entirely on
// legal moves (constraint #1 above).
softmax_masked :: proc(logits: []f32, legal_mask: []bool, out_probs: []f32) {
	max_logit := f32(-1e30)
	for i in 0 ..< len(logits) {
		if !legal_mask[i] {continue}
		if logits[i] > max_logit {max_logit = logits[i]}
	}
	sum := f32(0)
	for i in 0 ..< len(logits) {
		if !legal_mask[i] {out_probs[i] = 0; continue}
		e := math.exp_f32(logits[i] - max_logit)
		out_probs[i] = e
		sum += e
	}
	if sum > 0 {
		inv := f32(1) / sum
		for i in 0 ..< len(logits) {out_probs[i] *= inv}
	}
}

// ----------------------------------------------------------------------------
// Sequential evaluator: one NN forward per leaf.
// ----------------------------------------------------------------------------
sequential_nn_evaluator :: proc(
	state:       rawptr,
	out_actions: []int,
	out_probs:   []f32,
	out_value:   ^f32,
	user_data:   rawptr,
) -> int {
	ctx := cast(^NN_Context)user_data

	legal := make([dynamic]int, 0, ctx.game.max_actions, context.temp_allocator)
	defer delete(legal)
	ctx.game.legal_actions(state, &legal)
	if len(legal) == 0 {out_value^ = 0.5; return 0}

	logits: [POLICY_DIM]f32
	mock_nn_forward(state, logits[:], out_value)

	mask: [POLICY_DIM]bool
	for a in legal {mask[a] = true}
	probs: [POLICY_DIM]f32
	softmax_masked(logits[:], mask[:], probs[:])

	n := 0
	for a in legal {
		out_actions[n] = a
		out_probs[n] = probs[a]
		n += 1
	}
	return n
}

// ----------------------------------------------------------------------------
// Batched evaluator: one NN forward over the whole batch.
//
// The MCTS core descends `batch_size` leaves with virtual loss, then calls
// this once with cloned snapshots of each leaf state. The evaluator fills
// out_counts[i] = number of (action, prob) pairs written into out_actions[i]
// and out_probs[i]; out_values[i] = value for state i.
// ----------------------------------------------------------------------------
batched_nn_evaluator :: proc(
	states:      []rawptr,
	out_actions: [][]int,
	out_probs:   [][]f32,
	out_counts:  []int,
	out_values:  []f32,
	user_data:   rawptr,
) {
	ctx := cast(^NN_Context)user_data

	// Real code would stack all states into a single (B, C, H, W) tensor and
	// do one forward. The mock just loops, but the per-state plumbing is
	// identical.
	for s, b in states {
		legal := make([dynamic]int, 0, ctx.game.max_actions, context.temp_allocator)
		defer delete(legal)
		ctx.game.legal_actions(s, &legal)
		if len(legal) == 0 {
			out_counts[b] = 0
			out_values[b] = 0.5
			continue
		}

		logits: [POLICY_DIM]f32
		mock_nn_forward(s, logits[:], &out_values[b])

		mask: [POLICY_DIM]bool
		for a in legal {mask[a] = true}
		probs: [POLICY_DIM]f32
		softmax_masked(logits[:], mask[:], probs[:])

		n := 0
		for a in legal {
			out_actions[b][n] = a
			out_probs[b][n] = probs[a]
			n += 1
		}
		out_counts[b] = n
	}
}

main :: proc() {
	g := ttt.game()
	ctx := NN_Context{game = &g}

	fmt.println("NN evaluator skeleton — tic-tac-toe, mocked forward pass")
	fmt.println()

	// --- Sequential path -----------------------------------------------------
	{
		state := ttt.new_state()
		defer ttt.free_state(state)
		cfg := mcts.default_config()
		tree: mcts.Tree
		mcts.init(&tree, &g, ttt.clone_state(state), cfg, seed = 1)
		defer mcts.destroy(&tree)
		mcts.run_simulations(&tree, 200, sequential_nn_evaluator, &ctx)
		action := mcts.select_action(&tree, 0.0)
		fmt.printf("sequential: root visits=%d, picked action=%d, Q=%.3f\n",
			mcts.get_root_visit_count(&tree),
			action,
			mcts.get_root_q_value(&tree))
	}

	// --- Batched path --------------------------------------------------------
	{
		state := ttt.new_state()
		defer ttt.free_state(state)
		cfg := mcts.default_config()
		tree: mcts.Tree
		mcts.init(&tree, &g, ttt.clone_state(state), cfg, seed = 2)
		defer mcts.destroy(&tree)
		mcts.run_simulations_batched(&tree, 200, 8, batched_nn_evaluator, &ctx)
		action := mcts.select_action(&tree, 0.0)
		fmt.printf("batched:    root visits=%d, picked action=%d, Q=%.3f\n",
			mcts.get_root_visit_count(&tree),
			action,
			mcts.get_root_q_value(&tree))
	}

	fmt.println()
	fmt.println("To plug in a real model: replace mock_nn_forward with your")
	fmt.println("forward-pass call. Everything around it (masking, softmax,")
	fmt.println("MCTS wiring) stays the same.")
}
