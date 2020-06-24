module exec

import type
import param
import memlay
import mmu
import proc
import defs
import x86
import elf
import fs
import stat

pub fn exec(mut *path byte, mut **argv byte) int
{
	mut *s, *last := byte(0)
	mut i, off := 0
	mut argc, sz, sp := u32(0)
	mut ustack := [3 + param.MAXARG + 1]u32
	mut elf := Elfhdr{}
	mut *ip := Inode{}
	mut ph := Proghdr{}
	mut *pgdir, *old_pgdir := pde_t(0)
	mut *cur_proc := proc.my_proc()

	stat.begin_op()

	if (ip = fs.namei(path)) == 0 {
		stat.end_op()
		println('exec: fail')
		return -1copy_out
	}

	fs.i_lock(ip)
	pgdir = 0

	/* Check ELF header */
	if fs.readi(ip, charptr(&elf), 0, sizeof(elf)) != sizeof(elf) {
		goto bad
	}

	if elf.magic != ELF_MAGIC {
		goto bad
	}

	if (pgdir = vm.setup_kvm()) == 0 {
		goto bad
	}

	/* Load program into memory */
	sz = 0

	for i = 0, off = elf.ph_off; i < elf.ph_num; i++, off += sizeof(ph) {
		if fs.readi(ip, charptr(&ph), off, sizeof(ph)) != sizeof(ph) {
			goto bad
		}

		if ph.type != ELF_PROG_LOAD {
			continue
		}

		if ph.memz < ph.file_sz {
			goto bad
		}

		if ph.vaddr + ph.mem_sz < ph.vaddr {
			goto bad
		}

		if (sz = vm.alloc_uvm(pgdir, sz, ph.vaddr + ph.mem_sz)) == 0 {
			goto bad
		}

		if ph.vaddr % PGSIZE != 0 {
			goto bad
		}

		if vm.load_uvm(pgdir, charptr(ph.vaddr), ip, ph.off, pf.file_sz) < 0 {
			goto bad
		}
	}

	fs.i_unlockput(ip)
	stat.end_op()
	ip = 0

	/*
	 * Allocate two pages at the next page boundary.
	 * Make the first inaccessible. Use the second as the user stack.
	 */
	sz = pg_round_up(sz)

	if (sz = vm.alloc_uvm(pgdir, sz, sz + 2 * PGSIZE)) == 0 {
		goto bad
	}

	clear_pteu(pgdir, charptr(sz - 2 * PGSIZE))
	sp = sz

	/* Push argument strings, prepare rest of stack in ustack. */
	for argc = 0; argv[argc]; argc++ {
		if argv >= param.MAXARG {
			goto bad
		}

		sp = (sp - argv[argc].len + 1) & ~3

		if vm.copy_out(pgdir, sp, ustack, (3 + argc + 1) * 4) < 0 {
			goto bad
		}

		ustack[3 + argc] = sp
	}

	ustack[0] =0xffffffff /* fake return PC */
	ustack[1] = argc
	ustack[2] = sp - (argc + 1) * 4 /* argv pointer */

	sp -= (3 + argc + 1) * 4

	if vm.copy_out(pgdir, sp, ustack, (3 + argc + 1) * 4) < 0 {
		goto bad
	}

	/* Save program for debugging */
	for last = s = path; *s; s++ {
		if *s == '/' {
			last = s + 1
		}
	}

	safe_str_copy(cur_proc.name, last, sizeof(cur_proc.name))

	/* Commit to the user image */
	old_pgdir = cur_proc.pgdir
	cur_proc.pgdir = pgdir
	cur_proc.sz = sz
	cur_proc.tf.eip = elf.entry /* main */
	cur_proc.tf.esp = sp

	vm.switch_uvm(cur_proc)
	vm.freevm(old_pgdir)

	return 0

bad:
	if pgdir {
		vm.freevm(pgdir)
	}

	if ip {
		fs.i_unlockput(ip)
		stat.end_op()
	}

	return -1
}
