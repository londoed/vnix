module proc

import types
import defs
import param
import memlay
import mmu
import x86
import spinlock

struct PTable {
	lock Spinlock{},
	proc[NPROC] Proc{},
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
		die('my_cpu called with interrupts enabled')
	}

	api_cid = lapicid()

	for i = 0; i < ncpu; ++i {
		if cpus[i].api_cid == api_cid {
			return &cpus[i]
		}
	}

	die('unknown api_cid\n')
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

	acquire(&PTable.lock)

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
	memset(p.context, 0, sizeof(*p.context))
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
	if (p.pgdir = setup_kvm()) == 0 {
		die('user_init: out of memory?')
	}

	vm.init_uvm(p.pgdir, _binary_initcode_start, int(_binary_initcode_size))
	p.sz = PGSIZE
	memset(p.tf, 0, sizeof(*p.tf))

	p.tf.cs = (SEG_UCODE << 3) | DPL_USER
	p.tf.ds = (SEG_UDATA << 3) | DPL_USER
	p.tf.es = p.tf.ds
	p.tf.ss = p.tf.ds
	p.tf.eflags = FL_IF
	p.tf.esp = PGSIZE
	p.tf.eip = 0 // beginning of initcode.S

	safestrcopy(p.name, 'initcode', sizeof(p.name))
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
