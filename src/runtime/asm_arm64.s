// Copyright 2015 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "go_asm.h"
#include "go_tls.h"
#include "tls_arm64.h"
#include "funcdata.h"
#include "textflag.h"

TEXT runtime·rt0_go(SB),NOSPLIT,$0
	// SP = stack; R0 = argc; R1 = argv

	SUB	$32, RSP
	MOVW	R0, 8(RSP) // argc
	MOVD	R1, 16(RSP) // argv

	// create istack out of the given (operating system) stack.
	// _cgo_init may update stackguard.
	MOVD	$runtime·g0(SB), g
	MOVD RSP, R7
	MOVD	$(-64*1024)(R7), R0
	MOVD	R0, g_stackguard0(g)
	MOVD	R0, g_stackguard1(g)
	MOVD	R0, (g_stack+stack_lo)(g)
	MOVD	R7, (g_stack+stack_hi)(g)

	// if there is a _cgo_init, call it using the gcc ABI.
	MOVD	_cgo_init(SB), R12
	CMP	$0, R12
	BEQ	nocgo

	MRS_TPIDR_R0			// load TLS base pointer
	MOVD	R0, R3			// arg 3: TLS base pointer
#ifdef TLSG_IS_VARIABLE
	MOVD	$runtime·tls_g(SB), R2 	// arg 2: &tls_g
#else
	MOVD	$0, R2		        // arg 2: not used when using platform's TLS
#endif
	MOVD	$setg_gcc<>(SB), R1	// arg 1: setg
	MOVD	g, R0			// arg 0: G
	BL	(R12)
	MOVD	_cgo_init(SB), R12
	CMP	$0, R12
	BEQ	nocgo

nocgo:
	// update stackguard after _cgo_init
	MOVD	(g_stack+stack_lo)(g), R0
	ADD	$const__StackGuard, R0
	MOVD	R0, g_stackguard0(g)
	MOVD	R0, g_stackguard1(g)

	// set the per-goroutine and per-mach "registers"
	MOVD	$runtime·m0(SB), R0

	// save m->g0 = g0
	MOVD	g, m_g0(R0)
	// save m0 to g0->m
	MOVD	R0, g_m(g)

	BL	runtime·check(SB)

	MOVW	8(RSP), R0	// copy argc
	MOVW	R0, -8(RSP)
	MOVD	16(RSP), R0		// copy argv
	MOVD	R0, 0(RSP)
	BL	runtime·args(SB)
	BL	runtime·osinit(SB)
	BL	runtime·schedinit(SB)

	// create a new goroutine to start program
	MOVD	$runtime·mainPC(SB), R0		// entry
	MOVD	RSP, R7
	MOVD.W	$0, -8(R7)
	MOVD.W	R0, -8(R7)
	MOVD.W	$0, -8(R7)
	MOVD.W	$0, -8(R7)
	MOVD	R7, RSP
	BL	runtime·newproc(SB)
	ADD	$32, RSP

	// start this M
	BL	runtime·mstart(SB)

	MOVD	$0, R0
	MOVD	R0, (R0)	// boom
	UNDEF

DATA	runtime·mainPC+0(SB)/8,$runtime·main(SB)
GLOBL	runtime·mainPC(SB),RODATA,$8

TEXT runtime·breakpoint(SB),NOSPLIT,$-8-0
	BRK
	RET

TEXT runtime·asminit(SB),NOSPLIT,$-8-0
	RET

/*
 *  go-routine
 */

// void gosave(Gobuf*)
// save state in Gobuf; setjmp
TEXT runtime·gosave(SB), NOSPLIT, $-8-8
	MOVD	buf+0(FP), R3
	MOVD	RSP, R0
	MOVD	R0, gobuf_sp(R3)
	MOVD	LR, gobuf_pc(R3)
	MOVD	g, gobuf_g(R3)
	MOVD	ZR, gobuf_lr(R3)
	MOVD	ZR, gobuf_ret(R3)
	// Assert ctxt is zero. See func save.
	MOVD	gobuf_ctxt(R3), R0
	CMP	$0, R0
	BEQ	2(PC)
	CALL	runtime·badctxt(SB)
	RET

// void gogo(Gobuf*)
// restore state from Gobuf; longjmp
TEXT runtime·gogo(SB), NOSPLIT, $24-8
	MOVD	buf+0(FP), R5
	MOVD	gobuf_g(R5), g
	BL	runtime·save_g(SB)

	MOVD	0(g), R4	// make sure g is not nil
	MOVD	gobuf_sp(R5), R0
	MOVD	R0, RSP
	MOVD	gobuf_lr(R5), LR
	MOVD	gobuf_ret(R5), R0
	MOVD	gobuf_ctxt(R5), R26
	MOVD	$0, gobuf_sp(R5)
	MOVD	$0, gobuf_ret(R5)
	MOVD	$0, gobuf_lr(R5)
	MOVD	$0, gobuf_ctxt(R5)
	CMP	ZR, ZR // set condition codes for == test, needed by stack split
	MOVD	gobuf_pc(R5), R6
	B	(R6)

