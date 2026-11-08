#!/usr/bin/env bash
# One-time KCN setup, run from the repo root (in WSL or Linux). Safe to rerun:
#
#   scripts/setup_kcn.sh                              devnet
#   RPC_URL=http://127.0.0.1:8899 scripts/setup_kcn.sh   local solana-test-validator
#
# Makes keys/<wallet>.json and keys/mint.json, airdrops SOL to the treasury,
# creates KCN (SPL token, 0 decimals, treasury is mint authority and fee payer),
# one token account per wallet, mints the 1,000,000 supply to the treasury,
# and writes kcn.json. keys/ and kcn.json stay out of git.
set -eu
RPC_URL=${RPC_URL:-https://api.devnet.solana.com}
WALLETS="treasury escrow player builder miner farmer banker"
SUPPLY=1000000

mkdir -p keys
for w in $WALLETS mint; do
    [ -f keys/$w.json ] || solana-keygen new --no-bip39-passphrase --silent -o keys/$w.json
done

# Repo-local CLI config so the user's global solana config is untouched.
cfg=keys/cli.yml
solana config set --config $cfg --url "$RPC_URL" --keypair keys/treasury.json --commitment confirmed >/dev/null
sol() { solana --config $cfg "$@"; }
spl() { spl-token --config $cfg "$@"; }

treasury=$(solana-keygen pubkey keys/treasury.json)
lamports=$(sol balance --lamports "$treasury" | cut -d' ' -f1)
if [ "$lamports" -lt 1000000000 ]; then
    sol airdrop 2 "$treasury" || {
        echo "airdrop failed (faucet limit). Fund $treasury at https://faucet.solana.com, then rerun." >&2
        exit 1
    }
fi

mint=$(solana-keygen pubkey keys/mint.json)
spl display "$mint" >/dev/null 2>&1 || spl create-token --decimals 0 keys/mint.json >/dev/null

json="{\n  \"rpc_url\": \"$RPC_URL\",\n  \"mint\": \"$mint\",\n  \"wallets\": {"
sep=
for w in $WALLETS; do
    owner=$(solana-keygen pubkey keys/$w.json)
    ata=$(spl address --token "$mint" --owner "$owner" --verbose | sed -n 's/^Associated token address: //p')
    spl balance --address "$ata" >/dev/null 2>&1 ||
        spl create-account "$mint" --owner "$owner" --fee-payer keys/treasury.json >/dev/null
    json="$json$sep\n    \"$w\": {\"owner\": \"$owner\", \"token_account\": \"$ata\"}"
    sep=,
    [ $w = treasury ] && treasury_ata=$ata
done
printf "$json\n  }\n}\n" > kcn.json

[ "$(spl supply "$mint")" != 0 ] || spl mint "$mint" $SUPPLY "$treasury_ata" >/dev/null

echo "KCN mint $mint, supply $(spl supply "$mint"), treasury $(sol balance "$treasury")"
case $RPC_URL in *devnet*) echo "https://explorer.solana.com/address/$mint?cluster=devnet" ;; esac
