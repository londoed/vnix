module init

import asm
import boot
import dev
import fs
import io
import lock
import mem
import proc
import shell
import sys
import user
import utils

pub type pde_t := *kpgdir(0)
pub type end := string('') /* first address after kernel loaded from ELF file */

/*
 * Bootstrap processor starts running V code here.
 * Allocate a real stack and switch to it, first
 * doing some setup required for memory allocator to work.
 */
fn main() int
{
	mem.k_init1(end, mem.p2v(4 * 1024 * 1024)) /* phys page allocator */
	mem.kvm_alloc() /* kernel page table */
	dev.mp_init() /* detect other processors */
	dev.lapic_init() /* interrupt controller */
	mem.seg_init() /* segment descriptors */
	dev.pic_init() /* disable pic */
	dev.ioapic_init() /* another interrupt controller */
	io.console_init() /* console hardware */
	dev.uart_init() /* serial port */
	proc.p_init() /* process table */
	dev.tv_init() /* trap vectors */
	mem.b_init() /* buffer cache */
	fs.file_init()
	dev.ide_init()
	asm.start_others()
	mem.k_init2(mem.p2v(4 * 1024 * 1024), mem.p2v(mem.PHYSTOP))
	user.user_init()
	mp_main()
}

pub fn mp_enter() void
{
	mem.kvm_switch()
	mem.seg_init()
	dev.lapic_init()
	mp_main()
}

/* Common CPU setup code */
pub fn mp_main() void
{
	io.cprintf('cpu${proc.cpu_id()}: starting ${proc.cpu_id()}')
	dev.idt_init() /* load idt register */
	asm.xchg(&(proc.my_cpu().started), 1) /* tell start_others() we're up */
	proc.scheduler() /* start running processes */
}

/* Start the non-boot (AP) processors */
pub fn start_others() void
{
	mut *code := u16(0)
	mut *c := CPU{}
	mut *stack := byte(0)
	mut _binary_entryother_start := []u16{}
	mut _binary_entryother_size := []u16{}

	/*
	 * Write entry code to unused memory at 0x7000.
	 * The linker has placed the image of entryother.S in
	 * _binary_entryother_start.
	 */
	code = mem.p2v(0x7000)
	sys.memmove(code, _binary_entryother_start, u32(_binary_entryother_size))

	for c = dev.cpus; c < dev.cpus + sys.NCPU; c++ {
		if c == proc.my_cpu() { /* We've already started */
			continue
		}

		/*
		 * Tell entryother.S what stack to use, where to enter, and what
		 * pgdir to use. We cannot use kpgdir yet, because the AP processor
		 * is running in low memory, so we use entry_pgdir for the APs too.
		 */
		stack = mem.k_alloc()
		*(voidptr(code - 4)) = stack + sys.KSTACKSIZE
		*(voidpotr(code - 8)) = mp_enter()
		*(**int(code - 12)) = voidptr(entry_pgdir)

		dev.lapic_startap(c.apic_id, mem.v2p(code))

		for c.started == 0 {}
	}
}

/*
 * The boot page table used in entry.S and entryother.S.
 * Page directories (and page tables) must start on page boundaries,
 * hence the __aligned__ attribute.
 * PTE_PS in a page directory entry enables 4Mbyte pages.

 * TODO: implement
 * __attribute__((__aligned__(PGSIZE)))
 * pde_t entrypgdir[NPDENTRIES] = {
 *   Map VA's [0, 4MB) to PA's [0, 4MB)
 *   [0] = (0) | PTE_P | PTE_W | PTE_PS,
 *   Map VA's [KERNBASE, KERNBASE+4MB) to PA's [0, 4MB)
 * [KERNBASE>>PDXSHIFT] = (0) | PTE_P | PTE_W | PTE_PS,};
 */
