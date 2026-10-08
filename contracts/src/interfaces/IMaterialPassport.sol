// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IMaterialPassport (C-06)
interface IMaterialPassport is IERC721 {
    /// @dev NONE = never minted or burned. FROZEN is NOT a token state: it is derived from the warehouse flag in C-03.
    enum LotState {
        NONE,
        FREE,
        REDEEMING
    }

    struct Lot {
        bytes32 materialCode;
        bytes32 regionCode;
        uint32 warehouseId;
        uint96 quantityKg;
        uint64 mintedAt;
        uint64 lastAttestedAt;
        LotState state;
        bytes32 certHash;
        string evidenceURI;
    }

    function mint(
        address to,
        bytes32 materialCode,
        uint32 warehouseId,
        uint96 quantityKg,
        bytes32 certHash,
        string calldata evidenceURI
    ) external returns (uint256 tokenId);

    function setRedeeming(uint256 tokenId) external;
    function clearRedeeming(uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function recordAttestation(uint256 tokenId) external;

    function lotOf(uint256 tokenId) external view returns (Lot memory);
    function stateOf(uint256 tokenId) external view returns (LotState);
    function exists(uint256 tokenId) external view returns (bool);
    function certUsed(bytes32 certHash) external view returns (bool);
    function outstandingKg(uint32 warehouseId) external view returns (uint256);
}
