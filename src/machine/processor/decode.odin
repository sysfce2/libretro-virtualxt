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

package processor

import "core:container/queue"

decode_prepare :: proc() {
	state.invert_quotient = false
	state.div_zero = false

	state.base_ds = .DATA
	state.base_ss = .STACK

	state.instruction = Instruction {
		stream = {ip = registers.ip, addr = get_physical_address(Segment.CODE, registers.ip)},
	}
}

decode_prefix :: proc() {
	using state, state.instruction
	for {
		opcode.raw = decode_fetch_byte()

		// TODO: Not sure about this. Perhaps handle this in a nicer way?
		registers.ip += 1
		stream.size = 0

		switch opcode.raw {
		case 0x26:
			// Segment Ovrride: ES
			base_ds = .EXTRA
			base_ss = .EXTRA
		case 0x2E:
			// Segment Ovrride: CS
			base_ds = .CODE
			base_ss = .CODE
		case 0x36:
			// Segment Ovrride: SS
			base_ds = .STACK
			base_ss = .STACK
		case 0x3E:
			// Segment Ovrride: DS
			base_ds = .DATA
			base_ss = .DATA
		case 0xF0: // LOCK
		case 0xF2, 0xF3:
			// REPNE, REP/REPE
			rep_prefix = opcode.raw
		case:
			stream.op_ip = registers.ip

			if rep_prefix != 0 {
				switch opcode.raw {
				case 0xA4 ..= 0xA7, 0xAA ..= 0xAF:
					return // Opcode is valid to repeat.
				case 0x6C ..= 0x6F:
					if .USE_186 in cpu_options {
						return // Valid on 80186
					}
				case 0xF6, 0xF7:
					invert_quotient = true // Not valid but has side effects for IDIV.
				}
				rep_prefix = 0
			}
			return
		}
	}
}

decode_shift_byte :: proc() {
	using state.instruction

	switch mode.reg {
	case 0:
		// ROL eb,X
		exec = proc() {
			store_eb(ROL(load_eb(), state.shift_count))
			exec_cycles(4)
		}
	case 1:
		// ROR eb,X
		exec = proc() {
			store_eb(ROR(load_eb(), state.shift_count))
			exec_cycles(4)
		}
	case 2:
		// RCL eb,X
		exec = proc() {
			store_eb(RCL(load_eb(), state.shift_count))
			exec_cycles(4)
		}
	case 3:
		// RCR eb,X
		exec = proc() {
			store_eb(RCR(load_eb(), state.shift_count))
			exec_cycles(4)
		}
	case 4, 6:
		// SHL/SAL eb,X
		exec = proc() {
			store_eb(SHL(load_eb(), state.shift_count))
			exec_cycles(4)
		}
	case 5:
		// SHR eb,X
		exec = proc() {
			store_eb(SHR(load_eb(), state.shift_count))
			exec_cycles(4)
		}
	case 7:
		// SAR eb,X
		exec = proc() {
			store_eb(SAR(load_eb(), state.shift_count))
			exec_cycles(4)
		}
	}
}

decode_shift_word :: proc() {
	using state.instruction

	switch mode.reg {
	case 0:
		// ROL ew,X
		exec = proc() {
			store_ew(ROL(load_ew(), state.shift_count))
			exec_cycles(4)
		}
	case 1:
		// ROR ew,X
		exec = proc() {
			store_ew(ROR(load_ew(), state.shift_count))
			exec_cycles(4)
		}
	case 2:
		// RCL ew,X
		exec = proc() {
			store_ew(RCL(load_ew(), state.shift_count))
			exec_cycles(4)
		}
	case 3:
		// RCR ew,X
		exec = proc() {
			store_ew(RCR(load_ew(), state.shift_count))
			exec_cycles(4)
		}
	case 4, 6:
		// SHL/SAL ew,X
		exec = proc() {
			store_ew(SHL(load_ew(), state.shift_count))
			exec_cycles(4)
		}
	case 5:
		// SHR ew,X
		exec = proc() {
			store_ew(SHR(load_ew(), state.shift_count))
			exec_cycles(4)
		}
	case 7:
		// SAR ew,X
		exec = proc() {
			store_ew(SAR(load_ew(), state.shift_count))
			exec_cycles(4)
		}
	}
}

decode_opcode :: proc() {
	decode_8086()
	if !state.instruction.valid && (.USE_186 in state.cpu_options) {
		decode_80186()
	}
	exec_cycles(state.instruction.ea_cycles)
}

decode_fetch_byte :: proc() -> byte {
	using state.instruction

	data, ok := queue.pop_front_safe(&state.prefetch_queue)
	if !ok {
		data = read_segment_byte(.CODE, registers.ip + u16(stream.size))
	}

	stream.data[stream.size] = data
	stream.size += 1
	return data
}

decode_fetch_word :: proc() -> u16 {
	low := decode_fetch_byte()
	high := decode_fetch_byte()
	return (u16(high) << 8) | u16(low)
}
