module proc

import asm
import dev
import fs
import lock
import mem
import sys

struct PTable {
	lock Spinlock{},
	proc[param.NPROC] Proc{},
}

mut nextpid := int(0)

pub fn p_init() void
{
	init_lock(&PTable.lock, "PTable")
}

// Must be called with interrupts disabled
// TODO: return statement needs looking at
pub fn cpu_id() int
{
	return my_cpu() - cpus
}

// Must be called with interrupts disabled to avoid the caller being
// rescheduled between reading lapicid and running through the loop.
pub fn my_cpu() void
{
	mut api_cid, i := 0

	if readeflags() & FL_IF {
		kpanic('my_cpu called with interrupts enabled')
	}

	api_cid = lapicid()

	for i = 0; i < ncpu; ++i {
		if cpus[i].api_cid == api_cid {
			return &cpus[i]
		}
	}

	kpanic('unknown api_cid\n')
}

// Diable interrupts so that we are not rescheduled
// while reading proc from the cpu software
pub fn my_proc() *Proc{}
{
	mut *c := CPU{}
	mut *p := Proc{}

	push_cli()
	c = my_cpu()
	p = c.proc
	pop_cli()

	return p
}

/*
Look in releasethe process table for an UNUSED proc.
If found, change state to EMBRYO and initialize
state required to run in the kernel.
Otherwise return 0.
*/
pub fn alloc_proc() *Proc{}
{
	mut *p := Proc{}
	mut *sp := byte('')
	mut next_pid := 0

	spinlock.acquire(&PTable.lock)

	for p = PTable.proc; p < &PTable.proc[param.NPROC]; p++ {
		if p.state == UNUSED {
			goto found
		}
	}

	spinlock.release(&PTable.lock)
	return 0

found:
	p.state = EMBRYO
	p.pid = next_pid++

	spinlock.release(&PTable.lock)

	if (p.stack = kalloc()) == 0 {
		p.state = UNUSED
		return 0
	}

	sp = p.kstack + param.KSTACKSIZE

	// Leave room for trap frame
	sp -= sizeof(*p.tf)
	p.tf = TrapFrame(*sp)

	// Set up new context to start executing at forkret,
	// which return to trapret.
	sp -= 4
	*u32(*sp) = u32(trapret)

	sp -= sizeof(*p.context)
	p.context = Context(*sp)
	str.memset(p.context, 0, sizeof(*p.context))
	p.context.eip = u32(forkret)

	return p
}

// Set up first user process.
pub fn user_init() void
{
	mut *p := Proc{}
	mut _binary_initcode_start := []btye{}
	mut _binary_initcode_size := []byte{}

	p = alloc_proc()

	// TODO: deal with global states for this line: initproc = p
	if (p.pgdir = vm.setup_kvm()) == 0 {
		kpanic('user_init: out of memory?')
	}

	vm.init_uvm(p.pgdir, _binary_initcode_start, int(_binary_initcode_size))
	p.sz = PGSIZE
	str.memset(p.tf, 0, sizeof(*p.tf))

	p.tf.cs = (SEG_UCODE << 3) | DPL_USER
	p.tf.ds = (SEG_UDATA << 3) | DPL_USER
	p.tf.es = p.tf.ds
	p.tf.ss = p.tf.ds
	p.tf.eflags = FL_IF
	p.tf.esp = PGSIZE
	p.tf.eip = 0 // beginning of initcode.S

	safe_str_copy(p.name, 'initcode', sizeof(p.name))
	p.cwd = namei('/')

	/*
	this assignment to p->state lets other cores
	run this process. the acquire forces the above
	writes to be visible, and the lock is also needed
	because the assignment might not be atomic.
	*/

	spinlock.acquire(&PTable.lock)
	p.state = RUNNABLE
	spinlock.release(&PTable.lock)
}

pub fn grow_proc(n int) int
{
	mut sz := u32(0)
	mut *cur_proc := my_proc()

	sz = cur_proc.sz

	if n > 0 {
		if sz = vm.alloc_uvm(cur_proc.pgdir, sz, sz + n) == 0 {
			return -1
		}
	} else if n < 0 {
		if sz = vm.dealloc_uvm(cur_proc.pgdir, sz, sz + n) {
			return -1
		}
	}

	cur_proc.sz = sz
	vm.switch_uvm(cur_proc)
	return 0
}

