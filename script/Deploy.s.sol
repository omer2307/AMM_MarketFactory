// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MarketFactory} from "../src/amm/MarketFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Deploy Script
 * @notice Deploys the MarketFactory and sets up initial configuration
 */
contract Deploy is Script {
    // BSC Mainnet addresses
    address constant USDT_BSC = 0x55d398326f99059fF775485246999027B3197955;
    address constant FDUSD_BSC = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;
    
    // BSC Testnet addresses  
    address constant USDT_BSC_TESTNET = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying contracts with account:", deployer);
        console.log("Account balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MarketFactory
        MarketFactory factory = new MarketFactory(
            deployer, // treasury (deployer for now)
            deployer  // initial owner
        );

        console.log("MarketFactory deployed at:", address(factory));

        // Set up allowed quote tokens based on network
        uint256 chainId = block.chainid;
        
        if (chainId == 56) {
            // BSC Mainnet
            factory.allowQuoteToken(USDT_BSC, true);
            factory.allowQuoteToken(FDUSD_BSC, true);
            console.log("Allowed USDT on BSC Mainnet:", USDT_BSC);
            console.log("Allowed FDUSD on BSC Mainnet:", FDUSD_BSC);
        } else if (chainId == 97) {
            // BSC Testnet
            factory.allowQuoteToken(USDT_BSC_TESTNET, true);
            console.log("Allowed USDT on BSC Testnet:", USDT_BSC_TESTNET);
        } else {
            console.log("Unknown network, skipping quote token setup");
        }

        // Create a sample market for demonstration (only on testnet)
        if (chainId == 97) {
            address quoteToken = USDT_BSC_TESTNET;
            uint256 songId = 12345;
            uint16 t0Rank = 100;
            uint64 cutoffUtc = uint64(block.timestamp + 7 days); // 1 week from now
            
            try factory.createMarket(songId, t0Rank, cutoffUtc, quoteToken) returns (address market) {
                console.log("Sample market created at:", market);
                console.log("Song ID:", songId);
                console.log("Initial rank:", t0Rank);
                console.log("Cutoff time:", cutoffUtc);
            } catch {
                console.log("Failed to create sample market (this is expected if resolver not set)");
            }
        }

        vm.stopBroadcast();

        // Output deployment information
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("MarketFactory:", address(factory));
        console.log("Owner:", factory.owner());
        console.log("Treasury:", factory.treasury());
        console.log("Fee BPS:", factory.feeBps());
        console.log("Market Counter:", factory.marketIdCounter());
        
        // Output ABI information
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Set resolver address: factory.setResolver(resolverAddress)");
        console.log("2. Create markets: factory.createMarket(songId, t0Rank, cutoffUtc, quoteToken)");
        console.log("3. Fund treasury with gas for operations");
        
        if (chainId == 56 || chainId == 97) {
            console.log("4. Verify contracts on BSCScan");
        }
    }
}

/**
 * @title DeployLocal Script  
 * @notice Deploy script for local testing with mock tokens
 */
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy a mock USDT for local testing
        MockUSDT mockUSDT = new MockUSDT();
        console.log("Mock USDT deployed at:", address(mockUSDT));

        // Deploy MarketFactory
        MarketFactory factory = new MarketFactory(
            msg.sender, // treasury
            msg.sender  // initial owner
        );

        console.log("MarketFactory deployed at:", address(factory));

        // Allow mock USDT
        factory.allowQuoteToken(address(mockUSDT), true);
        
        // Set mock resolver
        factory.setResolver(msg.sender);

        // Create a sample market
        uint256 songId = 12345;
        uint16 t0Rank = 100;
        uint64 cutoffUtc = uint64(block.timestamp + 1 hours);
        
        address market = factory.createMarket(songId, t0Rank, cutoffUtc, address(mockUSDT));
        console.log("Sample market created at:", market);

        // Mint some mock USDT to deployer for testing
        mockUSDT.mint(msg.sender, 1000000 * 1e6); // 1M USDT
        console.log("Minted 1M mock USDT to deployer");

        vm.stopBroadcast();
    }
}

/**
 * @title MockUSDT
 * @notice Mock USDT token for local testing
 */
contract MockUSDT is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    
    uint256 private _totalSupply;
    string public name = "Mock USDT";
    string public symbol = "USDT";
    uint8 public decimals = 6;

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