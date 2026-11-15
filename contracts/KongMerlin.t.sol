// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KongMerlin} from "../src/KongMerlin.sol";

/// @notice Minimal stand-in for the Binance Agent ID registry: tracks who
/// holds an Agent ID via a balance mapping.
contract MockAgentIdRegistry {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to] += 1;
    }
}

contract KongMerlinTest is Test {
    KongMerlin nft;
    MockAgentIdRegistry registry;
    address owner = address(0xA11CE);
    address minter = address(0xBEEF);
    address noId = address(0xCAFE);

    function setUp() public {
        registry = new MockAgentIdRegistry();
        vm.prank(owner);
        nft = new KongMerlin(address(registry));
        registry.mint(minter);
        vm.deal(minter, 10 ether);
        vm.deal(owner, 1 ether);
        vm.deal(noId, 1 ether);
    }

    function testMintStartsClosed() public {
        vm.prank(minter);
        vm.expectRevert(KongMerlin.MintClosed.selector);
        nft.mint{value: 0.0001 ether}();
    }

    // ── Agent ID gate (mint only) ─────────────────────────────────────

    function testConstructorSetsRegistry() public view {
        assertEq(nft.agentIdRegistry(), address(registry));
    }

    function testConstructorRevertsOnZeroRegistry() public {
        vm.expectRevert(KongMerlin.InvalidAgentIdRegistry.selector);
        new KongMerlin(address(0));
    }

    function testMintRevertsWithoutAgentId() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(noId);
        vm.expectRevert(KongMerlin.MissingAgentId.selector);
        nft.mint{value: 0.0001 ether}();
        assertEq(nft.totalMinted(), 0);
    }

    function testMintSucceedsWithAgentId() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(minter);
        nft.mint{value: 0.0001 ether}();
        assertEq(nft.totalMinted(), 1);
    }

    function testBrewWorksWithoutAgentId() public {
        vm.prank(noId);
        nft.brew{value: 0.0001 ether}();
        assertEq(nft.brewCount(), 1);
    }

    function testBuyPotionWorksWithoutAgentId() public {
        vm.prank(noId);
        nft.buyPotion{value: 0.0005 ether}(7);
        assertTrue(nft.purchases(noId, 7));
    }

    // ── Helpers: find minted IDs without assuming any order ──────────

    /// @dev Count how many token IDs 1-1111 `who` owns. With N mints by
    /// one wallet, a count of N proves all minted IDs were distinct and
    /// inside 1-1111.
    function _ownedCount(address who) internal view returns (uint256 count) {
        for (uint256 id = 1; id <= 1111; id++) {
            try nft.ownerOf(id) returns (address o) {
                if (o == who) count++;
            } catch {}
        }
    }

    /// @dev Return the first token ID owned by `who` (reverts if none).
    function _findOwnedId(address who) internal view returns (uint256) {
        for (uint256 id = 1; id <= 1111; id++) {
            try nft.ownerOf(id) returns (address o) {
                if (o == who) return id;
            } catch {}
        }
        revert("none owned");
    }

    function testSingleMintPrice() public view {
        assertEq(nft.MINT_PRICE(), 0.0001 ether);
        assertEq(nft.PAID_MINT_PRICE(), 0.002 ether);
        assertEq(nft.FREE_MINT_LIMIT(), 500);
        // Before any mint, the free phase is active: next mint() is free.
        assertEq(nft.currentPrice(), 0);
        assertEq(nft.freeRemaining(), 500);
        assertEq(nft.freeMinted(), 0);
    }

    // ── Free Mint lane (mint() tiered pricing) ─────────────────────────

    function testFreeMintsCostZero() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        uint256 before = minter.balance;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(minter);
            nft.mint{value: 0}();
        }
        assertEq(nft.totalMinted(), 3);
        assertEq(nft.freeMinted(), 3);
        assertEq(nft.freeRemaining(), 497);
        assertEq(nft.currentPrice(), 0);
        assertEq(address(nft).balance, 0);
        assertEq(minter.balance, before);
    }

    function testFreeMintRefundsFullPayment() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        uint256 before = minter.balance;
        vm.prank(minter);
        nft.mint{value: 0.01 ether}();
        assertEq(nft.totalMinted(), 1);
        assertEq(nft.freeMinted(), 1);
        assertEq(minter.balance, before);
        assertEq(address(nft).balance, 0);
    }

    function testFreeMintExhaustionThenStandardPrice() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        for (uint256 i = 0; i < 500; i++) {
            vm.prank(minter);
            nft.mint{value: 0}();
        }
        assertEq(nft.freeMinted(), 500);
        assertEq(nft.freeRemaining(), 0);
        assertEq(nft.currentPrice(), 0.0001 ether);
        assertEq(address(nft).balance, 0);

        // The 501st mint() at 0 value reverts: the free phase is over.
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(KongMerlin.InsufficientPayment.selector, 0.0001 ether, 0)
        );
        nft.mint{value: 0}();

        // It succeeds at MINT_PRICE; freeMinted stays at the limit.
        vm.prank(minter);
        nft.mint{value: 0.0001 ether}();
        assertEq(nft.totalMinted(), 501);
        assertEq(nft.freeMinted(), 500);
        assertEq(address(nft).balance, 0.0001 ether);
    }

    // ── Paid Mint lane (mintPaid()) ────────────────────────────────────

    function testMintPaidAvailableFromOpen() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        // Paid mint works before any free mint is used.
        vm.prank(minter);
        nft.mintPaid{value: 0.002 ether}();
        assertEq(nft.totalMinted(), 1);
        assertEq(nft.freeMinted(), 0);
        assertEq(nft.freeRemaining(), 500);
        assertEq(nft.currentPrice(), 0);
        assertEq(address(nft).balance, 0.002 ether);
        assertEq(nft.remaining(), 1110);
    }

    function testMintPaidDoesNotConsumeFreeMints() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(minter);
        nft.mintPaid{value: 0.002 ether}();
        vm.prank(minter);
        nft.mintPaid{value: 0.002 ether}();
        assertEq(nft.freeMinted(), 0);
        assertEq(nft.freeRemaining(), 500);
        // The free lane is still fully available afterwards.
        vm.prank(minter);
        nft.mint{value: 0}();
        assertEq(nft.freeMinted(), 1);
        assertEq(nft.totalMinted(), 3);
    }

    function testMintPaidRevertsWhenUnderpaid() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(KongMerlin.InsufficientPayment.selector, 0.002 ether, 0.001 ether)
        );
        nft.mintPaid{value: 0.001 ether}();
        assertEq(nft.totalMinted(), 0);
    }

    function testMintPaidRefundsOverpayment() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        uint256 before = minter.balance;
        vm.prank(minter);
        nft.mintPaid{value: 0.01 ether}();
        assertEq(minter.balance, before - 0.002 ether);
        assertEq(address(nft).balance, 0.002 ether);
        assertEq(nft.totalMinted(), 1);
    }

    function testMintPaidRevertsWithoutAgentId() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(noId);
        vm.expectRevert(KongMerlin.MissingAgentId.selector);
        nft.mintPaid{value: 0.002 ether}();
        assertEq(nft.totalMinted(), 0);
    }

    function testMintPaidRevertsWhenClosed() public {
        vm.prank(minter);
        vm.expectRevert(KongMerlin.MintClosed.selector);
        nft.mintPaid{value: 0.002 ether}();
        assertEq(nft.totalMinted(), 0);
    }

    function testMixedLanesShareSupplyAndPool() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        // 500 free mints via mint() + 611 paid mints via mintPaid()
        // = full supply, drawn from the same pool.
        for (uint256 i = 0; i < 500; i++) {
            vm.prank(minter);
            nft.mint{value: 0}();
        }
        for (uint256 i = 0; i < 611; i++) {
            vm.prank(minter);
            nft.mintPaid{value: 0.002 ether}();
        }
        assertEq(nft.totalMinted(), 1111);
        assertEq(nft.remaining(), 0);
        assertEq(nft.freeMinted(), 500);
        assertEq(address(nft).balance, 611 * 0.002 ether);
        // Sold out on both lanes.
        vm.prank(minter);
        vm.expectRevert(KongMerlin.MaxSupplyReached.selector);
        nft.mint{value: 0.0001 ether}();
        vm.prank(minter);
        vm.expectRevert(KongMerlin.MaxSupplyReached.selector);
        nft.mintPaid{value: 0.002 ether}();
    }

    function testMintedIdsAreWithinRange() public {
        vm.prank(owner);
        nft.setMintOpen(true);

        // 20 random draws, one wallet: every minted ID must land in
        // 1-1111, so the owned count inside that range must be 20.
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(minter);
            nft.mint{value: 0.0001 ether}();
        }
        assertEq(nft.totalMinted(), 20);
        assertEq(_ownedCount(minter), 20);
        assertEq(nft.remaining(), 1111 - 20);
    }

    function testNoDuplicateIdsAcrossBatch() public {
        vm.prank(owner);
        nft.setMintOpen(true);

        // 100 random draws: no ID may repeat, so the wallet must own
        // exactly 100 distinct IDs.
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(minter);
            nft.mint{value: 0.0001 ether}();
        }
        assertEq(nft.totalMinted(), 100);
        assertEq(_ownedCount(minter), 100);
        assertEq(nft.remaining(), 1111 - 100);
    }

    function testMintPriceEnforcedAndOverpaymentRefunded() public {
        vm.prank(owner);
        nft.setMintOpen(true);

        // Use up the 500 free mints first so mint() charges MINT_PRICE.
        for (uint256 i = 0; i < 500; i++) {
            vm.prank(minter);
            nft.mint{value: 0}();
        }
        assertEq(nft.freeMinted(), 500);

        // Underpaying reverts.
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(KongMerlin.InsufficientPayment.selector, 0.0001 ether, 0.00005 ether)
        );
        nft.mint{value: 0.00005 ether}();

        // Overpayment is refunded; exactly 0.0001 BNB stays in the contract.
        uint256 before = minter.balance;
        vm.prank(minter);
        nft.mint{value: 0.01 ether}();
        assertEq(minter.balance, before - 0.0001 ether);
        assertEq(address(nft).balance, 0.0001 ether);
        assertEq(nft.totalMinted(), 501);
    }

    function testFullMintOutCoversEveryIdOnce() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.startPrank(minter);
        for (uint256 i = 0; i < 1111; i++) {
            nft.mint{value: nft.currentPrice()}();
        }
        vm.stopPrank();
        assertEq(nft.totalMinted(), 1111);
        assertEq(nft.remaining(), 0);
        // Every ID 1-1111 is owned exactly once (by the single minter).
        assertEq(_ownedCount(minter), 1111);
    }

    function testMaxSupply() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.startPrank(minter);
        for (uint256 i = 0; i < 1111; i++) {
            nft.mint{value: nft.currentPrice()}();
        }
        vm.stopPrank();
        assertEq(nft.totalMinted(), 1111);
        vm.prank(minter);
        vm.expectRevert(KongMerlin.MaxSupplyReached.selector);
        nft.mint{value: 0.0001 ether}();
    }

    function testWithdrawGoesToOwner() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(minter);
        nft.mintPaid{value: 0.002 ether}();

        uint256 before = owner.balance;
        vm.prank(owner);
        nft.withdraw();
        assertEq(owner.balance, before + 0.002 ether);
        assertEq(address(nft).balance, 0);
    }

    function testTokenUriIsDataUri() public {
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(minter);
        nft.mint{value: 0.0001 ether}();
        // Random draw: use whichever ID was actually minted.
        uint256 tokenId = _findOwnedId(minter);
        string memory uri = nft.tokenURI(tokenId);
        assertGt(bytes(uri).length, 100);
        // "data:application/json;base64," prefix
        assertEq(bytes(uri)[0], bytes1("d"));
    }

    // ── Potion Lab brewing ─────────────────────────────────────────────

    function testBrewStartsOpen() public view {
        assertTrue(nft.brewOpen());
        assertEq(nft.BREW_PRICE(), 0.0001 ether);
        assertEq(nft.brewCount(), 0);
    }

    function testBrewChargesExactlyBrewPrice() public {
        vm.expectEmit(true, false, false, true);
        emit KongMerlin.PotionBrewed(minter, 1);
        vm.prank(minter);
        nft.brew{value: 0.0001 ether}();
        assertEq(nft.brewCount(), 1);
        assertEq(address(nft).balance, 0.0001 ether);
    }

    function testBrewRefundsOverpayment() public {
        uint256 before = minter.balance;
        vm.prank(minter);
        nft.brew{value: 0.01 ether}();
        assertEq(nft.brewCount(), 1);
        assertEq(minter.balance, before - 0.0001 ether);
        assertEq(address(nft).balance, 0.0001 ether);
    }

    function testBrewRevertsWhenUnderpaid() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(KongMerlin.InsufficientPayment.selector, 0.0001 ether, 0.00005 ether)
        );
        nft.brew{value: 0.00005 ether}();
        assertEq(nft.brewCount(), 0);
    }

    function testBrewRevertsWhenClosed() public {
        vm.prank(owner);
        nft.setBrewOpen(false);
        assertFalse(nft.brewOpen());
        vm.prank(minter);
        vm.expectRevert(KongMerlin.BrewClosed.selector);
        nft.brew{value: 0.0001 ether}();
        assertEq(nft.brewCount(), 0);
    }

    function testSetBrewOpenTogglesAndIsOwnerOnly() public {
        // Non-owner cannot toggle.
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, minter)
        );
        nft.setBrewOpen(false);

        // Owner toggles off and back on; brew works again.
        vm.prank(owner);
        nft.setBrewOpen(false);
        assertFalse(nft.brewOpen());
        vm.prank(owner);
        nft.setBrewOpen(true);
        assertTrue(nft.brewOpen());
        vm.prank(minter);
        nft.brew{value: 0.0001 ether}();
        assertEq(nft.brewCount(), 1);
    }

    function testBrewCountIncrementsPerBrew() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(minter);
            nft.brew{value: 0.0001 ether}();
        }
        assertEq(nft.brewCount(), 3);
        assertEq(address(nft).balance, 0.0003 ether);
    }

    function testBrewFeesIncludedInWithdraw() public {
        // One paid mint (0.002) + two brews (0.0002) = 0.0022 in the contract.
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(minter);
        nft.mintPaid{value: 0.002 ether}();
        vm.prank(minter);
        nft.brew{value: 0.0001 ether}();
        vm.prank(minter);
        nft.brew{value: 0.0001 ether}();
        assertEq(address(nft).balance, 0.0022 ether);

        uint256 before = owner.balance;
        vm.prank(owner);
        nft.withdraw();
        assertEq(owner.balance, before + 0.0022 ether);
        assertEq(address(nft).balance, 0);
    }

    // ── Potion shop ──────────────────────────────────────────────────

    function testShopStartsOpen() public view {
        assertTrue(nft.shopOpen());
        assertEq(nft.SHOP_PRICE(), 0.0005 ether);
        assertFalse(nft.purchases(minter, 0));
    }

    function testBuyPotionChargesExactlyShopPrice() public {
        vm.expectEmit(true, true, false, true);
        emit KongMerlin.PotionPurchased(minter, 7);
        vm.prank(minter);
        nft.buyPotion{value: 0.0005 ether}(7);
        assertTrue(nft.purchases(minter, 7));
        assertEq(address(nft).balance, 0.0005 ether);
    }

    function testBuyPotionRefundsOverpayment() public {
        uint256 before = minter.balance;
        vm.prank(minter);
        nft.buyPotion{value: 0.01 ether}(3);
        assertTrue(nft.purchases(minter, 3));
        assertEq(minter.balance, before - 0.0005 ether);
        assertEq(address(nft).balance, 0.0005 ether);
    }

    function testBuyPotionRevertsWhenUnderpaid() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(KongMerlin.InsufficientPayment.selector, 0.0005 ether, 0.0001 ether)
        );
        nft.buyPotion{value: 0.0001 ether}(3);
        assertFalse(nft.purchases(minter, 3));
    }

    function testBuyPotionRevertsForInvalidPotionId() public {
        vm.prank(minter);
        vm.expectRevert(KongMerlin.InvalidPotionId.selector);
        nft.buyPotion{value: 0.0005 ether}(56);
        vm.prank(minter);
        vm.expectRevert(KongMerlin.InvalidPotionId.selector);
        nft.buyPotion{value: 0.0005 ether}(100);
        // Boundary: 55 is a valid potion ID.
        vm.prank(minter);
        nft.buyPotion{value: 0.0005 ether}(55);
        assertTrue(nft.purchases(minter, 55));
    }

    function testBuyPotionRevertsWhenClosed() public {
        vm.prank(owner);
        nft.setShopOpen(false);
        assertFalse(nft.shopOpen());
        vm.prank(minter);
        vm.expectRevert(KongMerlin.ShopClosed.selector);
        nft.buyPotion{value: 0.0005 ether}(3);
        assertFalse(nft.purchases(minter, 3));
    }

    function testSetShopOpenTogglesAndIsOwnerOnly() public {
        // Non-owner cannot toggle.
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, minter)
        );
        nft.setShopOpen(false);

        // Owner toggles off and back on; buying works again.
        vm.prank(owner);
        nft.setShopOpen(false);
        assertFalse(nft.shopOpen());
        vm.prank(owner);
        nft.setShopOpen(true);
        assertTrue(nft.shopOpen());
        vm.prank(minter);
        nft.buyPotion{value: 0.0005 ether}(3);
        assertTrue(nft.purchases(minter, 3));
    }

    function testShopFeesIncludedInWithdraw() public {
        // One paid mint (0.002) + one brew (0.0001) + one potion (0.0005)
        // = 0.0026 in the contract.
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(minter);
        nft.mintPaid{value: 0.002 ether}();
        vm.prank(minter);
        nft.brew{value: 0.0001 ether}();
        vm.prank(minter);
        nft.buyPotion{value: 0.0005 ether}(10);
        assertEq(address(nft).balance, 0.0026 ether);

        uint256 before = owner.balance;
        vm.prank(owner);
        nft.withdraw();
        assertEq(owner.balance, before + 0.0026 ether);
        assertEq(address(nft).balance, 0);
    }
}