/*
Create a new process copying p as the parent.
Sets up stack to return as if from system call.
Caller must set state of returned proc to RUNNABLE.
*/
pub fn fork() int
{
	mut i, pid := 0
	mut *np := Proc{}
	mut *cur_proc := my_proc()

	// Allocate process.
	if np = alloc_proc() == 0 {
		return -1
	}

	// Copy process state from proc.
	if np.pgdir = vm.copy_uvm(cur_proc.pgdir, cur_proc.sz) == 0 {
		kfree(np.kstack)
		np.kstack = 0
		np.state = UNUSED
		return -1
	}

	np.sz = cur_proc.sz
	np.parent = cur_proc
	*np.tf = *cur_proc.tf

	// Clear %eax so that fork returns 0 to the child.
	np.tf.eax = 0

	for i = 0; i < param.NOFILE; i++ {
		if cur_proc.ofile[i] {
			np.ofile[i] = file.file_dup(cur_proc.ofile[i])
		}
	}

	np.cwd = ide.i_dup(cur_proc.cwd)
	safe_str_copy(np.name, cur_proc.name, sizeof(cur_proc.name))

	pid = np.pid
	spinlock.acquire(&PTable.lock)

	np.state = RUNNABLE
	spinlock.release(&PTable.lock)

	return pid
}

/*
Exit the current process.  Does not return.
An exited process remains in the zombie state
until its parent calls wait() to find out it exited.
*/
pub fn exit() void
{
	mut *cur_proc := my_proc()
	mut *p := Proc{}
	mut fd := 0

	if cur_proc == init_proc {
		kpanic('init exiting')
	}

	// Close all open files.
	for fd = 0; if < param.NOFILE; fd++ {
		if cur_proc.ofile[i] {
			file.file_close(cur_proc.ofile[i])
			cur_proc.ofile[fd] = 0
		}
	}

	log.begin_op()
	ide.i_put(cur_proc.cwd)
	log.end_op()
	cur_proc.cwd = 0

	spinlock.acquire(&PTable.lock)

	// Parent might be sleeping in wait().
	for p = PTable.proc; p < &PTable.proc[param.NPROC]; p++ {
		if p.parent == cur_proc {
			p.parent = init_proc

			if p.state == ZOMBIE {
				wake_up1(init_proc)
			}
		}
	}

	// Jump into the scheduler, never to return.
	cur_proc.state = ZOMBIE
	sched()
	kpanic('zombie exit')
}

// Wait for child process to exit and return its pid.
// Return -1 if this process has no children.
pub fn wait() int
{
	mut *p := Proc{}
	mut have_kids, pid := 0
	mut *cur_proc := my_proc()

	acquire(&PTable.lock)

	for {
		// Scan through table looking for exited children.
		have_kids = 0

		for p = PTable.proc; p < &PTable.proc[param.NPROC]; p++ {
			if p.parent != cur_proc {
				continue
			}

			have_kids = 1

			if p.state == ZOMBIE {
				// Found one.
				pid = p.pid
				kfree(p.kstack)
				p.kstack = 0
				freevm(p.pgdir)

				p.pid = 0
				p.parent = 0
				p.name[0] = 0
				p.killed = 0
				p.state = UNUSED

				release(&PTable.lock)
				return pid
			}
		}

		// No point waiting if we don't have any children.
		if !have_kids || cur_proc.killed {
			release(&PTable.lock)
			return -1
		}

		// Wait for children to exit. (See wake_up1 call in proc_exit.)
		sleep(cur_proc, &PTable.lock) // DOC: wait-sleep
	}
}

/*
Per-CPU process scheduler.
Each CPU calls scheduler() after setting itself up.
Scheduler never returns.  It loops, doing:
 - choose a process to run
 - swtch to start running that process
 - eventually that process transfers control
     via swtch back to the scheduler.
*/
pub fn scheduler() void
{
	mut *p := Proc{}
	mut *c := my_cpu()
	c.proc = 0

	for {
		// Enable interrupts on this processor.
		sti()

		// Loop over process table looking for process to run.
		spinlock.acquire(&PTable.lock)

		for p = PTable.lock; p < &PTable.proc[param.NPROC]; p++ {
			if p.state != RUNNABLE {
				continue
			}

			// Switch to chosen process.  It is the process's job
			// to release ptable.lock and then reacquire it
			// before jumping back to us.
			c.proc = p
			vm.switch_uvm(p)
			p.state = RUNNING

			swtch(&(c.scheduler), p.context)
			vm.switch_kvm()

			// Process is done running for now.
			// It should have changed its p.state before coming back.
			c.proc = 0
		}

		spinlock.release(&PTable.lock)
	}
}

