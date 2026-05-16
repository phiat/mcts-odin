package mcts

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:sync"
import "core:thread"

// ============================================================================
// OS-thread parallel MCTS.
//
// N worker threads each run their own descent → eval → backup loop against
// the same shared Tree. Virtual loss decouples the descents so they don't all
// land on the same leaf; atomics on N / N_virt / Q + a coarse expand mutex
// around node creation keep the shared state consistent.
//
// Choose this over run_simulations / run_simulations_batched when the
// evaluator is expensive enough (a real NN forward pass, or any per-leaf
// work in the millisecond range) that the OS-thread cost is worth paying.
// For cheap evaluators the contention on the expand mutex and Q CAS-loops
// can erase the speedup or make it negative.
//
// Determinism: NOT deterministic across runs. Even with the same seed,
// thread interleavings change which leaf each worker reaches, so node visit
// counts and Q values diverge from run to run. Sequential
// `run_simulations` and the leaf-parallel `run_simulations_batched` remain
// deterministic. If you need reproducibility, don't use the threaded path.
//
// Evaluator contract: the supplied Evaluator is called concurrently from
// every worker thread. Its `user_data` and any state it touches must be
// thread-safe (most NN evaluators serialise on the model/GPU boundary; if
// yours doesn't, add the lock there).
// ============================================================================

// LLVM rejects cmpxchg / atomic loads on `float`, so the f32-valued Q running
// average is reinterpreted as the underlying u32 bit pattern for the duration
// of the atomic op. Reads in single-threaded paths still touch the f32 field
// directly — these helpers exist only on the threaded hot path.
@(private = "file")
atomic_q_load :: #force_inline proc "contextless" (p: ^f32) -> f32 {
	u := intrinsics.atomic_load((^u32)(p))
	return transmute(f32)u
}

@(private = "file")
atomic_q_cas :: #force_inline proc "contextless" (p: ^f32, old_v, new_v: f32) -> bool {
	old_u := transmute(u32)old_v
	new_u := transmute(u32)new_v
	_, ok := intrinsics.atomic_compare_exchange_strong((^u32)(p), old_u, new_u)
	return ok
}

@(private = "file")
Worker :: struct {
	tree:           ^Tree,
	working_state:  rawptr,         // per-worker clone of the root state
	scratch_arena:     virtual.Arena,
	scratch_allocator: runtime.Allocator,
	eval_a_buf:     []int,
	eval_p_buf:     []f32,
	rng_state:      Xoshiro256pp,
	rng_normal_cache: NormalCache,
	evaluator:      Evaluator,
	user_data:      rawptr,

	// Shared coordination (pointers into the driver's stack frame).
	sims_target:    int,            // total sims to perform
	sims_counter:   ^int,           // atomic claim counter; worker keeps doing while old < target
	expand_mutex:   ^sync.Mutex,    // protects t.nodes append + node.expanded transition + child[slot] := idx

	worker_id:      int,
}

