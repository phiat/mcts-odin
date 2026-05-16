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
	seen_hashes:  map[u64]struct{},

	// Captures stack reused across MCTS descents. do_move appends, undo_move
	// trims back to delta.capture_start. Living on the board means the MCTS
	// adapter doesn't allocate a fresh dynamic per move (was 2 heap allocs/move,
	// now 1 — just the Adapter_Delta itself).
	captures: [dynamic]CaptureRecord,

	allocator:    runtime.Allocator,
}

make_go_board :: proc(size: int = 9, komi: f32 = KOMI_DEFAULT, allocator := context.allocator) -> GoBoard {
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
	return b
}

destroy_go_board :: proc(b: ^GoBoard) {
	delete(b.board, b.allocator)
	delete(b.seen_hashes)
	delete(b.captures)
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
	dst.seen_hashes = make(map[u64]struct{}, len(src.seen_hashes))
	for h in src.seen_hashes {
		dst.seen_hashes[h] = {}
	}
	return dst
}

// Clone with empty seen_hashes — used by is_legal_flat for the simulation copy.
@(private = "file")
clone_for_sim :: proc(src: ^GoBoard, allocator := context.allocator) -> GoBoard {
	context.allocator = allocator
	dst := GoBoard {
		size               = src.size,
		komi               = src.komi,
		board              = slice.clone(src.board),
		to_play            = src.to_play,
		ko_point           = src.ko_point,
		consecutive_passes = src.consecutive_passes,
		move_count         = src.move_count,
		tables             = src.tables,
		current_hash       = src.current_hash,
		allocator          = allocator,
	}
	dst.seen_hashes = make(map[u64]struct{})
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
	return row * b.size + col
}

row_col :: proc(b: ^GoBoard, flat: int) -> (row, col: int) {
	return flat / b.size, flat % b.size
}

at :: proc(b: ^GoBoard, row, col: int) -> i8 {
	return b.board[row * b.size + col]
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
	n := b.size * b.size
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
	return is_legal_flat(b, row * b.size + col)
}

is_legal_flat :: proc(b: ^GoBoard, index: int) -> bool {
	if index < 0 || index >= b.size * b.size {return false}
	if b.board[index] != EMPTY {return false}
	if b.ko_point == index {return false}

	player := b.to_play
	opponent := opponent_of(player)

	has_friendly := false
	has_empty := false
	captures := false

	nb := b.tables.neighbors[index]
	loop: for k in 0 ..< nb.count {
		ni := nb.indices[k]
		v := b.board[ni]
		if v == EMPTY {
			has_empty = true
			break loop
		} else if v == player {
			has_friendly = true
		} else if v == opponent && !captures {
			group, libs := get_group_and_liberties(b, ni, context.temp_allocator)
			if len(libs) == 1 && libs[0] == index {
				captures = true
			}
			delete(group)
			delete(libs)
		}
	}

	// Single-stone-suicide fast reject.
	if !has_empty && !has_friendly && !captures {
		return false
	}

	need_suicide_check := !has_empty && !captures
	need_psk_check := len(b.seen_hashes) > 0
	if need_suicide_check || need_psk_check {
		tmp := clone_for_sim(b, context.temp_allocator)
		defer destroy_go_board(&tmp)
		play_flat_unchecked(&tmp, index)
		if need_suicide_check && tmp.board[index] == EMPTY {
			return false
		}
		if need_psk_check {
			if _, ok := b.seen_hashes[tmp.current_hash]; ok {
				return false
			}
		}
	}
	return true
}

get_legal_moves_flat :: proc(b: ^GoBoard, allocator := context.allocator) -> [dynamic]int {
	n := b.size * b.size
	moves := make([dynamic]int, 0, n, allocator)
	for i in 0 ..< n {
		if is_legal_flat(b, i) {
			append(&moves, i)
		}
	}
	return moves
}

play :: proc(b: ^GoBoard, row, col: int) -> bool {
	return play_flat(b, row * b.size + col)
}

play_flat :: proc(b: ^GoBoard, index: int) -> bool {
	if !is_legal_flat(b, index) {return false}
	play_flat_unchecked(b, index)
	return true
}

