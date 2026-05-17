package go_game

import "base:runtime"
import "core:slice"
import "core:sync"

EMPTY :: i8(0)
BLACK :: i8(1)
WHITE :: i8(2)

KOMI_DEFAULT :: f32(7.5)
NO_KO :: -1

// Internal sentinel for the pass move inside this package. The MCTS-facing
// action space uses `size*size` for pass; the adapter in `game.odin` translates
// between the two. Kept negative so it never collides with a real flat index.
PASS_ACTION :: -1

// Compile-time board-size hint. When > 0, hot paths fold b.size + b.size*b.size
// to constants instead of loading the field + IMUL. Runtime board size still
// works — the hint just enables better codegen for the common case.
//
//   odin build ... -define:BOARD_SIZE_HINT=9     # specialise for 9x9
//   odin build ...                                # default 0 = fully runtime
//
// When set, make_go_board asserts the runtime size matches.
BOARD_SIZE_HINT :: #config(BOARD_SIZE_HINT, 0)

// n_cells: number of cells on the board. Folds to a compile-time constant
// when BOARD_SIZE_HINT > 0.
@(private)
n_cells :: #force_inline proc "contextless" (b: ^GoBoard) -> int {
	when BOARD_SIZE_HINT > 0 {
		return BOARD_SIZE_HINT * BOARD_SIZE_HINT
	} else {
		return b.size * b.size
	}
}

// board_dim: linear board size. Same compile-time-fold pattern as n_cells.
@(private)
board_dim :: #force_inline proc "contextless" (b: ^GoBoard) -> int {
	when BOARD_SIZE_HINT > 0 {
		return BOARD_SIZE_HINT
	} else {
		return b.size
	}
}

Neighbors4 :: struct {
	indices: [4]int,
	count:   int,
}

// Per-size shared tables. neighbors + zobrist are a pure function of board size
// and never mutate, so every GoBoard of the same size points at the same instance.
// Built lazily on first request via get_board_tables(size); never freed during
// the process lifetime (singleton).
BoardTables :: struct {
	size:      int,
	neighbors: []Neighbors4,
	zobrist:   [][3]u64,
}

@(private)
_board_tables_cache: map[int]^BoardTables
@(private)
_board_tables_mu: sync.Mutex

get_board_tables :: proc(size: int) -> ^BoardTables {
	sync.mutex_lock(&_board_tables_mu)
	defer sync.mutex_unlock(&_board_tables_mu)
	if t, ok := _board_tables_cache[size]; ok {
		return t
	}
	// Singletons must outlive any per-test/per-tree allocator, so pin them to the
	// default heap regardless of what `context.allocator` is set to by the caller.
	context.allocator = runtime.default_allocator()
	if _board_tables_cache == nil {
		_board_tables_cache = make(map[int]^BoardTables)
	}
	t := new(BoardTables)
	t.size = size
	n := size * size
	t.neighbors = make([]Neighbors4, n)
	t.zobrist = make([][3]u64, n)
	init_neighbors_table(t)
	init_zobrist_table(t)
	_board_tables_cache[size] = t
	return t
}

// Singleton teardown — call from test runners or process shutdown if you want the
// memory tracker to report 0 live allocations. Idempotent.
release_board_tables_cache :: proc() {
	for _, t in _board_tables_cache {
		delete(t.neighbors)
		delete(t.zobrist)
		free(t)
	}
	delete(_board_tables_cache)
	_board_tables_cache = nil
}

