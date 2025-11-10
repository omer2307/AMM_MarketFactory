// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../src/amm/MarketFactory.sol";
import {Market} from "../src/amm/Market.sol";
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

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
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
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(_balances[from] >= amount, "ERC20: transfer amount exceeds balance");
        
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

contract FactoryTest is Test {
    MarketFactory public factory;
    MockERC20 public usdt;
    MockERC20 public fdusd;
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public resolver = address(0x3);
    address public user = address(0x4);
    
    uint256 public constant SONG_ID = 12345;
    uint16 public constant T0_RANK = 100;
    uint64 public cutoffUtc;

    event MarketCreated(
        uint256 indexed marketId,
        address indexed market,
        address yesToken,
        address noToken,
        address quoteToken,
        uint256 songId,
        uint16 t0Rank,
        uint64 cutoffUtc
    );

    function setUp() public {
        // Deploy mock tokens
        usdt = new MockERC20("Mock USDT", "USDT", 6);
        fdusd = new MockERC20("Mock FDUSD", "FDUSD", 18);
        
        // Set cutoff to 1 hour from now
        cutoffUtc = uint64(block.timestamp + 1 hours);
        
        // Deploy factory as owner
        vm.prank(owner);
        factory = new MarketFactory(treasury, owner);
        
        // Set resolver
        vm.prank(owner);
        factory.setResolver(resolver);
        
        // Allow quote tokens
        vm.startPrank(owner);
        factory.allowQuoteToken(address(usdt), true);
        factory.allowQuoteToken(address(fdusd), true);
        vm.stopPrank();
    }

    function test_FactoryDeployment() public {
        assertEq(factory.owner(), owner);
        assertEq(factory.treasury(), treasury);
        assertEq(factory.resolver(), resolver);
        assertEq(factory.feeBps(), 150);
        assertEq(factory.marketIdCounter(), 0);
        assertTrue(factory.allowedQuoteTokens(address(usdt)));
        assertTrue(factory.allowedQuoteTokens(address(fdusd)));
    }

    function test_CreateMarket() public {
        address market = factory.createMarket(SONG_ID, T0_RANK, cutoffUtc, address(usdt));
        
        assertEq(factory.marketIdCounter(), 1);
        assertEq(factory.getMarket(1), market);
        assertEq(factory.marketOfSong(SONG_ID), market);
        
        // Verify market properties
        Market marketContract = Market(market);
        assertEq(marketContract.songId(), SONG_ID);
        assertEq(marketContract.t0Rank(), T0_RANK);
        assertEq(marketContract.cutoffUtc(), cutoffUtc);
        assertEq(marketContract.quoteToken(), address(usdt));
        assertEq(marketContract.factory(), address(factory));
        assertEq(marketContract.resolver(), resolver);
    }

    function test_RevertCreateMarketInvalidCutoff() public {
        uint64 pastCutoff = uint64(block.timestamp - 1);
        
        vm.expectRevert(MarketFactory.ErrInvalidCutoff.selector);
        factory.createMarket(SONG_ID, T0_RANK, pastCutoff, address(usdt));
    }

    function test_RevertCreateMarketQuoteTokenNotAllowed() public {
        MockERC20 unauthorizedToken = new MockERC20("Bad Token", "BAD", 18);
        
        vm.expectRevert(MarketFactory.ErrQuoteTokenNotAllowed.selector);
        factory.createMarket(SONG_ID, T0_RANK, cutoffUtc, address(unauthorizedToken));
    }

    function test_RevertCreateMarketSongHasMarket() public {
        // Create first market
        factory.createMarket(SONG_ID, T0_RANK, cutoffUtc, address(usdt));
        
        // Try to create second market for same song
        vm.expectRevert(MarketFactory.ErrSongHasMarket.selector);
        factory.createMarket(SONG_ID, T0_RANK + 1, cutoffUtc + 1, address(usdt));
    }

    function test_SetResolver() public {
        address newResolver = address(0x5);
        
        vm.prank(owner);
        factory.setResolver(newResolver);
        
        assertEq(factory.resolver(), newResolver);
    }

    function test_RevertSetResolverNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        factory.setResolver(address(0x5));
    }

    function test_PauseUnpauseMarket() public {
        address market = factory.createMarket(SONG_ID, T0_RANK, cutoffUtc, address(usdt));
        
        // Pause market
        vm.prank(owner);
        factory.pauseMarket(1);
        
        assertTrue(Market(market).paused());
        
        // Unpause market
        vm.prank(owner);
        factory.unpauseMarket(1);
        
        assertFalse(Market(market).paused());
    }

    function test_RevertPauseMarketNotFound() public {
        vm.prank(owner);
        vm.expectRevert(MarketFactory.ErrMarketNotFound.selector);
        factory.pauseMarket(999);
    }

    function test_SetFeeBps() public {
        uint16 newFeeBps = 200;
        
        vm.prank(owner);
        factory.setFeeBps(newFeeBps);
        
        assertEq(factory.feeBps(), newFeeBps);
    }

    function test_SetTreasury() public {
        address newTreasury = address(0x6);
        
        vm.prank(owner);
        factory.setTreasury(newTreasury);
        
        assertEq(factory.treasury(), newTreasury);
    }

    function test_RevertSetTreasuryZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MarketFactory.ErrZeroTreasury.selector);
        factory.setTreasury(address(0));
    }

    function test_AllowQuoteToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        
        assertFalse(factory.allowedQuoteTokens(address(newToken)));
        
        vm.prank(owner);
        factory.allowQuoteToken(address(newToken), true);
        
        assertTrue(factory.allowedQuoteTokens(address(newToken)));
        
        vm.prank(owner);
        factory.allowQuoteToken(address(newToken), false);
        
        assertFalse(factory.allowedQuoteTokens(address(newToken)));
    }

    function test_PauseUnpauseFactory() public {
        vm.prank(owner);
        factory.pause();
        
        assertTrue(factory.paused());
        
        vm.expectRevert();
        factory.createMarket(SONG_ID, T0_RANK, cutoffUtc, address(usdt));
        
        vm.prank(owner);
        factory.unpause();
        
        assertFalse(factory.paused());
        
        // Should work now
        factory.createMarket(SONG_ID, T0_RANK, cutoffUtc, address(usdt));
    }

    function test_MultipleMarkets() public {
        uint256 songId1 = 111;
        uint256 songId2 = 222;
        
        address market1 = factory.createMarket(songId1, T0_RANK, cutoffUtc, address(usdt));
        address market2 = factory.createMarket(songId2, T0_RANK + 1, cutoffUtc + 1, address(fdusd));
        
        assertEq(factory.marketIdCounter(), 2);
        assertEq(factory.getMarket(1), market1);
        assertEq(factory.getMarket(2), market2);
        assertEq(factory.marketOfSong(songId1), market1);
        assertEq(factory.marketOfSong(songId2), market2);
        
        assertEq(Market(market1).quoteToken(), address(usdt));
        assertEq(Market(market2).quoteToken(), address(fdusd));
    }
}