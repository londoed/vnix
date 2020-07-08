module fs

/* Format of an ELF executable file */

pub const (
	ELF_MAGIC = 0x464C457F /* "\x7FELF" in little endian */
)

pub struct ElfHdr {
pub mut:
	magic u32 /* must equal ELF_MAGIC */
	elf [12]u16{}
	type u16
	machine u16
	version u32
	entry u32
	phoff u32
	shoff u32
	flags u32
	eh_size u16
	phent_size u16
	ph_num u16
	shent_size u16
	sh_num u16
	shstr_ndx u16
}

pub struct ProgHdr{
pub mut:
	type u32
	off u32
	vaddr u32
	paddr u32
	file_sz u32
	mem_sz u32
	flags u32
	align u32
}

/* Values for ProgHdr type */
pub const (
	ELF_PROG_LOAD = 1

	/* Flag bits for ProgHdr flags */
	ELF_PROG_FLAG_EXEC = 1
	ELF_PROG_FLAG_WRITE = 2
	ELF_PROG_FLAG_READ = 4
)