GoBoard :: struct {
	size:               int,
	komi:               f32,
	board:              []i8,
	to_play:            i8,
	ko_point:           int, // NO_KO = -1
	consecutive_passes: int,
	move_count:         int,

	tables:       ^BoardTables, // shared per-size; not owned.
	current_hash: u64,
	seen_hashes:  HashSet,

	// Captures stack reused across MCTS descents. do_move appends, undo_move
	// trims back to delta.capture_start. Living on the board means the MCTS
	// adapter doesn't allocate a fresh dynamic per move (was 2 heap allocs/move,
	// now 1 — just the Adapter_Delta itself).
	captures: [dynamic]CaptureRecord,

	// Incremental per-block (stone group) index — replaces get_group_and_liberties
	// flood-fill in the do_move / is_legal_flat hot path. See mcts-odin-81j.9.
	// Maintained inline by do_move; journaled mutations are reversed by undo_move.
	blocks:      BlockIndex,
	parent_undo: [dynamic]JournalParent,
	next_undo:   [dynamic]JournalNext,
	libs_undo:   [dynamic]JournalLibs,
	size_undo:   [dynamic]JournalSize,

	allocator:    runtime.Allocator,
}

make_go_board :: proc(size: int = 9, komi: f32 = KOMI_DEFAULT, allocator := context.allocator) -> GoBoard {
	when BOARD_SIZE_HINT > 0 {
		assert(size == BOARD_SIZE_HINT,
			"BOARD_SIZE_HINT was set at compile time; runtime board size must match")
	}
	context.allocator = allocator
	n := size * size
	b := GoBoard {
		size      = size,
		komi      = komi,
		board     = make([]i8, n),
		to_play   = BLACK,
		ko_point  = NO_KO,
		tables    = get_board_tables(size),
		allocator = allocator,
	}
	b.seen_hashes = hash_set_make(HASH_SET_INITIAL_CAP, allocator)
	b.blocks = block_index_make(n, allocator)
	return b
}

destroy_go_board :: proc(b: ^GoBoard) {
	delete(b.board, b.allocator)
	hash_set_destroy(&b.seen_hashes)
	delete(b.captures)
	block_index_destroy(&b.blocks)
	delete(b.parent_undo)
	delete(b.next_undo)
	delete(b.libs_undo)
	delete(b.size_undo)
	b^ = {}
}

// Clone with full PSK history. Caller owns all dst-allocated buffers.
clone_go_board :: proc(src: ^GoBoard, allocator := context.allocator) -> GoBoard {
	context.allocator = allocator
	dst := GoBoard {
		size               = src.size,
		komi               = src.komi,
		board              = slice.clone(src.board),
		to_play            = src.to_play,
		ko_point           = src.ko_point,
		consecutive_passes = src.consecutive_passes,
		move_count         = src.move_count,
		tables             = src.tables, // shared pointer; no clone needed
		current_hash       = src.current_hash,
		allocator          = allocator,
	}
	dst.seen_hashes = hash_set_clone(&src.seen_hashes, allocator)
	dst.blocks = block_index_clone(&src.blocks, allocator)
	// Journals are scratch / per-descent; clones start empty.
	return dst
}

@(private = "file")
init_neighbors_table :: proc(t: ^BoardTables) {
	size := t.size
	for row in 0 ..< size {
		for col in 0 ..< size {
			idx := row * size + col
			n := &t.neighbors[idx]
			n.count = 0
			if row > 0 {n.indices[n.count] = (row - 1) * size + col; n.count += 1}
			if row < size - 1 {n.indices[n.count] = (row + 1) * size + col; n.count += 1}
			if col > 0 {n.indices[n.count] = row * size + (col - 1); n.count += 1}
			if col < size - 1 {n.indices[n.count] = row * size + (col + 1); n.count += 1}
		}
	}
}

@(private = "file")
splitmix64 :: proc(seed: ^u64) -> u64 {
	seed^ += 0x9E3779B97F4A7C15
	z := seed^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private = "file")
init_zobrist_table :: proc(t: ^BoardTables) {
	seed := u64(0x9E3779B97F4A7C15) ~ u64(t.size)
	n := t.size * t.size
	for i in 0 ..< n {
		t.zobrist[i][EMPTY] = 0
		t.zobrist[i][BLACK] = splitmix64(&seed)
		t.zobrist[i][WHITE] = splitmix64(&seed)
	}
}

