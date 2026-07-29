#!/usr/bin/env bash
# Measure what the results table needs.
# Usage: bash benchmark.sh <public-ip>
set -euo pipefail

IP="${1:?usage: benchmark.sh <public-ip>}"
API="http://${IP}:8000"

model_id() {
  curl -s "${API}/v1/models" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])'
}

echo "Waiting for the model to load (first boot pulls the image and weights) ..."
READY=0
for _ in $(seq 1 90); do
  if curl -sf "${API}/v1/models" >/dev/null 2>&1; then READY=1; echo "ready"; break; fi
  sleep 10
done
[ "$READY" = 1 ] || { echo "Never became ready. Check: ssh in, then 'docker logs vllm'."; exit 1; }

MODEL="$(model_id)"
echo "model: $MODEL"

echo
echo "######## SINGLE STREAM ########"
START=$(python3 -c 'import time;print(time.time())')
OUT=$(curl -s "${API}/v1/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"Explain Kubernetes autoscaling in about 200 words.\",\"max_tokens\":256,\"temperature\":0}")
END=$(python3 -c 'import time;print(time.time())')

TOKENS=$(echo "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["usage"]["completion_tokens"])')
python3 - "$START" "$END" "$TOKENS" <<'PY'
import sys
start, end, tokens = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
el = end - start
print(f"completion tokens: {tokens}")
print(f"elapsed:           {el:.2f}s")
print(f"tokens/sec:        {tokens/el:.1f}")
PY

echo
echo "######## 16 CONCURRENT ########"
START=$(python3 -c 'import time;print(time.time())')
for _ in $(seq 1 16); do
  curl -s "${API}/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"Summarize CI/CD in about 100 words.\",\"max_tokens\":128,\"temperature\":0}" \
    >/dev/null &
done
wait
END=$(python3 -c 'import time;print(time.time())')
python3 - "$START" "$END" <<'PY'
import sys
start, end = float(sys.argv[1]), float(sys.argv[2])
el = end - start
print(f"16 requests x 128 max_tokens in {el:.2f}s")
print(f"aggregate throughput:          {(16*128)/el:.1f} tok/s (upper bound - not all requests hit max_tokens)")
PY

echo
echo "NOTE: this measures wall-clock for a batch, not a latency distribution."
echo "Use k6 for real p50/p95 before publishing percentiles."
echo
echo "Record the numbers, then: terraform destroy -auto-approve"
