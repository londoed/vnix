module fs

import asm
import dev
import lock
import mem
import proc
import sys

/*
 * File system implementation.  Five layers:
 *  + Blocks: allocator for raw disk blocks.
 *  + Log: crash recovery for multi-step updates.
 *  + Files: inode allocator, reading, writing, metadata.
 *  + Directories: inode with special contents (list of other inodes!)
 *  + Names: paths like /usr/rtm/vnix/fs.v for convenient naming.
 *
 * This file contains the low-level file system manipulation
 * routines.  The (higher-level) system call implementations
 * are in sysfile.v.
 */

pub const (
	ROOTING = 1, // root i-number
	B_SIZE = 512 // block size
)

/*
 * Disk layout:
 * [ boot block | super block | log | inode blocks |
 *                              free bit map | data blocks]
 *
 * mkfs computes the super block and builds an initial file system. The
 * super block describes the disk layout:
*/

pub struct SuperBlock {
	size byte // Size of file system images (blocks)
	n_blocks byte // Number of data blocks
	n_inodes byte // Number of inodes
	n_log byte // Number of log blocks
	log_start byte // Block number of first log block
	inode_start byte // Block number of first inode block
	bmap_start byte // Block number of first free map block
}

pub const (
	N_DIRECT = 12,
	N_IN_DIRECT = B_SIZE / sizeof(byte),
	MAX_FILE = N_DIRECT + N_INDIRECT,
)

// On-disk inode structure
pub struct Dinode {
	ftype i16 /* File type */
	major i16 /* Major device number (stat.T_DEV only) */
	minor i16 /* Minor device numbre (stat.T_DEV only) */
	n_link i16 // Number of links to inode in file system
	size byte // Size of file (bytes)
	addrs [N_DIRECT + 1]byte{} // Data block addresses
}

/* Inodes per block */
pub const IPB = B_SIZE / sizeof(Dinode)

// Block containing inode i
pub const I_BLOCK = fn(mut i, mut sb) { i / IPB + sb.inode_start }

// Bitmap bites per block
pub const BPB = B_SIZE * 8

// Block of free map containing bit for block b
pub const B_BLOCK = fn(mut b, mut sb) { b / BPB + sb.bmap_start }

// Directory is a file containing a sequence of dirent structures.
pub const DIR_SIZ = 14

pub const min := fn(mut a, mut b) { return a if a < b else return b }

pub struct Dirent {
	inum u16
	name [DIR_SIZ]byte{}
}

// There should be one superblock per disk device, but we run with
// only one device
global (
	sb SuperBlock{}
)

// Read the superblock.
pub fn read_sb(mut dev int, mut *sb SuperBlock) void
{
	mut *bp := mem.b_read(dev, 1)
	sys.memmove(sb, bp.data, sizeof(*sb))
	mem.b_relse(bp)
}

// Zero a block.
pub fn b_zero(dev, bno int) void
{
	mut *bp := mem.b_read(dev, bno)
	sys.memset(bp.data, 0, B_SIZE)

	log_write(bp)
	mem.b_relse(bp)
}

// Blocks.

// Allocate a zeroed disk block.
pub fn balloc(mut dev u32) u32
{
	mut b, bi, m := 0
	mut *bp := buf.Buf{}

	bp = 0

	for b = 0; b < sb.block; b += BPB {
		bp = mem.b_read(dev, B_BLOCK(b, sb))

		for bi = 0; bi < BPB && b + bi < sb.size; bi++ {
			m = 1 << (bi % 8)

			if (bp.data[bi / 8] & m) == 0 { // Is block free?
				bp.data[bi / 8] |= m // Mark block in use

				log_write(bp)
				mem.b_relse(bp)
				mem.b_zero(dev, b + bi)

				return b + bi
			}
		}

		mem.b_relse(bp)
	}

	kpanic('balloc: out of blocks')
}

// Free a disk block.
pub fn b_free(mut dev int, mut b u32) void
{
	mut *bp := buf.Buf{}
	mut bi, m := 0

	bp = mem.b_read(dev, B_BLOCK(b, sb))
	bi = b & BPB
	m = 1 << (bi % 8)

	if (bp.data[bi / 8] & m) == 0 {
		kpanic('freeing free block')
	}

	bp.data[bi / 8] &= ~m
	log_write(bp)
	mem.b_relse(bp)
}

