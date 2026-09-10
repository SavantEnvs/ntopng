#!/usr/bin/env bash
#
# ntopng/mayhem/build.sh — build ntopng's OSS-Fuzz harnesses as sanitized libFuzzer targets,
# plus a standalone (non-libFuzzer) reproducer used by mayhem/test.sh as a behavioral KAT oracle.
#
# The fuzzed surface is:
#   fuzz_dissect_packet — packet dissection / protocol parsing harness (pcap -> dissectPacket)
#   fuzz_zmq_flow       — ZMQ flow-JSON parsing harness
#
# AIR-GAP CONTRACT: nDPI (ntopng's mandatory peer dependency, ../nDPI relative to $SRC) is
# cloned+compiled by mayhem/Dockerfile as root, at IMAGE BUILD time (network available then).
# This script never fetches it and never needs the network: it only *uses* the pre-built
# ../nDPI tree (ntopng's own configure.ac.in reads ../nDPI/src/lib/libndpi.a directly; nDPI is
# never `make install`ed system-wide). The one guard below (build nDPI if the .a is somehow
# missing) exists purely for idempotency of a from-scratch, non-Docker re-run and does not
# perform any network I/O itself (no git clone) — if the source truly isn't there, we fail loudly.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE).

set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ntopng's own preprocessor gate for the parts of its codebase that need optional runtime deps
# (hiredis, ...) that we don't ship for the fuzz-only build. This is the same macro OSS-Fuzz's
# base-builder defines by default; ntop_includes.h already guards `#include <hiredis.h>` etc on it.
FUZZ_DEFS="-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
# -fsanitize=fuzzer-no-link: LIB_FUZZING_ENGINE (-fsanitize=fuzzer) is only threaded through at the
# final LINK step (fuzz/Makefile), so without this the compiled objects (ntopng's own src/*.o, the
# harness .cpp) carry ASan/UBSan but NO SanitizerCoverage trace-pc-guard instrumentation -> the
# target runs but records edges=0 ("Run Failed" with green CI). Add it at COMPILE time, alongside
# $SANITIZER_FLAGS, so coverage is actually measured. (nDPI is deliberately left uninstrumented,
# built plain in mayhem/Dockerfile — matches upstream OSS-Fuzz's own ntopng build.sh.)
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS $FUZZ_DEFS"
FUZZ_CXXFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS $FUZZ_DEFS"

# ── nDPI (peer dependency, pre-baked by the Dockerfile at ../nDPI == /nDPI) ────────────────

NDPI_DIR=""
for dir in ../nDPI /nDPI; do
  if [ -d "$dir" ]; then NDPI_DIR="$dir"; break; fi
done
if [ -z "$NDPI_DIR" ]; then
  echo "ERROR: nDPI source tree not found at ../nDPI or /nDPI. mayhem/Dockerfile must clone+build it" >&2
  exit 1
fi
if [ ! -f "$NDPI_DIR/src/lib/libndpi.a" ]; then
  # Idempotency fallback only (e.g. a bare re-run outside the baked image): build in place.
  # No network I/O — the nDPI source must already exist on disk (see Dockerfile).
  echo "nDPI static lib missing, building in place from existing source ($NDPI_DIR)..."
  ( cd "$NDPI_DIR" && [ -f configure ] || ./autogen.sh; ./configure; make -j"$MAYHEM_JOBS" )
fi

