module param

pub const (
	NPROC = 64, // maximum number of processes
	KSTACKSIZE = 4096, // size of per-process kernel stack
	NCPU = 8, // maximum number of CPUs
	NOFILE = 16, // open files per process
	NFILE = 100, // open files per system
	NINODE = 50, // maximum number of active i-nodes
	NDEV = 10, // maximum major device number
	ROOTDEV = 1, // device number of file system root disk
	MAXARG = 32, // maximum exec arguments
	MAXOPBLOCKS = 10, // max number of blocks any FS op writes
	LOGSIZE = MAXOPBLOCKS * 3, // max data blocks in on-disk log
	NBUF = MAXOPBLOCKS * 3, // size of disk block cache
	FSSIZE = 1000, // size of file system in blocks
)

pub fn nelem(x any) { return sizeof(x) / sizeof(x[0]) }
