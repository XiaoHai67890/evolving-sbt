// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EvolvingSBT } from "./EvolvingSBT.sol";
import { IEvolvingSBT } from "./interfaces/IEvolvingSBT.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IContributionRevocationReads {
    function hasRevocations(uint256 tokenId) external view returns (bool);
    function anyRevoked(uint256 tokenId, bytes32[2][] calldata ids) external view returns (bool);
}

/// @notice Optional issuer-operated revocation register for one signed-growth namespace and policy.
contract ContributionRevocationRegistry is IContributionRevocationReads, IERC165 {
    enum Target {
        Claim,
        Experience
    }

    struct Revocation {
        uint256 atBlock;
        bool atGenesis;
    }

    EvolvingSBT public immutable credential;
    bytes32 public immutable namespace;
    bytes32 public immutable policyId;
    address public immutable issuer;
    address public immutable controller;
    uint256 public immutable chainId;

    bool public activated;
    mapping(address => bool) public claimRevokers;
    mapping(uint256 => mapping(Target => mapping(bytes32 => Revocation))) private _revocations;
    mapping(uint256 tokenId => uint256) private _revokedIdFilter;

    error InvalidConfiguration();
    error Unauthorized();
    error WrongChain();
    error AlreadyActivated();
    error Inactive();
    error InvalidAccount();
    error RecordIdMismatch();
    error AlreadyRevoked();

    event Activated(address indexed issuer);
    event ClaimRevokerSet(address indexed account, bool enabled);
    event Revoked(uint256 indexed tokenId, Target indexed kind, bytes32 indexed id, address actor);

    constructor(
        EvolvingSBT credential_,
        bytes32 namespace_,
        bytes32 policyId_,
        address issuer_,
        address controller_
    ) {
        if (
            address(credential_).code.length == 0 || issuer_ == address(0) || controller_ == address(0)
                || issuer_ == controller_
        ) revert InvalidConfiguration();
        (IEvolvingSBT.PolicyDefinition memory definition,) = credential_.policyOf(namespace_, policyId_);
        if (
            definition.verifier != address(credential_)
                || definition.authorizationHash != keccak256(abi.encode(issuer_, controller_))
        ) revert InvalidConfiguration();

        credential = credential_;
        namespace = namespace_;
        policyId = policyId_;
        issuer = issuer_;
        controller = controller_;
        chainId = block.chainid;
    }

    modifier onRegistryChain() {
        if (block.chainid != chainId) revert WrongChain();
        _;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IContributionRevocationReads).interfaceId;
    }

    function activate() external onRegistryChain {
        if (msg.sender != issuer) revert Unauthorized();
        if (activated) revert AlreadyActivated();
        activated = true;
        emit Activated(msg.sender);
    }

    function setClaimRevoker(address account, bool enabled) external onRegistryChain {
        if (msg.sender != issuer) revert Unauthorized();
        if (!activated) revert Inactive();
        if (account == address(0)) revert InvalidAccount();
        if (claimRevokers[account] == enabled) return;
        claimRevokers[account] = enabled;
        emit ClaimRevokerSet(account, enabled);
    }

    /// @notice Permanently withdraw a single accepted version or the entire experience identified by it.
    /// @dev Resolves the supplied ID against the actual historical record, including superseded versions.
    function revoke(uint256 tokenId, uint256 recordIndex, Target kind, bytes32 expectedId)
        external
        onRegistryChain
    {
        if (!activated) revert Inactive();
        if (msg.sender != issuer && (kind != Target.Claim || !claimRevokers[msg.sender])) {
            revert Unauthorized();
        }

        (EvolvingSBT.Record memory record,) = credential.recordAt(tokenId, namespace, recordIndex);
        bytes32 id = kind == Target.Claim ? record.claimId : record.experienceId;
        if (expectedId != id) revert RecordIdMismatch();
        Revocation storage entry = _revocations[tokenId][kind][id];
        if (_revoked(entry)) revert AlreadyRevoked();
        // A normal withdrawal needs one exact-entry write. Block zero has an explicit representation.
        if (block.number == 0) entry.atGenesis = true;
        else entry.atBlock = block.number;
        _revokedIdFilter[tokenId] |= _filterBit(kind, id);
        emit Revoked(tokenId, kind, id, msg.sender);
    }

    /// @notice An absent entry does not establish that the specified contribution was ever accepted.
    function revocationOf(uint256 tokenId, Target kind, bytes32 id)
        external
        view
        onRegistryChain
        returns (bool revoked, uint256 atBlock)
    {
        Revocation storage entry = _revocations[tokenId][kind][id];
        return (_revoked(entry), entry.atBlock);
    }

    /// @notice True after this registry has accepted its first revocation for the token.
    function hasRevocations(uint256 tokenId) external view onRegistryChain returns (bool) {
        return _revokedIdFilter[tokenId] != 0;
    }

    /// @notice Test claim / experience ID pairs from the selected credential's accepted records.
    /// @dev Filter misses are definitive. Every hit is resolved against the original full ID and target.
    function anyRevoked(uint256 tokenId, bytes32[2][] calldata ids)
        external
        view
        onRegistryChain
        returns (bool)
    {
        uint256 filter = _revokedIdFilter[tokenId];
        if (filter == 0) return false;
        for (uint256 i; i < ids.length; ++i) {
            bytes32 claim = ids[i][0];
            bytes32 experience = ids[i][1];
            if (
                (filter & _filterBit(Target.Claim, claim) != 0
                        && _revoked(_revocations[tokenId][Target.Claim][claim]))
                    || (filter & _filterBit(Target.Experience, experience) != 0
                        && _revoked(_revocations[tokenId][Target.Experience][experience]))
            ) return true;
        }
        return false;
    }

    function _filterBit(Target kind, bytes32 id) private pure returns (uint256) {
        // A token has at most 32 records. The lower and upper 128 bits screen the two target domains.
        return uint256(1) << ((uint256(id) & 127) + uint256(kind) * 128);
    }

    function _revoked(Revocation storage entry) private view returns (bool) {
        return entry.atBlock != 0 || entry.atGenesis;
    }
}
