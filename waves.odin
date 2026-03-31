package main

GameWaves :: struct {
	wave_number : int,
	game_waves : [dynamic]GameWave,
}

GameWave :: struct {
	enemies : [dynamic]Enemy,
}