flat_index :: proc(b: ^GoBoard, row, col: int) -> int {
	return row * board_dim(b) + col
}

row_col :: proc(b: ^GoBoard, flat: int) -> (row, col: int) {
	dim := board_dim(b)
	return flat / dim, flat % dim
}

at :: proc(b: ^GoBoard, row, col: int) -> i8 {
	return b.board[row * board_dim(b) + col]
}

at_flat :: proc(b: ^GoBoard, index: int) -> i8 {
	return b.board[index]
}

is_game_over :: proc(b: ^GoBoard) -> bool {
	return b.consecutive_passes >= 2
}

@(private = "file")
opponent_of :: proc(c: i8) -> i8 {
	return WHITE if c == BLACK else BLACK
}

// DFS flood-fill: returns the connected group at `index` and its liberties.
// Both [dynamic] returns are allocated with the supplied allocator.
get_group_and_liberties :: proc(
	b: ^GoBoard,
	index: int,
	allocator := context.allocator,
) -> (
	group: [dynamic]int,
	liberties: [dynamic]int,
) {
	group = make([dynamic]int, 0, 16, allocator)
	liberties = make([dynamic]int, 0, 16, allocator)
	color := b.board[index]
	if color == EMPTY {
		return
	}
	n := n_cells(b)
	visited := make([]bool, n, context.temp_allocator)
	defer delete(visited, context.temp_allocator)
	lib_visited := make([]bool, n, context.temp_allocator)
	defer delete(lib_visited, context.temp_allocator)
	stack := make([dynamic]int, 0, 16, context.temp_allocator)
	defer delete(stack)

	append(&stack, index)
	visited[index] = true

	for len(stack) > 0 {
		current := pop(&stack)
		append(&group, current)
		nb := b.tables.neighbors[current]
		for k in 0 ..< nb.count {
			ni := nb.indices[k]
			v := b.board[ni]
			if v == EMPTY {
				if !lib_visited[ni] {
					lib_visited[ni] = true
					append(&liberties, ni)
				}
			} else if v == color && !visited[ni] {
				visited[ni] = true
				append(&stack, ni)
			}
		}
	}
	return
}

remove_group :: proc(b: ^GoBoard, group: []int) -> int {
	for idx in group {
		b.current_hash ~= b.tables.zobrist[idx][int(b.board[idx])]
		b.board[idx] = EMPTY
	}
	return len(group)
}

is_legal :: proc(b: ^GoBoard, row, col: int) -> bool {
	return is_legal_flat(b, row * board_dim(b) + col)
}

