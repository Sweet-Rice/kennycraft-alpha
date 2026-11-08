export const dynamic = "force-dynamic";

// Only the backend's read-only event stream is exposed, never its exchange or game controls.
export async function GET(request: Request) {
  try {
    const url = new URL(
      "/events",
      process.env.KCN_BACKEND_URL || "http://127.0.0.1:8000",
    );
    const upstream = await fetch(url, {
      cache: "no-store",
      signal: request.signal,
    });
    if (
      !upstream.ok ||
      !upstream.body ||
      !upstream.headers.get("content-type")?.includes("text/event-stream")
    ) {
      await upstream.body?.cancel();
      throw new Error("Backend stream unavailable");
    }
    return new Response(upstream.body, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-store, no-transform",
        "X-Accel-Buffering": "no",
      },
    });
  } catch {
    return Response.json(
      { error: "KennyCraft backend stream unavailable" },
      { status: 502, headers: { "Cache-Control": "no-store" } },
    );
  }
}