# ── Regenerate ntopng's build system WITHOUT fetching git submodules ──────────────────────
#
# Upstream's own ./autogen.sh does `git submodule init && git submodule update --remote`, which
# needs network (httpdocs/dist web assets, tests/e2e, third-party/clickhouse-cpp — none of which
# the fuzz targets need). Re-implement the rest of autogen.sh (configure.ac templating +
# autoreconf) so the build stays air-gapped and idempotent.
if [ ! -x ./configure ] || [ configure.ac.in -nt ./configure ]; then
  TODAY=$(date +%y%m%d)
  MAJOR_RELEASE="6"; MINOR_RELEASE="7"; SHORT_VERSION="$MAJOR_RELEASE.$MINOR_RELEASE"
  VERSION="$SHORT_VERSION.$TODAY"
  GIT_TAG=$(git rev-parse HEAD 2>/dev/null || echo unknown)
  GIT_DATE=$(date +%Y%m%d)
  GIT_RELEASE="$GIT_TAG:$GIT_DATE"
  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's/heads\///g' | tr '/' '-' || echo mayhem)
  sed \
      -e "s/@VERSION@/$VERSION/g" \
      -e "s/@SHORT_VERSION@/$SHORT_VERSION/g" \
      -e "s/@GIT_TAG@/$GIT_TAG/g" \
      -e "s/@GIT_DATE@/$GIT_DATE/g" \
      -e "s/@TODAY@/$TODAY/g" \
      -e "s/@GIT_RELEASE@/$GIT_RELEASE/g" \
      -e "s/@GIT_BRANCH@/$GIT_BRANCH/g" \
      -e "s/@PRO_GIT_RELEASE@//g" \
      -e "s/@PRO_GIT_DATE@//g" \
      configure.ac.in > configure.ac
  rm -f config.h config.h.in *~
  autoreconf -if
fi

# ── Install our (additive, mayhem/-staged) harnesses over the upstream fuzz/ copies ────────
#
# ntopng ships its own fuzz/fuzz_*.cpp upstream (fuzz_all is an upstream make target). We keep
# mayhem/harnesses/*.cpp as the source of truth (adds the MAYHEM_KAT_PROBE oracle hook) and
# install it here at BUILD time only — this never touches the git tree, so the `mayhem` branch
# stays a purely additive diff against upstream.
cp mayhem/harnesses/fuzz_dissect_packet.cpp fuzz/fuzz_dissect_packet.cpp
cp mayhem/harnesses/fuzz_zmq_flow.cpp fuzz/fuzz_zmq_flow.cpp

# Build-time LSan-off hook (SPEC.md 6.1, mayhem/lsan_off.c). ASan use-after-free/overflow and UBSan
# stay fully on and halting; only leak detection is affected. A runtime ASan default-options
# override is forbidden (Mayhem owns the runtime option set), and SPEC.md 6.2 item 15 bans the
# override symbol names anywhere under mayhem/, comments included -- hence prose, not names.
#
# Upstream's `make fuzz/<target>` does the final link via fuzz/Makefile.in, whose LDFLAGS/LIBS come
# from configure, so there is no way to hand it an extra object from here. Instead the hook is
# appended into each harness TU we just copied -- extern "C" because these are .cpp, and exactly one
# definition per binary since each harness links into its own target.
for _h in fuzz_dissect_packet fuzz_zmq_flow; do
  {
    printf '\n/* --- appended by mayhem/build.sh from mayhem/lsan_off.c --- */\nextern "C" {\n'
    cat "$SRC/mayhem/lsan_off.c"
    printf '}\n'
  } >> "fuzz/$_h.cpp"
  grep -q '__lsan_is_turned_off' "fuzz/$_h.cpp" || { echo "ERROR: LSan hook not appended to fuzz/$_h.cpp" >&2; exit 1; }
done
echo "appended the build-time LSan-off hook to both harness TUs"

echo "Configuring ntopng with fuzz targets..."
./configure \
  --enable-fuzztargets --without-hiredis \
  CFLAGS="$FUZZ_CFLAGS" \
  CXXFLAGS="$FUZZ_CXXFLAGS"

# Build ONLY the two targets this integration ships — NOT upstream's `fuzz_all`.
#
# `fuzz_all` expands to upstream's full FUZZ_TARGETS list, which grew from 2 to 4
# (fuzz_snmp_response, fuzz_syslog_parse). fuzz_snmp_response wraps its entire translation unit —
# including the `bool trace_new_delete = false;` that every harness must define, since fuzz/Makefile
# filters src/main.o out of OBJECTS_FOR_FUZZ — in `#ifdef HAVE_LIBSNMP`. We don't ship libsnmp, so
# that TU compiles to nothing and the link dies on undefined `trace_new_delete` from src/*.o.
#
# Naming the two targets explicitly also pins our fuzzed surface against the stamp's target set
# (the target-drop ratchet) instead of letting an upstream addition silently change it. Picking up
# fuzz_snmp_response / fuzz_syslog_parse is a deliberate new-target decision (Mayhemfiles + seeds +
# runs), not something a sync should do implicitly.
echo "Building ntopng fuzz targets..."
make -j"$MAYHEM_JOBS" fuzz/fuzz_dissect_packet fuzz/fuzz_zmq_flow

