#!/bin/zsh
# Rebuild across the fit range a user is told to adjust within; every
# variant must pass all design checks (stand.py exits 1 on any failure).
# Usage: tools/regress.sh [scratch_dir]
cd "${0:A:h}/.." || exit 1
out=${1:-${TMPDIR:-/tmp}/stand_regress}; mkdir -p "$out"
fails=0
run() {
  if blender -b -P stand.py -- --out "$out" --renders 0 "$@" >"$out/log.txt" 2>&1; then
    print "ok    $*"
  else
    print "FAIL  $*"; grep -E "CHECK FAIL|Error|Traceback" "$out/log.txt" | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}
for c in 0.20 0.25 0.30 0.35 0.40 0.45 0.50; do run --clr $c; done
for t in 13.2 13.5 13.8; do run --disp_t $t; done
for r in 0.20 0.30; do run --rod_clr $r; done
run --foot_w 24
for h in 65.0 66.0; do run --disp_h $h; done
for a in 50 55 65; do run --angle $a; done
print "$fails failure(s)"
exit $fails
