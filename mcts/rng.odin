package mcts

import "core:math"
import "core:math/rand"

// Marsaglia & Tsang's gamma sampler. Recursive boost for alpha < 1 (sample
// G(alpha+1) and multiply by U^(1/alpha)). Uses context.random_generator —
// bind tree RNG via use_tree_rng before calling.
@(private)
gamma_sample :: proc(alpha: f32) -> f32 {
	if alpha < 1.0 {
		g := gamma_sample(alpha + 1.0)
		u := rand.float32()
		return g * math.pow(u, 1.0 / alpha)
	}
	d := alpha - 1.0 / 3.0
	c := 1.0 / math.sqrt(9.0 * d)
	for {
		x := rand.float32_normal(0, 1)
		v := 1.0 + c * x
		if v <= 0.0 {continue}
		v = v * v * v
		u := rand.float32()
		if u < 1.0 - 0.0331 * x * x * x * x {return d * v}
		if math.ln(u) < 0.5 * x * x + d * (1.0 - v + math.ln(v)) {return d * v}
	}
}

// Categorical sample over a packed (action, prob) list. Applies temperature
// rescaling in log-space when temperature != 1. Returns -1 if the list is empty
// (caller decides what to do; MCTS treats that as "evaluator gave no moves").
//
// `scratch_allocator` is used only when temperature != 1.0 (the rescale path
// needs an n-element f32 scratch). Pass t.scratch_allocator on the hot path.
@(private)
sample_packed_action :: proc(actions: []int, probs: []f32, temperature: f32, scratch_allocator := context.temp_allocator) -> int {
	n := len(actions)
	if n == 0 {return -1}

	work := make([]f32, n, scratch_allocator)
	defer delete(work, scratch_allocator)

	if temperature != 1.0 && temperature > 0 {
		max_logit := f32(min(f32))
		for k in 0 ..< n {
			work[k] = math.ln(probs[k] + 1e-8) / temperature
			if work[k] > max_logit {max_logit = work[k]}
		}
		sum := f32(0)
		for k in 0 ..< n {
			work[k] = math.exp(work[k] - max_logit)
			sum += work[k]
		}
		for k in 0 ..< n {work[k] /= sum}
	} else {
		for k in 0 ..< n {work[k] = probs[k]}
	}

	r := rand.float32()
	cum := f32(0)
	for k in 0 ..< n {
		cum += work[k]
		if r < cum {return actions[k]}
	}
	return actions[n - 1]
}

