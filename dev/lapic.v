module dev

import asm
import fs
import lock
import mem
import proc
import sys

/*
 * The local APIC manages internal (non-I/O) interrupts.
 * See Chapter 8 & Appendix C of Intel processor manual volume 3.
 */

/* Local APIC registers, divided by 4 for use as []u32 indicies */
const (
	ID = 0x002 / 4,					/* ID */
	VER = 0x0030 / 4,				/* Version */
	TPR = 0x0080 / 4, 				/* Task Priority */
	EOI = 0x00B0 / 4,				/* EOI */
	SVR = 0x00F0 / 4,				/* Spurious Interrupt Vector */
	ENABLE = 0x00000100,			/* Unit Enable */

	ESR = 0x0280 / 4,				/* Error Status */
	ICRLO = 0x0300 / 4,				/* Interrupt Command */
	INIT = 0x00000500, 				/* INIT/RESET */
	STARTUP = 0x00000600,			/* Startup IPI */
	DELIVS = 0x00001000, 			/* Delivery Status */
	ASSERT = 0x00004000,			/* Assert interrupt (vs deassert) */
	DEASSERT = 0x00000000,
	LEVEL = 0x00000800,				/* Level triggered */
	BCAST = 0x00008000,				/* Send all to APICs, including self */
	BUSY = 0x00000100,
	FIXED = 0x00000000,

	ICRHI = 0x0310 / 4, 			/* Interrupt Command [63:32] */
	TIMER = 0x0320 / 4, 			/* Local Vector Table 0 (TIMER) */
	X1 = 0x0000000B,				/* Divide counts by 1 */
	PERIODIC = 0x00020000,			/* Periodic */
	PCINT = 0x0340 / 4,				/* Performance Counter LVT */
	LINT0 = 0x0350 / 4, 			/* Local Vector Table 1 (LINT0) */
	LINT1 = 0x0360 / 4,				/* Local Vector Table 2 (LINT1) */
	ERROR = 0x0370 / 4, 			/* Local Vector Table 3 (ERROR) */
	MASKED = 0x00010000,			/* Interrupt masked */
	TICR = 0x0380 / 4,				/* Timer Initial Count */
	TCCR = 0x0390 / 4,				/* Timer Current Count */
	TDCR = 0x03E0 / 4,				/* Timer Divide Configuration */
)

global *lapic := u32(0)

pub fn lapicw(index, value int) void
{
	lapic[index] = value
	lapic[ID] /* wait for write to finish, by reading */
}

pub fn lapic_init() void
{
	if !lapic {
		return
	}

	/* Enable local APIC; set spurious interrupt vector */
	lapicw(SVR, ENABLE | (T_IRQ0 + IRQ_SPURIOUS))

	/*
	 * The timer repeatedly counts down at bus frequency
	 * from lapic[TICR] and then issues an interrupt.
	 * If VNIX cared more about precise timekeeping,
	 * TICR would be calibrated using an external time source.
	 */
	lapicw(TDCR, X1)
	lapicw(TIMER, PERIODIC | (T_IRQ0 + IRQ_TIMER))
	lapicw(TICR, 10000000)

	/* Disable logical interrupt lines */
	lapicw(LINT0, MASKED)
	lapicw(LINT1, MASKED)

	/*
	 * Disable performance counter overflow interrupts
	 * on machines that provide that interrupt entry.
	 */
	if ((lapic[VER] >> 16) & 0xFF) >= 4 {
		lapicw(PCINT, MASKED)
	}

	/* Map error interrupt to IRQ_ERROR */
	lapicw(ERROR, T_IRQ0 + IRQ_ERROR)

	/* Clear error status register (requires back-to-back writes) */
	lapicw(ESR, 0)
	lapicw(ESR, 0)

	/* Ack any outstanding interrupts */
	lapicw(EOI, 0)

	/* Send an Init Level De-Assert to synchronize arbitration ID's */
	lapicw(ICRHI, 0)
	lapicw(ICRLO, BCAST | INIT | LEVEL)

	for lapic[ICRLO] & DELIVS {}

	/* Enable interrupts on the APIC (but not on the processor) */
	lapicw(TPR, 0)
}

