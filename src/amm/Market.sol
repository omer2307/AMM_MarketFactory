// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {YesToken} from "../tokens/YesToken.sol";
import {NoToken} from "../tokens/NoToken.sol";
import {IMarket} from "../interfaces/IMarket.sol";

/**
 * @title Market
 * @notice Binary AMM with YES/NO tokens and a single quote token. YES/NO are minted on buy, burned on redeem.
 */
contract Market is IMarket, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Market status enumeration
    enum MarketStatus { OPEN, PENDING_RESOLVE, COMMITTED, FINALIZED }
    
    /// @notice Outcome enumeration
    enum Outcome { NONE, YES, NO }

    /// @notice Virtual reserves for CPMM
    struct Reserves {
        uint256 yes;
        uint256 no;
    }

    /// @notice Song ID this market represents
    uint256 public immutable songId;
    
    /// @notice Initial rank at t0
    uint16 public immutable t0Rank;
    
    /// @notice Trading cutoff timestamp
    uint64 public immutable cutoffUtc;
    
    /// @notice Quote token (USDT/FDUSD)
    address public immutable quoteToken;
    
    /// @notice Factory address
    address public immutable factory;
    
    /// @notice Resolver address
    address public immutable resolver;
    
    /// @notice Treasury address
    address public immutable treasury;
    
    /// @notice Fee in basis points
    uint16 public immutable feeBps;
    
    /// @notice YES token contract
    YesToken public immutable yesToken;
    
    /// @notice NO token contract
    NoToken public immutable noToken;
    
    /// @notice Current market status
    MarketStatus public status;
    
    /// @notice Final outcome
    Outcome public outcome;
    
    /// @notice Virtual reserves
    Reserves public reserves;
    
    /// @notice Total LP shares outstanding
    uint256 public totalShares;
    
    /// @notice LP shares per user
    mapping(address => uint256) public sharesOf;
    
    /// @notice Quote token vault balance
    uint256 public quoteVault;
    
    /// @notice User redemption tracking
    mapping(address => bool) public hasRedeemed;

    /// @notice Emitted on token swaps
    event Swap(
        address indexed trader,
        bool buyYes,
        uint256 amountIn,
        uint256 amountOut,
        uint16 feeBps
    );
    
    /// @notice Emitted when liquidity is added
    event LiquidityAdded(
        address indexed provider,
        uint256 quoteIn,
        uint256 sharesOut
    );
    
    /// @notice Emitted when liquidity is removed
    event LiquidityRemoved(
        address indexed provider,
        uint256 sharesIn,
        uint256 quoteOut
    );
    
    /// @notice Emitted when outcome is applied
    event OutcomeApplied(Outcome outcome);
    
    /// @notice Emitted when user redeems tokens
    event Redeemed(address indexed user, uint256 payout);

    /// @notice Trading is closed
    error ErrTradingClosed();
    
    /// @notice Slippage protection triggered
    error ErrSlippage();
    
    /// @notice Insufficient output
    error ErrInsufficientOutput();
    
    /// @notice Unauthorized access
    error ErrUnauthorized();
    
    /// @notice Already finalized
    error ErrAlreadyFinalized();
    
    /// @notice Invalid state
    error ErrInvalidState();
    
    /// @notice Insufficient liquidity
    error ErrInsufficientLiquidity();
    
    /// @notice Already redeemed
    error ErrAlreadyRedeemed();

    constructor(
        uint256 _songId,
        uint16 _t0Rank,
        uint64 _cutoffUtc,
        address _quoteToken,
        address _factory,
        address _resolver,
        address _treasury,
        uint16 _feeBps
    ) {
        songId = _songId;
        t0Rank = _t0Rank;
        cutoffUtc = _cutoffUtc;
        quoteToken = _quoteToken;
        factory = _factory;
        resolver = _resolver;
        treasury = _treasury;
        feeBps = _feeBps;
        
        status = MarketStatus.OPEN;
        outcome = Outcome.NONE;
        
        // Deploy YES/NO tokens
        yesToken = new YesToken(_songId);
        noToken = new NoToken(_songId);
        
        // Initialize reserves with equal amounts for 50/50 price
        reserves = Reserves({
            yes: 1000 * 1e18,
            no: 1000 * 1e18
        });
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert ErrUnauthorized();
        _;
    }

    modifier onlyResolver() {
        if (msg.sender != resolver) revert ErrUnauthorized();
        _;
    }

    modifier tradingOpen() {
        if (status != MarketStatus.OPEN || block.timestamp >= cutoffUtc || paused()) {
            revert ErrTradingClosed();
        }
        _;
    }

    /**
     * @notice Quote YES tokens out for quote tokens in
     * @param quoteIn Amount of quote tokens to spend
     * @return yesOut Amount of YES tokens to receive
     * @return priceAfter Price after the trade
     */
    function quoteYesOut(uint256 quoteIn) external view override returns (uint256 yesOut, uint256 priceAfter) {
        uint256 effectiveInput = quoteIn * (10000 - feeBps) / 10000;
        yesOut = _calculateYesOut(effectiveInput);
        
        uint256 newYesReserve = reserves.yes + yesOut;
        uint256 newNoReserve = reserves.no - yesOut;
        priceAfter = (newNoReserve * 1e18) / (newYesReserve + newNoReserve);
    }

    /**
     * @notice Quote NO tokens out for quote tokens in
     * @param quoteIn Amount of quote tokens to spend
     * @return noOut Amount of NO tokens to receive
     * @return priceAfter Price after the trade
     */
    function quoteNoOut(uint256 quoteIn) external view override returns (uint256 noOut, uint256 priceAfter) {
        uint256 effectiveInput = quoteIn * (10000 - feeBps) / 10000;
        noOut = _calculateNoOut(effectiveInput);
        
        uint256 newYesReserve = reserves.yes - noOut;
        uint256 newNoReserve = reserves.no + noOut;
        priceAfter = (newNoReserve * 1e18) / (newYesReserve + newNoReserve);
    }

    /**
     * @notice Swap quote tokens for YES tokens
     * @param quoteIn Amount of quote tokens to spend
     * @param minYesOut Minimum YES tokens to receive
     */
    function swapQuoteForYes(uint256 quoteIn, uint256 minYesOut) external override nonReentrant tradingOpen {
        if (quoteIn == 0) revert ErrInsufficientOutput();
        
        // Calculate fee and effective input
        uint256 fee = quoteIn * feeBps / 10000;
        uint256 effectiveInput = quoteIn - fee;
        
        // Calculate YES tokens out
        uint256 yesOut = _calculateYesOut(effectiveInput);
        if (yesOut < minYesOut) revert ErrSlippage();
        
        // Update reserves
        reserves.yes += yesOut;
        reserves.no -= yesOut;
        
        // Update vault
        quoteVault += effectiveInput;
        
        // Transfer tokens
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), quoteIn);
        IERC20(quoteToken).safeTransfer(treasury, fee);
        
        // Mint YES tokens
        yesToken.mint(msg.sender, yesOut);
        
        emit Swap(msg.sender, true, quoteIn, yesOut, feeBps);
    }

    /**
     * @notice Swap quote tokens for NO tokens
     * @param quoteIn Amount of quote tokens to spend
     * @param minNoOut Minimum NO tokens to receive
     */
    function swapQuoteForNo(uint256 quoteIn, uint256 minNoOut) external override nonReentrant tradingOpen {
        if (quoteIn == 0) revert ErrInsufficientOutput();
        
        // Calculate fee and effective input
        uint256 fee = quoteIn * feeBps / 10000;
        uint256 effectiveInput = quoteIn - fee;
        
        // Calculate NO tokens out
        uint256 noOut = _calculateNoOut(effectiveInput);
        if (noOut < minNoOut) revert ErrSlippage();
        
        // Update reserves
        reserves.yes -= noOut;
        reserves.no += noOut;
        
        // Update vault
        quoteVault += effectiveInput;
        
        // Transfer tokens
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), quoteIn);
        IERC20(quoteToken).safeTransfer(treasury, fee);
        
        // Mint NO tokens
        noToken.mint(msg.sender, noOut);
        
        emit Swap(msg.sender, false, quoteIn, noOut, feeBps);
    }

    /**
     * @notice Add liquidity to the pool
     * @param quoteIn Amount of quote tokens to add
     * @param minSharesOut Minimum LP shares to receive
     */
    function addLiquidity(uint256 quoteIn, uint256 minSharesOut) external override nonReentrant tradingOpen {
        if (quoteIn == 0) revert ErrInsufficientOutput();
        
        uint256 sharesOut;
        if (totalShares == 0) {
            // First liquidity provision
            sharesOut = quoteIn;
            quoteVault = quoteIn;
        } else {
            // Proportional to existing liquidity
            sharesOut = (quoteIn * totalShares) / quoteVault;
            quoteVault += quoteIn;
        }
        
        if (sharesOut < minSharesOut) revert ErrSlippage();
        
        // Update state
        totalShares += sharesOut;
        sharesOf[msg.sender] += sharesOut;
        
        // Transfer quote tokens
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), quoteIn);
        
        emit LiquidityAdded(msg.sender, quoteIn, sharesOut);
    }

    /**
     * @notice Remove liquidity from the pool
     * @param sharesIn Amount of LP shares to burn
     * @param minQuoteOut Minimum quote tokens to receive
     */
    function removeLiquidity(uint256 sharesIn, uint256 minQuoteOut) external override nonReentrant {
        if (sharesIn == 0 || sharesOf[msg.sender] < sharesIn) revert ErrInsufficientLiquidity();
        
        // Calculate quote out proportionally
        uint256 quoteOut = (sharesIn * quoteVault) / totalShares;
        if (quoteOut < minQuoteOut) revert ErrSlippage();
        
        // Update state
        totalShares -= sharesIn;
        sharesOf[msg.sender] -= sharesIn;
        quoteVault -= quoteOut;
        
        // Transfer quote tokens
        IERC20(quoteToken).safeTransfer(msg.sender, quoteOut);
        
        emit LiquidityRemoved(msg.sender, sharesIn, quoteOut);
    }

    /**
     * @notice Set market status (factory only)
     * @param newStatus The new market status
     */
    function setStatus(MarketStatus newStatus) external override onlyFactory {
        status = newStatus;
    }

    /**
     * @notice Apply outcome and finalize market (resolver only)
     * @param _outcome The final outcome
     * @param _t0Rank Initial rank (for verification)
     * @param _t1Rank Final rank
     */
    function applyOutcome(Outcome _outcome, uint16 _t0Rank, uint16 _t1Rank) external override onlyResolver {
        if (status == MarketStatus.FINALIZED) revert ErrAlreadyFinalized();
        if (_t0Rank != t0Rank) revert ErrInvalidState();
        
        outcome = _outcome;
        status = MarketStatus.FINALIZED;
        
        emit OutcomeApplied(_outcome);
    }

    /**
     * @notice Redeem winning tokens for quote tokens
     * @param to Address to send quote tokens to
     */
    function redeem(address to) external override nonReentrant {
        if (status != MarketStatus.FINALIZED) revert ErrInvalidState();
        if (outcome == Outcome.NONE) revert ErrInvalidState();
        if (hasRedeemed[msg.sender]) revert ErrAlreadyRedeemed();
        
        uint256 payout = 0;
        
        if (outcome == Outcome.YES) {
            uint256 yesBalance = yesToken.balanceOf(msg.sender);
            if (yesBalance > 0) {
                uint256 totalYesSupply = yesToken.totalSupply();
                payout = (yesBalance * quoteVault) / totalYesSupply;
                yesToken.burnFrom(msg.sender, yesBalance);
            }
        } else if (outcome == Outcome.NO) {
            uint256 noBalance = noToken.balanceOf(msg.sender);
            if (noBalance > 0) {
                uint256 totalNoSupply = noToken.totalSupply();
                payout = (noBalance * quoteVault) / totalNoSupply;
                noToken.burnFrom(msg.sender, noBalance);
            }
        }
        
        if (payout > 0) {
            hasRedeemed[msg.sender] = true;
            quoteVault -= payout;
            IERC20(quoteToken).safeTransfer(to, payout);
            emit Redeemed(msg.sender, payout);
        }
    }

    /**
     * @notice Pause the market (factory only)
     */
    function pause() external onlyFactory {
        _pause();
    }

    /**
     * @notice Unpause the market (factory only)
     */
    function unpause() external onlyFactory {
        _unpause();
    }

    /**
     * @notice Calculate YES tokens out using CPMM formula
     * @param quoteIn Effective quote tokens in (after fees)
     * @return yesOut YES tokens to receive
     */
    function _calculateYesOut(uint256 quoteIn) internal view returns (uint256 yesOut) {
        // Using constant product formula: (R_y + yesOut) * (R_n - yesOut) = R_y * R_n
        // We solve for yesOut where we're buying YES and selling NO
        uint256 k = reserves.yes * reserves.no;
        uint256 newNoReserve = k / (reserves.yes + quoteIn);
        yesOut = reserves.no - newNoReserve;
        
        // Ensure we don't drain the pool
        if (yesOut >= reserves.no) revert ErrInsufficientLiquidity();
    }

    /**
     * @notice Calculate NO tokens out using CPMM formula
     * @param quoteIn Effective quote tokens in (after fees)
     * @return noOut NO tokens to receive
     */
    function _calculateNoOut(uint256 quoteIn) internal view returns (uint256 noOut) {
        // Using constant product formula: (R_y - noOut) * (R_n + noOut) = R_y * R_n
        // We solve for noOut where we're buying NO and selling YES
        uint256 k = reserves.yes * reserves.no;
        uint256 newYesReserve = k / (reserves.no + quoteIn);
        noOut = reserves.yes - newYesReserve;
        
        // Ensure we don't drain the pool
        if (noOut >= reserves.yes) revert ErrInsufficientLiquidity();
    }
}