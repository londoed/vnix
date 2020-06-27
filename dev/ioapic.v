module dev

import asm
import fs
import lock
import mem
import proc
import sys

/*
 * The I/O APIC manages hardware interrupts for an SMP system.
 * http://www.intel.com/design/chipsets/datashts/29056601.pdf
 * See also picirq.c.
 */

pub const (
	IOAPIC = 0xFEC0000, /* Default physical address of IO APIC */
	REG_ID = 0x00, /* Register index: ID */
	REG_VER = 0x01, /* Register index: version */
	REG_TABLE = 0x10, /* Redirection table base */

	/*
	 * The redirection table starts at REG_TABLE and uses
	 * two registers to configure each interrupt.
	 * The first (low) register in a pair contains configuration bits.
	 * The second (high) register contains a bitmask telling which
	 * CPUs can serve that interrupt.
	 */
	INT_DISABLED = 0x00010000, /* Interrupt disabled */
	INT_LEVEL = 0x00008000, /* Level-triggered (vs edge-) */
	INT_ACTIVELOW = 0x00002000, /* Active low (vs high) */
	INT_LOGICAL = 0x000008000, /* Destination is CPU id (vs APIC ID) */
)

/* IO APIC MMIO structure: write reg, then read or write data */
pub struct Ioapic {
	reg u32
	pad [3]u32{}
	data u32
}

pub fn ioapic_read(reg int) u32
{
	Ioapic.reg = reg
	return Ioapic.data
}

pub fn ioapic_write(reg int, data u32) void
{
	Ioapic.reg = reg
	Ioapic.data = data
}

pub fn ioapic_init() void
{
	mut i, id, max_intr := 0
	mut ioapic := Ioapic{}

	max_intr := (ioapic_read(REG_VER) >> 16) & 0xFF
	id = ioapic_read(REG_ID) >> 24

	if id != ioapic_id {
		println('ioapic_init: id isn\'t equal to ioapic_id; not a MP')
	}

	/*
	 * Mark all interrupts edge-triggered, active high, disabled,
	 * and not routed by any CPUs.
	 */
	for i = 0; i <= max_intr; i++ {
		ioapic_write(REG_TABLE + 2 * i, INT_DISABLED | (T_IRQ0 + i))
		ioapic_write(REG_TABLE + 2 * i + 1, 0)
	}
}

pub fn ioapic_enable(irq, cpu_num int) void
{
	/*
	 * Mark interrupt edge-triggered, active high,
	 * enabled, and routed to the given cpu_num,
	 * which happens to be that CPU's APIC ID.
	 */
	ioapic_write(REG_TABLE + 2 * irq, T_IRQ0 + irq)
	ioapic_write(REG_TABLE + 2 * irq + 1, cpu_num << 24)
}
