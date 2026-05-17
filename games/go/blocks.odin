package go_game

// Per-block (stone group) index used to replace flood-fill in the Go hot path.
// See mcts-odin-81j.9.
//
// PHASE 1 (this file): data structures + builders + consistency check vs.
// flood-fill. Not yet wired into GoBoard or the do_move / is_legal_flat hot
// path. Phase 2 attaches a BlockIndex to GoBoard; Phase 3 maintains it
// incrementally with a journal so do_move / undo_move stay reversible.
//
// Invariants (when valid):
//   - parent[i]     = root cell of i's block, OR NO_PARENT if b.board[i] == EMPTY
//   - parent[r]     = r when r is a root
//   - block_next[r] = circular linked list of cells in block r (starts at r,
//                     returns to r)
//   - blk_libs[r]   = bitset of empty cells adjacent to any stone in block r
//   - blk_size[r]   = number of stones in block r
//
// For non-root cells: blk_libs[i] and blk_size[i] are stale / undefined.
// For EMPTY cells: parent[i] = NO_PARENT, block_next[i] = i (self-loop), and
// blk_libs[i] / blk_size[i] are unused.

import "core:slice"
import "base:runtime"

// Compile-time bitset width. With BOARD_SIZE_HINT, fold to the minimum needed
// (2 words = 128 bits for 9x9). Without the hint, size for 19x19 worst case
// (6 words = 384 bits). This trades a few KB of board footprint for branchless,
// statically-sized bitset ops in the hot path.
when BOARD_SIZE_HINT > 0 {
	BITSET_WORDS :: (BOARD_SIZE_HINT * BOARD_SIZE_HINT + 63) / 64
} else {
	BITSET_WORDS :: (19 * 19 + 63) / 64
}

LibBitset :: [BITSET_WORDS]u64

NO_PARENT :: u16(0xFFFF)

BlockIndex :: struct {
	parent:     []u16,
	block_next: []u16,
	blk_libs:   []LibBitset,
	blk_size:   []u16,
	allocator:  runtime.Allocator,
}

// Journal entries for do_move → undo_move reversibility. Pushed by do_move,
// popped in reverse by undo_move. Live as four [dynamic]'s on GoBoard so
// they survive across MCTS descents (push during descent, pop during backup;
// net stable capacity after warmup, same lifecycle as b.captures).
JournalParent :: struct {cell: u16, prev: u16}
JournalNext   :: struct {cell: u16, prev: u16}
JournalLibs   :: struct {root: u16, prev: LibBitset}
JournalSize   :: struct {root: u16, prev: u16}

// ---------------------------------------------------------------------------
// Bitset helpers. Inlined; codegen folds the loop when BITSET_WORDS is small.
// ---------------------------------------------------------------------------

@(private)
libset_set :: #force_inline proc "contextless" (s: ^LibBitset, bit: int) {
	s[bit >> 6] |= u64(1) << u64(bit & 63)
}

@(private)
libset_clear :: #force_inline proc "contextless" (s: ^LibBitset, bit: int) {
	s[bit >> 6] &~= u64(1) << u64(bit & 63)
}

@(private)
libset_test :: #force_inline proc "contextless" (s: ^LibBitset, bit: int) -> bool {
	return (s[bit >> 6] & (u64(1) << u64(bit & 63))) != 0
}

@(private)
libset_zero :: #force_inline proc "contextless" (s: ^LibBitset) {
	for w in 0 ..< BITSET_WORDS {s[w] = 0}
}

@(private)
libset_is_zero :: #force_inline proc "contextless" (s: ^LibBitset) -> bool {
	for w in 0 ..< BITSET_WORDS {
		if s[w] != 0 {return false}
	}
	return true
}

