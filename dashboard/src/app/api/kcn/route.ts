import { getKcnState } from "@/lib/chain";
import { ConfigError } from "@/lib/kcn";
export const dynamic = "force-dynamic";
export async function GET() {
  const headers = { "Cache-Control": "no-store" };
  try {
    return Response.json(await getKcnState(), { headers });
  } catch (error) {
    if (error instanceof ConfigError)
      return Response.json(
        { error: "config", missing: error.missing },
        { status: 503, headers },
      );
    return Response.json(
      {
        error: "rpc",
        message: "Unable to read KCN balances from Solana devnet",
      },
      { status: 502, headers },
    );
  }
}
