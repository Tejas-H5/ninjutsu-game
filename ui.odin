package main

import rl "vendor:raylib"
import c "core:c"

// Decisions:
// - Going to make a UI tree that does a layout pass. The results of the layout pass can be used in the next frame.
// - We will use @(deferred_out) instead of begin/end pairs

UiRect :: struct {
	top, left, bottom, right: f32,
}

UiNode :: struct {
	parent: ^UiNode,
	first_child: ^UiNode,
	next_sibling: ^UiNode,
	prev_sibling: ^UiNode,

	layout: UiLayout,
}

UiLayoutType :: enum {
	Block,
	Inline,
	Row,
	Column,
	// TODO: css-grid clone
}

UiLayoutFlags :: enum {
	Relative,
	Absolute,
	Wrap,
}

UiDimensionConstraint :: enum {
	Rigid,
	FitContent,
	Flex,
}

UiDimension :: struct {
	constraint: UiDimensionConstraint,
	value: f32,
}

UiLayout :: struct {
	type  : UiLayoutType,
	flags : bit_set[UiLayoutFlags],

	rect   : UiRect,
	width  : UiDimensionConstraint,
	height : UiDimensionConstraint,
}

UiState :: struct {
	root: UiNode
}

global_ui_state : UiState;

// The UI has a HTML-like coordinate system. 
// This is unlike the game world, which has a mathematical coordinate system.

__ui_get_current_rect :: proc(ui: ^UiState) -> UiRect {
	if len(ui.stack) == 0 { return {} }
	return ui.stack[len(ui.stack) - 1]
}

ui_get_rect :: proc() -> UiRect {
	return __ui_get_current_rect(&global_ui_state)
}

ui_get_rect_width :: proc() -> f32 {
	rect := ui_get_rect()
	return rect.right - rect.left
}

ui_get_rect_height :: proc() -> f32 {
	rect := ui_get_rect()
	return rect.bottom - rect.top
}

ui_begin :: proc(window_size: Vector2) {
	ui := &global_ui_state

	assert(len(ui.stack) == 0)

	ui_begin_rect(UiRect{ top = 0, left = 0, bottom = window_size.y, right = window_size.x })
}

ui_end :: proc() {
	ui := &global_ui_state

	ui_end_rect()

	assert(len(ui.stack) == 0)
}

ui_begin_rect :: proc(rect: UiRect) {
	ui := &global_ui_state

	append(&ui.stack, rect);

	_update_scissor_mode()
}

_update_scissor_mode :: proc() {
	ui := &global_ui_state

	if len(ui.stack) == 0 {
		rl.EndScissorMode()
		return
	}

	rect := ui_get_rect()

	x      := c.int(rect.left)
	y      := c.int(rect.top)
	width  := c.int(rect.right - rect.left)
	height := c.int(rect.bottom - rect.top)

	rl.BeginScissorMode(x, y, width, height);
}

ui_end_rect :: proc() {
	ui := &global_ui_state
	pop(&ui.stack)

	_update_scissor_mode()
}

UiSplitType :: enum {
	Vertical,
	Horizontal,
}

ui_split :: proc(type: UiSplitType, flex_start, divider_size, flex_end: f32) -> (UiRect, UiRect, UiRect) {
	ui := &global_ui_state

	rect := __ui_get_current_rect(ui);

	switch (type) {
	case .Vertical:
		height := rect.bottom - rect.top - divider_size

		top := rect; {
			if height > 0 {
				top.bottom = height * flex_start
			} else {
				top.bottom = 0
			}
		}
		
		middle := rect; {
			middle.top = top.bottom;
			middle.bottom = middle.top + divider_size
		}

		bottom := rect; {
			bottom.top = middle.bottom
		}

		return top, middle, bottom
	case .Horizontal:
		width := rect.right - rect.left - divider_size

		left := rect; {
			if width > 0 {
				left.right = width * flex_start
			} else {
				left.right = 0
			}
		}
		
		middle: = rect; {
			middle.left = left.right;
			middle.right = middle.left + divider_size
		}

		right := rect; {
			right.left = middle.right
		}

		return left, middle, right
	}

	panic("unreachable")
}

// Purely to catch missing calls to end(), has no behaviour
ui_begin_component :: proc(component_name: string) {
	ui := &global_ui_state
	append(&ui.component_stack, component_name)
}

// Purely to catch missing calls to end(), has no behaviour
ui_end_component :: proc(component_name: string) {
	ui := &global_ui_state

	pushed_component := pop(&ui.component_stack)
	assert(pushed_component == component_name)
}

ui_begin_rect_piece :: proc(rect: ^UiRect, amount: UiRect) -> (has_room: bool) {
	rect := ui_get_rect()

	rect.left += amount.left;
	rect.top += amount.top;
	rect.right -= amount.right;
	rect.bottom -= amount.bottom;

	has_room = true

	if rect.left > rect.right {
		rect.left = rect.right
		has_room = false
	}

	if rect.top > rect.right {
		rect.top = rect.right
		has_room = false
	}

	if rect.right < rect.left {
		rect.right = rect.left
		has_room = false
	}

	if rect.bottom < rect.left {
		rect.bottom = rect.left
		has_room = false
	}

	return
}