// void mcall(fn func(*g))
// Switch to m->g0's stack, call fn(g).
// Fn must never return. It should gogo(&g->sched)
// to keep running g.
TEXT runtime·mcall(SB), NOSPLIT, $-8-8
	// Save caller state in g->sched
	MOVD	RSP, R0
	MOVD	R0, (g_sched+gobuf_sp)(g)
	MOVD	LR, (g_sched+gobuf_pc)(g)
	MOVD	$0, (g_sched+gobuf_lr)(g)
	MOVD	g, (g_sched+gobuf_g)(g)

	// Switch to m->g0 & its stack, call fn.
	MOVD	g, R3
	MOVD	g_m(g), R8
	MOVD	m_g0(R8), g
	BL	runtime·save_g(SB)
	CMP	g, R3
	BNE	2(PC)
	B	runtime·badmcall(SB)
	MOVD	fn+0(FP), R26			// context
	MOVD	0(R26), R4			// code pointer
	MOVD	(g_sched+gobuf_sp)(g), R0
	MOVD	R0, RSP	// sp = m->g0->sched.sp
	MOVD	R3, -8(RSP)
	MOVD	$0, -16(RSP)
	SUB	$16, RSP
	BL	(R4)
	B	runtime·badmcall2(SB)

// systemstack_switch is a dummy routine that systemstack leaves at the bottom
// of the G stack. We need to distinguish the routine that
// lives at the bottom of the G stack from the one that lives
// at the top of the system stack because the one at the top of
// the system stack terminates the stack walk (see topofstack()).
TEXT runtime·systemstack_switch(SB), NOSPLIT, $0-0
	UNDEF
	BL	(LR)	// make sure this function is not leaf
	RET

// func systemstack(fn func())
TEXT runtime·systemstack(SB), NOSPLIT, $0-8
	MOVD	fn+0(FP), R3	// R3 = fn
	MOVD	R3, R26		// context
	MOVD	g_m(g), R4	// R4 = m

	MOVD	m_gsignal(R4), R5	// R5 = gsignal
	CMP	g, R5
	BEQ	noswitch

	MOVD	m_g0(R4), R5	// R5 = g0
	CMP	g, R5
	BEQ	noswitch

	MOVD	m_curg(R4), R6
	CMP	g, R6
	BEQ	switch

	// Bad: g is not gsignal, not g0, not curg. What is it?
	// Hide call from linker nosplit analysis.
	MOVD	$runtime·badsystemstack(SB), R3
	BL	(R3)

switch:
	// save our state in g->sched. Pretend to
	// be systemstack_switch if the G stack is scanned.
	MOVD	$runtime·systemstack_switch(SB), R6
	ADD	$8, R6	// get past prologue
	MOVD	R6, (g_sched+gobuf_pc)(g)
	MOVD	RSP, R0
	MOVD	R0, (g_sched+gobuf_sp)(g)
	MOVD	$0, (g_sched+gobuf_lr)(g)
	MOVD	g, (g_sched+gobuf_g)(g)

	// switch to g0
	MOVD	R5, g
	BL	runtime·save_g(SB)
	MOVD	(g_sched+gobuf_sp)(g), R3
	// make it look like mstart called systemstack on g0, to stop traceback
	SUB	$16, R3
	AND	$~15, R3
	MOVD	$runtime·mstart(SB), R4
	MOVD	R4, 0(R3)
	MOVD	R3, RSP

	// call target function
	MOVD	0(R26), R3	// code pointer
	BL	(R3)

	// switch back to g
	MOVD	g_m(g), R3
	MOVD	m_curg(R3), g
	BL	runtime·save_g(SB)
	MOVD	(g_sched+gobuf_sp)(g), R0
	MOVD	R0, RSP
	MOVD	$0, (g_sched+gobuf_sp)(g)
	RET

noswitch:
	// already on m stack, just call directly
	// Using a tail call here cleans up tracebacks since we won't stop
	// at an intermediate systemstack.
	MOVD	0(R26), R3	// code pointer
	MOVD.P	16(RSP), R30	// restore LR
	B	(R3)

/*
 * support for morestack
 */

// Called during function prolog when more stack is needed.
// Caller has already loaded:
// R3 prolog's LR (R30)
//
// The traceback routines see morestack on a g0 as being
// the top of a stack (for example, morestack calling newstack
// calling the scheduler calling newm calling gc), so we must
// record an argument size. For that purpose, it has no arguments.
TEXT runtime·morestack(SB),NOSPLIT,$-8-0
	// Cannot grow scheduler stack (m->g0).
	MOVD	g_m(g), R8
	MOVD	m_g0(R8), R4
	CMP	g, R4
	BNE	3(PC)
	BL	runtime·badmorestackg0(SB)
	B	runtime·abort(SB)

	// Cannot grow signal stack (m->gsignal).
	MOVD	m_gsignal(R8), R4
	CMP	g, R4
	BNE	3(PC)
	BL	runtime·badmorestackgsignal(SB)
	B	runtime·abort(SB)

	// Called from f.
	// Set g->sched to context in f
	MOVD	RSP, R0
	MOVD	R0, (g_sched+gobuf_sp)(g)
	MOVD	LR, (g_sched+gobuf_pc)(g)
	MOVD	R3, (g_sched+gobuf_lr)(g)
	MOVD	R26, (g_sched+gobuf_ctxt)(g)

	// Called from f.
	// Set m->morebuf to f's callers.
	MOVD	R3, (m_morebuf+gobuf_pc)(R8)	// f's caller's PC
	MOVD	RSP, R0
	MOVD	R0, (m_morebuf+gobuf_sp)(R8)	// f's caller's RSP
	MOVD	g, (m_morebuf+gobuf_g)(R8)

	// Call newstack on m->g0's stack.
	MOVD	m_g0(R8), g
	BL	runtime·save_g(SB)
	MOVD	(g_sched+gobuf_sp)(g), R0
	MOVD	R0, RSP
	MOVD.W	$0, -16(RSP)	// create a call frame on g0 (saved LR; keep 16-aligned)
	BL	runtime·newstack(SB)

	// Not reached, but make sure the return PC from the call to newstack
	// is still in this function, and not the beginning of the next.
	UNDEF

