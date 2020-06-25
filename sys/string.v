module sys

import asm
import dev
import fs
import lock
import mem
import proc

import type
import x86

pub fn memset(mut *dst any, mut c int, mut n u32) voidptr
{
	if int(dst) % 4 == 0 && n % 4 == 0 {
		c &= 0xFF
		x86.stosl(dst, (c << 24) | (c << 16) | (c << 8) | c, n / 4)
	} else {
		x86.stosb(dst, c, n)
	}

	return dst
}

pub fn memcmp(*v1 any, *v2 any, mut n u32)
{
	const *s1 := byte(v1)
	const *s2 := byte(v2)

	for n-- > 0 {
		if *s1 != *s2 {
			return *s1 - *s2
		}

		s1++
		s2++
	}

	return 0
}

pub fn memmove(mut *dst any, *src any, mut n u32) voidptr
{
	mut *s := src
	mut *d := dst

	if s < d && s + n > d {
		s += n
		d += n

		for n-- > 0 {
			*--d = *--s
		}
	} else {
		for n-- > 0 {
			*d++ = *d++
		}
	}

	return dst
}

pub fn memcpy(mut *dst any, *src any, mut n u32) voidptr
{
	return memmove(dst, src, n)
}

pub fn strncmp(mut *p, *q byte, mut n u32) int
{
	for n > 0 && *p && *p == *q {
		n--
		p++
		q++
	}

	if n == 0 {
		return 0
	}

	return byte(*p) - byte(*q)
}

pub fn strncpy(mut *s, *t byte, mut n int) charptr
{
	mut *os := s

	for n-- > 0 && (*s++ = *t++) != 0 {}

	*s = 0
	return os
}

pub fn strlen(mut *s byte) int
{
	mut n := 0

	for n = 0; s[n]; n++ {}

	return n
}
