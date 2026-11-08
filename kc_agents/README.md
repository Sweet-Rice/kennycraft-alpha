# kc_agents: Nemotron agents for KennyCraft

Laptop-side agents that act in the game world. Three sizes:

| Who | Brain | Model |
|---|---|---|
| Chickens, zombies | Rules (wander, flee, chase) | none |
| Villagers (trader, contractor) within 24 blocks of the player | One JSON decision per call, 2 villagers per call, memory of the last 3 actions; rules on any timeout (3 s), error or bad answer | Nemotron Nano, local (`llama-server` on the laptop GPU) |
| Builder contractor, when hired | Multi-step tool agent: survey, plan, price, quote, build, inspect, get paid | Nemotron Super (build.nvidia.com or a Brev box) |

The model only chooses actions. Code enforces the rules: one decision moves a mob at most 8 blocks per axis and villagers stay within 16 blocks of home (`mobs.py`); the builder can't quote without a valid plan, build before escrow is funded, build more than 3 times, or get paid before the chip's blocks check out (`builder.py`); the bank clamps every price to 0.5x-1.5x of the rule price (`5 + cells + 2 * breaks`), at most 200 KCN and the player's balance, and keeps a 10% fee on release (`bank.py`). Cancelling after funding but before inspect passes pays the builder for the share of blocks already placed and refunds the rest; `run` does this itself if the model stops mid-contract. Cancelling after inspect passes moves no money: the escrow stays held.

## Files
| File | What |
|---|---|
| `world.py` | Blocks, plan expansion (`expand`), CR6 PLACE/FILL compression (`compress`), `FakeChip` (terrain, blocks, entities that walk like `game/src/entity.c`) |
| `mobs.py` | `MobManager`: rule brain, Nano villager brain, validation, fallback |
| `builder.py` | The builder agent: tools, `Contract` state machine, agent loop (`run`) |
| `bank.py` | What agents may ask of the bank (`balance`, `fund`, `release`, `refund`), `rule_price`, `clamp_price` and a `FakeBank` |
| `cr6.py` | CR6 laptop side: frames + CRC-8, stream decoder, credit-paced `Link`, `Cr6Chip` (the agents' chip interface over UART, with a local world copy; `verify()` reads blocks back from the chip), `FakeUartChip` (16-byte FIFO, one drain and STATUS per frame) |
| `llm.py` | `nemotron_chat()` (Super, tool calls) and `nano_json()` (Nano, JSON) over the OpenAI API |
| `demo.py` | Mobs for 20 s, then a full builder contract on `FakeChip` and `FakeBank` |
| `test_builder.py`, `test_mobs.py`, `test_cr6.py` | Unit tests; no model, network, board or serial port |
| `__init__.py` | Empty package marker |

`Cr6Chip` exposes the methods the agents call on `FakeChip` (`ground`, `get`, `place`, `fill`, `spawn`, `move`, `entity`; not `tick`); `demo.py` and `builder.py` use `FakeChip` only. A real bank plugs in by exposing the same methods as `FakeBank`. `Cr6Chip` does not yet apply player edits (EDIT events) to its world copy.

`host/` at the repo root (`host/cr6.py`, `host/bank.py`, `host/agents.py`, ...) is a separate laptop-side implementation with its own CR6 bridge, ledger and pricing agent; neither package imports the other.

## Run
```sh
python -m unittest kc_agents.test_builder kc_agents.test_mobs kc_agents.test_cr6   # no network
python -m kc_agents.demo                                         # rules + scripted builder
NVIDIA_API_KEY=... python -m kc_agents.demo                      # builder on Nemotron Super
NANO_BASE_URL=http://127.0.0.1:8080/v1 python -m kc_agents.demo  # villagers on local Nano
NVIDIA_API_KEY=... python -m kc_agents.builder "a small plank hut"  # builder alone on FakeChip
```
Run from the repo root. The model paths need the `openai` package; the tests and the offline demo need only the standard library.

| Variable | Default (`llm.py`) |
|---|---|
| `NEMOTRON_BASE_URL` | `https://integrate.api.nvidia.com/v1` |
| `NEMOTRON_MODEL` | `nvidia/nemotron-3-super-120b-a12b` |
| `NVIDIA_API_KEY` | `none` (any string works for a local server) |
| `NANO_BASE_URL` | `http://127.0.0.1:8080/v1` |
| `NANO_MODEL` | `nemotron-nano` (llama-server serves whatever it loaded) |

Check the exact model names on build.nvidia.com and Hugging Face before the demo.

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
