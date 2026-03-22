package main

import "core:fmt"
import "core:strings"
import "core:mem"
import rl "vendor:raylib"

global_ui_state: UiState

// Decisions:
// - Going to make a UI tree that does a layout pass. The results of the layout pass can be used in the next frame.
// - We will use @(deferred_out) instead of begin/end pairs

UiRect :: struct {
	top, left, bottom, right: f32,
}

UiNode :: struct {
	parent: ^UiNode,

	// Intrusive doubly-linked linked list, so all the allocations can be done into the arena.
	// Also, next-sibling will wrap back around to first, prev wraps back around to last.
	// I first saw it here, and want to see if its any good: https://www.youtube.com/watch?v=-m7lhJ_Mzdg
	first_child: ^UiNode,
	next_sibling: ^UiNode,
	prev_sibling: ^UiNode,

	layout: UiLayout,
	text: cstring, // when set, layout is ignored
}

UiLayoutType :: enum {
	Block, Row, Col,
}

UiLayoutFlags :: enum {
	Relative,
	Absolute,
}

UiDimensionConstraint :: enum {
	FitContent, // the default
	Fixed,
}

UiDimension :: struct {
	constraint: UiDimensionConstraint,
	value: f32,
}

UiAlignmentType :: enum {
	Start,
	Center,
	End,
}

UiLayout :: struct {
	layout  : UiLayoutType,
	flags : bit_set[UiLayoutFlags],

	rect : UiRect,
	width : UiDimension, 
	height : UiDimension,
	gap : UiDimension,
	padding : UiDimension,
	align : UiAlignmentType,
}

UiState :: struct {
	viewport: UiRect,
	arena_mem : []byte,
	arena     : mem.Arena,
	allocator : mem.Allocator,
}

new_ui :: proc() -> UiState {
	state: UiState

	state.arena_mem = make([]byte, 8*mem.Megabyte)
	mem.arena_init(&state.arena, state.arena_mem)
	state.allocator = mem.arena_allocator(&state.arena)

	return state
}

window_rect :: proc(window_size: Vector2) -> UiRect {
	return {
		top = 0,
		left = 0,
		right = window_size.x,
		bottom = window_size.y
	}
}

ui_root_begin :: proc(window_size: Vector2) -> ^UiNode {
	ui := &global_ui_state

	mem.arena_free_all(&ui.arena)
	width := window_size.x
	height := window_size.y

	return _ui_new_node(ui, {
		flags={ .Absolute, .Relative },
		width={ .Fixed,  width },
		height={ .Fixed, height }
	})
}

// NOTE: for persistent references, could potentially use a pool allocator.

ui_layout_append :: proc(parent: ^UiNode, layout: UiLayout) -> ^UiNode {
	ui := &global_ui_state

	new_node := _ui_new_node(ui, layout)

	if parent.first_child == nil {
		parent.first_child    = new_node
		new_node.next_sibling = new_node
		new_node.prev_sibling = new_node
	} else {
		first_child := parent.first_child
		last_child := first_child.prev_sibling;
		last_child.next_sibling  = new_node
		new_node.next_sibling    = first_child
		first_child.prev_sibling = new_node
	}

	return new_node
}

_ui_new_node :: proc(ui: ^UiState, layout: UiLayout) -> ^UiNode {
	return new_clone(UiNode{layout=layout}, allocator = ui.allocator)
}

ui_root_end :: proc() {
	// TODO: run layout computation, and then render the UI.
}

ui_rect_width :: proc(rect: UiRect) -> f32 {
	return rect.right - rect.left
}

ui_rect_height :: proc(rect: UiRect) -> f32 {
	return rect.bottom - rect.top
}

ui_init :: proc() {
	global_ui_state = new_ui()
}

ui_text :: proc(format: string, args: ..any) {
	ui := &global_ui_state

	sb := strings.builder_make_none(ui.allocator)
	fmt.sbprintf(&sb, format, args)

	new_node := _ui_new_node(ui, {})
	new_node.text = strings.to_cstring(&sb)
}
