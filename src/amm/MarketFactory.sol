// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Market} from "./Market.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";

/**
 * @title MarketFactory
 * @notice Deploy & index markets; own the control-plane (pause, cutoff), and be the only party allowed to wire the Resolver authorized to settle.
 */
contract MarketFactory is IMarketFactory, Ownable, ReentrancyGuard, Pausable {
    /// @notice Current market ID counter
    uint256 public marketIdCounter;
    
    /// @notice Fee in basis points (1.5% = 150 bps)
    uint16 public feeBps = 150;
    
    /// @notice Treasury address for fee collection
    address public treasury;
    
    /// @notice Resolver authorized to settle markets
    address public resolver;
    
    /// @notice Mapping of market ID to market address
    mapping(uint256 => address) public markets;
    
    /// @notice Mapping of song ID to market address
    mapping(uint256 => address) public marketOfSong;
    
    /// @notice Mapping of allowed quote tokens
    mapping(address => bool) public allowedQuoteTokens;
    
    /// @notice Market status enumeration
    enum MarketStatus { OPEN, PENDING_RESOLVE, COMMITTED, FINALIZED }
    
    /// @notice Mapping of market ID to status
    mapping(uint256 => MarketStatus) public marketStatus;

    /// @notice Emitted when a new market is created
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

    /// @notice Emitted when market status changes
    event MarketStatusChanged(uint256 indexed marketId, MarketStatus status);
    
    /// @notice Emitted when treasury is set
    event TreasurySet(address indexed newTreasury);
    
    /// @notice Emitted when fee basis points are set
    event FeeBpsSet(uint16 oldBps, uint16 newBps);
    
    /// @notice Emitted when resolver is set
    event ResolverSet(address indexed newResolver);
    
    /// @notice Emitted when quote token allowance is changed
    event QuoteTokenAllowanceChanged(address indexed token, bool allowed);

    /// @notice Invalid cutoff time
    error ErrInvalidCutoff();
    
    /// @notice Quote token not allowed
    error ErrQuoteTokenNotAllowed();
    
    /// @notice Market not found
    error ErrMarketNotFound();
    
    /// @notice Treasury cannot be zero address
    error ErrZeroTreasury();
    
    /// @notice Song already has market
    error ErrSongHasMarket();

    constructor(address _treasury, address _initialOwner) Ownable(_initialOwner) {
        if (_treasury == address(0)) revert ErrZeroTreasury();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /**
     * @notice Create a new prediction market for a song
     * @param songId The unique song identifier
     * @param t0Rank The initial rank of the song at t0
     * @param cutoffUtc The cutoff timestamp for trading
     * @param quoteToken The quote token address (USDT/FDUSD)
     * @return market The address of the created market
     */
    function createMarket(
        uint256 songId,
        uint16 t0Rank,
        uint64 cutoffUtc,
        address quoteToken
    ) external override nonReentrant whenNotPaused returns (address market) {
        if (cutoffUtc <= block.timestamp) revert ErrInvalidCutoff();
        if (!allowedQuoteTokens[quoteToken]) revert ErrQuoteTokenNotAllowed();
        if (marketOfSong[songId] != address(0)) revert ErrSongHasMarket();

        uint256 marketId = ++marketIdCounter;
        
        // Deploy new market
        Market newMarket = new Market(
            songId,
            t0Rank,
            cutoffUtc,
            quoteToken,
            address(this),
            resolver,
            treasury,
            feeBps
        );
        
        market = address(newMarket);
        markets[marketId] = market;
        marketOfSong[songId] = market;
        marketStatus[marketId] = MarketStatus.OPEN;

        emit MarketCreated(
            marketId,
            market,
            address(newMarket.yesToken()),
            address(newMarket.noToken()),
            quoteToken,
            songId,
            t0Rank,
            cutoffUtc
        );
        
        emit MarketStatusChanged(marketId, MarketStatus.OPEN);
    }

    /**
     * @notice Set the resolver address
     * @param _resolver The new resolver address
     */
    function setResolver(address _resolver) external override onlyOwner {
        resolver = _resolver;
        emit ResolverSet(_resolver);
    }

    /**
     * @notice Pause a specific market
     * @param marketId The market ID to pause
     */
    function pauseMarket(uint256 marketId) external override onlyOwner {
        address market = markets[marketId];
        if (market == address(0)) revert ErrMarketNotFound();
        
        Market(market).pause();
        marketStatus[marketId] = MarketStatus.PENDING_RESOLVE;
        emit MarketStatusChanged(marketId, MarketStatus.PENDING_RESOLVE);
    }

    /**
     * @notice Unpause a specific market
     * @param marketId The market ID to unpause
     */
    function unpauseMarket(uint256 marketId) external override onlyOwner {
        address market = markets[marketId];
        if (market == address(0)) revert ErrMarketNotFound();
        
        Market(market).unpause();
        marketStatus[marketId] = MarketStatus.OPEN;
        emit MarketStatusChanged(marketId, MarketStatus.OPEN);
    }

    /**
     * @notice Set the fee basis points
     * @param newFeeBps The new fee in basis points
     */
    function setFeeBps(uint16 newFeeBps) external override onlyOwner {
        uint16 oldBps = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsSet(oldBps, newFeeBps);
    }

    /**
     * @notice Set treasury address
     * @param _treasury The new treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ErrZeroTreasury();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /**
     * @notice Allow or disallow a quote token
     * @param token The quote token address
     * @param allowed Whether the token is allowed
     */
    function allowQuoteToken(address token, bool allowed) external override onlyOwner {
        allowedQuoteTokens[token] = allowed;
        emit QuoteTokenAllowanceChanged(token, allowed);
    }

    /**
     * @notice Get market address by market ID
     * @param marketId The market ID
     * @return The market address
     */
    function getMarket(uint256 marketId) external view override returns (address) {
        return markets[marketId];
    }

    /**
     * @notice Pause all factory operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause all factory operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}