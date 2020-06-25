module mem

import asm
import dev
import fs
import lock
import proc
import sys

const (
	data = []byte{} // defined by kernel.id
	*kpgdir = pde_t(0) // for use in scheduler()
)

// Set up CPU's kernel segment descriptors.
// Run once on entry on each CPU.
pub fn seg_init() void
{
	*c := CPU{}

	/*
	Map 'logical' addresses to virtual addresses using identity map.
	Cannot share a CODE descriptor for both kernel and user
	because it would have to have DPL_USR, but the CPU forbids
	an interrupt from CPL=0 to DPL=3.
	*/
	c = &cpus[cpu_id()]
	c.gdt[SEG_KCODE] = seg(STA_X | STA_R, 0, 0xffffffff, 0)
	c.gdt[SEG_KDATA] = seg(STA_W, 0, 0xffffffff, 0)
	c.gdt[SEG_UCODE] = seg(STA_X | STA_R, 0, 0xffffffff, DPL_USER)
	c.gdt[SEGUDATA] = seg(STA_W, 0, 0xffffffff, DPL_USER)
	x86.lgdt(c.gdt, sizeof(c.gdt))
}

/*
Return the address of the PTE in page table pgdir
that corresponds to virtual address va.  If alloc!=0,
create any required page table pages.
*/
pub fn walk_pgdir(*pgdir pde_t, *va any, alloc int) pde_t *
{
	mut *pde := pde_t(0)
	mut *pgtab := pte_t(0)

	pde = &pgdir[pdx(va)]

	if (*pde & PTE_P) {
		pgtab = pte_t(*p2v(pte_addr(*pde)))
	} else {
		if !alloc || (pgtab = pte_t(*kalloc()) == 0) {
			return 0
		}

		// Make sure all those PTE_P bits are zero
		str.memset(pgtab, 0, PGSIZE)

		/*
		The permissions here are overly generous, but they can
	    be further restricted by the permissions in the page table
	    entries, if necessary.
		*/
		*pde = v2p(pgtab) | PTE_P | PTE_W | PTE_U
	}

	return &pgtab[ptx(va)]
}

/*
Create PTEs for virtual addresses starting at va that refer to
physical addresses starting at pa. va and size might not
be page-aligned.
*/
fn mappages(*pgdir pde_t, *va any, size, pa u32, perm int) int
{
	mut *a, *last := byte('')
	mut *pte := pte_t(0)

	a = charptr(*pg_round_down(u32(va)))
	last = charptr(pg_round_down(u32(va) + size - 1))

	for {
		if (pte = walkpgdir(pgdir, a, 1)) == 0 {
			return -1
		}

		if *pte & PTE_P {
			die('remap')
		}

		*pte = pa | perm | PTE_P

		if a == last {
			break
		}

		a += PGSIZE
		pa += PGSIZE
	}

	return 0
}

/*
There is one page table per process, plus one that's used when
a CPU is not running any process (kpgdir). The kernel uses the
current process's page table during system calls and interrupts;
page protection bits prevent user code from using the kernel's
mappings.

setupkvm() and exec() set up every page table like this:

  0..KERNBASE: user memory (text+data+stack+heap), mapped to
               phys memory allocated by the kernel
  KERNBASE..KERNBASE+EXTMEM: mapped to 0..EXTMEM (for I/O space)
  KERNBASE+EXTMEM..data: mapped to EXTMEM..V2P(data)
               for the kernel's instructions and r/o data
  data..KERNBASE+PHYSTOP: mapped to V2P(data)..PHYSTOP,
                                 rw data + free physical memory
  0xfe000000..0: mapped direct (devices such as ioapic)

The kernel allocates physical memory for its heap and for user memory
between V2P(end) and the end of physical memory (PHYSTOP)
(directly addressable from end..P2V(PHYSTOP))
*/

// This table defines the kernel's mappings, which are present in
// every processes's page table
pub struct KMap {
	*virt any,
	phys_start u32,
	phys_end u32,
	perm int,
} []KMap{
	[voidptr(KERNBASE), 0, EXTMEM, PTE_W], // I/O space
	[voidptr(KERNLINK), v2p(KERNLINK), v2p(data), 0], // kernel text + rodata
	[voidptr(data), v2p(data), PHYSTOP, PTE_W], // kernel data + memory
	[voidptr(DEVSPACE), DEVSPACE, 0, PTE_W], // more decides
}

