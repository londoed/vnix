module dev

import asm
import fs
import lock
import mem
import proc
import sys

// x86 trap and interrupt constants.

const (
	T_DIVIDE = 0, // divide error
	T_DEBUG = 1, // debug exception
	T_NMI = 2, // non-maskable interrupt
	T_BRKPT = 3, // breakpoint
	T_OFLOW = 4, // overflow
	T_BOUND = 5, // bounds check
	T_ILLOP = 6, // illegal opcode
	T_DEVICE = 7, // device not available
	T_DBLFLT = 8, // double fault
	// T_COPROC = 9, // reserved
	T_TSS = 10, // invalid task switch statement
	T_SEGNP = 11, // segment not present
	T_STACK = 12, // stack exception
	T_GPFLT = 13, // general protection fault
	T_PGFLT = 14, // page fault
	// T_RES = 15 // reserved
	T_FPERR = 16, // floating point error
	T_ALIGN = 17, // alignment check
	T_MCHK = 18, // machine check
	T_SIMDERR = 19, // SIMD floating point error

	// These are arbitrarily chose, but with care not to overlap
	// processor defined exceptions or interrupt vectors.
	T_SYSCALL = 64, // system call
	T_DEFAULT = 500, // catchall
	T_IRQ0 = 32, // IRQ 0 corresponds to int T_IRQ

	IRQ_TIMER = 0,
	IRQ_KBD = 1,
	IRQ_COM1 = 4,
	IRQ_IDE = 14,
	IRQ_ERROR = 19,
	IRQ_SPURIOUS = 31,
)

global (
	ide [256]GateDesc{},
	vectors []byte,
	ticks_lock spinlock.Spinlock,
	ticks byte,
)

pub fn tv_init() void
{
	mut i := 0

	for i = 0; i < 256; i++ {
		SETGATE(idt[i], 0, SEG_KCODE << 3, vectors[i], 0)
	}

	SETGATE(idt[T_SYSCALL], 1, SEG_KCODE << 3, vectors[T_SYSCALL], DPL_USER)

	spinlock.init_lock(&ticks_lock, 'time')
}

pub fn idt_init() void
{
	lidt(idt, sizeof(idt))
}

pub fn trap(*tf TrapFrame) void
{
	if tf.trap_no == T_SYSCALL {
		if proc.my_proc().killed {
			proc.exit()
		}

		my_proc.tf = tf
		syscall.sys_call()

		if proc.my_proc().killed {
			proc.exit()
		}

		return
	}

	match tf.trap_no {
		T_IRQ0 + IRQ_TIMER {
			if cpu_id() == 0 {
				spinlock.acquire(&ticks_lock)
				ticks++
				proc.wake_up(&ticks)
				spinlock.release(&ticks_lock)
			}

			lapiceoi()
		}

		T_IRQ0 + IRQ_IDE {
			ide.ide_intr()
			lapiceoi()
		}

		T_IRQ0 + IRQ_IDE + 1 {
			// Bochs generates spurious IDE1 interrupts.
		}

		T_IRQ0 + IRQ_KBD {
			kbd_intr()
			lapiceoi()
		}

		T_IRQ0 + IRQ_COM1 {
			uart_intr()
			lapiceoi()
		}

		T_IRQ0 + 7 || T_IRQ0 + IRQ_SPURIOUS {
			println('cpu${cpu_id()}: spurious interrupt at ${tf.cs}:${tf.eip}')
			lapiceoi()
		}

		else {
			if proc.my_proc() == 0 || (tf.cs & 3) == 0 {
				// In kernel, it must be our mistake.
				println('unexpected trap ${tf.trap_no} from cpu ${cpu_id()} eip ${tf.eip} (cr2=0x${rcr2()})')
				kpanic('trap')
			}

			// In user space, assume process misbehaved.
			println('pid ${my_proc().pid} ${my_proc().name}: trap ${tf.trap_no} err ${tf.err} on cpu ${cpu_id()} eip 0x${tf.eip} addr 0x${rcr2()}--kill proc')

			proc.my_proc.killed = 1
		}
	}

	// Force process exit if it has been killed and is in user space.
	// (If it is still executing in the kernel, let it keep running
	// until it gets to the regular system call return.)
	if proc.my_proc() && proc.my_proc().killed && (tf.cs & 3) == DPL_USER {
		proc.exit()
	}

	// Force process to give up CPU on clock tick.
	// If interrupts were on while locks held, would need to check nlock.
	if proc.my_proc() && proc.my_proc().state == RUNNING && tf.trap_no == T_IRQ0 + IRQ_TIMER {
		proc.yield()
	}

	// Check if the process has been killed since we yielded.
	if proc.my_proc() &&  proc.my_proc().killed && (tf.cs & 3) == DPL_USER {
		proc.exit()
	}
}