// API stability: stable.
//
// Drives `num_simulations` PUCT playouts split across `n_threads` OS threads.
// All threads share the Tree; descents are decoupled by virtual loss; backups
// commit through atomics. The root is expanded sequentially (single-threaded
// prelude) before the workers spawn so all threads enter with an initialised
// root.
run_simulations_threaded :: proc(
	t:               ^Tree,
	num_simulations: int,
	n_threads:       int,
	evaluator:       Evaluator,
	user_data:       rawptr = nil,
) {
	free_all(t.scratch_allocator)
	n_sims := resolve_n_sims(t, num_simulations)

	// Single-threaded prelude: root expansion + Dirichlet noise. Done here so
	// all workers enter with the root fully ready, eliminating a startup race.
	if !t.nodes[t.root_idx].expanded && !t.nodes[t.root_idx].is_terminal {
		_ = expand_node(t, t.root_idx, evaluator, user_data)
	}
	maybe_add_root_dirichlet(t)

	if n_sims <= 0 {return}

	n := max(n_threads, 1)
	workers := make([]Worker, n, t.scratch_allocator)
	threads := make([]^thread.Thread, n, t.scratch_allocator)

	sims_counter := 0
	expand_mutex: sync.Mutex

	cap_n := t.game.max_actions
	base_seed := xoshiro_next_u64(&t.rng_state)

	for i in 0 ..< n {
		w := &workers[i]
		w.tree = t
		w.working_state = t.game.clone(t.working_state)
		_ = virtual.arena_init_growing(&w.scratch_arena, 1 << 20)
		w.scratch_allocator = virtual.arena_allocator(&w.scratch_arena)
		w.eval_a_buf = make([]int, cap_n, w.scratch_allocator)
		w.eval_p_buf = make([]f32, cap_n, w.scratch_allocator)
		xoshiro_seed(&w.rng_state, base_seed + u64(i) + 1)
		w.evaluator = evaluator
		w.user_data = user_data
		w.sims_target = n_sims
		w.sims_counter = &sims_counter
		w.expand_mutex = &expand_mutex
		w.worker_id = i

		threads[i] = thread.create_and_start_with_poly_data(w, worker_main)
	}

	for tr in threads {
		thread.join(tr)
		thread.destroy(tr)
	}

	// Tear down per-worker resources (scratch arenas + cloned states).
	for i in 0 ..< n {
		w := &workers[i]
		virtual.arena_destroy(&w.scratch_arena)
		if w.working_state != nil {t.game.free(w.working_state)}
	}
}

@(private = "file")
worker_main :: proc(w: ^Worker) {
	for {
		// Claim the next sim slot. atomic_add returns the old value, so
		// `mine` is unique across workers.
		mine := intrinsics.atomic_add(w.sims_counter, 1)
		if mine >= w.sims_target {break}
		// Free per-descent scratch (path + deltas) — keeps the arena bounded
		// to one descent's worth instead of growing for the full sim count.
		free_all(w.scratch_allocator)
		// Re-make the eval buffers — free_all just invalidated them.
		w.eval_a_buf = make([]int, w.tree.game.max_actions, w.scratch_allocator)
		w.eval_p_buf = make([]f32, w.tree.game.max_actions, w.scratch_allocator)
		worker_do_one_sim(w)
	}
}

