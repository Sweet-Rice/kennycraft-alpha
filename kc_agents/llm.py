"""Nemotron over the OpenAI-compatible API: the hosted build.nvidia.com endpoint, a Brev
vLLM/NIM box, or llama-server on the laptop. Only the base URL and model change.

  NEMOTRON_BASE_URL  default https://integrate.api.nvidia.com/v1
  NEMOTRON_MODEL     default nvidia/nemotron-3-super-120b-a12b
  NVIDIA_API_KEY     key for the hosted API (any string for a local server)
"""
import json
import os


def nemotron_chat():
    """Returns chat(messages, tools) -> {"content": str, "tool_calls": [{"id", "name", "args"}]}."""
    from openai import OpenAI
    client = OpenAI(base_url=os.environ.get("NEMOTRON_BASE_URL", "https://integrate.api.nvidia.com/v1"),
                    api_key=os.environ.get("NVIDIA_API_KEY", "none"))
    model = os.environ.get("NEMOTRON_MODEL", "nvidia/nemotron-3-super-120b-a12b")

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
