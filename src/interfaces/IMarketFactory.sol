// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IMarketFactory
 * @notice Interface for the MarketFactory contract
 */
interface IMarketFactory {
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
    ) external returns (address market);

    /**
     * @notice Set the resolver address
     * @param resolver The new resolver address
     */
    function setResolver(address resolver) external;

    /**
     * @notice Pause a specific market
     * @param marketId The market ID to pause
     */
    function pauseMarket(uint256 marketId) external;

    /**
     * @notice Unpause a specific market
     * @param marketId The market ID to unpause
     */
    function unpauseMarket(uint256 marketId) external;

    /**
     * @notice Set the fee basis points
     * @param newFeeBps The new fee in basis points
     */
    function setFeeBps(uint16 newFeeBps) external;

    /**
     * @notice Allow or disallow a quote token
     * @param token The quote token address
     * @param allowed Whether the token is allowed
     */
    function allowQuoteToken(address token, bool allowed) external;

    /**
     * @notice Get market address by market ID
     * @param marketId The market ID
     * @return The market address
     */
    function getMarket(uint256 marketId) external view returns (address);

    /**
     * @notice Get market address by song ID
     * @param songId The song ID
     * @return The market address
     */
    function marketOfSong(uint256 songId) external view returns (address);
}