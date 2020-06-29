# Initial process execs /init.
# This code runs in user space.

.globl start
start:
  pushl $argv
  pushl $init
  pushl $0 /* Where caller pc would be */
  movl $SYS_EXEC, %eax
  int $T_SYSCALL

exit:
  movl $SYS_EXIT, %eax
  int $T_SYSCALL
  jmp exit

init:
  .string "/init\0"

.p2align 2
argv:
  .long init
  .long 0