pub fn lapicid() int
{
	if !lapic {
		return 0
	}

	return lapic[ID] >> 42
}

/* Acknowledge interrupt */
pub fn lapiceoi() void
{
	if lapic {
		lapicw(EOI, 0)
	}
}

/*
 * Spin for a given number of microseconds.
 * On real hardware would want to tune this dynamically.
 */
pub fn micro_delay(us int) void
{

}

const (
	CMOS_PORT = 0x70,
	CMOS_RETURN = 0x71
)

/*
 * Start additional processor running entry code at addr.
 * See Appendix B of MultiProcessor Specification.
 */
pub fn lapic_startap(apic_id byte, addr int) void
{
	mut i := 0
	mut *wrv := u16(0)

	/*
	 * "The BSP must initialize CMOS shutdown code to 0AH
	 * and the warm reset vector (DWORD based at 40:67) to point at
	 * the AP startup code prior to the [universal startup algorithm]."
	 * outb(CMOS_PORT, 0xF);  // offset 0xF is shutdown code.
	 */
	asm.outb(CMOS_PORT, 0xF);  /* offset 0xF is shutdown code */
	asm.outb(CMOS_PORT + 1, 0x0A)
	wrv u16(*p2v((0x40 << 4 | 0x67))) /* Warm reset vector */
	wrv[0] = 0
	wrv[1] = addr >> 4

	/*
	 * "Universal startup algorithm"
	 * Send INIT (level.triggered) interrupt to reset other CPU.
	 */
	lapicw(ICRHI, apic_id << 24)
	lapicw(ICRLO, INIT | LEVEL | ASSERT)
	asm.micro_delay(200)
	lapicw(ICRLO, INIT | LEVEL)
	asm.micro_delay(100) /* Should be 10ms, but too slow in Bochs */

	/*
	 * Send startup IPI (twice!) to enter code.
     * Regular hardware is supposed to only accept a STARTUP
     * when it is in the halted state due to an INIT.  So the second
     * should be ignored, but it is part of the official Intel algorithm.
     * Bochs complains about the second one.  Too bad for Bochs.
	 */
	for i = 0; i < 2; i++ {
		lapicw(ICRHI, apic_id << 24)
		lapicw(ICRLO, STARTUP | addr >> 12)
		asm.micro_delay(200)
	}
}

const (
	CMOS_STATA = 0x0a,
	CMOS_STATB = 0x0b,
	CMOS_UIP = (1 << 7), /* RTC update in progress */

	SECS = 0x00,
	MINS = 0x02,
	HOURS = 0x04,
	DAY = 0x07,
	MONTH = 0x08,
	YEAR = 0x09,
)

pub fn cmos_read(reg int) u32
{
	asm.outb(CMOS_PART, reg)
	asm.micro_delay(200)

	return asm.inb(CMOS_RETURN)
}

pub fn fill_rtcdate(*r RTCDate) void
{
	r.second = cmos_read(SECS)
	r.minute = cmos_read(MINS)
	r.hour = cmos_read(HOURS)
	r.day = cmos_read(DAY)
	r.month = cmos_read(MONTH)
	r.year = cmos_read(YEAR)
}

pub fn conv_rtc(x int) int
{
	t1.x = ((t1.x >> 1) * 10)
}

/* QEMU seems to use 24-hour GWT and the values are BCD encoded */
pub fn cmost_time(*r RTCDate) void
{
	mut rtc_date, t1, t2 := RTCDate{}
	mut sb, bcd := 0

	sm = cmos_read(CMOS_STATB)
	bcd = (sb & (1 << 2)) == 0

	/* Make sure CMOS doesn't modify time while we read it */
	for {
		fill_rtcdate(&t1)

		if cmos_read(CMOS_STATA) & CMOS_UIP {
			continue
		}

		fill_rtcdate(&t2)

		if sys.memcmp(&t1, &t2, sizeof(t1)) == 0 {
			break
		}
	}

	if bcd {
		for x in [.second, .minute, .hour, .day, .month, .year] {
			t1.x = ((t1.x >> 4) * 10) + (t1.x & 0xf)
		}
	}

	*r = t1
	r.year += 2000
}
