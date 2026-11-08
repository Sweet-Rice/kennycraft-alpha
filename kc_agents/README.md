# kc_agents: Nemotron agents for KennyCraft

Laptop-side agents that act in the game world. Three sizes:

| Who | Brain | Model |
|---|---|---|
| Chickens, zombies | Rules (wander, flee, chase) | none |
| Villagers (trader, contractor) within 24 blocks of the player | One JSON decision per call, 2 villagers per call, memory of the last 3 actions; rules on any timeout (3 s), error or bad answer | Nemotron Nano, local (`llama-server` on the laptop GPU) |
| Builder contractor, when hired | Multi-step tool agent: survey, plan, price, quote, build, inspect, get paid | Nemotron Ultra by default, hosted or on an OpenAI-compatible server |
| Banker and trader, through `host/` | Tool agents for confirmed currency exchanges and material trades | The same configured tool model as the builder |

The model only chooses actions. Code limits one mob decision to 8 blocks per
axis and keeps villagers within 16 blocks of home (`mobs.py`). The builder
requires an accepted plan before quoting, funded escrow before building, at
most three build attempts, and a passing inspection before payment (`builder.py`).
Inspection samples up to eight target cells by default; it does not verify the
whole plan. Its progress count uses local `get()` values (a mirror in UART
adapters), not a full chip readback. An unsampled wrong block can therefore
remain even when inspection passes and payment is released.

Builder quotes are clamped to 0.5x-1.5x of the plan's rule price after the
player's material discount, at most 200 KCN and the player's balance.
Successful release charges a 10% treasury fee (`bank.py`).

`Contract.cancel()` in `FUNDED` or `BUILT` counts matching target cells through
local `get()`, pays the builder that proportion of the price rounded down, and
refunds the rest without a treasury fee. In `VERIFIED`, that method changes the
state to `CANCELLED` without moving money: escrow stays held. When its tool loop
ends normally in `FUNDED`, `BUILT` or `VERIFIED`, `run()` invokes this method.

The host's interrupt/error cleanup is separate: `Orchestrator.stop()` also
handles `VERIFIED`, using the same pro-rata split and setting `REFUNDED`.

## Files
| File | What |
|---|---|
| `world.py` | Blocks, plan expansion (`expand`), CR6 PLACE/FILL compression (`compress`), `FakeChip` (terrain, blocks, entities that walk like `game/src/entity.c`) |
| `mobs.py` | `MobManager`: rule brain, Nano villager brain, validation, fallback |
| `builder.py` | The builder agent: tools, `Contract` state machine, agent loop (`run`) |
| `banker.py` | Banker visit tools: balances, payment history, chain lookup and player-confirmed exchanges |
| `trader.py` | Trader visit tools: material stock and player-confirmed purchases/sales with bounded prices |
| `bank.py` | What agents may ask of the bank (`balance`, `fund`, `release`, `refund`), `rule_price`, `clamp_price` and a `FakeBank` |
| `cr6.py` | CR6 laptop side: frames + CRC-8, stream decoder, credit-paced `Link`, `Cr6Chip` (the agents' chip interface over UART, with a local world copy; `verify()` reads blocks back from the chip), `FakeUartChip` (16-byte FIFO, one drain and STATUS per frame) |
| `llm.py` | `nemotron_chat()` (tool calls, Ultra by default) and `nano_json()` (Nano, JSON) over the OpenAI-compatible API |
| `demo.py` | Mobs for 20 s, then a full builder contract on `FakeChip` and `FakeBank` |
| `test_builder.py`, `test_mobs.py`, `test_cr6.py`, `test_banker.py`, `test_trader.py` | Unit tests; no model, network, board or serial port |
| `__init__.py` | Empty package marker |

`Cr6Chip` exposes the methods the agents call on `FakeChip` (`ground`, `get`, `place`, `fill`, `spawn`, `move`, `entity`; not `tick`); `demo.py` and `builder.py` use `FakeChip` only. A real bank plugs in by exposing the same methods as `FakeBank`. `Cr6Chip` does not yet apply player edits (EDIT events) to its world copy.

`host/` at the repo root has its own CR6 bridge (`host/cr6.py`) and ledger
(`host/bank.py`). `host/orchestrator.py` imports this package's builder, banker,
trader and mob agents, adapting their chip and bank interfaces to CR6 and the
real ledger. `host/kchost.py` enables the Nano brain when `NANO_BASE_URL` is set.

## Run
```sh
python -m unittest kc_agents.test_builder kc_agents.test_mobs kc_agents.test_cr6 kc_agents.test_banker kc_agents.test_trader   # no network
python -m kc_agents.demo                                         # rules + scripted builder
NVIDIA_API_KEY=... python -m kc_agents.demo                      # builder on the hosted tool model
NANO_BASE_URL=http://127.0.0.1:8080/v1 python -m kc_agents.demo  # villagers on local Nano
NVIDIA_API_KEY=... python -m kc_agents.builder "a small plank hut"  # tool agent alone on FakeChip
```
Run from the repo root. The model paths need the `openai` package; the tests and the offline demo need only the standard library.

| Variable | Default (`llm.py`) |
|---|---|
| `NEMOTRON_BASE_URL` | `https://integrate.api.nvidia.com/v1` |
| `NEMOTRON_MODEL` | `nvidia/nemotron-3-ultra-550b-a55b` |
| `NVIDIA_API_KEY` | `none`; hosted API key, also enables the demo's model-backed builder |
| `NEMOTRON_API_KEY` | Unset; takes precedence over `NVIDIA_API_KEY` for the primary tool-model endpoint |
| `NANO_BASE_URL` | `http://127.0.0.1:8080/v1` |
| `NANO_MODEL` | `nemotron-nano` (llama-server serves whatever it loaded) |
| `NANO_API_KEY` | `none`; key for a hosted Nano endpoint |

With both `NEMOTRON_BASE_URL` and `NVIDIA_API_KEY` set, connection errors,
timeouts and server 5xx errors on the primary tool-model endpoint fall back to
hosted Ultra for 120 seconds before retrying the primary. The fallback uses
`NVIDIA_API_KEY` and the default Ultra model, not `NEMOTRON_MODEL`.

The demo selects its model-backed builder only when `NVIDIA_API_KEY` is set.
For a local or Brev tool server without a hosted key, set `NEMOTRON_MODEL` to
the model ID served there, then run the standalone builder:

```sh
NEMOTRON_MODEL="${NEMOTRON_MODEL:?set the server model ID first}" \
  NEMOTRON_BASE_URL=http://127.0.0.1:8000/v1 NEMOTRON_API_KEY=local \
  python -m kc_agents.builder "a small plank hut"
```

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

## Tool model on Brev (1x H200, Nebius, about $6.48/hr)
```sh
pip install vllm
vllm serve <model repo that fits the instance> --trust-remote-code --max-model-len 32768 \
  --enable-auto-tool-choice --tool-call-parser <parser from the model card> --port 8000
```
Then set `NEMOTRON_BASE_URL=http://<instance>:8000/v1`, `NEMOTRON_MODEL` to the
model served there, and `NEMOTRON_API_KEY` if the server requires one. Develop
against build.nvidia.com and run the Brev box only for testing and judging;
stop it when idle.