TEXT runtime·morestack_noctxt(SB),NOSPLIT,$-4-0
	MOVW	$0, R26
	B runtime·morestack(SB)

// reflectcall: call a function with the given argument list
// func call(argtype *_type, f *FuncVal, arg *byte, argsize, retoffset uint32).
// we don't have variable-sized frames, so we use a small number
// of constant-sized-frame functions to encode a few bits of size in the pc.
// Caution: ugly multiline assembly macros in your future!

#define DISPATCH(NAME,MAXSIZE)		\
	MOVD	$MAXSIZE, R27;		\
	CMP	R27, R16;		\
	BGT	3(PC);			\
	MOVD	$NAME(SB), R27;	\
	B	(R27)
// Note: can't just "B NAME(SB)" - bad inlining results.

TEXT reflect·call(SB), NOSPLIT, $0-0
	B	·reflectcall(SB)

TEXT ·reflectcall(SB), NOSPLIT, $-8-32
	MOVWU argsize+24(FP), R16
	DISPATCH(runtime·call32, 32)
	DISPATCH(runtime·call64, 64)
	DISPATCH(runtime·call128, 128)
	DISPATCH(runtime·call256, 256)
	DISPATCH(runtime·call512, 512)
	DISPATCH(runtime·call1024, 1024)
	DISPATCH(runtime·call2048, 2048)
	DISPATCH(runtime·call4096, 4096)
	DISPATCH(runtime·call8192, 8192)
	DISPATCH(runtime·call16384, 16384)
	DISPATCH(runtime·call32768, 32768)
	DISPATCH(runtime·call65536, 65536)
	DISPATCH(runtime·call131072, 131072)
	DISPATCH(runtime·call262144, 262144)
	DISPATCH(runtime·call524288, 524288)
	DISPATCH(runtime·call1048576, 1048576)
	DISPATCH(runtime·call2097152, 2097152)
	DISPATCH(runtime·call4194304, 4194304)
	DISPATCH(runtime·call8388608, 8388608)
	DISPATCH(runtime·call16777216, 16777216)
	DISPATCH(runtime·call33554432, 33554432)
	DISPATCH(runtime·call67108864, 67108864)
	DISPATCH(runtime·call134217728, 134217728)
	DISPATCH(runtime·call268435456, 268435456)
	DISPATCH(runtime·call536870912, 536870912)
	DISPATCH(runtime·call1073741824, 1073741824)
	MOVD	$runtime·badreflectcall(SB), R0
	B	(R0)

#define CALLFN(NAME,MAXSIZE)			\
TEXT NAME(SB), WRAPPER, $MAXSIZE-24;		\
	NO_LOCAL_POINTERS;			\
	/* copy arguments to stack */		\
	MOVD	arg+16(FP), R3;			\
	MOVWU	argsize+24(FP), R4;		\
	ADD	$8, RSP, R5;			\
	BIC	$0xf, R4, R6;			\
	CBZ	R6, 6(PC);			\
	/* if R6=(argsize&~15) != 0 */		\
	ADD	R6, R5, R6;			\
	/* copy 16 bytes a time */		\
	LDP.P	16(R3), (R7, R8);		\
	STP.P	(R7, R8), 16(R5);		\
	CMP	R5, R6;				\
	BNE	-3(PC);				\
	AND	$0xf, R4, R6;			\
	CBZ	R6, 6(PC);			\
	/* if R6=(argsize&15) != 0 */		\
	ADD	R6, R5, R6;			\
	/* copy 1 byte a time for the rest */	\
	MOVBU.P	1(R3), R7;			\
	MOVBU.P	R7, 1(R5);			\
	CMP	R5, R6;				\
	BNE	-3(PC);				\
	/* call function */			\
	MOVD	f+8(FP), R26;			\
	MOVD	(R26), R0;			\
	PCDATA  $PCDATA_StackMapIndex, $0;	\
	BL	(R0);				\
	/* copy return values back */		\
	MOVD	argtype+0(FP), R7;		\
	MOVD	arg+16(FP), R3;			\
	MOVWU	n+24(FP), R4;			\
	MOVWU	retoffset+28(FP), R6;		\
	ADD	$8, RSP, R5;			\
	ADD	R6, R5; 			\
	ADD	R6, R3;				\
	SUB	R6, R4;				\
	BL	callRet<>(SB);			\
	RET