# ── Standalone (non-libFuzzer) reproducer for fuzz_dissect_packet ─────────────────────────
#
# Linked against $STANDALONE_FUZZ_MAIN instead of libFuzzer so mayhem/test.sh can run a real
# KAT (known pcap -> known nDPI classification) without depending on libFuzzer's CLI. Reuses
# the exact same harness object + ntopng objects as the real fuzz target.
echo "Building standalone reproducer for fuzz_dissect_packet..."
"$CC" $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o fuzz/standalone_main.o
"$CXX" $FUZZ_CXXFLAGS \
  -I"$SRC" -I"$SRC/include" -std=c++17 \
  -I/usr/include/x86_64-linux-gnu -I"$SRC/third-party/mongoose" -I/usr/include/json-c \
  -I"$NDPI_DIR/src/include" -I"$NDPI_DIR/src/lib/third_party/include" \
  -I"$SRC/third-party/lua-5.4.6/src" \
  -isystem /usr/include/mit-krb5 -I/usr/include/pgm-5.3 -I/usr/include/libxml2 \
  -I"$SRC/third-party/http-client-c/src/" -I/usr/include/openssl \
  -DDATA_DIR='"/usr/local/share"' \
  -Wno-address-of-packed-member -Wno-unused-function \
  -c fuzz/fuzz_dissect_packet.cpp -o fuzz/fuzz_dissect_packet_standalone.o

NDPI_LIB="$NDPI_DIR/src/lib/libndpi.a"
LUA_LIB="$SRC/third-party/lua-5.4.6/src/liblua.a"
"$CXX" $FUZZ_CXXFLAGS \
  fuzz/fuzz_dissect_packet_standalone.o fuzz/standalone_main.o fuzz/stub/RedisStub.o \
  src/*.o src/flow_checks/*.o src/flow_alerts/*.o src/host_checks/*.o src/host_alerts/*.o \
  "$LUA_LIB" "$NDPI_LIB" -lpcap "$LUA_LIB" \
  -lrrd -ljson-c -lmaxminddb -lsqlite3 -lssl -lcrypto -lzmq \
  -lresolv -latomic -lsodium -L/usr/local/lib -lcap -lldap -llber -lrt -lz -ldl -lcurl -lzstd \
  -lm -lpthread -Wl,-z,relro,-z,now \
  -o fuzz/fuzz_dissect_packet_standalone

# ── Stage outputs where Mayhem/test.sh expect them ─────────────────────────────────────────
#
# The harness's own CLI-arg plumbing (setCLIArgs -> _PATH_docs / _PATH_scripts / _PATH_data-dir
# / _PATH_install) resolves those paths RELATIVE TO THE RUNNING BINARY'S OWN DIRECTORY (via
# /proc/self/exe), so the docs/scripts/scripts/callbacks/data-dir/install directories must exist
# next to wherever we copy the binaries — here, directly under /mayhem (== $SRC).
mkdir -p /mayhem/install /mayhem/data-dir /mayhem/docs /mayhem/scripts/callbacks

cp fuzz/fuzz_dissect_packet /mayhem/fuzz_dissect_packet
cp fuzz/fuzz_zmq_flow /mayhem/fuzz_zmq_flow
cp fuzz/fuzz_dissect_packet_standalone /mayhem/fuzz_dissect_packet_standalone

# Seed corpora + dictionaries (bootstrap only; Mayhem accumulates its own corpus over time —
# no `testsuite:` directive in the Mayhemfiles, see issue #124).
cp fuzz/*.dict /mayhem/ 2>/dev/null || true

echo "Build complete:"
ls -lh /mayhem/fuzz_dissect_packet /mayhem/fuzz_zmq_flow /mayhem/fuzz_dissect_packet_standalone

# mayhem-dict-fix: place the dictionaries the Mayhemfiles reference (build.sh never did -> libFuzzer exited 1 on missing -dict -> 0 edges)
find "$SRC/mayhem" -name "*.dict" -exec cp {} /mayhem/ \; 2>/dev/null || true
