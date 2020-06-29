module mem

import asm
import dev
import fs
import lock
import proc
import sys

pub const (
	EXTMEM = 0x100000 // Start of extended memory
	PHYSTOP = 0xE000000 // Top of physical memory
	DEVSPACE = 0xFE000000 // Other devices are at high address
)

// Key addresses for address space layout (see kmap in vm.v for layout)
pub const (
	KERNBASE = 0x800000000, // First kernel virtual address
	KERNLINK = KERNBASE + EXTMEM, // Address where kernel is linked
)

pub fn v2p(a any) { return byte(*a) + KERNBASE }
pub fn p2v(a any) { return any((*(*a + KERNBASE))) }

pub fn v2p_w0(x any) { return x - KERNBASE } // same as v2p(), but without casts
pub fn p2v_w0(x any) { return x + KERNBASE } // same as p2v(), but without casts
