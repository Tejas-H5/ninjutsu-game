package game

import "core:fmt"
import "core:strings"
import "core:c"
import "core:math"
import "core:math/linalg"
import "core:odin/parser"
import "core:reflect"
import "core:odin/ast"
import "core:strconv"

import rl "vendor:raylib";

DevtoolsMode :: enum {
	EditingOutline,
	PlacingDecorations,
}

PLACEMENT_CHOICES :: []DecorationType {
	.DeadTree1, .SeaUrchin, .LiveTree, .LiveTreeLeaves,
}

Devtools :: struct {
	dragging : bool,

	has_dir_input : bool,

	adhoc   : [dynamic]Vector2i,
	outline : ^[dynamic]Vector2i,

	mode    : DevtoolsMode,
	curr_placing_idx : int,
	curr_placing_size : f32,
	placed : [dynamic]Decoration,
}

init_outline :: proc(points: []Vector2i) -> [dynamic]Vector2i {
	outline := make([dynamic]Vector2i)
	for point in points {
		append(&outline, point)
	}
	return outline
}

init_devtools :: proc(devtools : ^Devtools) {

	// Current outline
	devtools.mode = .EditingOutline
	devtools.adhoc = init_outline([]Vector2i{{0, 0}})
	devtools.outline = &devtools.adhoc
}

run_devtools :: proc(state: ^GameState, devtools: ^Devtools, phase: RenderPhase) {
	placement_choices := PLACEMENT_CHOICES
	currently_placing := placement_choices[devtools.curr_placing_idx]

	dir := state.input.direction
	dir_pressed := false
	if state.input.direction != 0 {
		if !devtools.has_dir_input {
			devtools.has_dir_input = true
			dir_pressed = true
		}
	} else {
		devtools.has_dir_input = false
	}

	{
		text := text_column_make({ UiLength(state.window_size.x) - 10, 10 }, 30, 10, RIGHT_ALIGN)

		draw_text_row_screenspace(&text, "[Devtools]: %v", devtools.mode)
		switch devtools.mode {
		case .EditingOutline:
			draw_text_row_screenspace(&text, "points: %v", len(devtools.outline))
		case .PlacingDecorations:
			draw_text_row_screenspace(&text, "Currently placing: %v", currently_placing)
			draw_text_row_screenspace(&text, "size: %v", devtools.curr_placing_size)
		}
	}

	if phase == .Render {
		if state.player.viewing_map {
			mouse_pos := to_game_pos(state, state.input.screen_position)
			ground_pos := world_pos_to_ground_pos(mouse_pos)
			ground_pos_world := ground_pos_to_world_pos(ground_pos)
			draw_rect(state, ground_pos_world + CHUNK_GROUND_HALF_OFFSET, CHUNK_GROUND_SIZE, COL_DEBUG, .Outline)
		}

		if rl.IsKeyPressed(.P) {
			log_mouse_position(state)
		}
		if rl.IsKeyPressed(.G) {
			log_ground_position(state)
		}
	}


	switch devtools.mode {
	case .EditingOutline:
		if phase == .Render {
			if len(devtools.outline) > 0 {

				if state.input.click && state.input.shift {
					mouse_pos := to_game_pos(state, state.input.screen_position)
					a, ok := get_closest_edge_point_idx(mouse_pos, devtools.outline[:])
					if ok {
						ground_pos := world_pos_to_ground_pos(mouse_pos)
						append(devtools.outline, ground_pos)
						log_outline(devtools.outline[:])
					}
				} else if state.input.rclick {
					mouse_pos := to_game_pos(state, state.input.screen_position)
					a := get_closest_outline_point_idx(mouse_pos, devtools.outline[:])
					ordered_remove(devtools.outline, a)
				} else if state.input.click_hold {
					mouse_pos := to_game_pos(state, state.input.screen_position)
					a := get_closest_outline_point_idx(mouse_pos, devtools.outline[:])
					devtools.outline[a] = world_pos_to_ground_pos(mouse_pos)
					devtools.dragging = true
				} else if rl.IsKeyPressed(.R) {
					clear(devtools.outline)
					append(devtools.outline, Vector2i{0, 0})
				} else {
					if devtools.dragging {
						devtools.dragging = false
						log_outline(devtools.outline[:])
					}
				} 

				for i in 1..<len(devtools.outline) {
					prev := ground_pos_to_world_pos(devtools.outline[i-1]) + CHUNK_GROUND_HALF_OFFSET
					curr := ground_pos_to_world_pos(devtools.outline[i]) + CHUNK_GROUND_HALF_OFFSET
					draw_line(state, prev, curr, 3 / state.camera.zoom, COL_DEBUG)
				}
				for point in devtools.outline {
					pos := ground_pos_to_world_pos(point) + CHUNK_GROUND_HALF_OFFSET
					draw_rect(state, pos, 10 / state.camera.zoom, COL_DEBUG, .Solid)
				}
			}
		}
	case .PlacingDecorations:
		if phase == .Render {
			wheel := rl.GetMouseWheelMove()
			if wheel != 0 {
				if state.input.shift {
					wheel *= 100
				}
				devtools.curr_placing_size += wheel
				devtools.curr_placing_size = math.clamp(devtools.curr_placing_size, 20, state.large_items_grid.grid_size)
			}

			if dir_pressed {
				if dir.x > 0 {
					devtools.curr_placing_idx += 1
					if devtools.curr_placing_idx >= len(PLACEMENT_CHOICES) {
						devtools.curr_placing_idx = 0
					}
				} else if dir.x < 0 {
					devtools.curr_placing_idx -= 1
					if devtools.curr_placing_idx < 0 {
						devtools.curr_placing_idx = len(PLACEMENT_CHOICES) - 1
					}
				}
			}

			pos := to_game_pos(state, state.input.screen_position)
			col := COL_WHITE
			col.a = 0.5
			draw_decoration(state, currently_placing, pos, devtools.curr_placing_size, col)
			for decoration in devtools.placed {
				draw_decoration(state, decoration.type, decoration.pos, decoration.size, col)
			}

			if state.input.click {
				append(&devtools.placed, Decoration{ type=currently_placing, size=devtools.curr_placing_size, pos=pos })
				log_decorations(devtools)
			} 
		}
	}
}


