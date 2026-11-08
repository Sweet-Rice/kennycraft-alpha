#!/usr/bin/env bash
# Serve Nemotron 3 Super (FP8) with vLLM on one H200, for kc-host's builder, banker and trader.
# Run on the Brev box:   KC_LLM_KEY=<a secret you make up> bash brev_serve.sh
# Then on the laptop, tunnel the port (nothing is exposed publicly):
#   brev port-forward <instance> --port 8000:8000     (or: ssh -L 8000:localhost:8000 <instance>)
# and set in .env:  NEMOTRON_BASE_URL=http://127.0.0.1:8000/v1
#                   NEMOTRON_MODEL=nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8
#                   NEMOTRON_API_KEY=<the same secret>   (NVIDIA_API_KEY stays, for hosted Ultra)
# Flags follow the vLLM recipe (recipes.vllm.ai), with tensor parallelism 1 for a single H200.
# The first start downloads about 120 GB of weights. Stop the instance when you're done.
set -euo pipefail
: "${KC_LLM_KEY:?set KC_LLM_KEY to a secret; kc-host sends it as its API key}"
python3 -m pip install -q "vllm==0.17.1"
exec python3 -m vllm.entrypoints.openai.api_server \
  --model nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8 \
  --trust-remote-code --kv-cache-dtype fp8 --tensor-parallel-size 1 \
  --max-model-len 32768 --gpu-memory-utilization 0.95 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser nemotron_v3 \
  --host 127.0.0.1 --port 8000 --api-key "$KC_LLM_KEY"