@(private = "file")
worker_do_one_sim :: proc(w: ^Worker) {
	t := w.tree
	path := make([dynamic]int, 0, 8, w.scratch_allocator)
	deltas := make([dynamic]Move_Delta, 0, 8, w.scratch_allocator)

	append(&path, t.root_idx)
	current := t.root_idx
	// Eagerly bump root's N_virt so concurrent workers see it.
	intrinsics.atomic_add(&t.node_N_virt[current], 1)

	U: f32
	is_terminal_leaf := false
	descend_loop: for {
		if t.nodes[current].is_terminal {
			U = terminal_value_for_node(t, current)
			is_terminal_leaf = true
			break descend_loop
		}
		// Acquire-load: ensures we see actions/priors/child writes that
		// happened-before the matching atomic_store(expanded, true).
		expanded := intrinsics.atomic_load(&t.nodes[current].expanded)
		if !expanded {
			break descend_loop
		}

		slot := select_slot_puct_vloss_threaded(t, current)
		action := t.nodes[current].actions[slot]
		cp_parent := t.nodes[current].cp_at_node

		delta := t.game.do_move(w.working_state, action)
		append(&deltas, delta)

		// Look up the child slot. May be -1 (no child yet) — handle under lock.
		child_idx := t.nodes[current].child[slot]
		if child_idx < 0 {
			sync.lock(w.expand_mutex)
			// Re-check: another worker may have created the child while we waited.
			child_idx = t.nodes[current].child[slot]
			if child_idx < 0 {
				child_idx = create_node(t, w.working_state, current, action, cp_parent)
				// Publish via plain store. Other workers reading without the
				// lock may see -1 (rare) or the new idx — both safe; -1 just
				// means they'll fall into the same lock-and-create path and
				// re-check under the mutex.
				t.nodes[current].child[slot] = child_idx
			}
			sync.unlock(w.expand_mutex)
		}

		append(&path, child_idx)
		intrinsics.atomic_add(&t.node_N_virt[child_idx], 1)
		current = child_idx
	}

	if !is_terminal_leaf {
		// Evaluator runs OUTSIDE the expand mutex — this is the whole point
		// of OS-thread parallelism. Each worker calls evaluator concurrently.
		v_theta: f32
		n_priors := w.evaluator(w.working_state, w.eval_a_buf, w.eval_p_buf, &v_theta, w.user_data)

		// Convert v_theta to player_at_parent's frame (matches sequential).
		cp_leaf := t.nodes[current].cp_at_node
		persp := t.nodes[current].player_at_parent
		if cp_leaf != persp {v_theta = 1.0 - v_theta}
		U = v_theta

		// Now expand under the mutex if we're the winner of the race.
		sync.lock(w.expand_mutex)
		if !intrinsics.atomic_load(&t.nodes[current].expanded) {
			actions := make([]int, n_priors, t.allocator)
			priors  := make([]f32, n_priors, t.allocator)
			child   := make([]int, n_priors, t.allocator)
			for k in 0 ..< n_priors {
				actions[k] = w.eval_a_buf[k]
				priors[k]  = w.eval_p_buf[k]
				child[k]   = -1
			}
			t.nodes[current].actions = actions
			t.nodes[current].priors  = priors
			t.nodes[current].child   = child
			if !t.nodes[current].has_eval {
				t.nodes[current].first_eval_value = U
				t.nodes[current].has_eval = true
			}
			// Release-store: publishes the slice writes above.
			intrinsics.atomic_store(&t.nodes[current].expanded, true)
		}
		sync.unlock(w.expand_mutex)
	}

	// Unwind working_state and back up along the path.
	#reverse for d in deltas {t.game.undo_move(w.working_state, d)}

	#reverse for idx in path {
		// Decrement virtual loss eagerly, increment real visit, update Q.
		intrinsics.atomic_sub(&t.node_N_virt[idx], 1)
		new_n := intrinsics.atomic_add(&t.node_N[idx], 1) + 1
		// CAS-loop on Q running average. new_n is unique to this worker so
		// the divisor is correct; the CAS handles concurrent updates of Q.
		for {
			q_old := atomic_q_load(&t.node_Q[idx])
			q_new := q_old + (U - q_old) / f32(new_n)
			if atomic_q_cas(&t.node_Q[idx], q_old, q_new) {break}
		}
		U = 1.0 - U
	}
}

// Threaded PUCT scan. Identical math to select_slot_puct_vloss but reads N /
// N_virt / Q through atomic loads to avoid torn reads under concurrent
// updates. Hot enough that we keep the same branchless-argmax shape.
@(private = "file")
select_slot_puct_vloss_threaded :: proc(t: ^Tree, node_idx: int) -> int {
	node := &t.nodes[node_idx]

	total_visits := 0
	sum_visited_priors := f32(0)
	for k in 0 ..< len(node.actions) {
		ci := node.child[k]
		if ci >= 0 {
			total_visits += intrinsics.atomic_load(&t.node_N[ci]) + intrinsics.atomic_load(&t.node_N_virt[ci])
			sum_visited_priors += node.priors[k]
		}
	}
	sqrt_total := math.sqrt(f32(total_visits) + 1.0)

	parent_Q_self := 1.0 - atomic_q_load(&t.node_Q[node_idx])
	fpu_q := parent_Q_self - t.config.fpu_reduction * math.sqrt(sum_visited_priors)

	best_slot := 0
	best_score := f32(min(f32))
	c_puct := t.config.c_puct
	for k in 0 ..< len(node.actions) {
		prior := node.priors[k]
		ci := node.child[k]
		has_child := ci >= 0
		safe_ci := ci if has_child else 0
		q  := atomic_q_load(&t.node_Q[safe_ci])      if has_child else fpu_q
		n  := intrinsics.atomic_load(&t.node_N[safe_ci])      if has_child else 0
		nv := intrinsics.atomic_load(&t.node_N_virt[safe_ci]) if has_child else 0
		n_eff := f32(n + nv)
		q_eff := (q * f32(n)) / n_eff if n_eff > 0 else fpu_q
		u := c_puct * prior * sqrt_total / (1.0 + n_eff)
		score := q_eff + u
		is_better := score > best_score
		best_score = score if is_better else best_score
		best_slot  = k     if is_better else best_slot
	}
	return best_slot
}