/*
// Inodes.
//
// An inode describes a single unnamed file.
// The inode disk structure holds metadata: the file's type,
// its size, the number of links referring to it, and the
// list of blocks holding the file's content.
//
// The inodes are laid out sequentially on disk at
// sb.startinode. Each inode has a number, indicating its
// position on the disk.
//
// The kernel keeps a cache of in-use inodes in memory
// to provide a place for synchronizing access
// to inodes used by multiple processes. The cached
// inodes include book-keeping information that is
// not stored on disk: ip->ref and ip->valid.
//
// An inode and its in-memory representation go through a
// sequence of states before they can be used by the
// rest of the file system code.
//
// * Allocation: an inode is allocated if its type (on disk)
//   is non-zero. ialloc() allocates, and iput() frees if
//   the reference and link counts have fallen to zero.
//
// * Referencing in cache: an entry in the inode cache
//   is free if ip->ref is zero. Otherwise ip->ref tracks
//   the number of in-memory pointers to the entry (open
//   files and current directories). i_get() finds or
//   creates a cache entry and increments its ref; iput()
//   decrements ref.
//
// * Valid: the information (type, size, &c) in an inode
//   cache entry is only correct when ip->valid is 1.
//   ilock() reads the inode from
//   the disk and sets ip->valid, while iput() clears
//   ip->valid if ip->ref has fallen to zero.
//
// * Locked: file system code may only examine and modify
//   the information in an inode and its content if it
//   has first locked the inode.
//
// Thus a typical sequence is:
//   ip = i_get(dev, inum)
//   ilock(ip)
//   ... examine and modify ip->xxx ...
//   iunlock(ip)
//   iput(ip)
//
// ilock() is separate from i_get() so that system calls can
// get a long-term reference to an inode (as for an open file)
// and only lock it for short periods (e.g., in read()).
// The separation also helps avoid deadlock and races during
// pathname lookup. i_get() increments ip->ref so that the inode
// stays cached and pointers to it remain valid.
//
// Many internal file system functions expect the caller to
// have locked the inodes involved; this lets callers create
// multi-step atomic operations.
//
// The icache.lock spin-lock protects the allocation of icache
// entries. Since ip->ref indicates whether an entry is free,
// and ip->dev and ip->inum indicate which i-node an entry
// holds, one must hold icache.lock while using any of those fields.
//
// An ip->lock sleep-lock protects all ip-> fields other than ref,
// dev, and inum.  One must hold ip->lock in order to
// read or write that inode's ip->valid, ip->size, ip->type, &c.
*/

pub struct ICache {
	lock lock.Spinlock
	inode [sys.NINODE]Inode
}

pub fn i_init(mut dev int) void
{
	mut i := 0

	lock.init_lock(&ICache.lock, 'icache')

	for i = 0; i < param.NINODE; i++ {
		lock.init_sleeplock(&ICache.inode[i].lock, 'inode')
	}

	read_sb(dev, &sb)
	println(
		'sb: size ${sb.size} nblocks ${sb.n_locks} ninodes ${sb.n_inodes} nlog ${sb.n_log} logstart ${sb.log_start} inodestart ${sb.inode_start} bmap start ${sb.bmap_start}'
	)
}

pub struct Inode* := i_get(mut dev, mut inum u32)

/*
Allocate an inode on device dev.
Mark it as allocated by  giving it type type.
Returns an unlocked but allocated and referenced inode.
*/
pub fn ialloc(mut dev u32, mut ttype u16) inode*
{
	mut inum := 0
	mut *bp := buf.Buf{}
	mut *dip := Dinode{}

	for inum = 1; inum < sb.n_inodes; inum++ {
		bp = mem.b_read(dev, IBLOCK(inum, sb))
		dip = *Dinode(bp.data + inum % IPB)

		if dip.type == 0 { // a free inode
			sys.memset(dip, 0, sizeof(*dip))
			dip.type = ttype
			log_write(bp) // mark it allocated on the disk
			mem.b_relse(bp)

			return i_get(dev, inum)
		}

		mem.b_relse(bp)
	}

	kpanic('ialloc: no inodes')
}