// Legality test for placing b.to_play at `index`. Uses the incremental
// BlockIndex (Phase 3 of mcts-odin-81j.9) — no flood-fill on the hot path.
//
// Capture detection: an opp block dies iff (blk_libs[opp_root] with bit(index)
// cleared) == 0. Suicide detection: the placed stone's virtual block has
// libs == union of (empty neighbors of index) + (friendly neighbor block
// libs) with bit(index) cleared; if zero AND no captures, the move is suicide.
is_legal_flat :: proc(b: ^GoBoard, index: int) -> bool {
	if index < 0 || index >= n_cells(b) {return false}
	if b.board[index] != EMPTY {return false}
	if b.ko_point == index {return false}

	player := b.to_play
	opponent := opponent_of(player)
	nb := b.tables.neighbors[index]

	has_empty := false
	for k in 0 ..< nb.count {
		if b.board[nb.indices[k]] == EMPTY {has_empty = true; break}
	}

	need_psk_check := hash_set_len(&b.seen_hashes) > 0

	// Fast path: empty neighbor (immediate liberty) and no PSK history. No
	// captures need to be enumerated — the move can't be suicide and there's
	// no hash to probe.
	if has_empty && !need_psk_check {return true}

	// Enumerate distinct opp blocks adjacent to `index` and detect captures
	// via bitset. At most 4 distinct neighbor blocks (one per orthogonal dir).
	seen_opp_roots: [4]u16
	seen_opp_count := 0
	captured_groups: [4]u16  // roots of captured opp blocks (for PSK rebuild)
	captured_count := 0
	for k in 0 ..< nb.count {
		ni := nb.indices[k]
		if b.board[ni] != opponent {continue}
		or := b.blocks.parent[ni]
		already := false
		for j in 0 ..< seen_opp_count {
			if seen_opp_roots[j] == or {already = true; break}
		}
		if already {continue}
		seen_opp_roots[seen_opp_count] = or
		seen_opp_count += 1
		// Local copy of the bitset, clear bit(index), test zero.
		libs := b.blocks.blk_libs[or]
		libset_clear(&libs, index)
		if libset_is_zero(&libs) {
			captured_groups[captured_count] = or
			captured_count += 1
		}
	}

	has_capture := captured_count > 0

	// Suicide check (only reached when no empty neighbor and no capture).
	if !has_empty && !has_capture {
		// Build the virtual block's libs: union of friendly-block libs,
		// then clear bit(index). (No empty neighbors at this point — we
		// checked has_empty above.)
		virt_libs: LibBitset
		libset_zero(&virt_libs)
		seen_fr_roots: [4]u16
		seen_fr_count := 0
		for k in 0 ..< nb.count {
			ni := nb.indices[k]
			if b.board[ni] != player {continue}
			fr := b.blocks.parent[ni]
			already := false
			for j in 0 ..< seen_fr_count {
				if seen_fr_roots[j] == fr {already = true; break}
			}
			if already {continue}
			seen_fr_roots[seen_fr_count] = fr
			seen_fr_count += 1
			fr_libs := b.blocks.blk_libs[fr]
			libset_or(&virt_libs, &fr_libs)
		}
		libset_clear(&virt_libs, index)
		if libset_is_zero(&virt_libs) {return false}
	}

	// PSK check. Compute the would-be hash without mutating state:
	//   h := current_hash XOR placed_stone XOR each captured stone.
	// Walk each captured opp block via block_next to enumerate the cells.
	if need_psk_check {
		h := b.current_hash ~ b.tables.zobrist[index][int(player)]
		for ci in 0 ..< captured_count {
			root := int(captured_groups[ci])
			cur := root
			for {
				h ~= b.tables.zobrist[cur][int(opponent)]
				cur = int(b.blocks.block_next[cur])
				if cur == root {break}
			}
		}
		if hash_set_contains(&b.seen_hashes, h) {return false}
	}

	return true
}

get_legal_moves_flat :: proc(b: ^GoBoard, allocator := context.allocator) -> [dynamic]int {
	n := n_cells(b)
	moves := make([dynamic]int, 0, n, allocator)
	for i in 0 ..< n {
		if is_legal_flat(b, i) {
			append(&moves, i)
		}
	}
	return moves
}

play :: proc(b: ^GoBoard, row, col: int) -> bool {
	return play_flat(b, row * board_dim(b) + col)
}

play_flat :: proc(b: ^GoBoard, index: int) -> bool {
	if !is_legal_flat(b, index) {return false}
	play_flat_unchecked(b, index)
	return true
}

// Applies a move assuming legality already checked. Forward-only (no undo
// support). Used by play_flat for tests + external callers. Routes through
// do_move so the block index stays in sync, then drops the journal entries
// since play_flat has no undo path.
play_flat_unchecked :: proc(b: ^GoBoard, index: int) {
	_ = do_move(b, index, &b.captures)
	clear(&b.parent_undo)
	clear(&b.next_undo)
	clear(&b.libs_undo)
	clear(&b.size_undo)
}

pass_move :: proc(b: ^GoBoard) -> bool {
	hash_set_add(&b.seen_hashes, b.current_hash)
	b.consecutive_passes += 1
	b.move_count += 1
	b.to_play = opponent_of(b.to_play)
	b.ko_point = NO_KO
	return true
}

