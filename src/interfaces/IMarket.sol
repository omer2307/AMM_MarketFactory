// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IMarket
 * @notice Interface for the Market contract
 */
interface IMarket {
    /// @notice Market status enumeration
    enum MarketStatus { OPEN, PENDING_RESOLVE, COMMITTED, FINALIZED }
    
    /// @notice Outcome enumeration  
    enum Outcome { NONE, YES, NO }

    /**
     * @notice Quote YES tokens out for quote tokens in
     * @param quoteIn Amount of quote tokens to spend
     * @return yesOut Amount of YES tokens to receive
     * @return priceAfter Price after the trade
     */
    function quoteYesOut(uint256 quoteIn) external view returns (uint256 yesOut, uint256 priceAfter);

    /**
     * @notice Quote NO tokens out for quote tokens in
     * @param quoteIn Amount of quote tokens to spend
     * @return noOut Amount of NO tokens to receive
     * @return priceAfter Price after the trade
     */
    function quoteNoOut(uint256 quoteIn) external view returns (uint256 noOut, uint256 priceAfter);

    /**
     * @notice Swap quote tokens for YES tokens
     * @param quoteIn Amount of quote tokens to spend
     * @param minYesOut Minimum YES tokens to receive
     */
    function swapQuoteForYes(uint256 quoteIn, uint256 minYesOut) external;

    /**
     * @notice Swap quote tokens for NO tokens
     * @param quoteIn Amount of quote tokens to spend
     * @param minNoOut Minimum NO tokens to receive
     */
    function swapQuoteForNo(uint256 quoteIn, uint256 minNoOut) external;

    /**
     * @notice Add liquidity to the pool
     * @param quoteIn Amount of quote tokens to add
     * @param minSharesOut Minimum LP shares to receive
     */
    function addLiquidity(uint256 quoteIn, uint256 minSharesOut) external;

    /**
     * @notice Remove liquidity from the pool
     * @param sharesIn Amount of LP shares to burn
     * @param minQuoteOut Minimum quote tokens to receive
     */
    function removeLiquidity(uint256 sharesIn, uint256 minQuoteOut) external;

    /**
     * @notice Set market status (factory only)
     * @param status The new market status
     */
    function setStatus(MarketStatus status) external;

    /**
     * @notice Apply outcome and finalize market (resolver only)
     * @param _outcome The final outcome
     * @param _t0Rank Initial rank (for verification)
     * @param _t1Rank Final rank
     */
    function applyOutcome(Outcome _outcome, uint16 _t0Rank, uint16 _t1Rank) external;

    /**
     * @notice Redeem winning tokens for quote tokens
     * @param to Address to send quote tokens to
     */
    function redeem(address to) external;
}