/*
Copy a modified in-memory inode to disk.
Must be called after every change to an ip.xxx field
that lives on disk, since i-node cache is write-through.
Caller must hold ip.lock.
*/
pub fn i_update(mut *ip Inode)
{
	mut *bp := buf.Buf{}
	mut *dip := Dinode{}

	bp = mem.b_read(ip.dev, IBLOCK(ip.inum, sb))
	dip = *Dinode(bp.data) + ip.inum % IPB

	dip.type = ip.type
	dip.major = ip.major
	dip.minor= ip.minor
	dip.n_link = ip.n_link
	dip.size = ip.size

	sys.memmove(dip.addrs, ip.addrs, sizeof(ip.addrs))
	sys.log_write(bp)
	mem.b_relse(bp)
}

/*
Find the inode with number inum on device dev
and return the in-memory copy. Does not lock
the inode and does not read it from disk.
*/
pub fn i_get(mut dev, mut inum u32) Inode*
{
	mut *ip, *empty := Inode{}
	lock.acquire(&ICache.lock)

	// Is the inode already cached
	empty = 0

	for ip = &ICache.inode[0]; ip < &ICache.inode[sys.NINODE]; ip++ {
		if ip.ref > 0 && ip.dev == dev && ip.inum == inum {
			ip.ref++
			lock.release(&ICache.lock)

			return ip
		}

		if empty == 0 && ip.ref == 0 { // Remember empty slot.
			empty = ip
		}
	}

	// Recycle an inode cache entry.
	if empty == 0 {
		kpanic('i_get: no inodes')
	}

	ip = empty
	ip.dev = dev
	ip.inum = inum
	ip.ref = 1
	ip.valid = 0
	lock.release(&ICache.lock)

	return ip
}

// Increment reference count for ip.
// Returns ip to enable ip = i_dup(ip1) idiom.
pub fn i_dup(mut *ip Inode) Inode*
{
	lock.acquire(&ICache.lock)
	ip.ref++
	lock.release(*ICache.lock)

	return ip
}

// Lock the given inode.
// Reads the inode from disk if necessary.
pub fn i_lock(mut *ip Inode) void
{
	mut *bp := mem.Buf{}
	mut *dip := Dinode{}

	if ip == 0 || ip.ref < 1 {
		kpanic('i_lock')
	}

	lock.acquire_sleep(&ip.lock)

	if ip.valid == 0 {
		bp = sys.b_read(ip.dev, IBLOCK(ip.inum, sb))
		dip = *Dinode(bp.data, ip.inum % IPB)

		ip.type = dip.type
		ip.major = dip.major
		ip.minor = dip.major
		ip.n_link = dip.n_link
		ip.size = dip.size

		sys.memmove(ip.addrs, dip.addrs, sizeof(ip.addrs))
		lock.b_relse(bp)

		ip.valid = 1

		if ip.type == 0 {
			kpanic('i_lock: no type')
		}
	}
}

// Unlock the given inode.
pub fn i_unlock(mut *ip Inode) void
{
	if ip == 0 || !lock.holding_sleep(ip.lock) || ip.ref < 1 {
		kpanic('i_unlock')
	}

	lock.release_sleep(&ip.lock)
}

/*
Drop a reference to an in-memory inode.
If that was the last reference, the inode cache entry can
be recycled.
If that was the last reference and the inode has no links
to it, free the inode (and its content) on disk.
All calls to iput() must be inside a transaction in
case it has to free the inode.
*/
pub fn i_put(mut *ip Inode) void
{
	lock.acquire_sleep(&ip.lock)

	if ip.valid && ip.n_link == 0 {
		lock.acquire(&ICache.lock)
		mut r := ip.ref
		lock.release(&ICache.lock)

		if r == 1 {
			// inode has no links and no other references: truncate and free.
			i_trunc(ip)
			ip.type = 0
			i_update(ip)
			ip.valid = 0
		}
	}

	lock.release_sleep(&ip.lock)
	lock.acquire(&ICache.lock)
	ip.ref--
	lock.release(&ICache.lock)
}

// Common idiom: unlock, then put.
pub fn i_unlockput(mut *ip Inode) void
{
	i_unlock(ip)
	i_put(ip)
}