// =============================================================================
// Reversible moves (do_move / undo_move) — used by MCTS to mutate a single
// working_board while descending/ascending the tree. The board's state after
// do_move + undo_move is bit-identical to before do_move.
//
// Captures (both opponent-captures and the own-suicide branch) are pushed onto
// `captures` as (index, color) records. undo_move pops them back.
//
// NOTE: do_move does NOT check legality — it mirrors play_flat_unchecked.
// Callers must verify legality (or accept the resulting state).
// =============================================================================

CaptureRecord :: struct {
	index: i32,
	color: i8,
}

MoveDelta :: struct {
	action:                  int, // PASS_ACTION or [0, size*size)
	capture_start:           int, // index into captures stack
	capture_count:           int,
	parent_undo_start:       int, // index into b.parent_undo
	parent_undo_count:       int,
	next_undo_start:         int,
	next_undo_count:         int,
	libs_undo_start:         int,
	libs_undo_count:         int,
	size_undo_start:         int,
	size_undo_count:         int,
	prev_ko_point:           int,
	prev_consecutive_passes: int,
	prev_move_count:         int,
	prev_current_hash:       u64,
	prev_to_play:            i8,
	seen_hash_added:         u64, // hash inserted into seen_hashes by this move
	seen_hash_was_new:       bool, // if false, undo must NOT remove it
}

