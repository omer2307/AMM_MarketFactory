// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../src/amm/MarketFactory.sol";
import {Market} from "../src/amm/Market.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {YesToken} from "../src/tokens/YesToken.sol";
import {NoToken} from "../src/tokens/NoToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) external view override returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) external view override returns (uint256) { return _allowances[owner][spender]; }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        require(_balances[from] >= amount, "ERC20: transfer amount exceeds balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0) && spender != address(0), "ERC20: zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

contract RedemptionTest is Test {
    MarketFactory public factory;
    Market public market;
    MockERC20 public usdt;
    YesToken public yesToken;
    NoToken public noToken;
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public resolver = address(0x3);
    address public alice = address(0x4);
    address public bob = address(0x5);
    address public charlie = address(0x6);
    
    uint256 public constant SONG_ID = 12345;
    uint16 public constant T0_RANK = 100;
    uint64 public cutoffUtc;

    function setUp() public {
        usdt = new MockERC20("Mock USDT", "USDT", 6);
        cutoffUtc = uint64(block.timestamp + 1 hours);
        
        vm.prank(owner);
        factory = new MarketFactory(treasury, owner);
        
        vm.startPrank(owner);
        factory.setResolver(resolver);
        factory.allowQuoteToken(address(usdt), true);
        vm.stopPrank();
        
        address marketAddr = factory.createMarket(SONG_ID, T0_RANK, cutoffUtc, address(usdt));
        market = Market(marketAddr);
        yesToken = YesToken(market.yesToken());
        noToken = NoToken(market.noToken());
        
        // Mint USDT to users
        usdt.mint(alice, 1000000 * 1e6);
        usdt.mint(bob, 1000000 * 1e6);
        usdt.mint(charlie, 1000000 * 1e6);
        
        // Approve market
        vm.prank(alice);
        usdt.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdt.approve(address(market), type(uint256).max);
        vm.prank(charlie);
        usdt.approve(address(market), type(uint256).max);
    }

    function test_FullRedemptionScenarioYesWins() public {
        // Alice adds initial liquidity
        uint256 liquidityAmount = 100000 * 1e6; // 100k USDT
        vm.prank(alice);
        market.addLiquidity(liquidityAmount, 0);
        
        // Bob buys YES tokens
        uint256 bobBuyAmount = 10000 * 1e6; // 10k USDT
        vm.prank(bob);
        market.swapQuoteForYes(bobBuyAmount, 0);
        
        // Charlie buys NO tokens
        uint256 charlieBuyAmount = 5000 * 1e6; // 5k USDT
        vm.prank(charlie);
        market.swapQuoteForNo(charlieBuyAmount, 0);
        
        // Record balances before resolution
        uint256 bobYesBalance = yesToken.balanceOf(bob);
        uint256 charlieNoBalance = noToken.balanceOf(charlie);
        uint256 totalYesSupply = yesToken.totalSupply();
        uint256 totalNoSupply = noToken.totalSupply();
        uint256 vaultBalance = market.quoteVault();
        
        console.log("Bob YES balance:", bobYesBalance);
        console.log("Charlie NO balance:", charlieNoBalance);
        console.log("Total YES supply:", totalYesSupply);
        console.log("Total NO supply:", totalNoSupply);
        console.log("Vault balance:", vaultBalance);
        
        // Resolve market with YES winning
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50); // Rank improved to 50
        
        // Bob redeems his YES tokens
        uint256 bobUsdtBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        market.redeem(bob);
        uint256 bobUsdtAfter = usdt.balanceOf(bob);
        uint256 bobPayout = bobUsdtAfter - bobUsdtBefore;
        
        // Charlie tries to redeem NO tokens (should get nothing since NO lost)
        uint256 charlieUsdtBefore = usdt.balanceOf(charlie);
        vm.prank(charlie);
        market.redeem(charlie);
        uint256 charlieUsdtAfter = usdt.balanceOf(charlie);
        uint256 charliePayout = charlieUsdtAfter - charlieUsdtBefore;
        
        // Verify payouts
        uint256 expectedBobPayout = (bobYesBalance * vaultBalance) / totalYesSupply;
        assertEq(bobPayout, expectedBobPayout);
        assertEq(charliePayout, 0); // NO holders get nothing when YES wins
        
        // Verify tokens were burned
        assertEq(yesToken.balanceOf(bob), 0);
        assertEq(noToken.balanceOf(charlie), charlieNoBalance); // NO tokens not burned since NO lost
        
        // Verify redemption tracking
        assertTrue(market.hasRedeemed(bob));
        assertTrue(market.hasRedeemed(charlie));
        
        console.log("Bob payout:", bobPayout);
        console.log("Expected Bob payout:", expectedBobPayout);
        console.log("Charlie payout:", charliePayout);
    }

    function test_FullRedemptionScenarioNoWins() public {
        // Alice adds initial liquidity
        vm.prank(alice);
        market.addLiquidity(100000 * 1e6, 0);
        
        // Bob buys YES tokens
        vm.prank(bob);
        market.swapQuoteForYes(10000 * 1e6, 0);
        
        // Charlie buys NO tokens
        vm.prank(charlie);
        market.swapQuoteForNo(5000 * 1e6, 0);
        
        uint256 bobYesBalance = yesToken.balanceOf(bob);
        uint256 charlieNoBalance = noToken.balanceOf(charlie);
        uint256 totalNoSupply = noToken.totalSupply();
        uint256 vaultBalance = market.quoteVault();
        
        // Resolve market with NO winning
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.NO, T0_RANK, 150); // Rank declined to 150
        
        // Bob tries to redeem YES tokens (should get nothing)
        uint256 bobUsdtBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        market.redeem(bob);
        uint256 bobPayout = usdt.balanceOf(bob) - bobUsdtBefore;
        
        // Charlie redeems NO tokens
        uint256 charlieUsdtBefore = usdt.balanceOf(charlie);
        vm.prank(charlie);
        market.redeem(charlie);
        uint256 charliePayout = usdt.balanceOf(charlie) - charlieUsdtBefore;
        
        // Verify payouts
        assertEq(bobPayout, 0); // YES holders get nothing when NO wins
        uint256 expectedCharliePayout = (charlieNoBalance * vaultBalance) / totalNoSupply;
        assertEq(charliePayout, expectedCharliePayout);
        
        // Verify tokens
        assertEq(yesToken.balanceOf(bob), bobYesBalance); // YES tokens not burned since YES lost
        assertEq(noToken.balanceOf(charlie), 0); // NO tokens burned
    }

    function test_MultipleRedemptions() public {
        // Multiple users buy YES tokens
        address[] memory yesHolders = new address[](3);
        yesHolders[0] = alice;
        yesHolders[1] = bob;
        yesHolders[2] = charlie;
        
        uint256[] memory buyAmounts = new uint256[](3);
        buyAmounts[0] = 5000 * 1e6;
        buyAmounts[1] = 10000 * 1e6;
        buyAmounts[2] = 3000 * 1e6;
        
        // Add initial liquidity
        vm.prank(alice);
        market.addLiquidity(50000 * 1e6, 0);
        
        // Users buy YES tokens
        for (uint256 i = 0; i < yesHolders.length; i++) {
            vm.prank(yesHolders[i]);
            market.swapQuoteForYes(buyAmounts[i], 0);
        }
        
        uint256 vaultBalance = market.quoteVault();
        uint256 totalYesSupply = yesToken.totalSupply();
        
        // Resolve YES winning
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
        
        uint256 totalPayouts = 0;
        
        // Each user redeems
        for (uint256 i = 0; i < yesHolders.length; i++) {
            uint256 yesBalance = yesToken.balanceOf(yesHolders[i]);
            uint256 usdtBefore = usdt.balanceOf(yesHolders[i]);
            
            vm.prank(yesHolders[i]);
            market.redeem(yesHolders[i]);
            
            uint256 payout = usdt.balanceOf(yesHolders[i]) - usdtBefore;
            uint256 expectedPayout = (yesBalance * vaultBalance) / totalYesSupply;
            
            assertEq(payout, expectedPayout);
            assertEq(yesToken.balanceOf(yesHolders[i]), 0);
            assertTrue(market.hasRedeemed(yesHolders[i]));
            
            totalPayouts += payout;
        }
        
        // Total payouts should equal vault balance
        assertEq(totalPayouts, vaultBalance);
        assertEq(market.quoteVault(), 0);
    }

    function test_PartialRedemption() public {
        // Setup scenario where user has tokens but doesn't hold all supply
        vm.prank(alice);
        market.addLiquidity(100000 * 1e6, 0);
        
        // Bob buys some YES
        vm.prank(bob);
        market.swapQuoteForYes(10000 * 1e6, 0);
        
        // Charlie also buys YES
        vm.prank(charlie);
        market.swapQuoteForYes(5000 * 1e6, 0);
        
        uint256 bobYesBalance = yesToken.balanceOf(bob);
        uint256 totalYesSupply = yesToken.totalSupply();
        uint256 vaultBalance = market.quoteVault();
        
        // Resolve YES winning
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
        
        // Only Bob redeems
        uint256 bobUsdtBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        market.redeem(bob);
        uint256 bobPayout = usdt.balanceOf(bob) - bobUsdtBefore;
        
        // Check Bob got his proportional share
        uint256 expectedPayout = (bobYesBalance * vaultBalance) / totalYesSupply;
        assertEq(bobPayout, expectedPayout);
        
        // Vault should be reduced by Bob's payout
        assertEq(market.quoteVault(), vaultBalance - bobPayout);
        
        // Charlie can still redeem later
        uint256 charlieYesBalance = yesToken.balanceOf(charlie);
        uint256 newVaultBalance = market.quoteVault();
        uint256 newTotalYesSupply = yesToken.totalSupply();
        
        uint256 charlieUsdtBefore = usdt.balanceOf(charlie);
        vm.prank(charlie);
        market.redeem(charlie);
        uint256 charliePayout = usdt.balanceOf(charlie) - charlieUsdtBefore;
        
        uint256 expectedCharliePayout = (charlieYesBalance * newVaultBalance) / newTotalYesSupply;
        assertEq(charliePayout, expectedCharliePayout);
    }

    function test_RedemptionWithFees() public {
        // Test that fees are properly accounted for in redemptions
        
        // Alice adds liquidity
        vm.prank(alice);
        market.addLiquidity(50000 * 1e6, 0);
        
        uint256 vaultAfterLiquidity = market.quoteVault();
        
        // Bob makes a trade (generates fees to treasury)
        uint256 tradeAmount = 10000 * 1e6;
        uint256 expectedFee = tradeAmount * 150 / 10000; // 1.5% fee
        
        vm.prank(bob);
        market.swapQuoteForYes(tradeAmount, 0);
        
        uint256 vaultAfterTrade = market.quoteVault();
        uint256 treasuryBalance = usdt.balanceOf(treasury);
        
        // Verify fee went to treasury and effective amount went to vault
        assertEq(treasuryBalance, expectedFee);
        assertEq(vaultAfterTrade, vaultAfterLiquidity + tradeAmount - expectedFee);
        
        // Resolve and redeem
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
        
        uint256 bobYesBalance = yesToken.balanceOf(bob);
        uint256 totalYesSupply = yesToken.totalSupply();
        
        uint256 bobUsdtBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        market.redeem(bob);
        uint256 bobPayout = usdt.balanceOf(bob) - bobUsdtBefore;
        
        // Bob's payout should be based on vault balance (excluding fees)
        uint256 expectedPayout = (bobYesBalance * vaultAfterTrade) / totalYesSupply;
        assertEq(bobPayout, expectedPayout);
        
        // Treasury should still have the fees
        assertEq(usdt.balanceOf(treasury), expectedFee);
    }

    function test_EdgeCaseDustRedemption() public {
        // Test redemption with very small amounts
        
        vm.prank(alice);
        market.addLiquidity(1000 * 1e6, 0); // 1k USDT liquidity
        
        // Bob buys tiny amount
        vm.prank(bob);
        market.swapQuoteForYes(1 * 1e6, 0); // 1 USDT
        
        uint256 bobYesBalance = yesToken.balanceOf(bob);
        assertGt(bobYesBalance, 0);
        
        // Resolve
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
        
        // Redeem tiny amount
        uint256 bobUsdtBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        market.redeem(bob);
        uint256 bobPayout = usdt.balanceOf(bob) - bobUsdtBefore;
        
        // Should get some payout, even if small
        assertGt(bobPayout, 0);
        assertEq(yesToken.balanceOf(bob), 0);
    }
}