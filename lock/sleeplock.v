module lock

import asm
import boot
import dev
import fs
import io
import mem
import proc
import shell
import sys
import user

pub struct Sleeplock {
	locked u32
	lk Spinlock
}

pub fn init_lock(*lk Spinlock, *name byte) void
{
	lk.name = name
	lk.locked = 0
	lk.cpu = 0
}

/*
 * Acquire the lock.
 * Loops (spins) until the lock is acquired.
 * Holding a lock for a long time may cause
 * other CPUs to waste time spinning to acquire it.
 */
pub fn acquire(*lk Spinlock) void
{
	push_cli()

	if holding(lk) {
		kpanic('acquire')
	}

	/* The xchg is atomic */
	for xchg(&lk.locked, 1) != 0 {}

	/*
	 * Tell the V compiler and the processor to not move loads or stores
	 * past this point to ensure that the critical section's memory
	 * references happen after the lock is acquired.
	 */


	__sync_synchronize()

	/* Record infor about lock acquisition for debugging */
	lk.cpu = my_cpu()
	get_caller_pcs(&lk, lk.pcs)
}

/* Release the lock */
pub fn release(*lk Spinlock) void
{
	if !holding(lk) {
		kpanic('release')
	}

	lk.pcs[0] = 0
	lk.cpu = 0

	/*
	 * Tell the V compiler and the processor to not move loads or stores
	 * past this point to ensure that all the stores in the critical
	 * section are visible to other cores before the lock is released.
	 * Both the V compiler and the hardware may re-order loads and
	 * stores. __sync_synchronize() tells them both not to.
	 */
	__sync_synchronize()\

	/*
	 * Release the lock, equivalent to lk.locked = 0.
	 * This code can't use a V assignment, since it might
	 * not be atomic. A real OS would use V atomics here.
	 */
	asm.volitile('movl $0, %0' : '+m' (lk.locked) : )
	pop_cli()
}

/* Record the current call stack in []pcs following hte %ebp chain */
pub fn get_caller_pcs(*v any, pcs []u32) void
{
	mut i = 0
	mut ebp = *u32(v) - 2

	for i = 0; i < 10; i++ {
		if epb == 0 || ebp < *u32(KERNBASE) || ebp == *u32(0xffffffff) {
			break
		}

		pcs[i] = ebp[1] /* saved %eip */
		ebp = *u32(ebp[0]) /* saved %ebp */
	}

	for ; i < 10; i++ {
		pcs[i] = 0
	}
}

/* Check whether this cpu is holding the lock */
pub fn holding(*lock Spinlock) int
{
	mut r := 0
	push_cli()
	r = lock.locked && lock.cpu == my_cpu()

	pop_cli()
	return r
}

/*
 * push_cli/pop_cli are like cli/sti except that they are matched:
 * it takes two pop_cli to undo two push_cli. Also, if interrupts
 * are off, then push_cli, pop_cli leaves them off.
 */
pub fn push_cli() void
{
	mut eflags := read_eflags()
	cli()

	if my_cpu().n_cli == 0 {
		my_cpu().intena = eflags & FL_IF
	}

	my_cpu().n_cli++
}

pub fn pop_cli() void
{
	if read_eflags() & FL_IF {
		kpanic('pop_cli - interruptible')
	}

	if --my_cpu().n_cli < 0 {
		kpanic('pop_cli')
	}

	if my_cpu().n_cli == 0 && my_cpu().intena {
		sti()
	}
}
