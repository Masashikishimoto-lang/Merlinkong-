// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Minimal view of the Binance Agent ID registry (ERC-721):
/// minting only checks that the caller holds at least one Agent ID.
interface IAgentIdRegistry {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title KongMerlin
/// @notice ERC721 collection of 1,111 pixel wizard apes (Kong + Merlin)
/// on BNB Chain. Minting is a random draw: each mint assigns a random
/// unminted token ID (swap-and-pop pool), so the minter never picks a
/// number. Every ID 1-1111 is drawn exactly once.
/// Two mint lanes, both a random draw from the same pool:
/// - Free Mint: mint() is FREE (0 BNB) for the first 500 mints, then
///   0.0001 BNB per mint once the 500 free mints are used.
/// - Paid Mint: mintPaid() is 0.002 BNB per mint, available from the
///   moment mint opens (not phase-gated). It never consumes the free
///   mint allocation.
/// Mint fees stay in the contract ("fee goes to the contract wallet") and
/// only the owner can withdraw them with withdraw().
/// Minting requires a Binance Agent ID: the minter must hold at least one
/// Agent ID (ERC-721) from the registry registered at deploy time.
/// Brewing and the potion shop have no Agent ID gate. No whitelist.
/// Mint starts CLOSED. Nobody can mint until the owner opens it with
/// setMintOpen(true). The owner can close it again at any time.
/// Potion Lab brewing: anyone can pay the brew fee with brew() to play
/// one round of the Potion Lab game. Brew fees stay in the contract
/// together with the mint fees and are withdrawn by the owner with
/// withdraw(). Brewing starts OPEN; the owner can close it with
/// setBrewOpen(false).
/// Potion shop: anyone can buy a potion from the 56-combination catalog
/// with buyPotion(potionId) for 0.0005 BNB. The purchase is recorded
/// on-chain in purchases(); the potion catalog itself lives off-chain.
/// Shop fees stay in the contract and are withdrawn by the owner with
/// withdraw(). The shop starts OPEN; the owner can close it with
/// setShopOpen(false).
/// Artwork is generated fully on-chain from the token ID (deterministic
/// SVG data URI): same token ID always renders the same wizard ape.
/// Token #1 is THE KING and wears a gold crown instead of a wizard hat.
contract KongMerlin is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 1111;
    uint256 public constant MINT_PRICE = 0.0001 ether;
    uint256 public constant PAID_MINT_PRICE = 0.002 ether;
    uint256 public constant FREE_MINT_LIMIT = 500;
    uint256 public constant BREW_PRICE = 0.0001 ether;
    uint256 public constant SHOP_PRICE = 0.0005 ether;

    /// @notice Binance Agent ID registry, registered once at deploy time
    /// via the constructor argument. Minting requires
    /// balanceOf(msg.sender) > 0 on this registry. Brewing and the
    /// potion shop do not check it.
    address public immutable agentIdRegistry;

    /// @notice Mint starts CLOSED. Nobody can mint until the owner opens it
    /// with setMintOpen(true). The owner can close it again at any time.
    bool public mintOpen;

    /// @notice Brewing starts OPEN. The owner can close it with
    /// setBrewOpen(false) and reopen it at any time.
    bool public brewOpen = true;

    /// @notice The potion shop starts OPEN. The owner can close it with
    /// setShopOpen(false) and reopen it at any time.
    bool public shopOpen = true;

    uint256 public totalMinted;

    /// @notice How many of the FREE_MINT_LIMIT free mints have been used.
    /// Only mint() during the free phase increments this; mintPaid()
    /// never touches it.
    uint256 public freeMinted;

    uint256 public brewCount;

    /// @notice On-chain record of potion shop purchases: purchases[buyer][potionId]
    /// is true once that buyer has bought that potion (potion IDs 0-55,
    /// the 56 combinations of 8 ingredients taken 3 at a time).
    mapping(address => mapping(uint256 => bool)) public purchases;

    /// @notice How many token IDs are still unminted. Valid pool indices
    /// are 0 .. remaining-1; it starts at MAX_SUPPLY and drops by one
    /// per mint.
    uint256 public remaining = MAX_SUPPLY;

    /// @notice Unminted ID pool (swap-and-pop). _pool[i] is the token ID
    /// at index i, or 0 meaning the identity ID i + 1. Drawing an index
    /// removes its ID from the pool by moving the last ID into its slot.
    mapping(uint256 => uint256) private _pool;

    /// @notice Increments on every mint so consecutive draws differ even
    /// within the same block.
    uint256 private _mintNonce;

