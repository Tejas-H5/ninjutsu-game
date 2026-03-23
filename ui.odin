package main

import "core:fmt"
import "core:strings"
import "core:c"
import rl "vendor:raylib"

UiString :: cstring; // Whatever string our current rendering API uses
UiSize   :: c.int;    // whatever length our rendering API uses

fmt_tprintfcstr :: proc(format: string, args: ..any) -> UiString {
	sb := strings.builder_make_none(context.temp_allocator)
	fmt.sbprintf(&sb, format, ..args)
	return UiString(strings.to_cstring(&sb))
}

measure_text :: proc(str: UiString, size: UiSize) -> UiSize {
	return UiSize(rl.MeasureText(cstring(str), c.int(size)))
}

ui_text :: proc(str: UiString, size: UiSize) -> UiText {
	return {
		width = measure_text(str, size),
		height = size,
		text = str,
	}
}

UiText :: struct {
	text: UiString,
	width, height: UiSize,
}


