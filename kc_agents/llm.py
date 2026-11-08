"""Nemotron over the OpenAI-compatible API: the hosted build.nvidia.com endpoint, a Brev
vLLM/NIM box, or llama-server on the laptop. Only the base URL and model change.

  NEMOTRON_BASE_URL  default https://integrate.api.nvidia.com/v1
  NEMOTRON_MODEL     default nvidia/nemotron-3-ultra-550b-a55b
  NVIDIA_API_KEY     key for the hosted API (any string for a local server)
"""
import json
import os


def nemotron_chat():
    """Returns chat(messages, tools) -> {"content": str, "tool_calls": [{"id", "name", "args"}]}."""
    from openai import OpenAI
    client = OpenAI(base_url=os.environ.get("NEMOTRON_BASE_URL", "https://integrate.api.nvidia.com/v1"),
                    api_key=os.environ.get("NVIDIA_API_KEY", "none"))
    model = os.environ.get("NEMOTRON_MODEL", "nvidia/nemotron-3-ultra-550b-a55b")

    def chat(messages, tools):
        msg = client.chat.completions.create(model=model, messages=messages, tools=tools,
                                             temperature=0.2).choices[0].message
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
    """
    from openai import OpenAI
    from .mobs import json_reply
    client = OpenAI(base_url=os.environ.get("NANO_BASE_URL", "http://127.0.0.1:8080/v1"),
                    api_key="none", timeout=timeout, max_retries=0)
    model = os.environ.get("NANO_MODEL", "nemotron-nano")

    def chat_json(messages):
        # Thinking off: with it on, Nano spends all 200 tokens reasoning and answers nothing (3 s/call).
        r = client.chat.completions.create(model=model, messages=messages, temperature=0.7, max_tokens=200,
                                           response_format={"type": "json_object"},
                                           extra_body={"chat_template_kwargs": {"enable_thinking": False}})
        return json_reply(r.choices[0].message.content or "{}")

    return chat_json
