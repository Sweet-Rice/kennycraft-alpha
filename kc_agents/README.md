# kc_agents: Nemotron agents for KennyCraft

Laptop-side agents that act in the game world. Three sizes:

| Who | Brain | Model |
|---|---|---|
| Pigs, zombies | Rules (wander, flee, chase) | none |
| Villagers (trader, contractor) | One JSON decision per call, 2 villagers per call, short memory; rules on any failure | Nemotron Nano, local (`llama-server` on the laptop GPU) |
| Builder contractor, when hired | Multi-step tool agent: survey, plan, price, quote, build, inspect, get paid | Nemotron Super (build.nvidia.com or a Brev box) |

The model only chooses actions. Code enforces the rules: mobs move at most 8 blocks per decision and villagers stay within 16 blocks of home; the builder can't quote without a valid plan, build before escrow is funded, or get paid before the chip's blocks check out; the bank clamps every price.

## Files
| File | What |
|---|---|
| `world.py` | Blocks, plan expansion, CR6 command compression, `FakeChip` (terrain, blocks, entities that walk like `game/src/entity.c`) |
| `mobs.py` | `MobManager`: rule brain, Nano villager brain, validation, fallback |
| `builder.py` | The builder agent: tools, contract state machine, agent loop |
| `bank.py` | What agents may ask of the bank (`balance`, `fund`, `release`, `refund`) and a `FakeBank` |
| `llm.py` | `nemotron_chat()` (Super, tool calls) and `nano_json()` (Nano, JSON) over the OpenAI API |
| `demo.py` | Mobs for 20 s, then a full builder contract on the fake chip |

The real bank and the UART bridge plug in by exposing the same methods as `FakeBank` and `FakeChip`.

## Run
```sh
python -m unittest kc_agents.test_builder kc_agents.test_mobs   # no network
python -m kc_agents.demo                                         # rules + scripted builder
NVIDIA_API_KEY=... python -m kc_agents.demo                      # builder on Nemotron Super
NANO_BASE_URL=http://127.0.0.1:8080/v1 python -m kc_agents.demo  # villagers on local Nano
```
`NEMOTRON_MODEL`, `NEMOTRON_BASE_URL`, `NANO_MODEL` override the defaults (see `llm.py`). Check the exact model names on build.nvidia.com and Hugging Face before the demo.

## Local Nano (laptop GPU, 6 GB)
```sh
winget install ggml.llamacpp          # Vulkan build, runs on the RTX 3060
llama-server -hf nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF:Q4_K_M --device Vulkan0 -ngl 999 -c 8192 -np 4 \
  --jinja --port 8080
```
Measured on the RTX 3060 Laptop (6 GB): 3.7 GB of GPU memory in use, 0.7-2.6 s per call for two
villagers with thinking off (`llm.py` turns it off; with it on, Nano spends every token reasoning).
`--device Vulkan0` picks the NVIDIA GPU over the integrated one. 20 s of the demo: 20 villager
decisions from the model, 0 fallbacks.

## Super on Brev (1x H200, Nebius, about $6.48/hr)
```sh
pip install vllm
vllm serve <Nemotron 3 Super FP8 repo> --trust-remote-code --max-model-len 32768 \
  --enable-auto-tool-choice --tool-call-parser <parser from the model card> --port 8000
```
Then `NEMOTRON_BASE_URL=http://<instance>:8000/v1`. Develop against build.nvidia.com (free) and run the Brev box only for testing and judging; stop it when idle.