// callRet copies return values back at the end of call*. This is a
// separate function so it can allocate stack space for the arguments
// to reflectcallmove. It does not follow the Go ABI; it expects its
// arguments in registers.
TEXT callRet<>(SB), NOSPLIT, $40-0
	MOVD	R7, 8(RSP)
	MOVD	R3, 16(RSP)
	MOVD	R5, 24(RSP)
	MOVD	R4, 32(RSP)
	BL	runtime·reflectcallmove(SB)
	RET

// These have 8 added to make the overall frame size a multiple of 16,
// as required by the ABI. (There is another +8 for the saved LR.)
CALLFN(·call32, 40 )
CALLFN(·call64, 72 )
CALLFN(·call128, 136 )
CALLFN(·call256, 264 )
CALLFN(·call512, 520 )
CALLFN(·call1024, 1032 )
CALLFN(·call2048, 2056 )
CALLFN(·call4096, 4104 )
CALLFN(·call8192, 8200 )
CALLFN(·call16384, 16392 )
CALLFN(·call32768, 32776 )
CALLFN(·call65536, 65544 )
CALLFN(·call131072, 131080 )
CALLFN(·call262144, 262152 )
CALLFN(·call524288, 524296 )
CALLFN(·call1048576, 1048584 )
CALLFN(·call2097152, 2097160 )
CALLFN(·call4194304, 4194312 )
CALLFN(·call8388608, 8388616 )
CALLFN(·call16777216, 16777224 )
CALLFN(·call33554432, 33554440 )
CALLFN(·call67108864, 67108872 )
CALLFN(·call134217728, 134217736 )
CALLFN(·call268435456, 268435464 )
CALLFN(·call536870912, 536870920 )
CALLFN(·call1073741824, 1073741832 )

// AES hashing not implemented for ARM64, issue #10109.
TEXT runtime·aeshash(SB),NOSPLIT,$-8-0
	MOVW	$0, R0
	MOVW	(R0), R1
TEXT runtime·aeshash32(SB),NOSPLIT,$-8-0
	MOVW	$0, R0
	MOVW	(R0), R1
TEXT runtime·aeshash64(SB),NOSPLIT,$-8-0
	MOVW	$0, R0
	MOVW	(R0), R1
TEXT runtime·aeshashstr(SB),NOSPLIT,$-8-0
	MOVW	$0, R0
	MOVW	(R0), R1
	
TEXT runtime·procyield(SB),NOSPLIT,$0-0
	MOVWU	cycles+0(FP), R0
again:
	YIELD
	SUBW	$1, R0
	CBNZ	R0, again
	RET

// void jmpdefer(fv, sp);
// called from deferreturn.
// 1. grab stored LR for caller
// 2. sub 4 bytes to get back to BL deferreturn
// 3. BR to fn
TEXT runtime·jmpdefer(SB), NOSPLIT, $-8-16
	MOVD	0(RSP), R0
	SUB	$4, R0
	MOVD	R0, LR

	MOVD	fv+0(FP), R26
	MOVD	argp+8(FP), R0
	MOVD	R0, RSP
	SUB	$8, RSP
	MOVD	0(R26), R3
	B	(R3)

// Save state of caller into g->sched. Smashes R0.
TEXT gosave<>(SB),NOSPLIT,$-8
	MOVD	LR, (g_sched+gobuf_pc)(g)
	MOVD RSP, R0
	MOVD	R0, (g_sched+gobuf_sp)(g)
	MOVD	$0, (g_sched+gobuf_lr)(g)
	MOVD	$0, (g_sched+gobuf_ret)(g)
	// Assert ctxt is zero. See func save.
	MOVD	(g_sched+gobuf_ctxt)(g), R0
	CMP	$0, R0
	BEQ	2(PC)
	CALL	runtime·badctxt(SB)
	RET

// func asmcgocall(fn, arg unsafe.Pointer) int32
// Call fn(arg) on the scheduler stack,
// aligned appropriately for the gcc ABI.
// See cgocall.go for more details.
TEXT ·asmcgocall(SB),NOSPLIT,$0-20
	MOVD	fn+0(FP), R1
	MOVD	arg+8(FP), R0

	MOVD	RSP, R2		// save original stack pointer
	MOVD	g, R4

	// Figure out if we need to switch to m->g0 stack.
	// We get called to create new OS threads too, and those
	// come in on the m->g0 stack already.
	MOVD	g_m(g), R8
	MOVD	m_g0(R8), R3
	CMP	R3, g
	BEQ	g0
	MOVD	R0, R9	// gosave<> and save_g might clobber R0
	BL	gosave<>(SB)
	MOVD	R3, g
	BL	runtime·save_g(SB)
	MOVD	(g_sched+gobuf_sp)(g), R0
	MOVD	R0, RSP
	MOVD	R9, R0

	// Now on a scheduling stack (a pthread-created stack).
