// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {ICreditRouter} from "../interfaces/ICreditRouter.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {IPriceIndex} from "../interfaces/IPriceIndex.sol";

/// @title Marketplace (C-16)
/// @notice Non-custodial lot marketplace with atomic Delivery-versus-Payment.
///         - Fixed-price listings (public, or private OTC when `allowedBuyer` is set).
///         - RFQ bids: buyer escrows USDC, seller accepts.
///         - Encumbered lots (pledged through C-15) settle with an automatic loan payoff in the same transaction.
///         Either everything settles (payment, payoff, title, fees, index) or the whole transaction reverts.
contract Marketplace is TensileAccessControlled, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Listing {
        uint256 tokenId;
        address seller;
        address allowedBuyer; // address(0) = public
        uint128 price;
        uint64 expiry;
        bool active;
    }

    struct Bid {
        uint256 tokenId;
        address bidder;
        uint128 amount;
        uint64 expiry;
        bool active;
    }

    bytes32 public constant FEE_SETTLEMENT = keccak256("SETTLEMENT");
    uint16 public constant MAX_FEE_BPS = 500;

    IMaterialPassport public immutable passport;
    IIdentityRegistry public immutable identity;
    ICreditRouter public immutable router;
    IERC20 public immutable paymentToken;
    uint8 public immutable paymentDecimals;

    IFeeCollector public feeCollector;
    IPriceIndex public priceIndex; // optional
    uint16 public settlementFeeBps = 25; // 0.25%

    uint256 public listingCount;
    uint256 public bidCount;
    mapping(uint256 => Listing) private _listings;
    mapping(uint256 => Bid) private _bids;

    event Listed(uint256 indexed listingId, uint256 indexed tokenId, address indexed seller, uint256 price, address allowedBuyer, uint64 expiry);
    event ListingCancelled(uint256 indexed listingId);
    event BidPlaced(uint256 indexed bidId, uint256 indexed tokenId, address indexed bidder, uint256 amount, uint64 expiry);
    event BidCancelled(uint256 indexed bidId);
    event Settled(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 loanPayoff,
        uint256 fee,
        uint256 sellerProceeds
    );
    event FeeConfigSet(address collector, uint16 bps);
    event PriceIndexSet(address index);

    error NotVerified(address account);
    error NotEntitled(uint256 tokenId, address seller);
    error InvalidPrice();
    error InvalidExpiry();
    error ListingInactive(uint256 listingId);
    error BidInactive(uint256 bidId);
    error NotAllowedBuyer();
    error NotSeller();
    error NotBidder();
    error SelfTrade();
    error PriceBelowDebt(uint256 price, uint256 needed);
    error InvalidFee();

    constructor(
        ITensileAccess access_,
        IMaterialPassport passport_,
        IIdentityRegistry identity_,
        ICreditRouter router_,
        IERC20 paymentToken_,
        uint8 paymentDecimals_,
        IFeeCollector feeCollector_
    ) TensileAccessControlled(access_) {
        if (
            address(passport_) == address(0) || address(identity_) == address(0) || address(router_) == address(0)
                || address(paymentToken_) == address(0) || address(feeCollector_) == address(0)
        ) revert ZeroAddress();
        passport = passport_;
        identity = identity_;
        router = router_;
        paymentToken = paymentToken_;
        paymentDecimals = paymentDecimals_;
        feeCollector = feeCollector_;
    }

    // ------------------------------------------------------------------ admin

    function setFeeConfig(IFeeCollector collector, uint16 bps) external onlyAdmin {
        if (address(collector) == address(0)) revert ZeroAddress();
        if (bps > MAX_FEE_BPS) revert InvalidFee();
        feeCollector = collector;
        settlementFeeBps = bps;
        emit FeeConfigSet(address(collector), bps);
    }

    function setPriceIndex(IPriceIndex index) external onlyAdmin {
        priceIndex = index;
        emit PriceIndexSet(address(index));
    }

    // ------------------------------------------------------------------ listings

    /// @notice List a lot. Plain lots: seller must approve this contract for the NFT before a buyer settles.
    ///         Encumbered lots: no approval needed — the CreditRouter releases the NFT on payoff.
    function list(uint256 tokenId, uint128 price, address allowedBuyer, uint64 expiry)
        external
        returns (uint256 listingId)
    {
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (allowedBuyer == msg.sender) revert SelfTrade();
        if (!isEntitledSeller(tokenId, msg.sender)) revert NotEntitled(tokenId, msg.sender);

        listingId = ++listingCount;
        _listings[listingId] = Listing({
            tokenId: tokenId,
            seller: msg.sender,
            allowedBuyer: allowedBuyer,
            price: price,
            expiry: expiry,
            active: true
        });
        emit Listed(listingId, tokenId, msg.sender, price, allowedBuyer, expiry);
    }

    function cancelListing(uint256 listingId) external {
        Listing storage l = _listings[listingId];
        if (!l.active) revert ListingInactive(listingId);
        if (msg.sender != l.seller) revert NotSeller();
        l.active = false;
        emit ListingCancelled(listingId);
    }

    function buy(uint256 listingId) external nonReentrant {
        Listing storage l = _listings[listingId];
        if (!l.active || block.timestamp >= l.expiry) revert ListingInactive(listingId);
        if (l.allowedBuyer != address(0) && l.allowedBuyer != msg.sender) revert NotAllowedBuyer();
        if (msg.sender == l.seller) revert SelfTrade();
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        l.active = false;

        uint256 price = l.price;
        paymentToken.safeTransferFrom(msg.sender, address(this), price);
        _settle(l.tokenId, l.seller, msg.sender, price);
    }

    // ------------------------------------------------------------------ RFQ bids

    function placeBid(uint256 tokenId, uint128 amount, uint64 expiry) external nonReentrant returns (uint256 bidId) {
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        if (amount == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (!passport.exists(tokenId)) revert NotEntitled(tokenId, address(0));

        bidId = ++bidCount;
        _bids[bidId] = Bid({tokenId: tokenId, bidder: msg.sender, amount: amount, expiry: expiry, active: true});
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        emit BidPlaced(bidId, tokenId, msg.sender, amount, expiry);
    }

    /// @notice Bidder can withdraw an unaccepted bid at any time (including after expiry).
    function cancelBid(uint256 bidId) external nonReentrant {
        Bid storage b = _bids[bidId];
        if (!b.active) revert BidInactive(bidId);
        if (msg.sender != b.bidder) revert NotBidder();
        b.active = false;
        paymentToken.safeTransfer(b.bidder, b.amount);
        emit BidCancelled(bidId);
    }

    function acceptBid(uint256 bidId) external nonReentrant {
        Bid storage b = _bids[bidId];
        if (!b.active || block.timestamp >= b.expiry) revert BidInactive(bidId);
        if (msg.sender == b.bidder) revert SelfTrade();
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        if (!identity.isVerified(b.bidder)) revert NotVerified(b.bidder);
        b.active = false;
        _settle(b.tokenId, msg.sender, b.bidder, b.amount); // funds already escrowed here
    }

    // ------------------------------------------------------------------ settlement

    /// @dev Funds (`price`) must already be held by this contract.
    function _settle(uint256 tokenId, address seller, address buyer, uint256 price) internal {
        IMaterialPassport.Lot memory lot = passport.lotOf(tokenId);
        uint256 fee = price * settlementFeeBps / 10_000;
        uint256 payoff;

        if (passport.ownerOf(tokenId) == seller) {
            // plain lot: NFT moves seller -> buyer (C-06 enforces FREE, not frozen, buyer verified)
            passport.transferFrom(seller, buyer, tokenId);
        } else if (router.borrowerOf(tokenId) == seller) {
            // encumbered lot: router repays Morpho with funds from this contract, then delivers the NFT to buyer
            uint256 available = price - fee;
            paymentToken.forceApprove(address(router), available);
            payoff = router.payoffFor(tokenId, buyer);
            paymentToken.forceApprove(address(router), 0);
            if (payoff > available) revert PriceBelowDebt(price, payoff + fee); // defensive; transferFrom would fail first
        } else {
            revert NotEntitled(tokenId, seller);
        }

        if (fee != 0) {
            paymentToken.safeTransfer(address(feeCollector), fee);
            feeCollector.notify(FEE_SETTLEMENT, address(paymentToken), fee, tokenId);
        }
        uint256 proceeds = price - fee - payoff;
        if (proceeds != 0) paymentToken.safeTransfer(seller, proceeds);

        if (address(priceIndex) != address(0)) {
            // USD per tonne, 8 decimals: price / (qtyKg / 1000) scaled from payment decimals to 8
            uint256 pricePerTonne = Math.mulDiv(price, 1000 * 1e8, uint256(lot.quantityKg) * 10 ** paymentDecimals);
            priceIndex.record(lot.materialCode, lot.regionCode, pricePerTonne, lot.quantityKg);
        }

        emit Settled(tokenId, seller, buyer, price, payoff, fee, proceeds);
    }

    // ------------------------------------------------------------------ views

    /// @notice A seller is entitled if they own the lot outright, or are the recorded borrower of a pledged lot.
    function isEntitledSeller(uint256 tokenId, address seller) public view returns (bool) {
        if (!passport.exists(tokenId)) return false;
        if (passport.ownerOf(tokenId) == seller) return true;
        return router.borrowerOf(tokenId) == seller;
    }

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    function getBid(uint256 bidId) external view returns (Bid memory) {
        return _bids[bidId];
    }
}