do_move :: proc(b: ^GoBoard, action: int, captures: ^[dynamic]CaptureRecord) -> MoveDelta {
	delta := MoveDelta {
		action                  = action,
		capture_start           = len(captures),
		parent_undo_start       = len(b.parent_undo),
		next_undo_start         = len(b.next_undo),
		libs_undo_start         = len(b.libs_undo),
		size_undo_start         = len(b.size_undo),
		prev_ko_point           = b.ko_point,
		prev_consecutive_passes = b.consecutive_passes,
		prev_move_count         = b.move_count,
		prev_current_hash       = b.current_hash,
		prev_to_play            = b.to_play,
	}

	// Record + insert seen_hashes entry for the position BEFORE this move.
	delta.seen_hash_added = b.current_hash
	delta.seen_hash_was_new = hash_set_add(&b.seen_hashes, b.current_hash)

	if action == PASS_ACTION {
		b.consecutive_passes += 1
		b.move_count += 1
		b.to_play = opponent_of(b.to_play)
		b.ko_point = NO_KO
		return delta
	}

	// ----- Place stone + initialize singleton block -----
	player := b.to_play
	opp := opponent_of(player)
	b.board[action] = player
	b.current_hash ~= b.tables.zobrist[action][int(player)]
	b.ko_point = NO_KO

	nb := b.tables.neighbors[action]

	// New singleton block at `action`. Journal old (empty-cell) values so undo
	// restores parent[action]=NO_PARENT, block_next[action]=action.
	append(&b.parent_undo, JournalParent{cell = u16(action), prev = b.blocks.parent[action]})
	append(&b.next_undo, JournalNext{cell = u16(action), prev = b.blocks.block_next[action]})
	b.blocks.parent[action] = u16(action)
	b.blocks.block_next[action] = u16(action)
	// blk_libs[action] / blk_size[action] are "unused junk" while action was
	// empty; their prior values are irrelevant. Journal them anyway so undo
	// restores the slot to "junk we don't read" again.
	append(&b.libs_undo, JournalLibs{root = u16(action), prev = b.blocks.blk_libs[action]})
	append(&b.size_undo, JournalSize{root = u16(action), prev = b.blocks.blk_size[action]})
	libset_zero(&b.blocks.blk_libs[action])
	b.blocks.blk_size[action] = 1
	for k in 0 ..< nb.count {
		ni := nb.indices[k]
		if b.board[ni] == EMPTY {
			libset_set(&b.blocks.blk_libs[action], ni)
		}
	}

	// ----- Merge with friendly neighbors -----
	// my_root tracks the surviving root after each union (union-by-larger).
	my_root := action
	for k in 0 ..< nb.count {
		ni := nb.indices[k]
		if b.board[ni] != player {continue}
		fr := int(b.blocks.parent[ni])
		if fr == my_root {continue} // already merged through a previous neighbor
		// Union: keep the larger block's root, rewrite the smaller block's
		// parent[] entries.
		larger, smaller := fr, my_root
		if int(b.blocks.blk_size[larger]) < int(b.blocks.blk_size[smaller]) {
			larger, smaller = smaller, larger
		}
		cur := smaller
		for {
			append(&b.parent_undo, JournalParent{cell = u16(cur), prev = b.blocks.parent[cur]})
			b.blocks.parent[cur] = u16(larger)
			nxt := int(b.blocks.block_next[cur])
			if nxt == smaller {break}
			cur = nxt
		}
		// Splice the two cycles into one. Both lists are circular at this
		// point; swap larger.next and smaller.next.
		append(&b.next_undo, JournalNext{cell = u16(larger), prev = b.blocks.block_next[larger]})
		append(&b.next_undo, JournalNext{cell = u16(smaller), prev = b.blocks.block_next[smaller]})
		la_n := b.blocks.block_next[larger]
		sm_n := b.blocks.block_next[smaller]
		b.blocks.block_next[larger] = sm_n
		b.blocks.block_next[smaller] = la_n
		// Merge libs and size into larger; clear bit(action) since the placed
		// stone is no longer a liberty.
		append(&b.libs_undo, JournalLibs{root = u16(larger), prev = b.blocks.blk_libs[larger]})
		append(&b.size_undo, JournalSize{root = u16(larger), prev = b.blocks.blk_size[larger]})
		libset_or(&b.blocks.blk_libs[larger], &b.blocks.blk_libs[smaller])
		libset_clear(&b.blocks.blk_libs[larger], action)
		b.blocks.blk_size[larger] += b.blocks.blk_size[smaller]
		my_root = larger
	}

	// ----- Decrement opp libs; capture groups whose libs hit zero -----
	total_captured := 0
	last_captured := -1
	captured_cells := make([dynamic]int, 0, 16, context.temp_allocator)
	defer delete(captured_cells)
	for k in 0 ..< nb.count {
		ni := nb.indices[k]
		if b.board[ni] != opp {continue}
		or := int(b.blocks.parent[ni])
		// Dedup multiple neighbors in same opp block: once we clear bit(action),
		// a second visit sees it cleared and skips.
		if !libset_test(&b.blocks.blk_libs[or], action) {continue}
		append(&b.libs_undo, JournalLibs{root = u16(or), prev = b.blocks.blk_libs[or]})
		libset_clear(&b.blocks.blk_libs[or], action)
		if !libset_is_zero(&b.blocks.blk_libs[or]) {continue}

		// Capture the opp block. Walk block_next chain, collect cells.
		size_before := len(captured_cells)
		cur := or
		for {
			append(&captured_cells, cur)
			cur = int(b.blocks.block_next[cur])
			if cur == or {break}
		}
		grp_size := len(captured_cells) - size_before
		if grp_size == 1 {last_captured = captured_cells[size_before]}
		for i in size_before ..< len(captured_cells) {
			c := captured_cells[i]
			append(captures, CaptureRecord{index = i32(c), color = opp})
			b.current_hash ~= b.tables.zobrist[c][int(opp)]
			b.board[c] = EMPTY
			append(&b.parent_undo, JournalParent{cell = u16(c), prev = b.blocks.parent[c]})
			append(&b.next_undo, JournalNext{cell = u16(c), prev = b.blocks.block_next[c]})
			b.blocks.parent[c] = NO_PARENT
			b.blocks.block_next[c] = u16(c)
		}
		total_captured += grp_size
		// For each captured cell, walk neighbors and liberate adjacent blocks
		// (add bit(c) to their blk_libs).
		for i in size_before ..< len(captured_cells) {
			c := captured_cells[i]
			nc := b.tables.neighbors[c]
			for j in 0 ..< nc.count {
				nni := nc.indices[j]
				if b.board[nni] == EMPTY {continue}
				or2 := int(b.blocks.parent[nni])
				if libset_test(&b.blocks.blk_libs[or2], c) {continue}
				append(&b.libs_undo, JournalLibs{root = u16(or2), prev = b.blocks.blk_libs[or2]})
				libset_set(&b.blocks.blk_libs[or2], c)
			}
		}
	}

	// ----- Suicide check on the placed-stone's combined block -----
	if libset_is_zero(&b.blocks.blk_libs[my_root]) {
		// Multi-stone suicide: remove own group. Same shape as opp capture
		// above, but with player color. Walk block_next, record + clear.
		own_start := len(captured_cells)
		cur := my_root
		for {
			append(&captured_cells, cur)
			cur = int(b.blocks.block_next[cur])
			if cur == my_root {break}
		}
		for i in own_start ..< len(captured_cells) {
			c := captured_cells[i]
			append(captures, CaptureRecord{index = i32(c), color = player})
			b.current_hash ~= b.tables.zobrist[c][int(player)]
			b.board[c] = EMPTY
			append(&b.parent_undo, JournalParent{cell = u16(c), prev = b.blocks.parent[c]})
			append(&b.next_undo, JournalNext{cell = u16(c), prev = b.blocks.block_next[c]})
			b.blocks.parent[c] = NO_PARENT
			b.blocks.block_next[c] = u16(c)
		}
		for i in own_start ..< len(captured_cells) {
			c := captured_cells[i]
			nc := b.tables.neighbors[c]
			for j in 0 ..< nc.count {
				nni := nc.indices[j]
				if b.board[nni] == EMPTY {continue}
				or2 := int(b.blocks.parent[nni])
				if libset_test(&b.blocks.blk_libs[or2], c) {continue}
				append(&b.libs_undo, JournalLibs{root = u16(or2), prev = b.blocks.blk_libs[or2]})
				libset_set(&b.blocks.blk_libs[or2], c)
			}
		}
	} else if total_captured == 1 && b.blocks.blk_size[my_root] == 1 && libset_popcount(&b.blocks.blk_libs[my_root]) == 1 {
		b.ko_point = last_captured
	}

	b.consecutive_passes = 0
	b.move_count += 1
	b.to_play = opp

	delta.capture_count = len(captures) - delta.capture_start
	delta.parent_undo_count = len(b.parent_undo) - delta.parent_undo_start
	delta.next_undo_count = len(b.next_undo) - delta.next_undo_start
	delta.libs_undo_count = len(b.libs_undo) - delta.libs_undo_start
	delta.size_undo_count = len(b.size_undo) - delta.size_undo_start
	return delta
}

