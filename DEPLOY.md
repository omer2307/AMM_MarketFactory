# Deploy AMM MarketFactory to BSC Testnet (chainId 97)

## 1) Prepare env locally (DO NOT COMMIT `.env`)
```bash
cp -n .env.example .env || true
# Edit .env with:
# - BSC_RPC_URL
# - DEPLOYER_PRIVATE_KEY (fresh funded testnet key)
# - CHAIN_ID=97
# - BSCSCAN_API_KEY (optional)
```

## 2) Export env & sanity checks
```bash
set -a; source .env; set +a
cast chain-id --rpc-url "$BSC_RPC_URL"          # expect 97
cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY"
cast balance $(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY") --rpc-url "$BSC_RPC_URL"
```

## 3) Build
```bash
forge build
```

## 4) Deploy
```bash
forge script script/Deploy.s.sol \
  --rpc-url "$BSC_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  ${BSCSCAN_API_KEY:+--verify --etherscan-api-key "$BSCSCAN_API_KEY"}
```

## 5) Post-deployment
- Deployed addresses appear in: `broadcast/*/run-latest.json`
- After deploy: transfer ownership/admin to your admin/multisig
- Retire deployer key for security
- Update frontend and infrastructure with new contract addresses