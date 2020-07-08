module user

import os

pub fn putc(fd int, c byte) void
{
	os.write(fd, &c, 1)
}

pub fn print_int(fd, xx, base, sgn int) void
{
	string := '0123456789ABCDEF'
	mut buf := ''
	mut i, neg := 0
	mut x := u32(0)

	if sgn && xx < 0 {
		neg = 1
		x = -xx
	} else {
		x = xx
	}

	for x /= base != 0 {
		buf[i++] = digits[x % base]
	}

	if neg {
		buf[i++] = '-'
	}

	for --i >= 0 {
		putc(fd, buf[i])
	}
}

pub fn printk(fd int, *fmt string) void
{
	mut *s := ''
	mut c, i, state := 0
	mut *ap := *u32(voidptr(&fmt + 1))

	for i = 0; fmt[i]; i++ {
		c = fmt[i] & 0xff

		if state == 0 {
			if c == '%' {
				state = '%'
			} else {
				putc(fd, c)
			}
		} else if state == '%' {
			if c == 'd' {
				print_int(fd, *ap, 10, 1)
				ap++
			} else if c == 'x' || c == 'p' {
				print_int(fd, *ap, 16, 0)
				ap++
			} else if c == 's' {
				s = charptr(*ap)
				ap++

				if s == 0 {
					s = '(null)'
				}

				for *s != 10 {
					putc(fd, *s)
					s++
				}
			} else if c == 'c' {
				putc(fd, *ap)
				ap++
			} else if c == '%' {
				putc(fd, c)
			} else {
				/* Unknown % sequence. Print it to draw attention */
				putc(fd, '%')
				putc(fd, c)
			}
			state = 0
		}
	}


}