g0:
	// Save room for two of our pointers /*, plus 32 bytes of callee
	// save area that lives on the caller stack. */
	MOVD	RSP, R13
	SUB	$16, R13
	MOVD	R13, RSP
	MOVD	R4, 0(RSP)	// save old g on stack
	MOVD	(g_stack+stack_hi)(R4), R4
	SUB	R2, R4
	MOVD	R4, 8(RSP)	// save depth in old g stack (can't just save SP, as stack might be copied during a callback)
	BL	(R1)
	MOVD	R0, R9

	// Restore g, stack pointer. R0 is errno, so don't touch it
	MOVD	0(RSP), g
	BL	runtime·save_g(SB)
	MOVD	(g_stack+stack_hi)(g), R5
	MOVD	8(RSP), R6
	SUB	R6, R5
	MOVD	R9, R0
	MOVD	R5, RSP

	MOVW	R0, ret+16(FP)
	RET

// cgocallback(void (*fn)(void*), void *frame, uintptr framesize, uintptr ctxt)
// Turn the fn into a Go func (by taking its address) and call
// cgocallback_gofunc.
TEXT runtime·cgocallback(SB),NOSPLIT,$40-32
	MOVD	$fn+0(FP), R0
	MOVD	R0, 8(RSP)
	MOVD	frame+8(FP), R0
	MOVD	R0, 16(RSP)
	MOVD	framesize+16(FP), R0
	MOVD	R0, 24(RSP)
	MOVD	ctxt+24(FP), R0
	MOVD	R0, 32(RSP)
	MOVD	$runtime·cgocallback_gofunc(SB), R0
	BL	(R0)
	RET

// cgocallback_gofunc(FuncVal*, void *frame, uintptr framesize, uintptr ctxt)
// See cgocall.go for more details.
TEXT ·cgocallback_gofunc(SB),NOSPLIT,$24-32
	NO_LOCAL_POINTERS

	// Load g from thread-local storage.
	MOVB	runtime·iscgo(SB), R3
	CMP	$0, R3
	BEQ	nocgo
	BL	runtime·load_g(SB)
nocgo:

	// If g is nil, Go did not create the current thread.
	// Call needm to obtain one for temporary use.
	// In this case, we're running on the thread stack, so there's
	// lots of space, but the linker doesn't know. Hide the call from
	// the linker analysis by using an indirect call.
	CMP	$0, g
	BEQ	needm

	MOVD	g_m(g), R8
	MOVD	R8, savedm-8(SP)
	B	havem

needm:
	MOVD	g, savedm-8(SP) // g is zero, so is m.
	MOVD	$runtime·needm(SB), R0
	BL	(R0)

	// Set m->sched.sp = SP, so that if a panic happens
	// during the function we are about to execute, it will
	// have a valid SP to run on the g0 stack.
	// The next few lines (after the havem label)
	// will save this SP onto the stack and then write
	// the same SP back to m->sched.sp. That seems redundant,
	// but if an unrecovered panic happens, unwindm will
	// restore the g->sched.sp from the stack location
	// and then systemstack will try to use it. If we don't set it here,
	// that restored SP will be uninitialized (typically 0) and
	// will not be usable.
	MOVD	g_m(g), R8
	MOVD	m_g0(R8), R3
	MOVD	RSP, R0
	MOVD	R0, (g_sched+gobuf_sp)(R3)

havem:
	// Now there's a valid m, and we're running on its m->g0.
	// Save current m->g0->sched.sp on stack and then set it to SP.
	// Save current sp in m->g0->sched.sp in preparation for
	// switch back to m->curg stack.
	// NOTE: unwindm knows that the saved g->sched.sp is at 16(RSP) aka savedsp-16(SP).
	// Beware that the frame size is actually 32.
	MOVD	m_g0(R8), R3
	MOVD	(g_sched+gobuf_sp)(R3), R4
	MOVD	R4, savedsp-16(SP)
	MOVD	RSP, R0
	MOVD	R0, (g_sched+gobuf_sp)(R3)

	// Switch to m->curg stack and call runtime.cgocallbackg.
	// Because we are taking over the execution of m->curg
	// but *not* resuming what had been running, we need to
	// save that information (m->curg->sched) so we can restore it.
	// We can restore m->curg->sched.sp easily, because calling
	// runtime.cgocallbackg leaves SP unchanged upon return.
	// To save m->curg->sched.pc, we push it onto the stack.
	// This has the added benefit that it looks to the traceback
	// routine like cgocallbackg is going to return to that
	// PC (because the frame we allocate below has the same
	// size as cgocallback_gofunc's frame declared above)
	// so that the traceback will seamlessly trace back into
	// the earlier calls.
	//
	// In the new goroutine, -8(SP) is unused (where SP refers to
	// m->curg's SP while we're setting it up, before we've adjusted it).
	MOVD	m_curg(R8), g
	BL	runtime·save_g(SB)
	MOVD	(g_sched+gobuf_sp)(g), R4 // prepare stack as R4
	MOVD	(g_sched+gobuf_pc)(g), R5
	MOVD	R5, -(24+8)(R4)
	MOVD	ctxt+24(FP), R0
	MOVD	R0, -(16+8)(R4)
	MOVD	$-(24+8)(R4), R0 // maintain 16-byte SP alignment
	MOVD	R0, RSP
	BL	runtime·cgocallbackg(SB)

	// Restore g->sched (== m->curg->sched) from saved values.
	MOVD	0(RSP), R5
	MOVD	R5, (g_sched+gobuf_pc)(g)
	MOVD	RSP, R4
	ADD	$(24+8), R4, R4
	MOVD	R4, (g_sched+gobuf_sp)(g)

	// Switch back to m->g0's stack and restore m->g0->sched.sp.
	// (Unlike m->curg, the g0 goroutine never uses sched.pc,
	// so we do not have to restore it.)
	MOVD	g_m(g), R8
	MOVD	m_g0(R8), g
	BL	runtime·save_g(SB)
	MOVD	(g_sched+gobuf_sp)(g), R0
	MOVD	R0, RSP
	MOVD	savedsp-16(SP), R4
	MOVD	R4, (g_sched+gobuf_sp)(g)

	// If the m on entry was nil, we called needm above to borrow an m
	// for the duration of the call. Since the call is over, return it with dropm.
	MOVD	savedm-8(SP), R6
	CMP	$0, R6
	BNE	droppedm
	MOVD	$runtime·dropm(SB), R0
	BL	(R0)
