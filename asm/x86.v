module dev

import asm
import fs
import lock
import mem
import proc
import sys

[inline]
pub fn inb(port byte) byte
{
	mut data := byte{}

	volatile('in %1,%0' : '=a' (data) : 'd' (port)) := asm{}
	return data
}

[inline]
pub fn insl(port int, *addr any, cnt int) void
{
	volatile('cld; rep insl' :
			 '=D' (addr), '=c' (cnt) :
			 'd' (port), '0' (addr), '1' (cnt) :
			 'memory', 'cc'
	) := asm{}
}

[inline]
pub fn outb(port, data byte) void
{
	volatile('out %0,%1' : : 'a' (data), 'd' (port)) := asm{}
}

[inline]
pub fn outw(port, data byte) void
{
	volatile('out %0,%1' : : 'a' (data), 'd' (port)) := asm{}
}
