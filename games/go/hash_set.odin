package go_game

import "base:runtime"

// Open-addressing flat set for u64 keys (Zobrist hashes for PSK).
// Linear probing + backward-shift deletion (no tombstones). Replaces the
// per-board `map[u64]struct{}` whose general-purpose hashing and per-insert
// allocations were eating ~25% of bench wall on the 9x9 Go workload after
// 81j.8. Key probes are pure pointer arithmetic — Zobrist values come out of
// splitmix64 already well-mixed, so we use them directly modulo capacity.
//
// Sentinel: `HASH_SET_EMPTY = u64(max(u64))`. Empty slots hold this value.
// Real keys can theoretically collide with the sentinel at probability
// 2^-64; in practice this never happens in a single game. A debug-build
// assertion in `hash_set_add` catches it if it ever does.

HASH_SET_EMPTY :: u64(max(u64))

HASH_SET_INITIAL_CAP :: 16
HASH_SET_MAX_LOAD_NUM :: 3 // grow when count * 4 > cap * 3 (75% load)
HASH_SET_MAX_LOAD_DEN :: 4

HashSet :: struct {
	keys:      []u64,
	count:     int,
	allocator: runtime.Allocator,
}

@(require_results)
hash_set_make :: proc(initial_cap: int = HASH_SET_INITIAL_CAP, allocator := context.allocator) -> HashSet {
	cap := next_pow2(initial_cap)
	keys := make([]u64, cap, allocator)
	for i in 0 ..< cap {keys[i] = HASH_SET_EMPTY}
	return HashSet{keys = keys, count = 0, allocator = allocator}
}

hash_set_destroy :: proc(s: ^HashSet) {
	if s.keys != nil {
		delete(s.keys, s.allocator)
		s.keys = nil
	}
	s.count = 0
}

hash_set_clear :: proc(s: ^HashSet) {
	for i in 0 ..< len(s.keys) {s.keys[i] = HASH_SET_EMPTY}
	s.count = 0
}

hash_set_clone :: proc(src: ^HashSet, allocator := context.allocator) -> HashSet {
	cap := len(src.keys)
	keys := make([]u64, cap, allocator)
	copy(keys, src.keys)
	return HashSet{keys = keys, count = src.count, allocator = allocator}
}

@(require_results)
hash_set_contains :: #force_inline proc "contextless" (s: ^HashSet, key: u64) -> bool {
	if len(s.keys) == 0 {return false}
	mask := u64(len(s.keys) - 1)
	i := key & mask
	for {
		k := s.keys[i]
		if k == HASH_SET_EMPTY {return false}
		if k == key {return true}
		i = (i + 1) & mask
	}
}

// Insert key; no-op if already present. Returns true if newly inserted.
hash_set_add :: proc(s: ^HashSet, key: u64) -> bool {
	when ODIN_DEBUG {
		assert(key != HASH_SET_EMPTY, "hash_set: real key collided with sentinel u64(max) — astronomically improbable")
	}
	if len(s.keys) == 0 || (s.count + 1) * HASH_SET_MAX_LOAD_DEN > len(s.keys) * HASH_SET_MAX_LOAD_NUM {
		hash_set_grow(s)
	}
	mask := u64(len(s.keys) - 1)
	i := key & mask
	for {
		k := s.keys[i]
		if k == HASH_SET_EMPTY {
			s.keys[i] = key
			s.count += 1
			return true
		}
		if k == key {return false}
		i = (i + 1) & mask
	}
}

// Remove key. Backward-shift deletion: walk forward from the gap, pulling
// back any element whose ideal slot is at or before the gap.
hash_set_remove :: proc(s: ^HashSet, key: u64) -> bool {
	if len(s.keys) == 0 {return false}
	mask := u64(len(s.keys) - 1)
	i := key & mask
	for {
		k := s.keys[i]
		if k == HASH_SET_EMPTY {return false}
		if k == key {break}
		i = (i + 1) & mask
	}
	// i now points to the removed slot. Backward-shift to fill the hole.
	for {
		j := (i + 1) & mask
		kj := s.keys[j]
		if kj == HASH_SET_EMPTY {
			s.keys[i] = HASH_SET_EMPTY
			s.count -= 1
			return true
		}
		ideal := kj & mask
		// Element at j has ideal `ideal`. If the gap at `i` is on the path
		// from `ideal` to `j`, we can pull kj back to i without breaking
		// any probe chain. The check below holds for both wrap-around and
		// the simple case (treating the ring as a circle starting at ideal).
		if (j - ideal) & mask >= (j - i) & mask {
			s.keys[i] = kj
			i = j
		} else {
			s.keys[i] = HASH_SET_EMPTY
			s.count -= 1
			return true
		}
	}
}

@(require_results)
hash_set_len :: #force_inline proc "contextless" (s: ^HashSet) -> int {
	return s.count
}

@(private = "file")
hash_set_grow :: proc(s: ^HashSet) {
	old_keys := s.keys
	new_cap := max(HASH_SET_INITIAL_CAP, len(old_keys) * 2)
	new_keys := make([]u64, new_cap, s.allocator)
	for i in 0 ..< new_cap {new_keys[i] = HASH_SET_EMPTY}
	s.keys = new_keys
	s.count = 0
	for k in old_keys {
		if k != HASH_SET_EMPTY {hash_set_add(s, k)}
	}
	delete(old_keys, s.allocator)
}

@(private = "file")
next_pow2 :: proc "contextless" (n: int) -> int {
	if n <= 1 {return 1}
	v := u64(n - 1)
	v |= v >> 1
	v |= v >> 2
	v |= v >> 4
	v |= v >> 8
	v |= v >> 16
	v |= v >> 32
	return int(v + 1)
}

// Equality check for tests / debug. O(n) — walks one side, probes the other.
@(require_results)
hash_set_equal :: proc(a, b: ^HashSet) -> bool {
	if a.count != b.count {return false}
	for k in a.keys {
		if k == HASH_SET_EMPTY {continue}
		if !hash_set_contains(b, k) {return false}
	}
	return true
}
