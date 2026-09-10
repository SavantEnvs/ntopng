/* Fleet policy (SPEC.md 6.1): disable LeakSanitizer preventively at BUILD time. ASan
   use-after-free/overflow and UBSan stay fully on and halting -- only leak detection is affected.

   ntopng's harnesses drive nDPI packet dissection and the ZMQ flow parser through the full ntopng
   object set; those allocate interface/flow/host state that is not freed per input, so LSan reports
   on inputs that are not the defect being hunted.

   NOTE ON HOW THIS IS LINKED: ntopng's libFuzzer binaries are produced by upstream's own
   'make fuzz/<target>' rule in fuzz/Makefile.in, whose link rule we cannot append an object to from
   outside (its LDFLAGS/LIBS come from configure). So mayhem/build.sh appends this definition into
   each harness translation unit it already copies into fuzz/, wrapped in extern "C" because those
   are .cpp. One definition per binary -- each harness TU links into its own target.

   A runtime ASan default-options override -- whether compiled in or passed via ASAN_OPTIONS -- is
   forbidden, because Mayhem alone owns the runtime ASAN/LibFuzzer option set, so this is done via
   the sanctioned build-time hook instead. SPEC.md 6.2 item 15 bans the override symbol NAMES
   anywhere under mayhem/, comments included, so the forbidden construct is described in prose here
   rather than named. __lsan_is_turned_off is the sanctioned hook and is NOT the banned construct. */
int __lsan_is_turned_off(void) {
  return 1;
}
