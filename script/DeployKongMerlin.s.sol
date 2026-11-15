// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {KongMerlin} from "../src/KongMerlin.sol";

/// @notice Deploy KongMerlin to BNB Chain mainnet.
/// @dev The Binance Agent ID registry address is passed as the constructor
/// argument; minting requires holding an Agent ID from that registry.
/// Run with (no key is stored anywhere in this repo):
///   forge script script/DeployKongMerlin.s.sol --rpc-url <BSC_RPC> --broadcast --verify --verifier sourcify
/// or deploy from the browser deploy page (workspace/your_files/kongmerlin/kongmerlin-deploy.html),
/// then verify with Sourcify using the exact source in src/KongMerlin.sol.
contract DeployKongMerlin is Script {
    /// @notice Binance Agent ID registry (ERC-721) on BNB Chain.
    address internal constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function run() external {
        vm.startBroadcast();

        KongMerlin nft = new KongMerlin(AGENT_ID_REGISTRY);

        vm.stopBroadcast();

        console.log("KongMerlin:", address(nft));
        console.log("MAX_SUPPLY:", nft.MAX_SUPPLY());
        console.log("FREE_MINT_LIMIT:", nft.FREE_MINT_LIMIT());
        console.log("MINT_PRICE (after free mints):", nft.MINT_PRICE());
        console.log("PAID_MINT_PRICE (from open):", nft.PAID_MINT_PRICE());
        console.log("Agent ID registry:", nft.agentIdRegistry());
        console.log("NOTE: mint starts CLOSED. Owner must call nft.setMintOpen(true) to open mint.");
    }
}
