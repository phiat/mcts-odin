package mcts

import "core:math"

// xoshiro256++ (Blackman & Vigna 2018). 4×u64 state, period 2^256-1, passes
// PractRand. Inlined `next_*` helpers replace `context.random_generator`
// indirection — each call is a handful of ALU ops with no function-call
// boundary. The MCTS hot paths (gamma_sample, sample_packed_action,
// fast_rollout) pass an explicit `^Xoshiro256pp` pointer.

Xoshiro256pp :: struct {
	s: [4]u64,
}

@(private)
splitmix64_step :: #force_inline proc "contextless" (seed: ^u64) -> u64 {
	seed^ += 0x9E3779B97F4A7C15
	z := seed^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private)
xoshiro_seed :: proc "contextless" (rng: ^Xoshiro256pp, seed: u64) {
	// Use splitmix64 to expand the 64-bit seed into 4×u64 state. Per the
	// xoshiro authors, splitmix64 is the recommended bootstrap.
	s := seed if seed != 0 else 0xC0FFEE_DECADE
	for i in 0 ..< 4 {rng.s[i] = splitmix64_step(&s)}
}

@(private)
rotl64 :: #force_inline proc "contextless" (x: u64, k: int) -> u64 {
	return (x << u64(k)) | (x >> u64(64 - k))
}

@(private)
xoshiro_next_u64 :: #force_inline proc "contextless" (rng: ^Xoshiro256pp) -> u64 {
	result := rotl64(rng.s[0] + rng.s[3], 23) + rng.s[0]
	t := rng.s[1] << 17
	rng.s[2] ~= rng.s[0]
	rng.s[3] ~= rng.s[1]
	rng.s[1] ~= rng.s[2]
	rng.s[0] ~= rng.s[3]
	rng.s[2] ~= t
	rng.s[3] = rotl64(rng.s[3], 45)
	return result
}

// f32 in [0, 1). Uses the top 24 bits of a u64 for the mantissa — that's the
// full f32 precision; the lower bits would just be discarded by the float
// cast.
@(private)
xoshiro_next_f32 :: #force_inline proc "contextless" (rng: ^Xoshiro256pp) -> f32 {
	return f32(xoshiro_next_u64(rng) >> 40) * (1.0 / 16777216.0)
}

// f64 in [0, 1). Top 53 bits → full f64 precision.
@(private)
xoshiro_next_f64 :: #force_inline proc "contextless" (rng: ^Xoshiro256pp) -> f64 {
	return f64(xoshiro_next_u64(rng) >> 11) * (1.0 / 9007199254740992.0)
}

// Polar Marsaglia normal sampler. Generates two N(0,1) samples per accept;
// we cache the second in `rng_n_cached` to amortise the rejection loop. The
// cache lives next to the RNG state so each Tree/Worker gets its own.
//
// Returns a single N(0,1) sample.
@(private)
NormalCache :: struct {
	value: f32,
	valid: bool,
}

@(private)
xoshiro_normal :: proc "contextless" (rng: ^Xoshiro256pp, cache: ^NormalCache) -> f32 {
	if cache.valid {
		cache.valid = false
		return cache.value
	}
	for {
		u := 2.0 * xoshiro_next_f32(rng) - 1.0
		v := 2.0 * xoshiro_next_f32(rng) - 1.0
		s := u * u + v * v
		if s >= 1.0 || s == 0.0 {continue}
		factor := math.sqrt(-2.0 * math.ln(s) / s)
		cache.value = v * factor
		cache.valid = true
		return u * factor
	}
}

// Marsaglia & Tsang's gamma sampler. Recursive boost for alpha < 1 (sample
// G(alpha+1) and multiply by U^(1/alpha)).
@(private)
gamma_sample :: proc(rng: ^Xoshiro256pp, cache: ^NormalCache, alpha: f32) -> f32 {
	if alpha < 1.0 {
		g := gamma_sample(rng, cache, alpha + 1.0)
		u := xoshiro_next_f32(rng)
		return g * math.pow(u, 1.0 / alpha)
	}
	d := alpha - 1.0 / 3.0
	c := 1.0 / math.sqrt(9.0 * d)
	for {
		x := xoshiro_normal(rng, cache)
		v := 1.0 + c * x
		if v <= 0.0 {continue}
		v = v * v * v
		u := xoshiro_next_f32(rng)
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
sample_packed_action :: proc(rng: ^Xoshiro256pp, actions: []int, probs: []f32, temperature: f32, scratch_allocator := context.temp_allocator) -> int {
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

	r := xoshiro_next_f32(rng)
	cum := f32(0)
	for k in 0 ..< n {
		cum += work[k]
		if r < cum {return actions[k]}
	}
	return actions[n - 1]
}
