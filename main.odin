package main

import rl "vendor:raylib";

main :: proc() {
	rl.InitWindow(0, 0, "Ninja")
	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})

	defer rl.CloseWindow();

	state: GameState
	init_game(&state)

	for !rl.WindowShouldClose() {
		produce_frame(&state)
	}
}
