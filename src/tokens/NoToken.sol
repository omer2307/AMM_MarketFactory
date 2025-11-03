// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title NoToken
 * @notice ERC20 token representing NO outcome for a song market
 */
contract NoToken is ERC20, ERC20Burnable {
    /// @notice The market contract that can mint tokens
    address public immutable market;
    
    /// @notice Song ID this token represents
    uint256 public immutable songId;

    /// @notice Only market can mint tokens
    error ErrUnauthorized();

    constructor(uint256 _songId) ERC20(
        string.concat("Song ", _toString(_songId), " NO"),
        string.concat("HNO-", _toString(_songId))
    ) {
        market = msg.sender;
        songId = _songId;
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert ErrUnauthorized();
        _;
    }

    /**
     * @notice Mint tokens to a user (market only)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyMarket {
        _mint(to, amount);
    }

    /**
     * @notice Convert uint256 to string
     * @param value The number to convert
     * @return The string representation
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}