/*
Inode content

The content (data) associated with each inode is stored
in blocks on the disk. The first N_DIRECT block numbers
are listed in ip->addrs[].  The next NIN_DIRECT blocks are
listed in block ip->addrs[N_DIRECT].

Return the disk block address of the nth block in inode ip.
If there is no such block, bmap allocates one.
*/
pub fn bmap(mut *ip Inode, bn u32) u32
{
	mut addr, *a := u32(0)
	mut *bp := mem.Buf{}

	if bn < N_DIRECT {
		if (addr = ip.addrs[bn]) == 0 {
			ip.addrs[bn] = addr = balloc(ip.dev)
		}

		return addr
	}

	bn -= sys.N_DIRECT

	if bn < sys.NIN_DIRECT {
		// Load iN_DIRECT block, allocating if necessary.
		if (addr = ip.addrs[N_DIRECT]) == 0 {
			ip.addrs[sys.N_DIRECT] = addr = balloc(ip.dev)
		}

		bp = mem.b_read(ip.dev, addr)
		a = *u32(bp.data)

		if (addr = a[bn]) == 0 {
			a[bn] = addr = balloc(ip.dev)
			sys.log_write(bp)
		}

		mem.b_relse(bp)
		return addr
	}

	kpanic('bmap: out of range')
}

/*
Truncate inode (discard contents).
Only called when the inode has no links
to it (no directory entries referring to it)
and has no in-memory reference to it (is
not an open file or current directory).
*/
pub fn i_trunc(mut *ip Inode) void
{
	mut i, j := 0
	mut *bp := buf.Buf{}
	mut *a := u32(0)

	for i = 0; i < N_DIRECT; i++ {
		if ip.addrs[i] {
			b_free(ip.dev, ip.addrs[i])
			ip.addrs[i] = 0
		}
	}

	if ip.addrs[N_DIRECT] {
		bp = bio.b_read(ip.dev, ip.addrs[N_DIRECT])
		a = *u32(bp.data)

		for j = 0; j < NIN_DIRECT; j++ {
			if a[j] {
				b_free(ip.dev, a[j])
			}
		}

		mem.b_relse(bp)
		b_free(ip.dev, ip.addrs[N_DIRECT])
		ip.addrs[N_DIRECT] = 0
	}

	ip.size = 0
	i_update(ip)
}

// Copy stat information from inode.
// Caller must hold ip.lock
pub fn stati(mut *ip Inode, mut *st Stat) void
{
	st.dev = ip.dev
	st.ino = ip.inum
	st.type = ip.type
	st.n_link = ip.n_link
	st.size = ip.size
}

// Read data from inode.
// Caller must hold ip.lock.
pub fn readi(mut *ip Inode, mut *dst byte, mut off, n u32) int
{
	mut tot, m := u32(0)
	mut *bp := mem.Buf{}

	if ip.type == proc.T_DEV {
		if ip.major < 0 || ip.major >= sys.NDEV || !devsw[ip.major].read {
			return -1
		}

		return devsw[ip.major].read(ip, dst, n)
	}

	if off > ip.size || off + n < off {
		return -1
	}

	if off + n > ip.size {
		n = ip.size - off
	}

	for tot = 0; tot < n; tot += m, off += m, dst += m {
		bp = mem.b_read(ip.dev, bmap(ip, off / B_SIZE))
		m = min(n - tot, B_SIZE - off % B_SIZE)
		sys.memmove(dst, bp.data + off % B_SIZE, m)
		mem.b_relse(bp)
	}

	return n
}

// Write data to inode.
// Caller must hold ip.lock
pub fn writei(mut *ip Inode, mut *src byte, mut off, n u32) int
{
	mut tot, m := u32(0)
	mut *bp := mem.Buf{}

	if ip.type == proc.T_DEV {
		if ip.major < 0 || ip.major >= sys.NDEV || !devsw[ip.major].write {
			return -1
		}

		return devsw[ip.major].write(ip, src, n)
	}

	if off > ip.size || off + n < off {
		return -1
	}

	if off + n > MAX_FILE * B_SIZE {
		return -1
	}

	for tot = 0; tot += m, off += m, src += m {
		bp = mem.b_read(ip.dev, bmap(ip, off / B_SIZE))
		m = min(n - tot, B_SIZE - off % B_SIZE)
		sys.memmove(bp.data + off % B_SIZE, src, m)
		log_write(bp)
		mem.b_relse(bp)
	}

	if n > 0 && off > ip.size {
		ip.size = off
		i_update(ip)
	}

	return n
}