    event KongMinted(address indexed minter, uint256 indexed tokenId, uint256 pricePaid);
    event MintOpenChanged(bool open);
    event PotionBrewed(address indexed player, uint256 brewCount);
    event BrewOpenChanged(bool open);
    event PotionPurchased(address indexed buyer, uint256 indexed potionId);
    event ShopOpenChanged(bool open);

    error MintClosed();
    error MissingAgentId();
    error InvalidAgentIdRegistry();
    error BrewClosed();
    error ShopClosed();
    error InvalidPotionId();
    error MaxSupplyReached();
    error InsufficientPayment(uint256 required, uint256 sent);
    error WithdrawFailed();

    constructor(address _agentIdRegistry) ERC721("KongMerlin", "KONG") Ownable(msg.sender) {
        if (_agentIdRegistry == address(0)) revert InvalidAgentIdRegistry();
        agentIdRegistry = _agentIdRegistry;
    }

    /// @notice Open or close minting. Owner only. Mint is closed at deploy.
    function setMintOpen(bool open_) external onlyOwner {
        mintOpen = open_;
        emit MintOpenChanged(open_);
    }

    /// @notice Price of the next mint() call: 0 while free mints remain,
    /// MINT_PRICE once the FREE_MINT_LIMIT free mints are used.
    function currentPrice() external view returns (uint256) {
        return freeMinted < FREE_MINT_LIMIT ? 0 : MINT_PRICE;
    }

    /// @notice How many free mints are left (0 once the allocation is used).
    function freeRemaining() external view returns (uint256) {
        return freeMinted < FREE_MINT_LIMIT ? FREE_MINT_LIMIT - freeMinted : 0;
    }

    /// @notice Mint a random unminted token ID. The ID is drawn by the
    /// contract from the unminted pool (swap-and-pop) — it cannot be
    /// chosen by the minter. Every ID 1-1111 is drawn exactly once.
    /// Free Mint: the first FREE_MINT_LIMIT mints are free (0 BNB);
    /// after that, mint() costs MINT_PRICE. Any excess payment is
    /// refunded (for a free mint, the full msg.value is refunded).
    /// The caller must hold at least one Binance Agent ID from the
    /// registry registered at deploy time.
    function mint() external payable nonReentrant {
        if (!mintOpen) revert MintClosed();
        if (IAgentIdRegistry(agentIdRegistry).balanceOf(msg.sender) == 0) revert MissingAgentId();
        if (totalMinted >= MAX_SUPPLY) revert MaxSupplyReached();

        uint256 price = freeMinted < FREE_MINT_LIMIT ? 0 : MINT_PRICE;
        if (msg.value < price) revert InsufficientPayment(price, msg.value);
        if (price == 0) freeMinted += 1;

        _drawAndMint(price);
        _refund(msg.value - price);
    }

    /// @notice Paid Mint: mint a random unminted token ID for
    /// PAID_MINT_PRICE, available from the moment mint opens. Same
    /// random draw, same Agent ID and mint-open gates as mint(), same
    /// refund behavior. Does not consume the free mint allocation.
    function mintPaid() external payable nonReentrant {
        if (!mintOpen) revert MintClosed();
        if (IAgentIdRegistry(agentIdRegistry).balanceOf(msg.sender) == 0) revert MissingAgentId();
        if (totalMinted >= MAX_SUPPLY) revert MaxSupplyReached();
        if (msg.value < PAID_MINT_PRICE) revert InsufficientPayment(PAID_MINT_PRICE, msg.value);

        _drawAndMint(PAID_MINT_PRICE);
        _refund(msg.value - PAID_MINT_PRICE);
    }

    /// @notice Draw one random unminted ID from the swap-and-pop pool,
    /// mint it to the caller, and emit KongMinted with the price paid.
    /// Shared by mint() and mintPaid() so both lanes draw from the same
    /// pool and every ID 1-1111 is drawn exactly once.
    function _drawAndMint(uint256 price) internal {
        uint256 remaining_ = remaining;
        uint256 rand = uint256(
            keccak256(abi.encodePacked(block.prevrandao, block.timestamp, msg.sender, _mintNonce))
        );
        _mintNonce += 1;
        uint256 idx = rand % remaining_;
        uint256 tokenId = _pool[idx];
        if (tokenId == 0) tokenId = idx + 1;

        uint256 lastIdx = remaining_ - 1;
        uint256 lastId = _pool[lastIdx];
        if (lastId == 0) lastId = lastIdx + 1;
        if (idx != lastIdx) {
            _pool[idx] = lastId;
        }
        delete _pool[lastIdx];

        remaining = remaining_ - 1;
        totalMinted += 1;
        _safeMint(msg.sender, tokenId);
        emit KongMinted(msg.sender, tokenId, price);
    }

