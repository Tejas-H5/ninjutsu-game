package main

import "core:fmt"

debug_log :: proc(args: ..any) {
	fmt.print("[debug_log] ")

	for arg in args {
		fmt.printf("%v, ", arg)
	}

	fmt.print("\n")
}
