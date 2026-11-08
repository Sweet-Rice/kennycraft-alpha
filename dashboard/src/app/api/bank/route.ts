import { getBankState } from "@/lib/nessie";
export const dynamic = "force-dynamic";
export async function GET() {
  const headers = { "Cache-Control": "no-store" };
  try {
    return Response.json(await getBankState(), { headers });
  } catch {
    return Response.json(
      { error: "Nessie account unavailable" },
      { status: 502, headers },
    );
  }
}