    // ── Potion Lab brewing ─────────────────────────────────────────────

    /// @notice Open or close brewing. Owner only. Brewing is open at deploy.
    function setBrewOpen(bool open_) external onlyOwner {
        brewOpen = open_;
        emit BrewOpenChanged(open_);
    }

    /// @notice Pay the brew fee for one round of the Potion Lab game.
    /// The fee stays in the contract together with the mint fees and is
    /// withdrawn by the owner with withdraw(). The brew result itself is
    /// computed off-chain from the chosen ingredients; this call records
    /// the paid brew on-chain and counts it in brewCount.
    function brew() external payable nonReentrant {
        if (!brewOpen) revert BrewClosed();
        if (msg.value < BREW_PRICE) revert InsufficientPayment(BREW_PRICE, msg.value);

        brewCount += 1;
        emit PotionBrewed(msg.sender, brewCount);

        _refund(msg.value - BREW_PRICE);
    }

    // ── Potion shop ──────────────────────────────────────────────────

    /// @notice Open or close the potion shop. Owner only. The shop is
    /// open at deploy.
    function setShopOpen(bool open_) external onlyOwner {
        shopOpen = open_;
        emit ShopOpenChanged(open_);
    }

    /// @notice Buy one potion from the shop catalog for SHOP_PRICE.
    /// potionId is an index into the 56-combination catalog (0-55) that
    /// lives off-chain; this call only records the purchase on-chain in
    /// purchases(). The fee stays in the contract together with the mint
    /// and brew fees and is withdrawn by the owner with withdraw().
    function buyPotion(uint256 potionId) external payable nonReentrant {
        if (!shopOpen) revert ShopClosed();
        if (potionId >= 56) revert InvalidPotionId();
        if (msg.value < SHOP_PRICE) revert InsufficientPayment(SHOP_PRICE, msg.value);

        purchases[msg.sender][potionId] = true;
        emit PotionPurchased(msg.sender, potionId);

        _refund(msg.value - SHOP_PRICE);
    }