// Directories
/*
pub fn name_cmp(*s, *t byte) int
{
	return strncmp(s, t, DIR_SIZ)
}
*/

// Look for a directory entry in a directory.
// If found, set *poff to byte offset of entry.
pub fn dir_lookup(mut *dp Inode, mut *name byte, mut *poff u32) Inode
{
	mut off, inum := u32(0)
	mut de := Dirent{}

	if dp.type != T_DIR {
		kpanic('dir_lookup not DIR')
	}

	for off = 0; off < dp.size; off += sizeof(de) {
		if readi(dp, charptr(&de), off, sizeof(de)) != sizeof(de) {
			kpanic('dir_lookup read')
		}

		if de.inum == 0 {
			continue
		}

		if name == de.name {
			// Entry matches path element.
			if poff {
				*poff = off
			}

			inum = de.inum
			return i_get(dp.dev, inum)
		}
	}

	return 0
}

// Write a new directory entry (name, inum) into directory dp.
pub fn dir_link(mut *dp Inode, mut *name byte, mut inum u32) int
{
	mut off := 0
	mut de := Dirent{}
	mut *ip := Inode{}

	// Check that name is not present.
	if (ip = dir_lookup(dp, name, 0)) != 0 {
		i_put(ip)
		return -1
	}

	// Look for an empty dirent.
	for off = 0; off < dp.size; off += sizeof(de) {
		if readi(dp, charptr(&de), off, sizeof(de)) != sizeof(de) {
			kpanic('dir_link read')
		}

		if de.inum == 0 {
			break
		}
	}

	str.strncpy(de.name, name, DIR_SIZ)
	de.inum = inum

	if writei(dp, charptr(&de), off, sizeof(de)) != sizeof(de) {
		kpanic('dir_link')
	}

	return 0
}

/*
Paths

Copy the next path element from path into name.
Return a pointer to the element following the copied one.
The returned path has no leading slashes,
so the caller can check *path=='\0' to see if the name is the last one.
If no name to remove, return 0.

Examples:
  skipelem("a/bb/c", name) = "bb/c", setting name = "a"
  skipelem("///a//bb", name) = "bb", setting name = "a"
  skipelem("a", name) = "", setting name = "a"
  skipelem("", name) = skipelem("////", name) = 0
*/
pub fn skip_elem(mut *path, *name byte) charptr
{
	mut *s := byte(0)
	mut len := 0

	for *path == '/' {
		path++
	}

	if *path == 0 {
		return 0
	}

	s = path

	for *path != '/' && *path != 0 {
		path++
	}

	len = path - s

	if len >= DIR_SIZ {
		sys.memmove(name, s, DIR_SIZ)
	} else {
		sys.memmove(name, s, len)
		name[len] = 0
	}

	for *path == '/' {
		path++
	}

	return path
}

/*
Look up and return the inode for a path name.
If parent != 0, return the inode for the parent and copy the final
path element into name, which must have room for DIR_SIZ bytes.
Must be called inside a transaction since it calls iput().
*/
pub fn namex(mut *path byte, mut name_iparent int, mut *name byte) Inode*
{
	mut *ip, *next := Inode{}

	if *path == '/' {
		ip = i_get(sys.ROOTDEV, ROOTING)
	} else {
		ip = i_dup(proc.my_proc().cwd)
	}

	for (path = skip_elem(path, name)) != 0 {
		i_lock(ip)

		if ip.type != T_DIR {
			i_unlockput(ip)
			return 0
		}

		if name_iparent && *path == '' {
			// Stop one level early.
			i_unlock(ip)
			return ip
		}

		if (next = dir_lookup(ip, name, 0)) == 0 {
			i_unlockput(ip)
			return 0
		}

		i_unlockput(ip)
		ip = next
	}

	if name_iparent {
		ide.i_put(ip)
		return 0
	}

	return ip
}

pub fn namei(mut *path byte) Inode*
{
	mut name := [DIR_SIZ]byte{}
	return namex(path, 0, name)
}

pub fn parent(mut *path, *name byte) Inode*
{
	return namex(path, 1, name)
}