droppedm:

	// Done!
	RET

// Called from cgo wrappers, this function returns g->m->curg.stack.hi.
// Must obey the gcc calling convention.
TEXT _cgo_topofstack(SB),NOSPLIT,$24
	// g (R28) and REGTMP (R27)  might be clobbered by load_g. They
	// are callee-save in the gcc calling convention, so save them.
	MOVD	R27, savedR27-8(SP)
	MOVD	g, saveG-16(SP)

	BL	runtime·load_g(SB)
	MOVD	g_m(g), R0
	MOVD	m_curg(R0), R0
	MOVD	(g_stack+stack_hi)(R0), R0

	MOVD	saveG-16(SP), g
	MOVD	savedR28-8(SP), R27
	RET

// void setg(G*); set g. for use by needm.
TEXT runtime·setg(SB), NOSPLIT, $0-8
	MOVD	gg+0(FP), g
	// This only happens if iscgo, so jump straight to save_g
	BL	runtime·save_g(SB)
	RET

// void setg_gcc(G*); set g called from gcc
TEXT setg_gcc<>(SB),NOSPLIT,$8
	MOVD	R0, g
	MOVD	R27, savedR27-8(SP)
	BL	runtime·save_g(SB)
	MOVD	savedR27-8(SP), R27
	RET

TEXT runtime·getcallerpc(SB),NOSPLIT,$-8-8
	MOVD	0(RSP), R0		// LR saved by caller
	MOVD	R0, ret+0(FP)
	RET

TEXT runtime·abort(SB),NOSPLIT,$-8-0
	B	(ZR)
	UNDEF

// memequal(a, b unsafe.Pointer, size uintptr) bool
TEXT runtime·memequal(SB),NOSPLIT,$-8-25
	MOVD	size+16(FP), R1
	// short path to handle 0-byte case
	CBZ	R1, equal
	MOVD	a+0(FP), R0
	MOVD	b+8(FP), R2
	MOVD	$ret+24(FP), R8
	B	runtime·memeqbody<>(SB)
equal:
	MOVD	$1, R0
	MOVB	R0, ret+24(FP)
	RET

// memequal_varlen(a, b unsafe.Pointer) bool
TEXT runtime·memequal_varlen(SB),NOSPLIT,$40-17
	MOVD	a+0(FP), R3
	MOVD	b+8(FP), R4
	CMP	R3, R4
	BEQ	eq
	MOVD	8(R26), R5    // compiler stores size at offset 8 in the closure
	MOVD	R3, 8(RSP)
	MOVD	R4, 16(RSP)
	MOVD	R5, 24(RSP)
	BL	runtime·memequal(SB)
	MOVBU	32(RSP), R3
	MOVB	R3, ret+16(FP)
	RET
eq:
	MOVD	$1, R3
	MOVB	R3, ret+16(FP)
	RET

TEXT runtime·cmpstring(SB),NOSPLIT,$-4-40
	MOVD	s1_base+0(FP), R2
	MOVD	s1_len+8(FP), R0
	MOVD	s2_base+16(FP), R3
	MOVD	s2_len+24(FP), R1
	ADD	$40, RSP, R7
	B	runtime·cmpbody<>(SB)

TEXT bytes·Compare(SB),NOSPLIT,$-4-56
	MOVD	s1+0(FP), R2
	MOVD	s1+8(FP), R0
	MOVD	s2+24(FP), R3
	MOVD	s2+32(FP), R1
	ADD	$56, RSP, R7
	B	runtime·cmpbody<>(SB)

// On entry:
// R0 is the length of s1
// R1 is the length of s2
// R2 points to the start of s1
// R3 points to the start of s2
// R7 points to return value (-1/0/1 will be written here)
//
// On exit:
// R4, R5, and R6 are clobbered
TEXT runtime·cmpbody<>(SB),NOSPLIT,$-4-0
	CMP	R2, R3
	BEQ	samebytes // same starting pointers; compare lengths
	CMP	R0, R1
	CSEL    LT, R1, R0, R6 // R6 is min(R0, R1)

	ADD	R2, R6	// R2 is current byte in s1, R6 is last byte in s1 to compare