get_closest_outline_point_idx :: proc(mouse_pos: Vector2, points: []Vector2i) -> int {
	a := 0
	distance := math.INF_F32
	for point, i in points {
		this_distance := linalg.length(mouse_pos - ground_pos_to_world_pos(point))
		if this_distance < distance {
			distance = this_distance
			a = i
		}
	}

	return a
}

get_closest_edge_point_idx :: proc(mouse_pos: Vector2, points: []Vector2i) -> (int, bool) {
	a, b := 0, 0
	distance := math.INF_F32
	for i in 0..<len(points) {
		prev := ground_pos_to_world_pos(points[i])
		next := ground_pos_to_world_pos(points[(i + 1) % len(points)])

		mid := prev + (next - prev) / 2
		this_distance := linalg.length(mouse_pos - mid)
		if this_distance < distance {
			distance = this_distance
			a, b = i, i + 1
		}
	}	

	return a, a != b
}

// Braces were screwing up navigation, so I've just moved this templating code to the bottom
log_outline :: proc(outline: []Vector2i) {
	debug_log_intentional("Outline so far:")
	debug_log_intentional("  []Vector2i {{")
	for point in outline {
		debug_log_intentional("    Vector2i {{ %v, %v },", point.x, point.y)
	}
	debug_log_intentional("    Vector2i {{ %v, %v },", outline[0].x, outline[0].y)
	debug_log_intentional("  }")
}

log_decorations :: proc(devtools: ^Devtools) {
	debug_log_intentional("Decorations placed: ")
	for decoration in devtools.placed {
		// DecorationPlacement
		debug_log_intentional("{{ .%v, %v, {{ %v, %v }, your_colour_here },", decoration.type, decoration.size, decoration.pos.x, decoration.pos.y)
	}
}

log_mouse_position :: proc(state: ^GameState) {
	pos := to_game_pos(state, state.input.screen_position)
	debug_log_intentional("Vector2{{ %v, %v }", pos.x, pos.y)
}

log_ground_position :: proc(state: ^GameState) {
	pos := to_game_pos(state, state.input.screen_position)
	ground := world_pos_to_ground_pos(pos)
	debug_log_intentional("Vector2i{{ %v, %v }", ground.x, ground.y)
}

log_code_offset :: proc(offset: Vector2i, code: string) {
	// NOTE: Couldn't figure out how to do it with code:ast, so I'm doing it like this for now.

	Parser :: struct {
		code : string,
		idx  : int, 
	}

	parser : Parser
	parser.code = code

	advance_keyword :: proc(parser: ^Parser, keyword: string) -> bool {
		i := 0
		for ; i < len(keyword); i += 1 {
			code_idx := parser.idx + i
			if code_idx >= len(parser.code)        do return false
			if parser.code[code_idx] != keyword[i] do return false
		}

		parser.idx += i
		return true
	}

	advance_ws :: proc(parser: ^Parser) {
		for parser.idx < len(parser.code) {
			if !strings.is_space(rune(parser.code[parser.idx])) {
				return;
			}
			parser.idx += 1
		}
	}

	advance_integer :: proc(parser: ^Parser) -> int {
		start := parser.idx
		for parser.idx < len(parser.code) {
			char := parser.code[parser.idx]
			if '0' <= char && char <= '9' {
				parser.idx += 1
				continue
			}
			break;
		}

		val, _ := strconv.parse_int(parser.code[start:parser.idx])
		return val
	}

	last_slice_idx := 0
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	n := len(code)
	for parser.idx < n {
		if advance_keyword(&parser, "[]Vector2i") {
			// ignore
		} else if advance_keyword(&parser, "Vector2i") {
			advance_ws(&parser)
			if (!advance_keyword(&parser, "{")) {
				debug_log_intentional("No {{ found after Vector2i")
				return
			}

			fmt.sbprint(&sb, code[last_slice_idx:parser.idx])
			last_slice_idx = parser.idx

			advance_ws(&parser)
			x := advance_integer(&parser)
			advance_ws(&parser)
			advance_keyword(&parser, ",")
			advance_ws(&parser)
			y := advance_integer(&parser)
			advance_ws(&parser)
			advance_keyword(&parser, ",")
			advance_keyword(&parser, "}")

			last_slice_idx = parser.idx

			// reuse existing {
			fmt.sbprint(&sb, x + offset.x, ",", y + offset.y, "}")

			continue
		}

		parser.idx += 1
	}

	if last_slice_idx != n {
		fmt.sbprint(&sb, code[last_slice_idx:])
		last_slice_idx = parser.idx
	}

	debug_log_intentional("%v", strings.to_string(sb))
}
