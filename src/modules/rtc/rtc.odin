#+private
#+build !freestanding

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

package rtc

import "core:strconv"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

import "vxt:machine/peripheral"
import rt "vxt:xruntime"

CMOS_SIZE :: 64

RTC :: struct {
	io_base:      u16,
	addr, busy:   byte,
	cmos:         [CMOS_SIZE]byte,
	current_time: time.Time,
	region:       ^datetime.TZ_Region,
}

install :: proc(rtc: ^RTC) -> (ok := true) {
	peripheral.register_io_address_range(rtc, rtc.io_base, rtc.io_base + 1)
	peripheral.register_timer(rtc, 1000000)
	rtc.region = timezone.region_load("local") or_return
	return
}

destroy :: proc(rtc: ^RTC) {
	free(rtc.region)
}

config :: proc(rtc: ^RTC, name, key: string, value: any) -> bool {
	if name != "rtc" {
		return true
	}

	switch key {
	case "port":
		switch v in value {
		case u16:
			rtc.io_base = value.(u16)
		case string:
			n, ok := strconv.parse_uint(v)
			assert(ok)
			rtc.io_base = u16(n)
		case:
			return false
		}
	case:
		return false
	}
	return true
}

timer :: proc(rtc: ^RTC, _: peripheral.Peripheral_Timer_ID, _: uint) {
	dtime, ok := time.time_to_datetime(time.now())
	assert(ok)
	dtime, ok = timezone.datetime_to_tz(dtime, rtc.region)
	assert(ok)
	rtc.current_time, ok = time.datetime_to_time(dtime)
	assert(ok)

	rtc.busy = 0x80
}

io_in :: proc(using rtc: ^RTC, port: u16) -> byte {
	if port & 1 == 0 {
		return addr
	}

	hours, minutes, seconds := time.clock(current_time)
	year, month, day := time.date(current_time)

	to_bcd :: proc(rtc: ^RTC, #any_int data: byte) -> byte {
		if rtc.cmos[0xB] & 4 == 0 {
			rh := (data / 10) % 10
			rl := data % 10
			return (rh << 4) | rl
		}
		return data
	}

	data: byte
	switch addr {
	case 0x0:
		data = to_bcd(rtc, seconds)
	case 0x2:
		data = to_bcd(rtc, minutes)
	case 0x4:
		data = to_bcd(rtc, hours)
	case 0x6:
		data = to_bcd(rtc, time.weekday(current_time))
	case 0x7:
		data = to_bcd(rtc, day)
	case 0x8:
		data = to_bcd(rtc, month)
	case 0x9:
		data = to_bcd(rtc, year - 2000)
	case 0xA:
		// Status A
		data = busy | (cmos[addr] & 0x7F)
		busy = 0
	case 0xB:
		// Status B
		data = cmos[addr] & 0xFD // 24h format only.
	case 0xD:
		// Status D
		// CMOS battery power good
		data = 0x80
	case 0x32:
		data = to_bcd(rtc, 20)
	case:
		data = cmos[addr]
	}

	addr = 0xD
	return data
}

io_out :: proc(using rtc: ^RTC, port: u16, data: byte) {
	if port & 1 != 0 {
		cmos[addr] = data
		addr = 0xD
	} else {
		// Not sure about this behaviour?
		addr = (data >= CMOS_SIZE) ? 0xD : data
	}
}

@(init)
rtc :: proc "contextless" () {
	context = rt.default_context
	peripheral.register_constructor(proc(_: string) {
		rtc, cb := peripheral.allocate(RTC)
		rtc.io_base = 0x240

		cb.install = install
		cb.config = config
		cb.timer = timer
		cb.io_in = io_in
		cb.io_out = io_out

		cb.name = proc(_: ^RTC) -> string {
			return "RTC (Motorola MC146818)"
		}
	})
}