// Set up kernel part of page table.
pub fn setup_kvm() pde_t* {
	mut pde_t *pgdir
	mut *k := KMap{}

	if (pgdir = pde_t*(kalloc()) == 0) {
		return 0
	}

	str.memset(pgdir, 0, PGSIZE)

	if p2v(PHYSTOP) > voidptr(DEVSPACE) {
		die('PHYSTPE too high')
	}

	for k = kmap; k < &kmap[nelem(kmap)]; k++ {
		if mappages(pgdir, k.virt, k.phys_end - k.phys_start, u32(k.phys_start, k.perm) < 0) {
			freevm(pgdir)
			return 0
		}
	}

	return pgdir
}

// Allocate one page table for the machine for the kernel address
// space for scheduler processes.
pub fn kvm_alloc() void
{
	mut *kpgdir := pde_t(0)
	lcr3(v2p(kpgdir)) // switch to the kernel page table
}

// Switch TSS and h/w page table to correspond to process p.
pub fn (*p Proc) switch_uvm() void
{
	if p == 0 {
		die('switch_uvm: no process')
	}

	if p.kstack == 0 {
		die('')
	}

	if p.pgdir == 0 {
		die('switch_uvm: no pgdir')
	}

	push_cli()

	my_cpu().gdt[SEG_TSS] = seg16(STS_T32A, &my_cpu().ts, sizeof(my_cpu().ts - 1), 0)

	my_cpu().gdt[SEG_TSS].s = 0
	my_cpu().ts.ss0 = SEG_KDATA << 3
	my_cpu().ts.esp0 = u32(p.kstack + param.KSTACKSIZE)
	// setting IOPL=0 in eflags *and* iomb beyond the tss segment limit
 	// forbids I/O instructions (e.g., inb and outb) from user space
	my_cpu().ts.iomb = byte(0xFFFF)
	ltr(SEG_TSS << 3)
	lcr3(v2p(p.pgdir)) // switch to process's address space
	pop_cli()
}

// Load the initcode into address 0 of pgdir.
// sz must be less than a page.
pub fn init_uvm(*pgdir pde_t, *init byte, sz u32) void
{
	mut *mem = byte(0)

	if sz >= PGSIZE {
		die('init_uvm: more than a page')
	}

	mem = kalloc()
	str.memset(mem, 0, PGSIZE)
	mappages(pgdir, 0, PGSIZE, v2p(mem), PTE_W | PRE_U)
	str.memmove(mem, init, sz)
}

// Load a program segment into pgdir. addr must be page-aligned
// and the pages from addr to addr + sz must already be mapped.
pub fn load_uvm(*pgdir pde_t, *addr byte, *ip Inode, offset, sz u32) int
{
	mut i, pa, n := u32(0)
	mut *pte := pte_t(0)

	if u32(addr) % PGSIZE != 0 {
		die('load_uvm: address should exist')
	}

	pa = pte_addr(*pte)

	if sz - i < PGSIZE {
		n = sz - i
	} else {
		n = PGSIZE
	}

	if readi(ip, p2v(pa), offset + i, n) != n {
		return -1
	}

	return 0
}

// Allocate page tables and physical memory to grow process from oldsz to
// newsz, which need not be page-aligned. Returns new size or 0 on error.
pub fn alloc_uvm(*pgdir pde_t, oldsz, newsz u32) int
{
	mut *mem := byte(0)
	mut a := u32(0)

	if newsz >= KERNBASE {
		return 0
	}

	if newsz < oldsz {
		return oldsz
	}

	a = pg_round_up(oldsz)

	for ; a < newsz; a += PGSIZE {
		mem = kalloc()

		if mem == 0 {
			println('alloc_uvm out of memory')
			dealloc_uvm(pgdir, newsz, oldsz)
			return 0
		}

		str.memset(mem, 0, PGSIZE)

		if mappages(pgdir, charptr(a), PGSIZE, v2p(mem), PTE_W | PTE_U) < 0 {
			println('alloc_uvm out of memory (2)')
			dealloc_uvm(pgdir, newsz, oldsz)
			kfree(mem)
			return 0
		}
	}

	return newsz
}

