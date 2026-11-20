// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

/// @title QBondIdentityRegistry
/// @notice Lightweight ERC-8004-compatible Agent Identity Registry for QDay Aevum Testnet
contract QBondIdentityRegistry is ERC721URIStorage {
    uint256 public nextAgentId = 1;

    event AgentRegistered(uint256 indexed agentId, address indexed owner, string agentURI);
    event AgentURIUpdated(uint256 indexed agentId, string newURI);

    error NotAgentOwner();

    constructor() ERC721("QBond ERC-8004 Agent", "QBAGENT") {}

    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = nextAgentId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        emit AgentRegistered(agentId, msg.sender, agentURI);
    }

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        if (ownerOf(agentId) != msg.sender) revert NotAgentOwner();
        _setTokenURI(agentId, newURI);
        emit AgentURIUpdated(agentId, newURI);
    }
}