loop:
	CMP	R2, R6
	BEQ	samebytes // all compared bytes were the same; compare lengths
	MOVBU.P	1(R2), R4
	MOVBU.P	1(R3), R5
	CMP	R4, R5
	BEQ	loop
	// bytes differed
	MOVD	$1, R4
	CSNEG	LT, R4, R4, R4
	MOVD	R4, (R7)
	RET
samebytes:
	MOVD	$1, R4
	CMP	R0, R1
	CSNEG	LT, R4, R4, R4
	CSEL	EQ, ZR, R4, R4
	MOVD	R4, (R7)
	RET

//
// functions for other packages
//
TEXT bytes·IndexByte(SB),NOSPLIT,$0-40
	MOVD	b+0(FP), R0
	MOVD	b_len+8(FP), R2
	MOVBU	c+24(FP), R1
	MOVD	$ret+32(FP), R8
	B	runtime·indexbytebody<>(SB)

TEXT strings·IndexByte(SB),NOSPLIT,$0-32
	MOVD	s+0(FP), R0
	MOVD	s_len+8(FP), R2
	MOVBU	c+16(FP), R1
	MOVD	$ret+24(FP), R8
	B	runtime·indexbytebody<>(SB)

// input:
//   R0: data
//   R1: byte to search
//   R2: data len
//   R8: address to put result
TEXT runtime·indexbytebody<>(SB),NOSPLIT,$0
	// Core algorithm:
	// For each 32-byte chunk we calculate a 64-bit syndrome value,
	// with two bits per byte. For each tuple, bit 0 is set if the
	// relevant byte matched the requested character and bit 1 is
	// not used (faster than using a 32bit syndrome). Since the bits
	// in the syndrome reflect exactly the order in which things occur
	// in the original string, counting trailing zeros allows to
	// identify exactly which byte has matched.

	CBZ	R2, fail
	MOVD	R0, R11
	// Magic constant 0x40100401 allows us to identify
	// which lane matches the requested byte.
	// 0x40100401 = ((1<<0) + (4<<8) + (16<<16) + (64<<24))
	// Different bytes have different bit masks (i.e: 1, 4, 16, 64)
	MOVD	$0x40100401, R5
	VMOV	R1, V0.B16
	// Work with aligned 32-byte chunks
	BIC	$0x1f, R0, R3
	VMOV	R5, V5.S4
	ANDS	$0x1f, R0, R9
	AND	$0x1f, R2, R10
	BEQ	loop

	// Input string is not 32-byte aligned. We calculate the
	// syndrome value for the aligned 32 bytes block containing
	// the first bytes and mask off the irrelevant part.
	VLD1.P	(R3), [V1.B16, V2.B16]
	SUB	$0x20, R9, R4
	ADDS	R4, R2, R2
	VCMEQ	V0.B16, V1.B16, V3.B16
	VCMEQ	V0.B16, V2.B16, V4.B16
	VAND	V5.B16, V3.B16, V3.B16
	VAND	V5.B16, V4.B16, V4.B16
	VADDP	V4.B16, V3.B16, V6.B16 // 256->128
	VADDP	V6.B16, V6.B16, V6.B16 // 128->64
	VMOV	V6.D[0], R6
	// Clear the irrelevant lower bits
	LSL	$1, R9, R4
	LSR	R4, R6, R6
	LSL	R4, R6, R6
	// The first block can also be the last
	BLS	masklast
	// Have we found something already?
	CBNZ	R6, tail

loop:
	VLD1.P	(R3), [V1.B16, V2.B16]
	SUBS	$0x20, R2, R2
	VCMEQ	V0.B16, V1.B16, V3.B16
	VCMEQ	V0.B16, V2.B16, V4.B16
	// If we're out of data we finish regardless of the result
	BLS	end
	// Use a fast check for the termination condition
	VORR	V4.B16, V3.B16, V6.B16
	VADDP	V6.D2, V6.D2, V6.D2
	VMOV	V6.D[0], R6
	// We're not out of data, loop if we haven't found the character
	CBZ	R6, loop

end:
	// Termination condition found, let's calculate the syndrome value
	VAND	V5.B16, V3.B16, V3.B16
	VAND	V5.B16, V4.B16, V4.B16
	VADDP	V4.B16, V3.B16, V6.B16
	VADDP	V6.B16, V6.B16, V6.B16
	VMOV	V6.D[0], R6
	// Only do the clear for the last possible block with less than 32 bytes
	// Condition flags come from SUBS in the loop
	BHS	tail

masklast:
	// Clear the irrelevant upper bits
	ADD	R9, R10, R4
	AND	$0x1f, R4, R4
	SUB	$0x20, R4, R4
	NEG	R4<<1, R4
	LSL	R4, R6, R6
	LSR	R4, R6, R6

