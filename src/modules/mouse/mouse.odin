#+private

// Copyright (c) 2019-2025 Andreas T Jonsson <mail@andreasjonsson.se>
//
// This software is provided 'as-is', without any express or implied
// warranty. In no event will the authors be held liable for any damages
// arising from the use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it
// freely, subject to the following restrictions:
//
// 1. The origin of this software must not be misrepresented; you must not
//    claim that you wrote the original software. If you use this software
//    in a product, an acknowledgment in the product documentation would be
//    appreciated but is not required.
//
// 2. Altered source versions must be plainly marked as such, and must not be
//    misrepresented as being the original software.
//
// 3. This notice may not be removed or altered from any source
//    distribution.

package mouse

import "core:log"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"
import "vxt:machine/peripheral"

MAX_BUFFER_SIZE :: 8 * 3

Mouse :: struct {
	irq:            uint,
	base_port:      u16,
	registers:      [8]byte,
	buffer:         [dynamic]byte,
	button_state:   byte,
	input_state_cb: retro.input_state_t,
}

install :: proc(mouse: ^Mouse) -> bool {
	using peripheral
	register_io_address_range(mouse, mouse.base_port, mouse.base_port + 7)
	register_timer(mouse, 1000000 / 40) // Think this is standard poll-rate?
	return true
}

config :: proc(mouse: ^Mouse, name, key: string, value: any) -> (ok := true) {
	if name != "mouse" {
		return
	}

	switch key {
	case "set_irq":
		mouse.irq = value.(uint)
	case "set_base_port":
		mouse.base_port = value.(u16)
	case "set_input_state_callback":
		mouse.input_state_cb = value.(retro.input_state_t)
	case:
		ok = false
	}
	return
}

io_in :: proc(using mouse: ^Mouse, port: u16) -> byte {
	reg := port & 7
	switch reg {
	case 0:
		// Serial Data Register
		if data, ok := pop_front_safe(&mouse.buffer); ok {
			peripheral.peripheral_interface.interrupt(mouse.irq)
			return data
		}
		return 0
	case 5:
		// Line Status Register
		return (len(mouse.buffer) > 0) ? 0x61 : 0x60
	case:
		return registers[reg]
	}
}

io_out :: proc(using mouse: ^Mouse, port: u16, data: byte) {
	reg := port & 7
	rval := registers[reg]
	registers[reg] = data

	if reg == 4 { 	// Modem Control Register
		if (data & 1) != (rval & 1) {
			clear(&buffer)
			push_data(mouse, byte('M'))
			log.info("Mouse reset!")
		}
	}
}

timer :: proc(using mouse: ^Mouse, _: peripheral.Peripheral_Timer_ID, _: uint) {
	if input_state_cb == nil {
		input_state_cb = retro_callbacks.input_state
		assert(input_state_cb)
	}

	if len(buffer) > MAX_BUFFER_SIZE {
		return
	}

	x := input_state_cb(0, retro.DEVICE_MOUSE, 0, retro.DEVICE_ID_MOUSE_X)
	y := input_state_cb(0, retro.DEVICE_MOUSE, 0, retro.DEVICE_ID_MOUSE_Y)
	l := input_state_cb(0, retro.DEVICE_MOUSE, 0, retro.DEVICE_ID_MOUSE_LEFT) & 1
	r := input_state_cb(0, retro.DEVICE_MOUSE, 0, retro.DEVICE_ID_MOUSE_RIGHT) & 1

	state := byte((l << 1) | r)
	if (state == mouse.button_state) && (x == 0) && (y == 0) {
		return
	}
	mouse.button_state = state

	upper: byte = 0
	if x < 0 {
		upper = 0x3
	}
	if y < 0 {
		upper |= 0xC
	}

	push_data(mouse, 0x40 | ((state & 3) << 4) | upper)
	push_data(mouse, byte(x & 0x3F))
	push_data(mouse, byte(y & 0x3F))
}

push_data :: proc(mouse: ^Mouse, data: byte) {
	append(&mouse.buffer, data)
	peripheral.peripheral_interface.interrupt(mouse.irq)
}
