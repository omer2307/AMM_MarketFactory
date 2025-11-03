#!/usr/bin/env node

/**
 * Export contract ABIs in a clean format for frontend consumption
 */

const fs = require('fs');
const path = require('path');

const contractsToExport = [
    'MarketFactory',
    'Market', 
    'YesToken',
    'NoToken'
];

const outDir = './out';
const outputDir = './abis';

// Create output directory if it doesn't exist
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir);
}

function exportABI(contractName) {
    try {
        // Find the contract artifact
        const artifactPath = path.join(outDir, `${contractName}.sol`, `${contractName}.json`);
        
        if (!fs.existsSync(artifactPath)) {
            console.log(`❌ Artifact not found: ${artifactPath}`);
            return;
        }

        const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
        
        if (!artifact.abi) {
            console.log(`❌ No ABI found in artifact: ${contractName}`);
            return;
        }

        // Export clean ABI
        const cleanABI = {
            abi: artifact.abi,
            bytecode: artifact.bytecode.object,
            contractName: contractName
        };

        const outputPath = path.join(outputDir, `${contractName}.json`);
        fs.writeFileSync(outputPath, JSON.stringify(cleanABI, null, 2));
        
        console.log(`✅ Exported ${contractName} ABI to ${outputPath}`);
        
        // Also export just the ABI array for easier consumption
        const abiOnlyPath = path.join(outputDir, `${contractName}.abi.json`);
        fs.writeFileSync(abiOnlyPath, JSON.stringify(artifact.abi, null, 2));
        
    } catch (error) {
        console.error(`❌ Error exporting ${contractName}:`, error.message);
    }
}

function main() {
    console.log('🚀 Exporting contract ABIs...\n');

    // Check if artifacts exist
    if (!fs.existsSync(outDir)) {
        console.error('❌ Artifacts directory not found. Run `forge build` first.');
        process.exit(1);
    }

    contractsToExport.forEach(exportABI);
    
    console.log('\n✨ ABI export complete!');
    console.log(`📁 ABIs exported to: ${outputDir}/`);
    
    // List exported files
    const files = fs.readdirSync(outputDir);
    files.forEach(file => {
        console.log(`   - ${file}`);
    });
}

if (require.main === module) {
    main();
}

module.exports = { exportABI };