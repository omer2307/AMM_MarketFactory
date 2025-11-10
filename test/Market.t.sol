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

contract MarketTest is Test {
    MarketFactory public factory;
    Market public market;
    MockERC20 public usdt;
    YesToken public yesToken;
    NoToken public noToken;
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public resolver = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    
    uint256 public constant SONG_ID = 12345;
    uint16 public constant T0_RANK = 100;
    uint64 public cutoffUtc;
    uint256 public constant INITIAL_BALANCE = 1000000 * 1e6; // 1M USDT

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
        usdt.mint(user1, INITIAL_BALANCE);
        usdt.mint(user2, INITIAL_BALANCE);
        
        // Approve market to spend USDT
        vm.prank(user1);
        usdt.approve(address(market), type(uint256).max);
        vm.prank(user2);
        usdt.approve(address(market), type(uint256).max);
    }

    function test_MarketInitialization() public {
        assertEq(market.songId(), SONG_ID);
        assertEq(market.t0Rank(), T0_RANK);
        assertEq(market.cutoffUtc(), cutoffUtc);
        assertEq(market.quoteToken(), address(usdt));
        assertEq(market.factory(), address(factory));
        assertEq(market.resolver(), resolver);
        assertEq(market.treasury(), treasury);
        assertEq(market.feeBps(), 150);
        
        // Check initial reserves
        (uint256 yesReserve, uint256 noReserve) = market.reserves();
        assertEq(yesReserve, 1000 * 1e18);
        assertEq(noReserve, 1000 * 1e18);
        
        // Check tokens
        assertEq(yesToken.name(), "Song 12345 YES");
        assertEq(yesToken.symbol(), "HYES-12345");
        assertEq(noToken.name(), "Song 12345 NO");
        assertEq(noToken.symbol(), "HNO-12345");
    }

    function test_QuoteYesOut() public {
        uint256 quoteIn = 1000 * 1e6; // 1000 USDT
        (uint256 yesOut, uint256 priceAfter) = market.quoteYesOut(quoteIn);
        
        assertGt(yesOut, 0);
        assertGt(priceAfter, 0);
        assertLt(priceAfter, 1e18); // Price should be less than 1 (buying YES should increase YES price)
    }

    function test_QuoteNoOut() public {
        uint256 quoteIn = 1000 * 1e6; // 1000 USDT
        (uint256 noOut, uint256 priceAfter) = market.quoteNoOut(quoteIn);
        
        assertGt(noOut, 0);
        assertGt(priceAfter, 0);
        assertGt(priceAfter, 1e18 / 2); // Price should be greater than 0.5 (buying NO should decrease YES price)
    }

    function test_SwapQuoteForYes() public {
        uint256 quoteIn = 1000 * 1e6; // 1000 USDT
        (uint256 expectedYesOut,) = market.quoteYesOut(quoteIn);
        
        uint256 userUsdtBefore = usdt.balanceOf(user1);
        uint256 treasuryUsdtBefore = usdt.balanceOf(treasury);
        
        vm.prank(user1);
        market.swapQuoteForYes(quoteIn, expectedYesOut);
        
        uint256 userUsdtAfter = usdt.balanceOf(user1);
        uint256 treasuryUsdtAfter = usdt.balanceOf(treasury);
        uint256 userYesBalance = yesToken.balanceOf(user1);
        
        // Check USDT balances
        assertEq(userUsdtBefore - userUsdtAfter, quoteIn);
        uint256 expectedFee = quoteIn * 150 / 10000;
        assertEq(treasuryUsdtAfter - treasuryUsdtBefore, expectedFee);
        
        // Check YES tokens received
        assertEq(userYesBalance, expectedYesOut);
        
        // Check vault updated
        assertGt(market.quoteVault(), 0);
    }

    function test_SwapQuoteForNo() public {
        uint256 quoteIn = 1000 * 1e6; // 1000 USDT
        (uint256 expectedNoOut,) = market.quoteNoOut(quoteIn);
        
        uint256 userUsdtBefore = usdt.balanceOf(user1);
        uint256 treasuryUsdtBefore = usdt.balanceOf(treasury);
        
        vm.prank(user1);
        market.swapQuoteForNo(quoteIn, expectedNoOut);
        
        uint256 userUsdtAfter = usdt.balanceOf(user1);
        uint256 treasuryUsdtAfter = usdt.balanceOf(treasury);
        uint256 userNoBalance = noToken.balanceOf(user1);
        
        // Check USDT balances
        assertEq(userUsdtBefore - userUsdtAfter, quoteIn);
        uint256 expectedFee = quoteIn * 150 / 10000;
        assertEq(treasuryUsdtAfter - treasuryUsdtBefore, expectedFee);
        
        // Check NO tokens received
        assertEq(userNoBalance, expectedNoOut);
    }

    function test_RevertSwapSlippage() public {
        uint256 quoteIn = 1000 * 1e6;
        (uint256 expectedYesOut,) = market.quoteYesOut(quoteIn);
        
        vm.prank(user1);
        vm.expectRevert(Market.ErrSlippage.selector);
        market.swapQuoteForYes(quoteIn, expectedYesOut + 1);
    }

    function test_RevertSwapTradingClosed() public {
        // Move time past cutoff
        vm.warp(cutoffUtc + 1);
        
        vm.prank(user1);
        vm.expectRevert(Market.ErrTradingClosed.selector);
        market.swapQuoteForYes(1000 * 1e6, 0);
    }

    function test_AddLiquidity() public {
        uint256 quoteIn = 10000 * 1e6; // 10k USDT
        
        uint256 userUsdtBefore = usdt.balanceOf(user1);
        
        vm.prank(user1);
        market.addLiquidity(quoteIn, 0);
        
        uint256 userUsdtAfter = usdt.balanceOf(user1);
        uint256 userShares = market.sharesOf(user1);
        uint256 totalShares = market.totalShares();
        
        assertEq(userUsdtBefore - userUsdtAfter, quoteIn);
        assertEq(userShares, quoteIn); // First LP gets 1:1 shares
        assertEq(totalShares, quoteIn);
        assertEq(market.quoteVault(), quoteIn);
    }

    function test_RemoveLiquidity() public {
        uint256 quoteIn = 10000 * 1e6;
        
        // Add liquidity first
        vm.prank(user1);
        market.addLiquidity(quoteIn, 0);
        
        uint256 sharesToRemove = market.sharesOf(user1) / 2;
        uint256 userUsdtBefore = usdt.balanceOf(user1);
        
        vm.prank(user1);
        market.removeLiquidity(sharesToRemove, 0);
        
        uint256 userUsdtAfter = usdt.balanceOf(user1);
        uint256 userSharesAfter = market.sharesOf(user1);
        
        assertEq(userUsdtAfter - userUsdtBefore, quoteIn / 2);
        assertEq(userSharesAfter, quoteIn / 2);
    }

    function test_ApplyOutcome() public {
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
        
        assertEq(uint256(market.outcome()), uint256(IMarket.Outcome.YES));
        assertEq(uint256(market.status()), uint256(IMarket.MarketStatus.FINALIZED));
    }

    function test_RevertApplyOutcomeUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert(Market.ErrUnauthorized.selector);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
    }

    function test_RevertApplyOutcomeInvalidRank() public {
        vm.prank(resolver);
        vm.expectRevert(Market.ErrInvalidState.selector);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK + 1, 50);
    }

    function test_RedemptionYesWins() public {
        // Add liquidity
        vm.prank(user1);
        market.addLiquidity(10000 * 1e6, 0);
        
        // User2 buys YES tokens
        uint256 quoteIn = 1000 * 1e6;
        vm.prank(user2);
        market.swapQuoteForYes(quoteIn, 0);
        
        uint256 yesBalance = yesToken.balanceOf(user2);
        uint256 vaultBefore = market.quoteVault();
        
        // Apply YES outcome
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
        
        // Redeem
        uint256 userUsdtBefore = usdt.balanceOf(user2);
        vm.prank(user2);
        market.redeem(user2);
        
        uint256 userUsdtAfter = usdt.balanceOf(user2);
        uint256 payout = userUsdtAfter - userUsdtBefore;
        
        // Check payout calculation
        uint256 totalYesSupply = yesBalance; // Only user2 has YES tokens
        uint256 expectedPayout = (yesBalance * vaultBefore) / totalYesSupply;
        assertEq(payout, expectedPayout);
        
        // Check tokens burned
        assertEq(yesToken.balanceOf(user2), 0);
        assertTrue(market.hasRedeemed(user2));
    }

    function test_RedemptionNoWins() public {
        // Add liquidity
        vm.prank(user1);
        market.addLiquidity(10000 * 1e6, 0);
        
        // User2 buys NO tokens
        uint256 quoteIn = 1000 * 1e6;
        vm.prank(user2);
        market.swapQuoteForNo(quoteIn, 0);
        
        uint256 noBalance = noToken.balanceOf(user2);
        uint256 vaultBefore = market.quoteVault();
        
        // Apply NO outcome
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.NO, T0_RANK, 150);
        
        // Redeem
        uint256 userUsdtBefore = usdt.balanceOf(user2);
        vm.prank(user2);
        market.redeem(user2);
        
        uint256 userUsdtAfter = usdt.balanceOf(user2);
        uint256 payout = userUsdtAfter - userUsdtBefore;
        
        // Check payout calculation
        uint256 totalNoSupply = noBalance; // Only user2 has NO tokens
        uint256 expectedPayout = (noBalance * vaultBefore) / totalNoSupply;
        assertEq(payout, expectedPayout);
        
        // Check tokens burned
        assertEq(noToken.balanceOf(user2), 0);
        assertTrue(market.hasRedeemed(user2));
    }

    function test_RevertRedeemAlreadyRedeemed() public {
        // Setup and redeem once
        vm.prank(user1);
        market.addLiquidity(10000 * 1e6, 0);
        
        vm.prank(user2);
        market.swapQuoteForYes(1000 * 1e6, 0);
        
        vm.prank(resolver);
        market.applyOutcome(IMarket.Outcome.YES, T0_RANK, 50);
        
        vm.prank(user2);
        market.redeem(user2);
        
        // Try to redeem again
        vm.prank(user2);
        vm.expectRevert(Market.ErrAlreadyRedeemed.selector);
        market.redeem(user2);
    }

    function test_RevertRedeemNotFinalized() public {
        vm.prank(user1);
        vm.expectRevert(Market.ErrInvalidState.selector);
        market.redeem(user1);
    }

    function test_InvariantConstantProduct() public {
        // Initial reserves
        (uint256 yesReserve, uint256 noReserve) = market.reserves();
        uint256 initialK = yesReserve * noReserve;
        
        // Make a trade
        vm.prank(user1);
        market.swapQuoteForYes(1000 * 1e6, 0);
        
        // Check invariant
        (uint256 newYesReserve, uint256 newNoReserve) = market.reserves();
        uint256 newK = newYesReserve * newNoReserve;
        
        // K should be greater than or equal to initial (fees increase it)
        assertGe(newK, initialK);
    }

    function test_GasUsage() public {
        uint256 gasStart = gasleft();
        
        vm.prank(user1);
        market.swapQuoteForYes(100 * 1e6, 0); // 100 USDT
        
        uint256 gasUsed = gasStart - gasleft();
        console.log("Gas used for swap:", gasUsed);
        
        // Should be reasonable for BSC (target < 200k gas)
        assertLt(gasUsed, 200000);
    }
}