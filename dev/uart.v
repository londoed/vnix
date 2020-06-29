module dev

import asm
import fs
import io
import lock
import mem
import proc
import sys

/* Intel 8250 serial port (UART) */
pub const COM1 = 0x3f8

global (
	mut uart := 0 /* is there a uart? */
)

pub fn uart_init() void
{
	mut *p := byte(0)

	/* Turn off the FIFO */
	asm.outb(COM1 + 2, 0)

	/* 9600 baud, 8 data bits, 1 stop bit, parity off */
	asm.outb(COM1 + 3, 0x80) /* Unlock divisor */
	asm.outb(COM1 + 0, 115200 / 9600)
	asm.outb(COM1 + 1, 0)
	asm.outb(COM1 + 3, 0x03) /* Lock divisor, 8 data bits */
	asm.outb(COM1 + 4, 0)
	asm.outb(COM1 + 1, 0x01) /* Enable receive interrupts */

	/* If status is 0xFF, no serial port */
	if asm.inb(COM1 + 5) == 0xFF {
		return
	}

	uart = 1

	/*
	 * Acknowledge per-existing interrupt condition
	 * enable interrupts.
	 */
	asm.inb(COM1 + 2)
	asm.inb(COM1 + 0)
	ioapic_enable(IRQ_COM1, 0)

	/* Announce that we're here */
	for p = 'vnix...\n'; *p; p++ {
		uart_putc(*p)
	}
}

pub fn uart_putc(c int) void
{
	mut i := 0

	if !uart {
		return -1
	}

	if !(asm.inb(COM1 + 5) & 0x01) {
		return -1
	}

	return asm.inb(COM1 + 0)
}

pub fn uart_intr() void
{
	io.console_intr(uart_getc())
}