tail:
	// Check that we have found a character
	CBZ	R6, fail
	// Count the trailing zeros using bit reversing
	RBIT	R6, R6
	// Compensate the last post-increment
	SUB	$0x20, R3, R3
	// And count the leading zeros
	CLZ	R6, R6
	// R6 is twice the offset into the fragment
	ADD	R6>>1, R3, R0
	// Compute the offset result
	SUB	R11, R0, R0
	MOVD	R0, (R8)
	RET

fail:
	MOVD	$-1, R0
	MOVD	R0, (R8)
	RET

// Equal(a, b []byte) bool
TEXT bytes·Equal(SB),NOSPLIT,$0-49
	MOVD	a_len+8(FP), R1
	MOVD	b_len+32(FP), R3
	CMP	R1, R3
	// unequal lengths are not equal
	BNE	not_equal
	// short path to handle 0-byte case
	CBZ	R1, equal
	MOVD	a+0(FP), R0
	MOVD	b+24(FP), R2
	MOVD	$ret+48(FP), R8
	B	runtime·memeqbody<>(SB)
equal:
	MOVD	$1, R0
	MOVB	R0, ret+48(FP)
	RET
not_equal:
	MOVB	ZR, ret+48(FP)
	RET

// input:
// R0: pointer a
// R1: data len
// R2: pointer b
// R8: address to put result
TEXT runtime·memeqbody<>(SB),NOSPLIT,$0
	CMP	$1, R1
	// handle 1-byte special case for better performance
	BEQ	one
	CMP	$16, R1
	// handle specially if length < 16
	BLO	tail
	BIC	$0x3f, R1, R3
	CBZ	R3, chunk16
	// work with 64-byte chunks
	ADD	R3, R0, R6	// end of chunks
chunk64_loop:
	VLD1.P	(R0), [V0.D2, V1.D2, V2.D2, V3.D2]
	VLD1.P	(R2), [V4.D2, V5.D2, V6.D2, V7.D2]
	VCMEQ	V0.D2, V4.D2, V8.D2
	VCMEQ	V1.D2, V5.D2, V9.D2
	VCMEQ	V2.D2, V6.D2, V10.D2
	VCMEQ	V3.D2, V7.D2, V11.D2
	VAND	V8.B16, V9.B16, V8.B16
	VAND	V8.B16, V10.B16, V8.B16
	VAND	V8.B16, V11.B16, V8.B16
	CMP	R0, R6
	VMOV	V8.D[0], R4
	VMOV	V8.D[1], R5
	CBZ	R4, not_equal
	CBZ	R5, not_equal
	BNE	chunk64_loop
	AND	$0x3f, R1, R1
	CBZ	R1, equal
chunk16:
	// work with 16-byte chunks
	BIC	$0xf, R1, R3
	CBZ	R3, tail
	ADD	R3, R0, R6	// end of chunks
chunk16_loop:
	VLD1.P	(R0), [V0.D2]
	VLD1.P	(R2), [V1.D2]
	VCMEQ	V0.D2, V1.D2, V2.D2
	CMP	R0, R6
	VMOV	V2.D[0], R4
	VMOV	V2.D[1], R5
	CBZ	R4, not_equal
	CBZ	R5, not_equal
	BNE	chunk16_loop
	AND	$0xf, R1, R1
	CBZ	R1, equal
tail:
	// special compare of tail with length < 16
	TBZ	$3, R1, lt_8
	MOVD.P	8(R0), R4
	MOVD.P	8(R2), R5
	CMP	R4, R5
	BNE	not_equal
lt_8:
	TBZ	$2, R1, lt_4
	MOVWU.P	4(R0), R4
	MOVWU.P	4(R2), R5
	CMP	R4, R5
	BNE	not_equal
lt_4:
	TBZ	$1, R1, lt_2
	MOVHU.P	2(R0), R4
	MOVHU.P	2(R2), R5
	CMP	R4, R5
	BNE	not_equal
lt_2:
	TBZ     $0, R1, equal
one:
	MOVBU	(R0), R4
	MOVBU	(R2), R5
	CMP	R4, R5
	BNE	not_equal
equal:
	MOVD	$1, R0
	MOVB	R0, (R8)
	RET
not_equal:
	MOVB	ZR, (R8)
	RET

TEXT runtime·return0(SB), NOSPLIT, $0
	MOVW	$0, R0
	RET

// The top-most function running on a goroutine
// returns to goexit+PCQuantum.
TEXT runtime·goexit(SB),NOSPLIT,$-8-0
	MOVD	R0, R0	// NOP
	BL	runtime·goexit1(SB)	// does not return

TEXT runtime·sigreturn(SB),NOSPLIT,$0-0
	RET

// This is called from .init_array and follows the platform, not Go, ABI.
TEXT runtime·addmoduledata(SB),NOSPLIT,$0-0
	SUB	$0x10, RSP
	MOVD	R27, 8(RSP) // The access to global variables below implicitly uses R27, which is callee-save
	MOVD	runtime·lastmoduledatap(SB), R1
	MOVD	R0, moduledata_next(R1)
	MOVD	R0, runtime·lastmoduledatap(SB)
	MOVD	8(RSP), R27
	ADD	$0x10, RSP
	RET

TEXT ·checkASM(SB),NOSPLIT,$0-1
	MOVW	$1, R3
	MOVB	R3, ret+0(FP)
	RET