    /// @notice Withdraw collected mint, brew, and shop fees to the owner.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool ok, ) = payable(owner()).call{value: balance}("");
        if (!ok) revert WithdrawFailed();
    }

    // ── On-chain artwork ─────────────────────────────────────────────────

    function _hash(uint256 tokenId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(tokenId)));
    }

    function _hatOf(uint256 tokenId) internal pure returns (string memory) {
        if (tokenId == 1) return "Gold Crown";
        string[3] memory hats = ["Pointed Hat", "Wide Hat", "Tall Hat"];
        return hats[_hash(tokenId) % 3];
    }

    function _robeOf(uint256 tokenId) internal pure returns (string memory) {
        string[4] memory robes = ["Royal Blue", "Forest Green", "Teal", "Emerald"];
        return robes[(_hash(tokenId) >> 8) % 4];
    }

    function _beardOf(uint256 tokenId) internal pure returns (string memory) {
        string[3] memory beards = ["Long White Beard", "Short Grey Beard", "Braided Beard"];
        return beards[(_hash(tokenId) >> 16) % 3];
    }

    function _staffOf(uint256 tokenId) internal pure returns (string memory) {
        string[3] memory staffs = ["Star Staff", "Orb Staff", "Crystal Staff"];
        return staffs[(_hash(tokenId) >> 24) % 3];
    }

    function _bgOf(uint256 tokenId) internal pure returns (string memory) {
        string[4] memory bgs = ["#0B1E3A", "#0A2E22", "#123B5C", "#0E3B2E"];
        return bgs[(_hash(tokenId) >> 32) % 4];
    }

    function _robeColor(uint256 tokenId) internal pure returns (string memory) {
        string[4] memory colors = ["#1D4ED8", "#15803D", "#0E7490", "#059669"];
        return colors[(_hash(tokenId) >> 8) % 4];
    }

    function _hatColor(uint256 tokenId) internal pure returns (string memory) {
        if (tokenId == 1) return "#F2B705";
        string[3] memory colors = ["#1D4ED8", "#15803D", "#7C3AED"];
        return colors[_hash(tokenId) % 3];
    }

    /// @notice Fully on-chain SVG: pixel wizard ape, deterministic per token.
    /// 32x32 grid: pointed hat (or gold crown for #1), ape face, long beard,
    /// robe, and a magic staff on one side.
    function _svg(uint256 tokenId) internal view returns (string memory) {
        uint256 h = _hash(tokenId);
        string memory bg = _bgOf(tokenId);
        string memory robe = _robeColor(tokenId);
        string memory hat = _hatColor(tokenId);
        bool staffLeft = (h >> 40) % 2 == 0;
        bool longBeard = (h >> 16) % 3 == 0;

        // Hat: tall pointed triangle; #1 gets a gold crown instead.
        string memory headgear;
        if (tokenId == 1) {
            headgear = string.concat(
                "<polygon points=\"9,11 9,6 12,9 16,5 20,9 23,6 23,11\" fill=\"",
                hat,
                "\" stroke=\"#000000\" stroke-width=\"0.75\"/>"
            );
        } else {
            headgear = string.concat(
                "<polygon points=\"10,11 16,2 22,11\" fill=\"",
                hat,
                "\" stroke=\"#000000\" stroke-width=\"0.75\"/>"
                "<rect x=\"9\" y=\"10\" width=\"14\" height=\"2.5\" fill=\"",
                hat,
                "\" stroke=\"#000000\" stroke-width=\"0.75\"/>"
            );
        }

        // Beard: long covers the robe, short stops at the chin.
        string memory beard = longBeard
            ? "<polygon points=\"11,20 21,20 19,29 13,29\" fill=\"#E8E8E8\" stroke=\"#000000\" stroke-width=\"0.75\"/>"
            : "<polygon points=\"11,20 21,20 19,24 13,24\" fill=\"#E8E8E8\" stroke=\"#000000\" stroke-width=\"0.75\"/>";

        // Staff on the left or right edge, with a gold star tip.
        string memory staff = staffLeft
            ? "<rect x=\"4\" y=\"6\" width=\"1.6\" height=\"22\" fill=\"#8B5E34\"/><polygon points=\"4.8,2 5.8,4.5 8.5,4.5 6.3,6.2 7.1,9 4.8,7.4 2.5,9 3.3,6.2 1.1,4.5 3.8,4.5\" fill=\"#F2B705\"/>"
            : "<rect x=\"26.4\" y=\"6\" width=\"1.6\" height=\"22\" fill=\"#8B5E34\"/><polygon points=\"27.2,2 28.2,4.5 30.9,4.5 28.7,6.2 29.5,9 27.2,7.4 24.9,9 25.7,6.2 23.5,4.5 26.2,4.5\" fill=\"#F2B705\"/>";

        return string.concat(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\" shape-rendering=\"crispEdges\">",
            "<rect width=\"32\" height=\"32\" fill=\"",
            bg,
            "\"/>",
            staff,
            "<rect x=\"8\" y=\"20\" width=\"16\" height=\"11\" fill=\"",
            robe,
            "\" stroke=\"#000000\" stroke-width=\"0.75\"/>",
            beard,
            "<rect x=\"9\" y=\"11\" width=\"14\" height=\"10\" fill=\"#C89B6A\" stroke=\"#000000\" stroke-width=\"0.75\"/>",
            "<rect x=\"12\" y=\"14\" width=\"2.5\" height=\"2.5\" fill=\"#000000\"/>",
            "<rect x=\"17.5\" y=\"14\" width=\"2.5\" height=\"2.5\" fill=\"#000000\"/>",
            "<rect x=\"14\" y=\"18\" width=\"4\" height=\"1.4\" fill=\"#000000\"/>",
            headgear,
            "</svg>"
        );
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory svg = Base64.encode(bytes(_svg(tokenId)));
        string memory json = Base64.encode(
            bytes(
                string.concat(
                    "{\"name\":\"KongMerlin #",
                    tokenId.toString(),
                    "\",\"description\":\"A pixel wizard ape - part mighty kong, part legendary Merlin. One of 1,111 unique portraits on BNB Chain.\",",
                    "\"image\":\"data:image/svg+xml;base64,",
                    svg,
                    "\",\"attributes\":[",
                    "{\"trait_type\":\"Headgear\",\"value\":\"",
                    _hatOf(tokenId),
                    "\"},",
                    "{\"trait_type\":\"Robe\",\"value\":\"",
                    _robeOf(tokenId),
                    "\"},",
                    "{\"trait_type\":\"Beard\",\"value\":\"",
                    _beardOf(tokenId),
                    "\"},",
                    "{\"trait_type\":\"Staff\",\"value\":\"",
                    _staffOf(tokenId),
                    "\"},",
                    "{\"trait_type\":\"Background\",\"value\":\"",
                    _bgOf(tokenId),
                    "\"}",
                    "]}"
                )
            )
        );
        return string.concat("data:application/json;base64,", json);
    }

    function _refund(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "refund failed");
    }
}
