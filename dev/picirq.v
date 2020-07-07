module dev

import asm


/* I/O Addresses of the two programmable interrupt controllers */
const (
	IO_PIC1 = 0x20, /* Master (IRQs 0-7) */
	IO_PIC2 = 0xA0, /* Slave (IRQs 8-15) */
)

/* Don't use the 8259 interrupt controllers. VNIX assumes SMP hardware. */
pub fn pic_init() void
{
	/* Mask all interrupts */
	asm.outb(IO_PIC1 + 1, 0xFF)
	asm.outb(IO_PIC2 + 1, 0xFF)
}
