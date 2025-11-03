# Hitcastor AMM Market Factory

Binary CPMM (Constant Product Market Maker) smart contracts for Hitcastor's prediction markets on song chart rankings.

## Overview

This repository implements a complete prediction market system for trading YES/NO outcome tokens on song chart performance. Users can:

- **Create Markets**: Deploy new prediction markets for songs with specific cutoff dates
- **Trade**: Buy/sell YES/NO tokens using USDT/FDUSD via CPMM pricing
- **Provide Liquidity**: Add/remove liquidity to earn from trading fees
- **Resolve & Redeem**: Apply outcomes and redeem winning tokens for quote assets

## Architecture

### Core Contracts

#### MarketFactory.sol
- **Purpose**: Central factory for deploying and managing markets
- **Key Features**:
  - Deploy new markets for songs
  - Control market lifecycle (pause/unpause)
  - Manage authorized resolvers and quote tokens
  - Fee configuration and treasury management

#### Market.sol
- **Purpose**: Binary AMM implementing CPMM for YES/NO token trading
- **Key Features**:
  - Constant product market maker with virtual reserves
  - Mints YES/NO tokens on purchase, burns on redemption
  - Liquidity provision with LP tokens
  - Automated market resolution and redemption

#### YesToken.sol / NoToken.sol
- **Purpose**: ERC20 tokens representing binary outcomes
- **Key Features**:
  - Mintable by market contract only
  - Burnable for redemption
  - Standard ERC20 with transfers enabled

## Math & Pricing

### CPMM Formula
The system uses a constant product formula: `R_y × R_n = k`

Where:
- `R_y` = Virtual YES token reserves  
- `R_n` = Virtual NO token reserves
- `k` = Constant product invariant

### Price Calculation
- **YES Price** = `R_n / (R_y + R_n)`
- **NO Price** = `R_y / (R_y + R_n)`
- **Total Price** = YES Price + NO Price = 1.0

### Trading
When buying YES tokens with quote amount `q`:
1. Apply fee: `effective_q = q × (1 - feeBps/10000)`
2. Calculate output: `yesOut = R_n - (k / (R_y + effective_q))`
3. Update reserves: `R_y += effective_q`, `R_n -= yesOut`
4. Mint `yesOut` YES tokens to user
5. Send fee to treasury

## Fee Model

- **Default Fee**: 1.5% (150 basis points) on all trades
- **Fee Collection**: Deducted from input amount and sent to treasury
- **LP Revenue**: LPs earn from the effective trading amount (post-fee) added to vault
- **Configurable**: Factory owner can adjust fee rates

## Settlement Flow

1. **Trading Phase**: Users trade YES/NO tokens until cutoff time
2. **Cutoff**: Trading stops automatically at `cutoffUtc`
3. **Resolution**: Authorized resolver calls `applyOutcome(YES/NO, t0Rank, t1Rank)`
4. **Redemption**: Winning token holders redeem for proportional quote token share

### Redemption Formula
If YES wins: `payout = (userYesBalance × quoteVault) / totalYesSupply`

## Deployment Guide

### Prerequisites
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies  
forge install
```

### Local Testing
```bash
# Run tests
forge test -vvv

# Deploy locally with mock tokens
forge script script/Deploy.s.sol:DeployLocal --fork-url http://localhost:8545 --broadcast

# Run invariant tests
forge test --match-contract Invariant -vvv
```

### BSC Mainnet Deployment
```bash
# Set environment variables
export PRIVATE_KEY="your_private_key"
export BSC_RPC_URL="https://bsc-dataseed.binance.org/"

# Deploy to BSC
forge script script/Deploy.s.sol:Deploy --rpc-url $BSC_RPC_URL --broadcast --verify

# Verify contracts
forge verify-contract <factory_address> src/amm/MarketFactory.sol:MarketFactory --chain 56
```

### Post-Deployment Setup
```solidity
// 1. Set resolver (authorized to resolve markets)
factory.setResolver(resolverAddress);

// 2. Allow quote tokens
factory.allowQuoteToken(0x55d398326f99059fF775485246999027B3197955, true); // USDT BSC
factory.allowQuoteToken(0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409, true); // FDUSD BSC

// 3. Create first market
factory.createMarket(
    songId,           // Unique song identifier
    t0Rank,           // Initial chart rank
    cutoffUtc,        // Trading cutoff timestamp  
    quoteTokenAddress // USDT/FDUSD address
);
```

## Usage Examples

### Creating a Market
```solidity
uint256 songId = 12345;
uint16 initialRank = 100;
uint64 cutoff = block.timestamp + 7 days;
address quoteToken = USDT_ADDRESS;

address market = factory.createMarket(songId, initialRank, cutoff, quoteToken);
```

### Trading YES Tokens
```solidity
Market market = Market(marketAddress);
IERC20 usdt = IERC20(usdtAddress);

// Approve USDT spending
usdt.approve(address(market), amount);

// Get quote for trade
(uint256 yesOut, uint256 priceAfter) = market.quoteYesOut(1000e6); // 1000 USDT

// Execute trade with slippage protection
market.swapQuoteForYes(1000e6, yesOut * 99 / 100); // 1% slippage tolerance
```

### Providing Liquidity
```solidity
// Add liquidity
usdt.approve(address(market), 10000e6);
market.addLiquidity(10000e6, minSharesOut);

// Remove liquidity later
uint256 userShares = market.sharesOf(msg.sender);
market.removeLiquidity(userShares / 2, minQuoteOut); // Remove 50%
```

### Resolution & Redemption
```solidity
// Resolver applies outcome
market.applyOutcome(Market.Outcome.YES, t0Rank, t1Rank);

// Winners redeem tokens
market.redeem(msg.sender); // Burns winning tokens, sends quote tokens
```

## Testing

### Test Coverage
- **Factory Tests**: Market creation, access control, fee management
- **Market Tests**: Trading, liquidity, CPMM mechanics, gas optimization  
- **Redemption Tests**: Multi-user scenarios, edge cases, fee accounting
- **Invariant Tests**: Constant product maintenance, fund conservation

### Running Tests
```bash
# All tests
forge test

# Specific test file
forge test test/Market.t.sol -vvv

# Gas report
forge test --gas-report

# Coverage report
forge coverage
```

## Security Considerations

### Access Control
- **Factory Owner**: Can pause markets, set fees, manage quote tokens
- **Resolver**: Can apply outcomes to finalize markets
- **Market**: Autonomous after deployment, controlled only by factory/resolver

### Safety Features
- **Reentrancy Protection**: All state-changing functions protected
- **Slippage Protection**: Minimum output parameters on trades
- **Cutoff Enforcement**: Trading automatically stops at cutoff time
- **Outcome Finality**: Outcomes can only be set once by authorized resolver

### Potential Risks
- **Resolver Trust**: Market resolution depends on trusted resolver
- **Liquidity Risk**: Low liquidity can cause high slippage
- **Smart Contract Risk**: Standard smart contract vulnerabilities

## Gas Optimization

Target gas costs on BSC:
- **Market Creation**: ~2M gas
- **Token Swap**: <200k gas  
- **Add/Remove Liquidity**: <150k gas
- **Redemption**: <100k gas

## ABI Export

Contract ABIs are available in `out/` directory after compilation:
```bash
# Generate clean ABI files
node scripts/export-abis.js
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `forge test`
5. Submit a pull request

## License

MIT License - see LICENSE file for details.