// tsan_preinit.d — the five lines without which a --fsanitize=thread build of
// this editor does not reach main() at all (task 1411).
//
// THE CRASH
// ---------
// Built with --fsanitize=thread, ./vibe3d died in SIGSEGV BEFORE main. Read
// out of the coredump under gdb, not inferred from behaviour:
//
//   #0  0x0000000000000000 in ?? ()
//   #1  ___interceptor_prctl () at sanitizer_common_interceptors.inc:1291
//   #2  ?? () from /lib64/libcap.so.2
//   #3  call_init (...) at dl-init.c:74
//   #5  _dl_init (...)
//
// libcap.so.2 (pulled in by SDL2 -> libsystemd) runs an ELF constructor that
// calls prctl(). ELF constructors run during _dl_init, i.e. BEFORE the
// TSan runtime has initialised, so the interceptor jumps through a REAL(prctl)
// that is still null.
//
// WHY THE RUNTIME DID NOT INITIALISE ITSELF
// -----------------------------------------
// It is supposed to: compiler-rt ships tsan_preinit.cpp, whose whole job is to
// put __tsan_init into .preinit_array, which the loader runs BEFORE any ELF
// constructor. `readelf -S ./vibe3d` showed NO .preinit_array section at all.
// The reason is ordinary static-archive linkage: tsan_preinit.cpp.o's only
// symbol, _ZL7preinit, is LOCAL, so nothing ever references it, so the linker
// never pulls that member out of libldc_rt.tsan.a. Linking the member by its
// absolute path inside the LDC installation also fixes it — and is exactly the
// kind of absolute path that must not appear in dub.json.
//
// THE FIX
// -------
// Put the entry in .preinit_array from D. @assumeUsed keeps the symbol from
// being dropped as unreferenced; @section places it. Verified both ways on a
// three-line reproducer linked with -L-lcap: with this module the program
// reaches main (rc=0) and the binary has a PREINIT_ARRAY section; without it,
// rc=139 and there is no such section.
//
// SCOPE
// -----
// version=SanitizerThreadPreinit is declared by the `tsan` buildType and by
// nothing else, so this module compiles to nothing in every shipped build. It
// declares __tsan_init WITHOUT defining it; in a build that is not linked
// against the TSan runtime the reference would not resolve, which is why the
// version gate and the buildType are the same switch.
module tsan_preinit;

version (SanitizerThreadPreinit):

import ldc.attributes : section, assumeUsed;

extern (C) void __tsan_init();

@section(".preinit_array") @assumeUsed
__gshared extern (C) void function() _v3dTsanPreinit = &__tsan_init;
