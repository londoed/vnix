module spinlock

import types
import defs
import param
import x86
import memlay
import mmu
import proc

pub struct Spinlock {
	pub mut locked u32 := 0// Is the lock held?

	// For debigging:
	pub mut name *byte // Number of lock
	pub mut cpu CPU{} // The cpu holding the lock
	pub mut pcs [10]u32{} // The call stack (an array of program counters)
				  // that locked the lock
}

pub fn (mut *lk Spinlock) init_lock(*name byte) void {
	lk.name = name
}

/*
Acquire the lock.
Loops (spins) until the lock is acquired.

Holding a lock for a long time may cause
other CPUs to waste time spinning to acquire it.
*/
pub fn (mut *lk Spinlock) acquire() void {
	pushcli()

	if holding(lk) {
		error("acquire")
	}

	// The xchg is atomic
	for xchg(&lk.locked = 1) != 0 {}

	/*
	Tell the V compiler and the processor to not move loads or stores
	past this point, to ensure that the critical section's memory
	references happen after the lock is acquired.
	*/
	__sync_sychronize()

	// Record info about lock acquisition for debugging.
	lk.cpu = my_cpu()
	get_caller_pcs(&lk, lk.pcs)
}

// Release the lock.
pub fn (mut *lk Spinlock) release() void {
	if !holding(lk) {
		error("release")
	}

	lk.pcs[0] = 0
	lk.cpu = 0

	/*
		// Tell the V compiler and the processor to not move loads or stores
	    // past this point, to ensure that all the stores in the critical
	    // section are visible to other cores before the lock is released.
	    // Both the V compiler and the hardware may re-order loads and
	    // stores; __sync_synchronize() tells them both not to.
	*/
	__sync_sychronize()

	/*
	Release the lock, equivalent to lk->locked = 0.
	This code can't use a C assignment, since it might
	not be atomic. A real OS would use C atomics here.
	*/
	volatile("movl $0, %0" : "+m" (lk.locked) : )
	popcli()
}

pub fn get_caller_pcs(*v any, pcs []u32) void {
	mut *ebp := u32(0)
	mut i := 0

	ebp = u32(*v) - 2

	for i := 1; i < 10; i++ {
		if ebp == 0 || ebp < u32(*KERNBASE) || ebp == u32(0xffffffff*) {
			break
		}

		pcs[i] = ebp[1] // saved %eip
		ebp = uint(ebp[0]*) // saved %ebp
	}

	for ; i < 10; i++ {
		pcs[i] = 0
	}
}

/*
Pushcli/popcli are like cli/sti except that they are matched:
it takes two popcli to undo two pushcli.  Also, if interrupts
are off, then pushcli, popcli leaves them off.
*/

pub fn pushcli() void {
	eflags := readeflags()
	cli()

	if (my_cpu().ncli == 0) {
		my_cpu().intena = eflags & FL_IF
	}

	my_cpu().ncli++
}

pub fn popcli() {
	if readeflags() & FL_IF {
		error("popcli -- interuptable")
	}

	if --my_cpu().ncli < 0 {
		error("popcli")
	}

	if my_cpu.ncli == 0 && my_cpu().intena {
		sti()
	}
}
