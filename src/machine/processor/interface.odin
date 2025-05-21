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

package processor

import "core:container/queue"
import "core:log"
import "vxt:machine/peripheral"

get_registers :: proc() -> ^peripheral.Peripheral_CPU_Registers {
	return &registers
}

flush_prefetch :: proc() {
	state.flush = true
}

exec_cycles :: proc(#any_int cycles: uint = 1) {
	state.ex_cycles += cycles
}

reset :: proc() {
	state.instruction.rep_prefix = 0

	state.flush = false
	queue.clear(&state.prefetch_queue)

	registers = peripheral.Peripheral_CPU_Registers {
		debug = registers.debug, // Preserve flag for external debugger.
		flags = flags_to_set(validate_flags(byte(0))),
		ip    = 0,
		cs    = 0xFFFF,
	}
}

initialize :: proc(options: peripheral.Peripheral_CPU_Options) {
	state.cpu_options = options
	queue.init_from_slice(&state.prefetch_queue, state.prefetch_buffer[:])

	state.reserved = {.RESERVED_0}
	if .FLAG_286 not_in state.cpu_options {
		state.reserved += {.RESERVED_3, .RESERVED_4, .RESERVED_5, .RESERVED_6}
	}

	ok: bool
	if _, interrupt_controler, ok = peripheral.get_peripheral_from_class(.PIC); !ok {
		log.warn("Interrupt controller is not connected!")
	}
}

step :: proc() -> (cycles: uint, repeat, div_zero: bool, ok := true) {
	using state.instruction

	state.ex_cycles = 0
	state.bu_cycles = 0

	if rep_prefix == 0 {
		decode_prepare()
		decode_prefix()
		decode_opcode()

		write_cpu_trace()
		registers.ip += u16(stream.size)
	}

	if valid {
		if (rep_prefix != 0) && (registers.cx == 0) {
			rep_prefix = 0
			state.ex_cycles = 1
		} else {
			exec()
			div_zero = state.div_zero
		}
	} else {
		registers.debug = true
		state.ex_cycles = 3 // Just like a NOP?
		rep_prefix = 0 // Break repeat here!
		ok = false
	}

	// We expect cycle timing at this point!
	assert(state.ex_cycles > 0)

	// This all happes after opcode is executed.
	if rep_prefix != 0 {
		using registers
		cx -= 1

		switch opcode.raw {
		case 0xA6, 0xA7, 0xAE, 0xAF:
			if rep_prefix == 0xF2 {
				// REPNE/REPNZ
				rep_prefix &= (.ZERO in flags) ? 0 : 0xFF
			} else if rep_prefix == 0xF3 {
				// REP/REPE
				rep_prefix &= (.ZERO not_in flags) ? 0 : 0xFF
			}
		}
	}

	check_interrupts()

	// Update prefetch queue.
	if state.flush {
		state.flush = false
		queue.clear(&state.prefetch_queue)
	} else {
		n := max(int(state.ex_cycles) - int(state.bu_cycles), 0) / 2
		for i := 0; i < n; i += 1 {
			ln := u16(queue.len(state.prefetch_queue))
			if ln >= PREFETCH_QUEUE_SIZE {
				break
			}
			queue.push_back(&state.prefetch_queue, read_segment_byte(.CODE, registers.ip + ln))
		}
	}

	cycles = max(state.ex_cycles, state.bu_cycles)
	repeat = rep_prefix != 0
	return
}

destroy :: proc() {
	close_cpu_trace()
}
