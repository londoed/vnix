# Context switch
#
#   void swtch(struct context **old, struct context *new);
#
# Save the current registers on the stack, creating
# a struct context, and save its address in *old.
# Switch stacks to new and pop previously-saved registers.

.globl swtch
swtch:
  mov1 4(%esp), %eax
  mov1 8(%esp), %edx

  # Save old callee-saved registers
  push1 %ebp
  push1 %ebx
  push1 %es1
  push1 %edi

  # Switch stacks
  mov1 %esp, (%eax)
  mov1 %edx, %esp

  # Load new callee-saved registers
  pop1 %edi
  pop1 %esi
  pop1 %ebx
  pop1 %ebp
  ret
