/*
 * This file contains definitions for the
 * x86 memory management unit (MMU).
 */

/* Eflags register */
pub const (
	FL_IF = 0x00000200, /* Interrupt Enable */

	/* Control Register flags */
	CR0_PE = 0x00000001, /* Protection Enable */
	CR0_WP = 0x00010000, /* Write Protect */
	CR0_PG = 0x80000000, /* Paging */
	CR4_PSE = 0x00000010, /* Page size extension */

	/* Varius segment selectors */
	SEG_KCODE = 1, /* Kernel code */
	SEG_KDATA = 2, /* Kernel data & stack */
	SEG_UCODE = 3, /* User code */
	SEG_UDATA = 4, /* User data & stack */
	SEG_TSS = 5, /* This process' task state */

	/* cpu.gdt[NSEGS] holds the above segment */
	NSEGS = 6,
)

/* Segment Descriptor */
pub struct SegDesc {
	mut lim_15_0 := u32(16)  	/* Low bits of segment limit */
	mut base_15_0 := u32(16) 	/* Low bits of segment base address */
	mut base_23_16 := u32(8) 	/* Middle bits of segment base address */
	mut type := u32(4) 			/* Segment type (see STS_ constants) */
	mut s := u32(1)				/* 0 = system, 1 = application level */
	mut dpl := u32(2)			/* Descriptor privilege level */
	mut p := u32(1)				/* Present */
	mut lim_19_16 := u32(4)		/* High bits of segment limit */
	mut avl := u32(1)			/* Unused (available for software use) */
	mut rsv1 := u32(1)			/* Reserved space */
	mut db := u32(1)			/* 0 = 16-bit segment, 1 = 32-bit segment */
	mut g := u32(1)				/* Granularity: limit scaled down by 4K when set */
	mut base_31_24 := u32(8)	/* High bits of segment base address */
}

/* Normal Segment */
pub fn (s* &SegDesc) SEG(type, base, lim, dpl u32) SegDisk
{
	s.lim_15_0 = (lim >> 12) & 0xffff
	s.base_15_0 = u32(base) & 0xffff
	s.base_23_16 = (u32(base) >> 16) & 0xffff
	s.type = type
	s.s = 1
	s.dpl = dpl
	s.p = 1
	s.lim_19_16 = u32(lim) >> 28
	s.avl = 0
	s.rsvl = 0
	s.db = 1
	s.g = 1
	s.base_31_24 = u32(base) >> 24

	return s
}

pub fn (s* &SegDesc) SEG16(type, base, lim, dpl u32) SegDesc
{
	s.lim_15_0 = lim & 0xffff
	s.base_15_0 = u32(base) & 0xffff
	s.base_23_16 = (u32(base) >> 16) & 0xff
	s.type = type
	s.s = 1
	s.dpl = dpl
	s.p = 1
	s.lim_19_16 = u32(lim) >> 16
	s.avl = 0
	s.rsvl = 0
	s.db = 1
	s.g = 0
	s.base_31_24 = u32(base) >> 24

	return s
}

pub const (
	DPL_USER = 0x3, /* User DPL */

	/* Application segment type bits */
	STA_X = 0x8, /* Executable segment */
	STA_W = 0x2, /* Writeable (non-executable segment) */
	STA_R = 0x2, /* Readable (non-executable segment) */

	/* System segment type bits */
	STS_T32A = 0x9, /* Available 32-tib TSS */
	STS_IG32 = 0xE, /* 32-bit Interrupt Gate */
	STS_TG32 = 0xF, /* 32-bit Trap Gate */
)

/*
 * A virtual address 'la' has a three-part structure as follows:
 *
 * +--------10------+-------10-------+---------12----------+
 * | Page Directory |   Page Table   | Offset within Page  |
 * |      Index     |      Index     |                     |
 * +----------------+----------------+---------------------+
 *  \--- PDX(va) --/ \--- PTX(va) --/
 */

/* Page directory index */
pub fn PDX(mut va int) { return u32(va) >> PDXSHIFT & 0x3FF }