@(private)
libset_popcount :: #force_inline proc "contextless" (s: ^LibBitset) -> int {
	total := 0
	for w in 0 ..< BITSET_WORDS {
		x := s[w]
		x = x - ((x >> 1) & 0x5555555555555555)
		x = (x & 0x3333333333333333) + ((x >> 2) & 0x3333333333333333)
		x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0F
		total += int((x * 0x0101010101010101) >> 56)
	}
	return total
}

@(private)
libset_or :: #force_inline proc "contextless" (dst: ^LibBitset, src: ^LibBitset) {
	for w in 0 ..< BITSET_WORDS {dst[w] |= src[w]}
}

@(private)
libset_equal :: #force_inline proc "contextless" (a, b: ^LibBitset) -> bool {
	for w in 0 ..< BITSET_WORDS {
		if a[w] != b[w] {return false}
	}
	return true
}

// ---------------------------------------------------------------------------
// BlockIndex lifecycle.
// ---------------------------------------------------------------------------

block_index_make :: proc(n_cells: int, allocator := context.allocator) -> BlockIndex {
	context.allocator = allocator
	bi := BlockIndex {
		parent     = make([]u16, n_cells),
		block_next = make([]u16, n_cells),
		blk_libs   = make([]LibBitset, n_cells),
		blk_size   = make([]u16, n_cells),
		allocator  = allocator,
	}
	// Empty board state: every cell self-links, no parent.
	for i in 0 ..< n_cells {
		bi.parent[i] = NO_PARENT
		bi.block_next[i] = u16(i)
	}
	return bi
}

block_index_destroy :: proc(bi: ^BlockIndex) {
	delete(bi.parent, bi.allocator)
	delete(bi.block_next, bi.allocator)
	delete(bi.blk_libs, bi.allocator)
	delete(bi.blk_size, bi.allocator)
	bi^ = {}
}

block_index_clone :: proc(src: ^BlockIndex, allocator := context.allocator) -> BlockIndex {
	context.allocator = allocator
	return BlockIndex {
		parent     = slice.clone(src.parent),
		block_next = slice.clone(src.block_next),
		blk_libs   = slice.clone(src.blk_libs),
		blk_size   = slice.clone(src.blk_size),
		allocator  = allocator,
	}
}

// ---------------------------------------------------------------------------
// Read-side helpers.
// ---------------------------------------------------------------------------

// Root cell of `cell`'s block. parent[] points directly at the root, so this
// is O(1). When the cell is EMPTY, returns NO_PARENT.
block_root :: #force_inline proc "contextless" (bi: ^BlockIndex, cell: int) -> u16 {
	return bi.parent[cell]
}

// ---------------------------------------------------------------------------
// Build from a board state via flood-fill. Used to seed the index from a
// `GoBoard` whose blocks are not yet tracked (initial state, set_from_array,
// or the eventual cut-over from the old flood-fill hot path). Allocates
// nothing beyond temp_allocator scratch.
// ---------------------------------------------------------------------------

block_index_rebuild :: proc(bi: ^BlockIndex, b: ^GoBoard) {
	n := n_cells(b)
	// Reset to empty-board baseline.
	for i in 0 ..< n {
		bi.parent[i] = NO_PARENT
		bi.block_next[i] = u16(i)
		libset_zero(&bi.blk_libs[i])
		bi.blk_size[i] = 0
	}
	visited := make([]bool, n, context.temp_allocator)
	defer delete(visited, context.temp_allocator)
	stack := make([dynamic]int, 0, 16, context.temp_allocator)
	defer delete(stack)

	for start in 0 ..< n {
		if visited[start] {continue}
		if b.board[start] == EMPTY {continue}
		color := b.board[start]
		// Flood-fill block + collect its liberties.
		clear(&stack)
		append(&stack, start)
		visited[start] = true
		// The root is the smallest cell index in the block (deterministic,
		// matches the union-by-keep-smaller policy planned for Phase 3).
		root := start
		members := make([dynamic]int, 0, 16, context.temp_allocator)
		defer delete(members)
		append(&members, start)
		libs: LibBitset
		libset_zero(&libs)

		for len(stack) > 0 {
			cur := pop(&stack)
			nb := b.tables.neighbors[cur]
			for k in 0 ..< nb.count {
				ni := nb.indices[k]
				v := b.board[ni]
				if v == EMPTY {
					libset_set(&libs, ni)
				} else if v == color && !visited[ni] {
					visited[ni] = true
					append(&members, ni)
					append(&stack, ni)
					if ni < root {root = ni}
				}
			}
		}

		// Wire up parent + block_next as a circular linked list anchored at root.
		// Membership list order is arbitrary; we just thread it as we go.
		for i, idx in members {
			bi.parent[i] = u16(root)
			if idx + 1 < len(members) {
				bi.block_next[i] = u16(members[idx + 1])
			} else {
				bi.block_next[i] = u16(members[0])
			}
		}
		bi.blk_libs[root] = libs
		bi.blk_size[root] = u16(len(members))
	}
}

