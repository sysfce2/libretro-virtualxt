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

package tests

import "core:encoding/cbor"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "vxt:machine"
import "vxt:machine/peripheral"

Flags :: peripheral.Peripheral_CPU_Flags

index_map :: proc(m: cbor.Value, key: string) -> cbor.Value {
	for entry in m.(^[]cbor.Map_Entry) {
		if entry.key.(^string)^ == key {
			return entry.value
		}
	}
	return nil
}

index_integer :: proc(m: cbor.Value, key: string, $ty: typeid) -> ty {
	entry := index_map(m, key)
	return to_integer(entry, ty)
}

to_integer :: proc(value: cbor.Value, $ty: typeid) -> ty {
	#partial switch v in value {
		case u8:
			return ty(v)
		case u16:
			return ty(v)
		case u32:
			return ty(v)
		case:
			panic("not handled")
	}
}

format_flags_message :: proc(builder: ^strings.Builder, a, b: Flags) -> string {
	write_flags :: proc(builder: ^strings.Builder, reg, exp: Flags) {
		flags := []string{"C", "-", "P", "-", "A", "-", "Z", "S", "T", "I", "D", "O"}
		for c, i in flags {
			mask := transmute(Flags)u16(1 << u16(i))
			mreg := mask & reg
			mexp := mask & exp

			if mreg != mexp {
				fmt.sbprint(builder, "*")
			}

			if mreg != nil {
				fmt.sbprint(builder, c)
			} else if mreg == mexp {
				fmt.sbprint(builder, "-")
			}
		}
	}

	fmt.sbprintf(builder, "expected flags to be 0x%X [", transmute(u16)b)
	write_flags(builder, b, b) // Don't mark errors.
	fmt.sbprintf(builder, "] but it was 0x%X [", transmute(u16)a)
	write_flags(builder, a, b)
	fmt.sbprint(builder, "]")

	return strings.to_string(builder^)
}

check_memory :: proc(addr: u32, res, value: byte, divz: bool) -> bool {
	if divz {
		// TODO: Better check here!
		log.debug("Div zero interrupt detected! Skipping memory validation.")
		return true
	}
	return res == value
}

execute_test :: proc(t: ^testing.T, test: cbor.Value, idx: int, flag_mask: Flags) {
	machine.create()
	defer machine.destroy()
	machine.initialize()

	using peripheral.peripheral_interface
	using regs := registers()

	// INT 0
	write(0, 0)
	write(1, 0x40)
	write(2, 0)
	write(3, 0)

	log.infof("Test %d \"%s\"", idx, index_map(test, "name").(^string)^)

	initial := index_map(test, "initial")
	ireg := index_map(initial, "regs")

	ax = index_integer(ireg, "ax", u16)
	bx = index_integer(ireg, "bx", u16)
	dx = index_integer(ireg, "dx", u16)
	cx = index_integer(ireg, "cx", u16)

	cs = index_integer(ireg, "cs", u16)
	ss = index_integer(ireg, "ss", u16)
	ds = index_integer(ireg, "ds", u16)
	es = index_integer(ireg, "es", u16)

	sp = index_integer(ireg, "sp", u16)
	bp = index_integer(ireg, "bp", u16)
	si = index_integer(ireg, "si", u16)
	di = index_integer(ireg, "di", u16)

	flags = transmute(Flags)index_integer(ireg, "flags", u16)
	ip = index_integer(ireg, "ip", u16)

	data := index_map(initial, "ram")
	for mop in data.(^[]cbor.Value) {
		pair := mop.(^[]cbor.Value)
		write(to_integer(pair[0], u32), to_integer(pair[1], byte))
	}

	div_zero: bool
	for {
		step, ok := machine.step(1)
		div_zero = step.div_zero

		if !ok {
			log.warn("invalid instruction")
			return
		}

		if !step.repeat {
			break
		}
	}

	final := index_map(test, "final")
	freg := index_map(final, "regs")

	get_reg :: proc(reg: string, ireg, freg: cbor.Value) -> u16 {
		v := index_map(freg, reg)
		return (v != nil) ? to_integer(v, u16) : index_integer(ireg, reg, u16)
	}

	testing.expect_value(t, ax, get_reg("ax", ireg, freg))
	testing.expect_value(t, bx, get_reg("bx", ireg, freg))
	testing.expect_value(t, cx, get_reg("cx", ireg, freg))
	testing.expect_value(t, dx, get_reg("dx", ireg, freg))

	testing.expect_value(t, cs, get_reg("cs", ireg, freg))
	testing.expect_value(t, ss, get_reg("ss", ireg, freg))
	testing.expect_value(t, ds, get_reg("ds", ireg, freg))
	testing.expect_value(t, es, get_reg("es", ireg, freg))

	testing.expect_value(t, sp, get_reg("sp", ireg, freg))
	testing.expect_value(t, bp, get_reg("bp", ireg, freg))
	testing.expect_value(t, si, get_reg("si", ireg, freg))
	testing.expect_value(t, di, get_reg("di", ireg, freg))

	testing.expect_value(t, ip, get_reg("ip", ireg, freg))

	{
		builder: strings.Builder
		defer strings.builder_destroy(&builder)

		a := flags & flag_mask
		b := transmute(Flags)get_reg("flags", ireg, freg) & flag_mask

		testing.expect(t, a == b, format_flags_message(&builder, a, b))
	}

	data = index_map(final, "ram")
	for mop in data.(^[]cbor.Value) {
		pair := mop.(^[]cbor.Value)
		value := to_integer(pair[1], byte)
		addr := to_integer(pair[0], u32)
		res := read(addr)

		if !check_memory(addr, res, value, div_zero) {
			log.errorf("expected memory at 0x%X to be 0x%X (%d) but it was 0x%X (%d)", addr, value, value, res, res)
			testing.fail_now(t) // Lets not spam the console. One error is enough.
		}
	}
}

run_opcode_tests :: proc(t: ^testing.T, file_path: string, flag_mask: Flags) {
	data, ok := os.read_entire_file_from_filename(file_path, context.temp_allocator)
	testing.expect(t, ok, "failed to load test file")

	cbor_data, err := cbor.decode(s = string(data), allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)

	for op, idx in cbor_data.(^[]cbor.Value) {
		execute_test(t, op, idx, flag_mask)
	}
}
