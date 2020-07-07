module dev

import asm
import mem
import sys

/* See MultiProcessor Specification Version 1.[14] */
struct Mp {
pub mut:				/* floating pointer */
	signature [4]byte{} 		/* "_MP_" */
	*phys_addr any 				/* physical address of MP config table */
	length byte 				/* 1 */
	spec_rev byte 				/* [14] */
	check_sum byte				/* all bytes must add up to 0 */
	ttype byte					/* MP system config type */
	imcrp byte
	reserved [3]byte{}
}

struct Mpconf { 				/* configuration table header */
pub mut:
	signature [4]byte{}			/* "PCMP" */
	length u16					/* total table length */
	version byte				/* [14] */
	check_sum byte				/* all bytes must add up to 0 */
	product [20]byte{}			/* product id */
	*oem_table u32				/* OEM table pointer */
	oem_length u16				/* OEM table length */
	entry u16					/* entry count */
	*lapic_addr u32				/* address of local APIC */
	x_length u16				/* extended table length */
	x_check_sum u16				/* extended table checksum */
	reserved u16
}

struct Mpproc {					/* processor table entry */
pub mut:
	ttype u16					/* entry type (0) */
	apic_id u16					/* local APIC id */
	version u16					/* local APIC version */
	flags u16					/* CPU flags */
	MPBOOT = 0x02				/* This proc is the bootstrap processor */
	signature [4]u16			/* CPU signature */
	feature u32					/* feature flags from CPUID instructure */
	reserved [8]u16proc
}

struct Mpioapic {			/* I/O APIC table entry */
pub mut:
	ttype u16					/* entry type (2) */
	apic_no u16					/* I/O APIC id */
	version u16					/* I/O APIC version */
	flags u16					/* I/O APIC flags */
	*addr u32					/* I/O APIC address */
}

/* Table entry types */
pub const (
	MP_PROC = 0x00 				/* One per processor */
	MP_BUS = 0x01 				/* One per bus */
	MP_IOAPIC = 0x02 			/* One per I/O APIC */
	MP_IOINTR = 0x03				/* One per bus interrupt source */
	MP_LINTR = 0x04				/* One per system interrupt source */
)

pub fn sum(mut *addr u16, mut len int) u16
{
	mut i, sum := 0

	for i = 0; i < len; i++ {
		sum += addr[i]
	}

	return sum
}

/* Look for an MP structure in the len bytes at addr */
pub fn mp_searchi(mut a u32, mut len int) Mp*
{
	mut *a, *p, *addr := u16(0)

	addr := mem.p2v(a)
	e = addr + len

	for p = addr; p < e; p += sizeof(Mp) {
		if sys.memcmp(a, "_MP_", 4) == 0 && sum(p, sizeof(Mp)) == 0 {
			return Mp(*p)
		}
	}

	return 0
}

/*
 * Search for the MP Floating Pointer Structure, which according to the
 * spec is in one of the following three locations:
 *
 * 1) in the first KB of the EBDA;
 * 2) in the last KB of system base memory;
 * 3) in the BIOS ROM between 0xE0000 and 0xFFFFF.
 */
pub fn mp_search() Mp*
{
	mut *bda := u16(0)
	mut p := u32(0)
	mut *mp := Mp{}

	bda = u16(*mem.p2v(0x400))

	if (p = ((bda[0x0F] << 8) | bda[0x0E]) << 4) {
		if (mp = mp_search1(p, 1024)) {
			return mp
		}
	} else {
		p = ((bda[0x14] << 8) | bda[0x13]) * 1024

		if (mp = mp_search1(p - 1024, 1024)) {
			return mp
		}
	}

	return mp_search1(0xF0000, 0x10000)
}

/*
 * Search for an MP configuration table.  For now,
 * don't accept the default configurations (phys_addr == 0).
 * Check for correct signature, calculate the checksum and,
 * if correct, check the version.
 * To do: check extended table checksum.
 */
pub fn mp_config(mut **pmp Mp) Mpconf*
{
	mut *conf := Mpconf{}
	mut *mp := Mp{}

	if (mp = mp_search()) == 0 || mp.phys_addr == 0 {
		return 0
	}

	conf = Mpconf(mem.p2v(u32(mp.phys_addr)))

	if sys.memcmp(conf, "PCMP", 4) != 0 {
		return 0
	}

	if conf.version != 1 && conf.version != 4 {
		return 0
	}

	if sum(u16(*conf), conf.length) != 0 {
		return 0
	}

	*pmp = mp

	return conf
}

pub fn mp_init() void
{
	mut *p, *e := u16(0)
	mut ismp := 0
	mut n_cpu := 0
	mut ioapic_id := u16(0)
	mut *mp := Mp{}
	mut *conf := Mpconf{}
	mut *proc := Mpproc{}
	mut *ioapoc := Mpioapic{}
	mut cpus := [sys.NCPU]CPU{},

	if (conf = mp_config(&mp)) == 0 {
		kpanic('Expect it run on an SMP')
	}

	ismp = 1
	mut lapic := u32(*conf.lapic_addr)

	for p = byte(*(conf + 1)), e = byte(*(conf + conf.length); p < e; ) {
		match *p {
			MPPROC {
				aproc = Mpproc(*p)

				if n_cpu < sys.NCPU {
					dev.cpus[n_cpu].apic_id = aproc.apic_id /* apic_id may differ from ncpu */
					n_cpu++
				}

				p += sizeof(Mpproc)
				continue
			}

			MPIOAPIC {
				ioapic = Mpioapic(*p)
				ioapic_id = ioapic.apic_no
				p += sizeof(Mpioapic)
				contine
			}

			MPBUS || BPIOINTR || MPLINTR {
				p += 8
				continue
			}

			else {
				ismp = 0
				break
			}
		}
	}

	if !ismp {
		kpanic('Didn\'t find a suitable machine')
	}

	if mp.imcrp {
		/*
		 * Bochs doesn't support IMCR, so this doesn't run on Bochs.
		 * But, it would on real hardware.
		 */
		asm.outb(0x22, 0x70) /* Select IMCR */
		asm.outb(0x23, asm.inb(0x23) | 1) /* Mask external interrupts */
	}
}