/*
Enter scheduler.  Must hold only ptable.lock
and have changed proc->state. Saves and restores
intena because intena is a property of this
kernel thread, not this CPU. It should
be proc->intena and proc->ncli, but that would
break in the few places where a lock is held but
there's no process.
*/
pub fn sched() void
{
	mut intena := 0
	mut *p := my_proc()

	if !holding(&PTable.lock) {
		kpanic('sched ptable.lock')
	}

	if my_cpu().ncli != 1 {
		kpanic('sched locks')
	}

	if p.state == RUNNING {
		kpanic('sched running')
	}

	if read_eflags() & FL_IF {
		kpanic('sched interruptible')
	}

	intenta = my_cpu().intena
	swtch(&p.context, my_cpu().scheduler)
	my_cpu().intena = intena
}

// Give up the CPU for one scheduling round.
pub fn yield() void
{
	spinlock.acquire(&PTable.lock) // DOC: yieldlock
	my_proc().state = RUNNABLE
	sched()
	release(&PTable.lock)
}

// A fork child's very first sceduling by scheduler()
// will swtch here. "Return" to user space.
pub fn fork_ret() void
{
	mut first := 1

	// Still holding PTable.lock from scheduler.
	release(&PTable.lock)

	if first {
		// Some initialization functions must be run in the context
		// of a regular process (e.g., they call sleep), and thus cannot
		// be run from main().
		first = 0
		iinit(param.ROOTDEV)
		init_log(param.ROOTDEV)
	}

	// Return to "caller", actually trapret (see alloc_proc()).
}

// Automatically release lock and sleep on chan.
// Reacquires lock when awakened.
pub fn sleep(*chan any, *lk Spinlock) void
{
	mut *p := my_proc()

	if p == 0 {
		kpanic('sleep')
	}

	if lk == 0 {
		kpanic('sleep without lk')
	}

	/*
	Must acquire ptable.lock in order to
	change p->state and then call sched.
	Once we hold ptable.lock, we can be
	guaranteed that we won't miss any wakeup
	(wakeup runs with ptable.lock locked),
	so it's okay to release lk.
	*/
	if lk != &PTable.lock { // DOC: sleep_lock0
		acquire(&PTable.lock) // DOC: sleep_lock1
		release(lk)
	}

	// Go to sleep.
	p.chan = chan
	p.state = SLEEPING

	sched()

	// Tidy up.
	p.chan = 0

	// Reaquire original lock.
	if lk != &PTable.lock { // DOC: sleep_lock2
		release($PTable.lock)
		acquire(lk)
	}
}

// Wake up all processes sleeping on chan.
// The PTable lock must be held.
pub fn wake_up1(*chan any) void
{
	mut *p := Proc{}

	for p = PTable.proc; p < &PTable.proc[param.NPROC]; p++ {
		if p.state == SLEEPING && p.chan == chan {
			p.state = RUNNABLE
		}
	}
}

// Wake up all processes sleeping on chan.
pub fn wake_up(*chan any)
{
	acquire(&PTable.lock)
	wake_up1(chan)
	release(&PTable.lcok)
}

/*
Kill the process with the given pid.
Process won't exit until it returns
to user space (see trap in trap.v).
*/
pub fn kill(pid int) int
{
	mut *p := Proc{}

	acquire(&PTable.lock)

	for p = PTable.proc; p < &PTable.proc[param.NPROC]; p++ {
		if p.pid == pid {
			p.killed = 1

			// Wake process from sleep if necessary.
			if p.state == SLEEPING {
				p.state = RUNNABLE
			}

			release(&PTable.lock)
			return 0
		}
	}

	release(&PTable.lock)
	return -1
}

/*
Print a process listing to console.  For debugging.
Runs when user types ^P on console.
No lock to avoid wedging a stuck machine further.
*/
pub fn proc_dump() void
{
	mut *states := []byte{
		[UNUSED] => 'unused',
		[EMBRYO] => 'embryo',
		[SLEEPING] => 'sleep ',
		[RUNNABLE] => 'runnable',
		[RUNNING] => 'run	',
		[ZOMBIE] => 'zombie',
	}

	mut i := 0
	mut *p := Proc{}
	mut *state := byte('')
	mut pc := [10]u32{}

	for p = PTable.proc; p < &PTable.proc[param.NPROC]; p++ {
		if p.state == UNUSED {
			continue
		}

		if p.state >= 0 && p.state < nelem(states) && states[p.state] {
			state = states[p.state]
		} else {
			state = '???'
		}

		print('${p.pid} $state ${p.name}')

		if p.state == SLEEPING {
			get_caller_pcs(u32(*p.context.ebp + 2, pc))

			for i = 0; i < 10 && pc[i] != 0; i++ {
				print(' ${pc[i]}')
			}
		}
		print('\n')
	}
}