/*
Deallocate user pages to bring the process size from oldsz to
newsz.  oldsz and newsz need not be page-aligned, nor does newsz
need to be less than oldsz.  oldsz can be larger than the actual
process size.  Returns the new process size.
*/

pub fn dealloc_uvm(*pgdir pde_t, oldsz, newsz u32) int
{
	mut *pte := pte_t(0)
	mut a, pa := u32(0)

	if newsz >= oldsz {
		return oldsz
	}

	a = pg_round_up(newsz)

	for ; a < oldsz; a += PGSIZE {
		pte = walkpgdir(pgdir, charptr(a), 0)

		if !pte {
			a = pg_addr(pdx(a) + 1, 0, 0) - PGSIZE
		} else if (*pte & PTE_P) != 0 {
			pa = pte_addr(*pte)

			if pa == 0 {
				die('kfree')
			}

			mut *v := p2v(pa)
			kfree(v)
			*pte = 0
		}
	}

	return newsz
}

// Free a page table and all the physical memory pages
// in the user part
pub fn freevm(*pgdir pde_t) void
{
	mut i := u32(0)

	if pgdir == 0 {
		die('freevm: no pgdir')
	}

	dealloc_uvm(pgdir, KERNBASE, 0)

	for i = 0; i < NPDENTRIES; i++ {
		if pgdir[i] & PTE_P {
			mut *v := charptr(p2v(pte_addr(pgdir[i])))
			kfree(v)
		}
	}

	kfree(charptr(pgdir))
}

// Clear PTE_U on a page. Used to create an inaccessible
// page beneath the user stack.
pub fn clear_pteu(*pgdir pde_t, *uva byte) void
{
	mut *pte := walkpgdir(pgdir, uva, 0)

	if pte == 0 {
		die('clear_pteu')
	}

	*pte &= ~PTE_U
}

// Given a parent process' page table, create a copy
// of it for a child
pub fn copy_uvm(*pgdir pde_t, sz u32) pde_t*
{
	mut *d := pde_t(0)
	mut *pte := pde_t(0)
	mut pa, i, flags := u32(0)
	mut *mem := byte('')

	if (d = setup_kvm()) == 0 {
		return 0
	}

	for i = 0; i < sz; i += PGSIZE {
		if (pte = walkpgdir(pgdir, voidptr(i), 0)) == 0 {
			die('copy_uvm: pte should exist')
		}

		if !(*pte & PTE_P) {
			die('copy_uvm: page not present')
		}

		pa = pte_addr(*pte)
		flags = pte_flags(*pte)

		if (mem = kalloc() == 0) {
			goto bad
		}

		str.memmove(mem, charptr(p2v(pa)), PGSIZE)

		if mappages(d, voidptr(i), PGSIZE, v2p(mem), flags) < 0 {
			kfree(mem)
			goto bad
		}
	}

	return d

bad:
	freevm(d)
	return 0
}

// Map user virtual address to kernel address.
pub fn uva2ka(*pgdir pde_t, *uva byte) charptr
{
	mut *pte := walkpgdir(pgdir, uva, 0)

	if (*pte & PTE_P) == 0 {
		return 0
	}

	if (*pte & PTE_U) == 0 {
		return 0
	}

	return charptr(p2v(pte_addr(*pte)))
}

/*
Copy len bytes from p to user address va in page table pgdir.
Most useful when pgdir is not the current page table.
uva2ka ensures this only works for PTE_U pages.
*/
pub fn copy_out(*pgdir pde_t, va u32, *p any, len uint)
{
	mut *buf, *pa0 := byte(0)
	mut n, va0 := u32(0)

	buf = charptr(p)

	for len > 0 {
		va0 = u32(pg_round_down(va))
		pa0 = uva2ka(pgdir, charptr(va0))

		if pa0 == 0 {
			return -1
		}

		n = PGSIZE - (va - va0)

		if n > len {
			n = len
		}

		str.memmove(pa0 + (va - va0), buf, n)
		len -= n
		buf += n
		va = va0 + PGSIZE
	}

	return 0
}
