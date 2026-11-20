// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC8004IdentityRegistry
/// @notice Minimal ERC-8004 Identity Registry interface (ERC-721 + agent URI)
interface IERC8004IdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
    function tokenURI(uint256 agentId) external view returns (string memory);
}

/// @title IERC8004ReputationRegistry
/// @notice Optional ERC-8004 Reputation Registry hook for post-settlement feedback
interface IERC8004ReputationRegistry {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
}
