#!/usr/bin/env bash
# Benchmarks catalog models on this Mac against a running Ollama (Personal AI or your own).
# Usage: scripts/bench.sh [model ...]   (default: every model in Resources/models.json)
# A model passes when it generates >= 15 tokens/s, which reads as instant in a chat or writing app.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${OLLAMA_HOST_URL:-http://127.0.0.1:11434}"
MODELS=("$@")
[ ${#MODELS[@]} -eq 0 ] && MODELS=($(python3 -c 'import json;print(" ".join(m["id"] for m in json.load(open("Resources/models.json"))["models"]))'))
PROMPT="Je me sens fatigué mais content de ma journée. Résume cette entrée de journal en une phrase et pose une question de suivi."

echo "Mac: $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
printf "%-14s %8s %10s %8s\n" model load_s tok/s pass
for m in "${MODELS[@]}"; do
  curl -sf "$HOST/api/pull" -d "{\"model\":\"$m\",\"stream\":false}" >/dev/null
  curl -sf "$HOST/api/generate" -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null   # unload, so load time is cold
  R=$(curl -sf "$HOST/api/generate" -d "{\"model\":\"$m\",\"prompt\":\"$PROMPT\",\"stream\":false,\"options\":{\"num_predict\":200}}")
  python3 - "$m" "$R" <<'PY'
import json, sys
m, r = sys.argv[1], json.loads(sys.argv[2])
load = r["load_duration"] / 1e9
tps = r["eval_count"] / (r["eval_duration"] / 1e9)
print(f"{m:<14} {load:8.1f} {tps:10.1f} {'yes' if tps >= 15 else 'no':>8}")
PY
done