undo_move :: proc(b: ^GoBoard, delta: MoveDelta, captures: ^[dynamic]CaptureRecord) {
	// Restore captured stones first (they hold board-cell state). For non-pass
	// moves the played stone is also at delta.action — clear it before restoring
	// captures in case the action cell itself was part of an own-suicide.
	if delta.action != PASS_ACTION {
		b.board[delta.action] = EMPTY
	}
	for i in 0 ..< delta.capture_count {
		rec := captures[delta.capture_start + i]
		b.board[rec.index] = rec.color
	}
	resize(captures, delta.capture_start)

	// Pop block-index journals in reverse push order to undo every mutation.
	// Order: size → libs → next → parent. Within each kind, reverse-pop.
	for i := delta.size_undo_count - 1; i >= 0; i -= 1 {
		e := b.size_undo[delta.size_undo_start + i]
		b.blocks.blk_size[e.root] = e.prev
	}
	resize(&b.size_undo, delta.size_undo_start)

	for i := delta.libs_undo_count - 1; i >= 0; i -= 1 {
		e := b.libs_undo[delta.libs_undo_start + i]
		b.blocks.blk_libs[e.root] = e.prev
	}
	resize(&b.libs_undo, delta.libs_undo_start)

	for i := delta.next_undo_count - 1; i >= 0; i -= 1 {
		e := b.next_undo[delta.next_undo_start + i]
		b.blocks.block_next[e.cell] = e.prev
	}
	resize(&b.next_undo, delta.next_undo_start)

	for i := delta.parent_undo_count - 1; i >= 0; i -= 1 {
		e := b.parent_undo[delta.parent_undo_start + i]
		b.blocks.parent[e.cell] = e.prev
	}
	resize(&b.parent_undo, delta.parent_undo_start)

	// Scalars: restore wholesale.
	b.current_hash = delta.prev_current_hash
	b.ko_point = delta.prev_ko_point
	b.consecutive_passes = delta.prev_consecutive_passes
	b.move_count = delta.prev_move_count
	b.to_play = delta.prev_to_play

	// Remove the seen_hashes entry we added, but only if it wasn't there before.
	if delta.seen_hash_was_new {
		hash_set_remove(&b.seen_hashes, delta.seen_hash_added)
	}
}

