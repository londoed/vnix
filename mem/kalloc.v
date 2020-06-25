module mem

import asm
import dev
import fs
import lock
import proc
import sys

/*
Physical memory alocator, intended to allocate
memory for user processes, kernel stacks, page table pages,
and pipe buffers. Allocates 4096-byte pages.
*/
import types
import defs
import param
import memlay
import mmu
import spinlock

pub end := []byte{} // First address after kernel loaded from ELF file
					// defined by the kernel linker script in kernel.ld.

pub struct Run {
	*next Run{}
}

pub struct KMem {
	lock Spinlock{}
	use_lock int
	*freelist Run{}
}

/*
Initialization happens in two phases.
1. main() calls kinit1() while still using entrypgdir to place just
the pages mapped by entrypgdir on free list.
2. main() calls kinit2() with the rest of the physical pages
after installing a full page table that maps them on all cores.
*/
pub fn kinit1(*vstart, *vend any) void
{
	init_lock(&KMem.lock, 'kmem')
	KMem.use_lock = 0
	free_range(vstart, vend)
}

pub fn kinit2(*vstart, *vend any) void
{
	free_range(vstart, vend)
	KMem.use_lock = 1
}

pub fn free_range(*vstart, *vend any) void
{
	mut *p := byte('')
	p = charptr(pg_round_up(u32(vstart)))

	for ; p + PGSIZE <= charptr(vend); p += PGSIZE {
		kfree(p)
	}
}

/*
Free the page of physical memory pointed at by v,
which normally should have been returned by a
call to kalloc().  (The exception is when
initializing the allocator; see kinit() above.)
*/
pub fn kfree(*v byte) void
{
	mut *r := Run{}

	if u32(v) % PGSIZE || v < end || v2p(v) >= PHYSTOP {
		die('kfree')
	}

	// Fill with junk to catch dangling references.
	memset(v, 1, PGSIZE)

	if KMem.use_lock {
		acquire(&KMem.lock)
	}

	r = &Run(v)
	r.next = KMem.free_list
	KMem.free_list = r

	if KMem.use_lock {
		release(&KMem.lock)
	}
}

/*
Allocate one 4096-byte page of physical memory.
Returns a pointer that the kernel can use.
Returns 0 if the memory cannot be allocated.
*/
pub fn kalloc() charptr {
	mut *r := Run{}

	if KMem.use_lock {
		acquire(&KMem.lock)
	}

	r = KMem.free_list

	if r {
		KMem.free_list = r.next
	}

	if KMem.use_lock {
		release(&KMem.lock)
	}

	return charptr(r)
}
