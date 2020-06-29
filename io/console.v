module io

import asm
import dev
import fs
import lock
import mem
import proc
import sys

/*
 * Console input and output.
 * Input is from the keyboard or serial port.
 * Output is written to the screen or serial port.
 */

global (
	panicked = 0,
)

pub struct Console {
	lock lock.Spinlock{}
	locking int
}


pub fn print_int(xx, base, sign int) void
{
	mut digits := '0123456789abcdef'
	mut buf := [16]byte{}
	mut i := 0
	mut x := u32(0)

	if sign && (sign = xx < 0) {
		x = -xx
	} else {
		x = xx
	}

	for (x /= base) != 0 {
		buf[i++] = digits[x % base]
	}

	if sign {
		buf[i++] = '-'
	}

	for --i >= 0 {
		cons_putc(buf[i])
	}
}

/* Print to the console. Only understands %d, %x, %p, %s */
pub fn cprintf(*fmt byte, ...) void
{
	mut i, c, locking := 0
	mut *argp := u32(0)
	mut *s := byte(0)

	locking = Console.locking

	if locking {
		lock.acquire(&Console.lock)
	}

	if fmt == 0 {
		kpanic('null fmt')
	}

	argp = u32(*voidptr(&fmt + 1))

	for i = 0; (c = fmt[i] & 0xff) != 0; i++ {
		if c != '%' {
			cons_putc(c)
			continue
		}

		c = fmt[++i] & 0xff

		if c == 0 {
			break
		}

		match c {
			'd' {
				print_int(*argp++, 10, 1)
			}

			'x' || 'p' {
				print_int(*argp++, 16, 0)
			}

			's' {
				if (s = charptr(*argp++)) == 0 {
					s = '(null)'
				}

				for ; *s; s++ {
					cons_putc(*s)
				}
			}

			'%' {
				cons_putc('%')
			}

			else {
				/* Print unknown % sequence to draw attention */
				cons_putc('%')
				cons_putc(c)
			}
		}
	}

	if locking {
		lock.release(&Console.lock)
	}
}

pub fn cons_panic(*s byte) void
{
	mut i := 0
	mut pcs := [10]u32{}

	cli()
	Console.locking = 0

	/* Use lapic_cpu_num so that we can call kpanic() from my_cpu() */
	println('lapicid ${lapicid()}: cons_panic: $s')
	get_caller_pcs(&s, pcs)

	for i in pcs {
		println(' ${pcs[i]}')
	}

	panicked = 1 /* freeze other CPU */

	for ; ; {}
}

pub const (
	BACKSPACE = 0x100,
	CRTPORT = 0x3d4,
)

global (
	*crt = u16(*p2v(0xb8000)) /* CGA memory */
)

pub fn cga_putc(c int) void
{
	mut pos := 0

	/* Cursor position: col + 80 * row */
	asm.outb(CRTPORT, 14)
	pos = asm.inb(CRTPORT + 1) << 8
	asm.outb(CRTPORT, 15)
	pos |= asm.inb(CRTPORT + 1)

	if c == '\n' {
		pos += 80 - pos % 80
	} else if c == BACKSPACE {
		if pos > 0 {
			--pos
		}
	} else {
		crt[pos++] = (c & 0xff) | 0x0700 /* black on white */
	}

	if pos < 0 || pos > 25 * 80 {
		kpanic('pos under/overflow')
	}

	if (pos / 80) >= 24 { /* scroll up */
		sys.memmove(crt, crt + 80, sizeof(crt[0]) * 23 * 80)
		pos -= 80
		sys.memset(crt + pos, 0, sizeof(crt[0]) * (24 * 80 - pos))
	}

	asm.outb(CRTPORT, 14)
	asm.outb(CRTPORT + 1, pos >> 8)
	asm.outb(CRTPORT, 15)
	asm.outb(CRTPORT + 1, pos)

	crt[pos] = ' ' | 0x0700
}

pub fn cons_putc(c int) void
{
	if panicked {
		cli()
		for ; ; {}
	}

	if c == BACKSPACE {
		uart_putc('\b')
		uart_putc(' ')
		uart_putc('\b')
	} else {
		uart_putc(c)
	}

	cga_putc(c)
}

const INPUT_BUF = 128

pub struct Input {
	buf [INPUT_BUF]byte{}
	r u32 /* Read index */
	w u32 /* Write index */
	e u32 /* Edit index */
}

const C = fn(x) { return x - '@' }

pub fn console_intr(*getc int) void
{
	mut c, do_proc_dump := 0

	lock.acquire(&Console.lock)

	for (c = getc()) >= 0 {
		match c {
			C('P') { /* Process listing */
				/* proc_dump() locks Console.lock indirectly. Invoke later */
				do_proc_dump = 1
			}

			C('U') { /* Kill line */
				for Input.e != Input.w && Input.buf[(Input.e - 1) % INPUT_BUF] != '\n' {
					Input.e--
					cons_putc(BACKSPACE)
				}
			}

			C('H') || '\x7f' { /* Backspace */
				if Input.e != Input.w {
					Input.e--
					cons_putc(BACKSPACE)
				}
			}

			else {
				if c != 0 && Input.e - Input.r < INPUT_BUF {
					c = if c == '\r' { '\n' } else { c }
					Input.buf[Input.e++ % INPUT_BUF] = c
					cons_putc(c)

					if c == '\n' || c == C('D') || Input.e == Input.r + INPUT_BUF {
						Input.w = Input.e
						wake_up(&Input.r)
					}
				}
			}
		}
	}

	lock.release(&Console.lock)

	if do_proc_dump {
		proc_dump() /* Now call proc_dump() w/o Console.lock held */
	}
}

pub fn console_read(*ip fs.Inode, *dst byte, n int) int
{
	mut target := u32(0)
	mut c := 0

	fs.i_unlock(ip)
	target = n
	lock.acquire(&Console.lock)

	for n > 0 {
		for Input.r == Input.w {
			if my_proc().killed {
				lock.release(&Console.lock)
				fs.i_lock(ip)
				return -1
			}

			proc.sleep(&Input.r, &Console.lock)
		}

		c = Input.buf[Input.r++ % INPUT_BUF]

		if c == C('D') { /* EOF */
			if n < target {
				/*
				 * Save ^D for next time to make sure
				 * caller gets a 0-byte result.
				 */
				Input.r--
			}

			break
		}

		*dst++ = c
		--n

		if c == '\n' {
			break
		}
	}

	lock.release(&Console.lock)
	fs.i_lock(ip)
	return target - n
}

pub fn console_write(*ip Inode, *buf byte, n int) int
{
	mut i := 0

	fs.i_unlock(ip)
	lock.acquire(&Console.lock)

	for i = 0; i < n; i++ {
		cons_putc(buf[i] & 0xff)
	}

	lock.release(&Console.lock)
	fs.i_lock(ip)

	return n
}

pub fn console_init() void
{
	lock.init_lock(&Console.lock, 'console')

	devsw[CONSOLE].write = console_write()
	devsw[CONSOLE].read = console_read()
	Console.locking = 1

	dev.ioapic_enable(dev.IRQ_KBD)
}
