module utils

import asm
import user
import sys
import proc
import boot
import mem
import lock
import dev
import fs
import io
import shell

pub fn strcpy(mut *s byte, *t byte) charptr
{
	mut os := s

	for (*s++ = *t++) != 0 {}

	return os
}

pub fn strcmp(*p, *q byte) int
{
	for *p && *p == *q {
		p++
		q++
	}

	return u32(*p) - u32(*q)
}

pub fn strlen(*s byte) u32
{
	mut n := 0

	for n = 0; s[n]; s++ {}

	return n
}

pub fn memset(mut *dst any, mut c int, n u32) voidptr
{
	stosb(dst, c, n)
	return dst
}

pub fn strchr(*s byte, mut c byte) charptr
{
	for ; *s; s++ {
		if *s == c {
			return charptr(s)
		}
	}

	return 0
}

pub fn gets(mut *buf byte, max int) charptr
{
	mut i, cc := 0
	mut c := byte(0)

	for i = 0; i + 1 < max; ; {
		cc = read(0, &c, 1)

		if cc < 1 {
			break
		}

		buf[i++] = c

		if c == '\n' || c == '\r' {
			break
		}
	}

	buf[i] = '\0'
	return buf
}
