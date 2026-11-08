import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "KennyCraft · KCN Live",
  description:
    "Read-only KennyCraft ledger balances and backend settlement activity.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className="h-full antialiased">
      <body className="min-h-full bg-slate-950 text-slate-100">{children}</body>
    </html>
  );
}
