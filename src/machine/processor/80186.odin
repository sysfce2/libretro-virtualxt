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

import "vxt:machine/peripheral"

decode_80186 :: proc() {
	using state.instruction
	valid = true

	// Let's not bother with correct 186 timings since
	// they do not represent a real CPU at this point.
	exec_cycles()

	switch opcode.raw {
	case 0x60:
		// PUSHA
		exec = proc() {
			using registers
			r := sp

			stack_push(ax)
			stack_push(cx)
			stack_push(dx)
			stack_push(bx)
			stack_push(r)
			stack_push(bp)
			stack_push(si)
			stack_push(di)
		}
	case 0x61:
		// POPA
		exec = proc() {
			using registers
			di = stack_pop()
			si = stack_pop()
			bp = stack_pop()
			stack_pop() // sp
			bx = stack_pop()
			dx = stack_pop()
			cx = stack_pop()
			ax = stack_pop()
		}
	case 0x62:
		// BOUND
		exec = proc() {
			idx := i16(load_rw())
			bmin, bmax := load_m1616()

			if (idx < i16(bmin)) || (idx > i16(bmax)) {
				trigger_interrupt(.BOUND_INT)
			}
		}
		decode_mod_reg_rm()
	case 0x68:
		// PUSH iw - Push immediate word
		exec = proc() {
			stack_push(state.instruction.iw1)
		}
		iw1 = decode_fetch_word()
	case 0x69:
		// IMUL rw,ew,iw - Signed multiply (rw = EA word * imm word)
		exec = proc() {
			store_rw(IMUL_w(load_ew(), state.instruction.iw1))
		}
		decode_mod_reg_rm()
		iw1 = decode_fetch_word()
	case 0x6A:
		// PUSH ib - Push immediate sign-extended byte
		exec = proc() {
			stack_push(state.instruction.ib)
		}
		ib = decode_fetch_byte()
	case 0x6B:
		// IMUL rw,ew,ib - Signed multiply (rw = EA word * imm byte)
		exec = proc() {
			store_rw(IMUL_w(load_ew(), u16(i8(state.instruction.ib))))
		}
		decode_mod_reg_rm()
		ib = decode_fetch_byte()
	case 0x6C:
		// INSB - Input byte from port DX into ES:[DI]
		exec = proc() {
			using registers
			write_segment_byte(.EXTRA, di, peripheral.peripheral_interface.read_port(dx))
			di = (.DIRECTION in flags) ? (di - 1) : (di + 1)
		}
	case 0x6D:
		// INSW - Input word from port DX into ES:[DI]
		exec = proc() {
			using registers
			write_segment_word(.EXTRA, di, (u16(peripheral.peripheral_interface.read_port(dx + 1)) << 8) | u16(peripheral.peripheral_interface.read_port(dx)))
			di = (.DIRECTION in flags) ? (di - 2) : (di + 2)
		}
	case 0x6E:
		// OUTSB - Output byte DS:[SI] to port number DX
		exec = proc() {
			using registers
			peripheral.peripheral_interface.write_port(dx, read_segment_byte(state.base_ds, si))
			si = (.DIRECTION in flags) ? (si - 1) : (si + 1)
		}
	case 0x6F:
		// OUTSW - Output word DS:[SI] to port number DX
		exec = proc() {
			using registers
			data := read_segment_word(state.base_ds, si)
			peripheral.peripheral_interface.write_port(dx, byte(data))
			peripheral.peripheral_interface.write_port(dx + 1, byte(data >> 8))
			si = (.DIRECTION in flags) ? (si - 2) : (si + 2)
		}
	case 0xC0:
		decode_mod_reg_rm()
		ib = decode_fetch_byte()
		state.shift_count = ib
		decode_shift_byte()
	case 0xC1:
		decode_mod_reg_rm()
		ib = decode_fetch_byte()
		state.shift_count = ib
		decode_shift_word()
	case 0xC8:
		// ENTER iw,ib - Make stack frame for procedure parameters
		exec = proc() {
			using state.instruction

			stack_push(registers.bp)
			bp := registers.bp
			sp := registers.sp

			if level := ib & 0x1F; level > 0 {
				for {
					if level -= 1; level == 0 {
						break
					}
					bp -= 2
					stack_push(read_segment_word(.STACK, bp))
				}
				stack_push(sp)
			}

			registers.sp -= iw1
			registers.bp = sp
		}
		iw1 = decode_fetch_word()
		ib = decode_fetch_byte()
	case 0xC9:
		// LEAVE - Set SP to BP, then POP BP
		exec = proc() {
			using registers
			sp = bp
			bp = stack_pop()
		}
	case:
		valid = false
	}
}