score :: proc(b: ^GoBoard) -> f32 {
	black_score := f32(0)
	white_score := b.komi
	n := n_cells(b)
	for i in 0 ..< n {
		if b.board[i] == BLACK {
			black_score += 1
		} else if b.board[i] == WHITE {
			white_score += 1
		}
	}

	visited := make([]bool, n, context.temp_allocator)
	defer delete(visited, context.temp_allocator)

	for i in 0 ..< n {
		if b.board[i] != EMPTY || visited[i] {continue}

		territory := make([dynamic]int, 0, 8, context.temp_allocator)
		defer delete(territory)
		stack := make([dynamic]int, 0, 8, context.temp_allocator)
		defer delete(stack)

		append(&stack, i)
		visited[i] = true
		borders_black := false
		borders_white := false

		for len(stack) > 0 {
			current := pop(&stack)
			append(&territory, current)
			nbrs := b.tables.neighbors[current]
			for k in 0 ..< nbrs.count {
				ni := nbrs.indices[k]
				v := b.board[ni]
				if v == EMPTY {
					if !visited[ni] {
						visited[ni] = true
						append(&stack, ni)
					}
				} else if v == BLACK {
					borders_black = true
				} else if v == WHITE {
					borders_white = true
				}
			}
		}

		if borders_black && !borders_white {
			black_score += f32(len(territory))
		} else if borders_white && !borders_black {
			white_score += f32(len(territory))
		}
	}

	return black_score - white_score
}

get_winner :: proc(b: ^GoBoard) -> i8 {
	s := score(b)
	if s > 0 {return BLACK}
	if s < 0 {return WHITE}
	return 0
}

set_from_array :: proc(b: ^GoBoard, data: []i8, to_play: i8) {
	n := n_cells(b)
	b.current_hash = 0
	for i in 0 ..< n {
		b.board[i] = data[i]
		if b.board[i] != EMPTY {
			b.current_hash ~= b.tables.zobrist[i][int(b.board[i])]
		}
	}
	hash_set_clear(&b.seen_hashes)
	b.to_play = to_play
	b.ko_point = NO_KO
	b.consecutive_passes = 0
	mc := 0
	for i in 0 ..< n {
		if b.board[i] != EMPTY {mc += 1}
	}
	b.move_count = mc
	// set_from_array bypasses do_move; resync the block index from scratch.
	block_index_rebuild(&b.blocks, b)
	// Drop any in-flight journal state — there's nothing to undo to.
	clear(&b.parent_undo)
	clear(&b.next_undo)
	clear(&b.libs_undo)
	clear(&b.size_undo)
}
