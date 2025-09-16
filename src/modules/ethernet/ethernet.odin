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

package ethernet

import "core:bytes"
import "core:log"

import "vxt:machine/peripheral"
import rt "vxt:xruntime"

MAX_PACKET_SIZE :: 0xFFF0
POLL_DELAY :: 1000 // Poll every millisecond.

Driver_Error :: enum {
	BAD_HANDLE = 1, // Invalid handle number.
	NO_CLASS, // No interfaces of specified class found.
	NO_TYPE, // No interfaces of specified type found.
	NO_NUMBER, // No interfaces of specified number found.
	BAD_TYPE, // Bad packet type specified.
	NO_MULTICAST, // This interface does not support multicast.
	CANT_TERMINATE, // This packet driver cannot terminate.
	BAD_MODE, // An invalid receiver mode was specified.
	NO_SPACE, // Operation failed because of insufficient space.
	TYPE_INUSE, // The type had previously been accessed, and not released.
	BAD_COMMAND, // The command was out of range, or not implemented.
	CANT_SEND, // The packet couldn't be sent (usually hardware error).
	CANT_SET, // Hardware address couldn't be changed (more than 1 handle open).
	BAD_ADDRESS, // Hardware address has bad length or format.
	CANT_RESET, // Couldn't reset interface (more than 1 handle open).
}

Driver_Command :: enum {
	DRIVE_INFO = 1,
	ACCESS_TYPE,
	RELEASE_TYPE,
	SEND_PACKET,
	TERMINATE,
	GET_ADDRESS,
	RESET_INTERFACE,
	GET_CALLBACK = 0xFE,
	COPY_PACKET = 0xFF,
}

default_mac := [6]byte{0x00, 0x0B, 0xAD, 0xC0, 0xFF, 0xEE}

Ethernet :: struct {
	can_recv:          bool,
	mac_addr:          [6]byte,
	rx_len:            u16,
	rx_buffer:         [MAX_PACKET_SIZE]byte,
	cb_seg, cb_offset: u16,

	// Temp buffer for package
	buffer:            [MAX_PACKET_SIZE]byte,
}

install :: proc(eth: ^Ethernet) -> bool {
	peripheral.register_io_address_at(eth, 0xB2)
	peripheral.register_timer(eth, POLL_DELAY)
	return true
}

config :: proc(eth: ^Ethernet, name, key: string, value: any) -> (ok := true) {
	if name != "ethernet" {
		return
	}
	return
}

io_in :: proc(eth: ^Ethernet, port: u16) -> byte {
	return 0 // Return 0 to indicate that we have a network card.
}

io_out :: proc(eth: ^Ethernet, port: u16, data: byte) {
	using reg := peripheral.peripheral_interface.registers()

	check_handle :: proc(eth: ^Ethernet, handle: u16) {
		if handle != 0 {
			log.error("Invalid handle passed by the packet driver!")
		}
	}

	// Assume no error
	flags -= {.CARRY}

	switch Driver_Command(ah) {
	case .DRIVE_INFO:
		bx = 1 // version
		ch = 1 // class
		dx = 1 // type
		cl = 0 // number
		al = 1 // functionality
	// Name in DS:SI is filled in by the driver.
	case .ACCESS_TYPE:
		// We only support capturing all types.
		// typelen != any_type
		if cx != 0 {
			flags += {.CARRY}
			dh = u8(Driver_Error.BAD_TYPE)
			return
		}

		eth.can_recv = true
		eth.cb_seg = es
		eth.cb_offset = di

		log.infof("Callback address: %X:%X", es, di)

		ax = 0 // Handle
	case .RELEASE_TYPE:
		check_handle(eth, bx)
	case .TERMINATE:
		check_handle(eth, bx)
		flags += {.CARRY}
		dh = u8(Driver_Error.CANT_TERMINATE)
	case .SEND_PACKET:
		if cx > MAX_PACKET_SIZE {
			log.info("Can't send! Invalid package size!")
			flags += {.CARRY}
			dh = u8(Driver_Error.CANT_SEND)
			return
		}

		for i: u16; i < cx; i += 1 {
			using peripheral
			eth.buffer[i] = peripheral_interface.read(address(ds, si + i))
		}

		//if (sendto(n->sockfd, (void*)n->buffer, r->cx, 0, (const struct sockaddr*)&n->addr, sizeof(n->addr)) != r->cx)
		//	log.info("Could not send packet!")

		log.infof("Sent package with size: %d bytes", cx)
	case .GET_ADDRESS:
		check_handle(eth, bx)

		if cx < 6 {
			log.info("Can't fit address!")
			flags += {.CARRY}
			dh = u8(Driver_Error.NO_SPACE)
			return
		}

		cx = 6
		for i: u16; i < cx; i += 1 {
			using peripheral
			peripheral_interface.write(address(es, di + i), eth.mac_addr[i])
		}
	case .RESET_INTERFACE:
		log.info("Reset interface!")
		check_handle(eth, bx)
		eth.can_recv = false // Not sure about this...
		eth.rx_len = 0
	case .GET_CALLBACK:
		es = eth.cb_seg
		di = eth.cb_offset
		bx = 0 // Handle
		cx = eth.rx_len
	case .COPY_PACKET:
		// Do we have a valid buffer?
		if (es != 0) || (di != 0) {
			for i: u16; i < eth.rx_len; i += 1 {
				using peripheral
				peripheral_interface.write(address(es, di + i), eth.rx_buffer[i])
			}

			// Callback expects buffer in DS:SI
			ds = es
			si = di
			cx = eth.rx_len

			log.infof("Received package with size: %d bytes", eth.rx_len)
		} else {
			log.info("Package discarded by driver!")
		}

		eth.rx_len = 0
		eth.can_recv = true
	case:
		flags += {.CARRY}
		dh = u8(Driver_Error.BAD_COMMAND)
	}
}

timer :: proc(using eth: ^Ethernet, id: peripheral.Peripheral_Timer_ID, cycles: uint) {
	if !can_recv { 	// || !has_data(n->sockfd))
		return
	}

	//ssize_t sz = recvfrom(n->sockfd, (void*)n->rx_buffer, MAX_PACKET_SIZE, 0, (struct sockaddr*)&addr, &addr_len);
	//if (sz <= 0) {
	//	VXT_LOG("'recvfrom' failed!");
	//	return VXT_NO_ERROR;
	//}

	// This should be done by the bridge but we need to be sure.
	if bytes.compare(rx_buffer[:6], mac_addr[:]) != 0 {
		return
	}

	can_recv = false
	//rx_len = sz

	peripheral.peripheral_interface.interrupt(6)
}

@(init)
ethernet :: proc "contextless" () {
	context = rt.default_context
	peripheral.register_constructor(proc(_: string) {
		_, cb := peripheral.allocate(Ethernet)

		cb.install = install
		cb.config = config
		cb.timer = timer
		cb.io_in = io_in
		cb.io_out = io_out

		cb.name = proc(_: ^Ethernet) -> string {
			return "Virtual Ethernet Adapter"
		}
	})
}