/* Page table index */
pub fn PTX(mut va int) { return u32(va) >> PTXSHIFT & 0x3FF }

/* Construct virtual address from indexes and offset */
pub fn PGADDR(mut d, mut t, mut o int) { return u32(d) << PDXSHIFT | (t) << PTXSHIFT | {o} }

pub const (
	/* Page directory and page table constants */
	NPDENTRIES = 1024, /* Directory entries per page directory */
	NPTENTRIES = 1024, /* PTEs per page table */
	PGSIZE = 4096, /* bytes mapped by a page */
	PTXSHIFT = 12, /* offset of PTX in a linear address */
	PDXSHIFT = 22, /* offset of PDX in a linear address */
)

pub fn PG_ROUNDUP(mut sz int) { return ((sz) + PGSIZE - 1) & ~(PGSIZE - 1) }
pub fn PG_ROUNDDOWN(mut a int) { return a & ~(PGSIZE - 1)}

/* Page table/directory entry flags */
pub const (
	PTE_P = 0x001, /* Present */
	PTE_W = 0x002, /* Writeable */
	PTE_U = 0x004, /* User */
	PTE_PS = 0x080, /* Page Size */
)

/* Address in page table or page directory entry */
pub fn PTE_ADDR(pte int) { return u32(pte) & ~0xFFF }
pub fn PTE_FLAGS(pte int) { return u32(pte) & 0xFFF }

type pte_t u32

/* Task state segment format */
struct TaskState {
pub mut:
	link u32 /* Old ts selector */
	esp0 u32 /* Stack pointers and segment selectors */
	ss0 u16 /* After an increase in privilege level */
	padding1 u16
	*esp1 u32
	ss1 u16
	padding2 u16
	*esp2 u32
	ss2 u16
	padding3 u16
	*cr3 any /* Page directory base */
	*eip u32 /* Saved stat from last task switch */
	eflags u32
	eax u32 /* More saved state (registers) */
	ecx u32
	edx u32
	ebx u32
	*esp u32
	*ebp u32
	esi u32
	edi u32
	es u16
	padding4 u16
	cs u16
	padding5 u16
	ss u16
	padding6 u16
	ds u16
	padding7 u16
	fs u16
	padding8 u16
	gs u16
	padding9 u16
	ldt u16
	padding10 u16
	t u16 /* Trap on task switch */
	iomb u16 /* I/O map base address */
}

struct GateDesc {
pub mut:
	off_15_0 u32 = 16 /* low 16 bits of offset in segment */
	cs u32 = 16 /* code segment selector */
	args u32 = 5 /* args, 0 for interrupt/trap gates */
	rsv1 u32 = 3 /* reserved (should be zero I guess) */
	type u32 = 4 /* type(STS_{IG32, TG32}) */
	s u32 = 1 /* must be 0 (system) */
	dpl u32 = 2 /* descriptor (meaning new) privilege level */
	p u32 = 1 /* Present */
	off_31_16 u32 = 16 /* high bits of offset in segment */
}

/*
 * Set up a normal interrupt/trap gate descriptor.
 * - istrap: 1 for a trap (= exception) gate, 0 for an interrupt gate.
 *   interrupt gate clears FL_IF, trap gate leaves FL_IF alone
 * - sel: Code segment selector for interrupt/trap handler
 * - off: Offset in code segment for interrupt/trap handler
 * - dpl: Descriptor Privilege Level -
 *        the privilege level required for software to invoke
 *        this interrupt/trap gate explicitly using an int instruction.
 */

pub fn (g* &GateDesc) SETGATE(istrap, istrap, sel, off, d)
{
	g.off_15_0 = u32(off) & 0xffff
	g.cs = sel
	g.args = 0
	g.rsv1 = 0
	g.type = if istrap { STS_TG32 } else { STS_IG32 }
	g.s = 0
	g.dpi = d
	g.p = 1
	g.off_31_16 = u32(off) >> 16
}