// Applies a move assuming legality already checked. Used by play_flat AND by
// is_legal_flat (on a temp clone) to detect multi-stone suicide.
play_flat_unchecked :: proc(b: ^GoBoard, index: int) {
	// Record the pre-move state hash in seen_hashes (for PSK on future moves).
	b.seen_hashes[b.current_hash] = {}

	b.board[index] = b.to_play
	b.current_hash ~= b.tables.zobrist[index][int(b.to_play)]
	opp := opponent_of(b.to_play)
	b.ko_point = NO_KO

	total_captured := 0
	last_captured := -1

	nb := b.tables.neighbors[index]
	for k in 0 ..< nb.count {
		ni := nb.indices[k]
		if b.board[ni] == opp {
			group, libs := get_group_and_liberties(b, ni, context.temp_allocator)
			if len(libs) == 0 {
				if len(group) == 1 {
					last_captured = group[0]
				}
				total_captured += remove_group(b, group[:])
			}
			delete(group)
			delete(libs)
		}
	}

	our_group, our_libs := get_group_and_liberties(b, index, context.temp_allocator)
	if len(our_libs) == 0 {
		remove_group(b, our_group[:])
	} else if total_captured == 1 && len(our_group) == 1 && len(our_libs) == 1 {
		b.ko_point = last_captured
	}
	delete(our_group)
	delete(our_libs)

	b.consecutive_passes = 0
	b.move_count += 1
	b.to_play = opp
}

pass_move :: proc(b: ^GoBoard) -> bool {
	b.seen_hashes[b.current_hash] = {}
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
		prev_ko_point           = b.ko_point,
		prev_consecutive_passes = b.consecutive_passes,
		prev_move_count         = b.move_count,
		prev_current_hash       = b.current_hash,
		prev_to_play            = b.to_play,
	}

	// Record + insert seen_hashes entry for the position BEFORE this move.
	_, was_seen := b.seen_hashes[b.current_hash]
	b.seen_hashes[b.current_hash] = {}
	delta.seen_hash_added = b.current_hash
	delta.seen_hash_was_new = !was_seen

	if action == PASS_ACTION {
		b.consecutive_passes += 1
		b.move_count += 1
		b.to_play = opponent_of(b.to_play)
		b.ko_point = NO_KO
		return delta
	}

	// Mirrors play_flat_unchecked, but records every captured stone on `captures`.
	b.board[action] = b.to_play
	b.current_hash ~= b.tables.zobrist[action][int(b.to_play)]
	opp := opponent_of(b.to_play)
	b.ko_point = NO_KO

	total_captured := 0
	last_captured := -1

	nb := b.tables.neighbors[action]
	for k in 0 ..< nb.count {
		ni := nb.indices[k]
		if b.board[ni] == opp {
			group, libs := get_group_and_liberties(b, ni, context.temp_allocator)
			if len(libs) == 0 {
				if len(group) == 1 {last_captured = group[0]}
				for idx in group {
					append(captures, CaptureRecord{index = i32(idx), color = opp})
				}
				total_captured += remove_group(b, group[:])
			}
			delete(group)
			delete(libs)
		}
	}

	our_group, our_libs := get_group_and_liberties(b, action, context.temp_allocator)
	if len(our_libs) == 0 {
		// Multi-stone suicide: our own group gets removed. Record those captures
		// under our own color so undo can restore them correctly.
		for idx in our_group {
			append(captures, CaptureRecord{index = i32(idx), color = b.to_play})
		}
		remove_group(b, our_group[:])
	} else if total_captured == 1 && len(our_group) == 1 && len(our_libs) == 1 {
		b.ko_point = last_captured
	}
	delete(our_group)
	delete(our_libs)

	b.consecutive_passes = 0
	b.move_count += 1
	b.to_play = opp

	delta.capture_count = len(captures) - delta.capture_start
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

	// Scalars: restore wholesale.
	b.current_hash = delta.prev_current_hash
	b.ko_point = delta.prev_ko_point
	b.consecutive_passes = delta.prev_consecutive_passes
	b.move_count = delta.prev_move_count
	b.to_play = delta.prev_to_play

	// Remove the seen_hashes entry we added, but only if it wasn't there before.
	if delta.seen_hash_was_new {
		delete_key(&b.seen_hashes, delta.seen_hash_added)
	}
}

score :: proc(b: ^GoBoard) -> f32 {
	black_score := f32(0)
	white_score := b.komi
	n := b.size * b.size
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
	n := b.size * b.size
	b.current_hash = 0
	for i in 0 ..< n {
		b.board[i] = data[i]
		if b.board[i] != EMPTY {
			b.current_hash ~= b.tables.zobrist[i][int(b.board[i])]
		}
	}
	clear(&b.seen_hashes)
	b.to_play = to_play
	b.ko_point = NO_KO
	b.consecutive_passes = 0
	mc := 0
	for i in 0 ..< n {
		if b.board[i] != EMPTY {mc += 1}
	}
	b.move_count = mc
}
