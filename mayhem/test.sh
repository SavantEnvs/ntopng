#!/usr/bin/env bash
#
# ntopng/mayhem/test.sh — behavioral KAT oracle (SPEC §6.3).
#
# This does NOT just check "the binary is executable" / "responds to -help" (that asserts
# nothing about correctness and is explicitly forbidden). Instead it feeds FIXED, known inputs
# through the real dissection/parsing code and asserts a specific COMPUTED value nDPI/ntopng
# derives from them. A patch that neuters the fuzzed code to a no-op (or the whole binary to
# exit(0)) makes these assertions fail, because the computed values would never appear.
#
#  1. fuzz_dissect_packet: a fixed, hand-crafted DLT_NULL/IPv4/UDP/NTP packet is dissected via
#     iface->dissectPacket(); we assert nDPI actually classified it as
#     master_protocol=0, app_protocol=9 (NTP) — printed by the harness's MAYHEM_KAT_PROBE hook.
#  2. fuzz_zmq_flow: zmq_iface->parseJSONCounter() is fed one well-formed and one malformed
#     JSON payload; we assert the real, distinct return codes (0 vs -1) it computes for each.

set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"

cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TESTS=0
PASSED=0
FAILED=0

check() {
  # check <description> -- runs the rest of the args as a command, counts pass/fail
  local desc="$1"; shift
  TESTS=$((TESTS + 1))
  if "$@"; then
    echo "PASS: $desc"
    PASSED=$((PASSED + 1))
    return 0
  else
    echo "FAIL: $desc"
    FAILED=$((FAILED + 1))
    return 1
  fi
}

DISSECT_STANDALONE=/mayhem/fuzz_dissect_packet_standalone
ZMQ_FLOW_BIN=/mayhem/fuzz_zmq_flow
KAT_PCAP="$SRC/mayhem/fuzz_dissect_packet/testsuite/kat_ntp_dlt_null.pcap"
KAT_ZMQ_VALID="$SRC/mayhem/fuzz_zmq_flow/testsuite/kat_valid_counter.bin"
KAT_ZMQ_INVALID="$SRC/mayhem/fuzz_zmq_flow/testsuite/kat_invalid_counter.bin"

echo "=== ntopng behavioral KAT oracle ==="

# Unconditional: missing binary/seed => FAIL (never silently skip).
check "fuzz_dissect_packet_standalone exists and is executable" \
  [ -x "$DISSECT_STANDALONE" ]
check "fuzz_zmq_flow exists and is executable" \
  [ -x "$ZMQ_FLOW_BIN" ]
check "fixed KAT pcap for fuzz_dissect_packet exists" \
  [ -f "$KAT_PCAP" ]
check "fixed KAT payloads for fuzz_zmq_flow exist" \
  bash -c '[ -f "'"$KAT_ZMQ_VALID"'" ] && [ -f "'"$KAT_ZMQ_INVALID"'" ]'

# --- KAT 1: fuzz_dissect_packet -> nDPI must classify our fixed NTP packet as master=0 app=9 ---
if [ -x "$DISSECT_STANDALONE" ] && [ -f "$KAT_PCAP" ]; then
  DISSECT_OUT=$(MAYHEM_KAT_PROBE=1 timeout 15 "$DISSECT_STANDALONE" "$KAT_PCAP" 2>&1)
  echo "$DISSECT_OUT" | sed 's/^/[dissect_packet] /'
  check "fuzz_dissect_packet classifies the fixed NTP packet as nDPI proto 0.9 (NTP)" \
    bash -c "echo \"\$1\" | grep -q 'MAYHEM_KAT master=0 app=9'" _ "$DISSECT_OUT"
else
  TESTS=$((TESTS + 1)); FAILED=$((FAILED + 1))
  echo "FAIL: fuzz_dissect_packet KAT (prerequisite binary/input missing)"
fi

# --- KAT 2: fuzz_zmq_flow -> parseJSONCounter must really parse (0) vs really reject (-1) ---
if [ -x "$ZMQ_FLOW_BIN" ] && [ -f "$KAT_ZMQ_VALID" ] && [ -f "$KAT_ZMQ_INVALID" ]; then
  ZMQ_VALID_OUT=$(MAYHEM_KAT_PROBE=1 timeout 15 "$ZMQ_FLOW_BIN" "$KAT_ZMQ_VALID" 2>&1)
  echo "$ZMQ_VALID_OUT" | sed 's/^/[zmq_flow valid] /'
  check "fuzz_zmq_flow parseJSONCounter accepts well-formed JSON (rc=0)" \
    bash -c "echo \"\$1\" | grep -q 'MAYHEM_KAT parseJSONCounter_rc=0'" _ "$ZMQ_VALID_OUT"

  ZMQ_INVALID_OUT=$(MAYHEM_KAT_PROBE=1 timeout 15 "$ZMQ_FLOW_BIN" "$KAT_ZMQ_INVALID" 2>&1)
  echo "$ZMQ_INVALID_OUT" | sed 's/^/[zmq_flow invalid] /'
  check "fuzz_zmq_flow parseJSONCounter rejects malformed JSON (rc=-1)" \
    bash -c "echo \"\$1\" | grep -q 'MAYHEM_KAT parseJSONCounter_rc=-1'" _ "$ZMQ_INVALID_OUT"
else
  TESTS=$((TESTS + 2)); FAILED=$((FAILED + 2))
  echo "FAIL: fuzz_zmq_flow KAT (prerequisite binary/input missing)"
fi

echo ""
echo "=== Test Summary ==="
echo "Tests: $TESTS, Passed: $PASSED, Failed: $FAILED"
echo ""

emit_ctrf "ntopng-fuzz-kat" "$PASSED" "$FAILED" 0
