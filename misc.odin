package main

unordered_remove_slice :: proc(slice: ^[]$T, idx: int) {
	assert(len(slice) > 0)
	slice[idx] = slice[len(slice) - 1]
	slice^ = slice[:len(slice) - 1]
}

