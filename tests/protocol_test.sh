#!/usr/bin/env bash
# Protocol robustness test: the server must survive malformed input.
# Feeds garbage, non-object JSON, missing/invalid method, empty lines,
# and a valid eval — expecting error responses but a live server.
set -uo pipefail

cd "$(dirname "$0")/.."

INPUT='garbage{not json
[1,2,3]
"sorry"

{"id":"a"}
{"id":"b","method":42}
{"id":"c","method":"eval","params":"not-an-object"}
{"id":"d","method":"invoke_restart","params":{"thread":"w9","index":"oops"}}
{"id":"e","method":"eval","params":{"form":"(+ 1 2)"}}
{"id":"f","method":"eval","params":{"form":"(* 6 7)"}}
'

OUT=$(printf '%s\n' "$INPUT" | ./run.sh --pipe 2>/dev/null)

pass=0; fail=0
check() { # name, condition
  if [[ "$2" == "yes" ]]; then echo "  [PASS] $1"; pass=$((pass+1))
  else echo "  [FAIL] $1"; echo "        got: $3"; fail=$((fail+1)); fi
}

l1=$(echo "$OUT" | grep -c "malformed JSON line")
check "garbage -> malformed JSON" "$([[ $l1 -ge 1 ]] && echo yes || echo no)" "$OUT"

nonobj=$(echo "$OUT" | grep -c "request must be a JSON object")
check "array -> not an object error" "$([[ $nonobj -ge 1 ]] && echo yes || echo no)" "$OUT"

nometh=$(echo "$OUT" | grep -c "missing or invalid 'method'")
check "no method -> method error" "$([[ $nometh -ge 1 ]] && echo yes || echo no)" "$OUT"

nonnum_method=$(echo "$OUT" | grep -c "missing or invalid 'method'")
check "non-string method -> method error" "$([[ $nonnum_method -ge 1 ]] && echo yes || echo no)" "$OUT"

badparams=$(echo "$OUT" | grep -c "'params' must be a JSON object")
check "non-object params -> params error" "$([[ $badparams -ge 1 ]] && echo yes || echo no)" "$OUT"

badidx=$(echo "$OUT" | grep -c "'index' must be a non-negative integer")
check "bad index -> index error (no 60s hang)" "$([[ $badidx -ge 1 ]] && echo yes || echo no)" "$OUT"

evals=$(echo "$OUT" | grep -c '"values":\["3"\]')
check "valid eval after errors -> 3" "$([[ $evals -ge 1 ]] && echo yes || echo no)" "$OUT"

evals2=$(echo "$OUT" | grep -c '"values":\["42"\]')
check "server still alive after all garbage -> 42" "$([[ $evals2 -ge 1 ]] && echo yes || echo no)" "$OUT"

lines=$(echo "$OUT" | grep -c '{"id"')
check "one response per request line (no dead loop)" "$([[ $lines -ge 8 ]] && echo yes || echo no)" "responses: $lines"

echo
echo "$pass/$((pass+fail)) passed"
[[ $fail -eq 0 ]] || exit 1
