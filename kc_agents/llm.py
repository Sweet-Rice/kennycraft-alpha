"""Nemotron over the OpenAI-compatible API: the hosted build.nvidia.com endpoint, a Brev
vLLM/NIM box, or llama-server on the laptop. Only the base URL and model change.

  NEMOTRON_BASE_URL  default https://integrate.api.nvidia.com/v1
  NEMOTRON_MODEL     default nvidia/nemotron-3-ultra-550b-a55b
  NVIDIA_API_KEY     key for the hosted API
  NEMOTRON_API_KEY   key for your own server (Brev vLLM); wins over NVIDIA_API_KEY
  NEMOTRON_THINKING  1 to let the model reason before each tool call (slower; off by default)
"""
import json
import os


HOSTED, ULTRA = "https://integrate.api.nvidia.com/v1", "nvidia/nemotron-3-ultra-550b-a55b"
FALLBACK_S = 120        # after the own server fails, use hosted Ultra this long before trying it again


def nemotron_chat():
    """Returns chat(messages, tools) -> {"content": str, "tool_calls": [{"id", "name", "args"}]}.
    With NEMOTRON_BASE_URL set (your own server) and NVIDIA_API_KEY too, a call that can't reach
    your server (stopped, unreachable, 5xx) goes to hosted Ultra instead, so a contract never stalls."""
    import time
    import httpx
    from openai import APIConnectionError, APITimeoutError, InternalServerError, OpenAI
    own = os.environ.get("NEMOTRON_BASE_URL")
    routes = [(OpenAI(base_url=own or HOSTED, timeout=httpx.Timeout(90, connect=5), max_retries=0 if own else 2,
                      api_key=os.environ.get("NEMOTRON_API_KEY") or os.environ.get("NVIDIA_API_KEY", "none")),
               os.environ.get("NEMOTRON_MODEL") or ULTRA)]
    if own and os.environ.get("NVIDIA_API_KEY"):
        routes.append((OpenAI(base_url=HOSTED, api_key=os.environ["NVIDIA_API_KEY"]), ULTRA))
    down_until = [0.0]
    # Reasoning off by default: picking a blueprint and a price took 4.8 s with it, 1.3 s without
    # (hosted Ultra, same choice). NEMOTRON_THINKING=1 turns it back on.
    thinking = None if os.environ.get("NEMOTRON_THINKING") == "1" else {"chat_template_kwargs": {"enable_thinking": False}}

    def create(messages, tools):
        for i, (client, model) in enumerate(routes):
            if i == 0 and len(routes) > 1 and time.monotonic() < down_until[0]:
                continue
            try:
                return client.chat.completions.create(model=model, messages=messages, tools=tools, temperature=0.2,
                                                      extra_body=thinking)
            except (APIConnectionError, APITimeoutError, InternalServerError):
                if i + 1 == len(routes):
                    raise
                down_until[0] = time.monotonic() + FALLBACK_S

    def chat(messages, tools):
        msg = create(messages, tools).choices[0].message
        calls = []
        for c in msg.tool_calls or []:
            try:
                args = json.loads(c.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {"_bad_json": c.function.arguments}
            calls.append({"id": c.id, "name": c.function.name, "args": args})
        return {"content": msg.content or "", "tool_calls": calls}

    return chat


def nano_json(timeout=3.0):
    """Mob brain: Nemotron Nano on the laptop's GPU (llama-server, OpenAI API), JSON out.
    Returns chat_json(messages) -> dict; raises on timeout or bad JSON (the caller falls back).

      NANO_BASE_URL  default http://127.0.0.1:8080/v1
      NANO_MODEL     default nemotron-nano (llama-server serves whatever it loaded)
      NANO_API_KEY   only for a hosted endpoint (e.g. build.nvidia.com's nemotron-3.5-bolt-e4b)
    """
    from openai import OpenAI
    from .mobs import json_reply
    client = OpenAI(base_url=os.environ.get("NANO_BASE_URL", "http://127.0.0.1:8080/v1"),
                    api_key=os.environ.get("NANO_API_KEY", "none"), timeout=timeout, max_retries=0)
    model = os.environ.get("NANO_MODEL", "nemotron-nano")

    def chat_json(messages):
        # Thinking off: with it on, Nano spends all 200 tokens reasoning and answers nothing (3 s/call).
        r = client.chat.completions.create(model=model, messages=messages, temperature=0.7, max_tokens=200,
                                           response_format={"type": "json_object"},
                                           extra_body={"chat_template_kwargs": {"enable_thinking": False}})
        return json_reply(r.choices[0].message.content or "{}")

    return chat_json