// ---------------------------------------------------------------------------
// Consistency check: rebuilds a fresh BlockIndex from `b` via flood-fill and
// compares observable per-cell + per-root fields with `bi`. Used in tests +
// future debug-build assertions. Allocates the comparison index on
// temp_allocator.
// ---------------------------------------------------------------------------

block_index_consistency_check :: proc(b: ^GoBoard, bi: ^BlockIndex) -> bool {
	n := n_cells(b)
	gold := block_index_make(n, context.temp_allocator)
	defer block_index_destroy(&gold)
	block_index_rebuild(&gold, b)

	// Compare per-cell parent + same-block partition. We don't require the
	// SAME root cell as gold (Phase 3 union-find may pick a different root for
	// the same partition), only that the partition itself matches.
	for i in 0 ..< n {
		gp := gold.parent[i]
		bp := bi.parent[i]
		// Both EMPTY ⇔ NO_PARENT.
		if (gp == NO_PARENT) != (bp == NO_PARENT) {return false}
		if gp == NO_PARENT {continue}
		// Same partition: for every j with gold.parent[j] == gp, we must have
		// bi.parent[j] == bp, and vice versa.
		for j in 0 ..< n {
			same_in_gold := gold.parent[j] == gp
			same_in_bi := bi.parent[j] == bp
			if same_in_gold != same_in_bi {return false}
		}
	}

	// Compare per-root blk_libs + blk_size. Roots may differ between gold and
	// bi (see above); we walk gold's roots and find the corresponding bi root
	// via bi.parent[gold_root].
	for i in 0 ..< n {
		if gold.parent[i] != u16(i) {continue} // not a gold root
		bi_root := int(bi.parent[i])
		if !libset_equal(&gold.blk_libs[i], &bi.blk_libs[bi_root]) {return false}
		if gold.blk_size[i] != bi.blk_size[bi_root] {return false}
	}

	// Block_next must form a closed cycle covering exactly the block's cells.
	// Walk each gold block and verify bi's traversal hits the same set.
	for i in 0 ..< n {
		if gold.parent[i] != u16(i) {continue}
		// Collect gold members.
		gold_members: map[int]bool
		gold_members = make(map[int]bool, allocator = context.temp_allocator)
		defer delete(gold_members)
		cur := int(i)
		for {
			gold_members[cur] = true
			cur = int(gold.block_next[cur])
			if cur == int(i) {break}
		}
		// Walk bi's cycle starting at any cell in this partition (use i).
		bi_members: map[int]bool
		bi_members = make(map[int]bool, allocator = context.temp_allocator)
		defer delete(bi_members)
		cur = int(i)
		steps := 0
		for {
			bi_members[cur] = true
			cur = int(bi.block_next[cur])
			steps += 1
			if cur == int(i) {break}
			if steps > n {return false} // not a closed cycle
		}
		if len(gold_members) != len(bi_members) {return false}
		for k in gold_members {
			if k not_in bi_members {return false}
		}
	}

	return true
}
