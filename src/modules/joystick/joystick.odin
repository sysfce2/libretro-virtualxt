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

package joystick

import "core:math/bits"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"
import "vxt:machine/peripheral"
import rt "vxt:xruntime"

Stick :: struct {
	axis:     [2]i16,
	timeouts: [2]f64,
	buttons:  byte,
}

Joystick :: struct {
	time_stamp, ticker: f64,
	sticks:             [2]Stick,
	input_state_cb:     retro.input_state_t,
	pull_timer_id:      peripheral.Peripheral_Timer_ID,
}

axis_timeout :: proc(axis: int) -> f64 {
	position_to_ohm :: proc(axis: int) -> f64 {
		return (f64(axis + 1) / f64(bits.U16_MAX)) * 60000
	}
	return (24.2 + 0.011 * position_to_ohm(axis)) * 1000
}

install :: proc(joystick: ^Joystick) -> bool {
	using peripheral
	register_io_address_at(joystick, 0x201)
	register_timer(joystick)
	joystick.pull_timer_id = register_timer(joystick, 1000000 / 60)
	return true
}

config :: proc(joystick: ^Joystick, name, key: string, value: any) -> bool {
	if (name == "joystick") && (key == "set_input_state_callback") {
		joystick.input_state_cb = value.(retro.input_state_t)
	}
	return true
}

io_in :: proc(joystick: ^Joystick, port: u16) -> byte {
	data: byte = 0xF0
	d := joystick.ticker - joystick.time_stamp

	for i: uint; i < 2; i += 1 {
		using stick := &joystick.sticks[i]
		shift := i * 2

		for j: byte; j < 2; j += 1 {
			timeouts[j] -= d
			if timeouts[j] > 0 {
				data |= (j + 1) << shift
			} else {
				timeouts[j] = 0
			}
		}

		data ~= buttons << (4 + shift)
	}
	return data
}

io_out :: proc(joystick: ^Joystick, port: u16, _: byte) {
	joystick.time_stamp = 0
	joystick.ticker = 0

	for i: int; i < 2; i += 1 {
		using stick := &joystick.sticks[i]
		timeouts[0] = axis_timeout(int(axis[0]) - bits.I16_MIN)
		timeouts[1] = axis_timeout(int(axis[1]) - bits.I16_MIN)
	}
}

timer :: proc(using joystick: ^Joystick, id: peripheral.Peripheral_Timer_ID, cycles: uint) {
	if ticker < 1000000 {
		ticker += f64(cycles) / (f64(peripheral.peripheral_interface.frequency()) / 1000000)
	}

	if id == pull_timer_id {
		if input_state_cb == nil {
			input_state_cb = retro_callbacks.input_state
			assert(input_state_cb != nil)
		}

		for i: u32; i < 2; i += 1 {
			using retro

			stick := &joystick.sticks[i]
			stick.axis[0] = (input_state_cb(i, DEVICE_ANALOG, DEVICE_INDEX_ANALOG_LEFT, DEVICE_ID_ANALOG_X) / 256) + 128
			stick.axis[1] = (input_state_cb(i, DEVICE_ANALOG, DEVICE_INDEX_ANALOG_LEFT, DEVICE_ID_ANALOG_Y) / 256) + 128

			stick.buttons = (bool(input_state_cb(i, DEVICE_JOYPAD, 0, DEVICE_ID_JOYPAD_A)) ? 1 : 0)
			stick.buttons = (bool(input_state_cb(i, DEVICE_JOYPAD, 0, DEVICE_ID_JOYPAD_B)) ? 2 : 0)
		}
	}
}

@(init)
joystick :: proc "contextless" () {
	context = rt.default_context
	peripheral.register_constructor(proc(_: string) {
		_, cb := peripheral.allocate(Joystick)

		cb.install = install
		cb.timer = timer
		cb.config = config
		cb.io_in = io_in
		cb.io_out = io_out

		cb.name = proc(_: ^Joystick) -> string {
			return "Gameport Joystick(s)"
		}
	})
}
