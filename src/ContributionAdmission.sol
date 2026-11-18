// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { EvolvingSBT } from "./EvolvingSBT.sol";
import {
    ContributionRevocationRegistry,
    IContributionRevocationReads
} from "./ContributionRevocationRegistry.sol";

/// @notice Public contribution gate and shared consumption ledger for one event benefit.
/// @dev All entrances for this benefit must use this deployment and check their confirmed session event.
contract ContributionAdmission is EIP712 {
    struct Session {
        address holder;
        bytes32 entranceId;
        bytes32 nonce;
        uint64 deadline;
    }

    bytes32 public constant SESSION_TYPEHASH = keccak256(
        "GateSession(bytes32 eventId,bytes32 benefitId,address holder,bytes32 entranceId,bytes32 nonce,uint64 deadline)"
    );

    ContributionRevocationRegistry public immutable registry;
    EvolvingSBT public immutable credential;
    uint256 public immutable chainId;
    bytes32 public immutable namespace;
    bytes32 public immutable policyId;
    bytes32 public immutable eventId;
    bytes32 public immutable benefitId;
    uint8 public immutable threshold;
    address public immutable gateSigner;

    bool private immutable _compactRecords;
    bool private immutable _batchRevocations;

    mapping(uint256 bucket => uint256 bits) private _usedSessionWords;
    mapping(bytes32 entitlement => bool) private _consumed;

    error InvalidConfiguration();
    error NotHolder();
    error InvalidSession();
    error InvalidGateSignature();
    error SessionAlreadyUsed();
    error AlreadyConsumed();
    error Ineligible();

    event Admitted(
        address indexed holder, bytes32 indexed entranceId, bytes32 indexed sessionDigest, uint256 tokenId
    );

    constructor(
        ContributionRevocationRegistry registry_,
        bytes32 eventId_,
        bytes32 benefitId_,
        uint8 threshold_,
        address gateSigner_
    ) EIP712("ContributionAdmission", "1") {
        if (
            address(registry_).code.length == 0 || !registry_.activated()
                || registry_.chainId() != block.chainid || eventId_ == bytes32(0) || benefitId_ == bytes32(0)
                || gateSigner_ == address(0)
        ) revert InvalidConfiguration();
        EvolvingSBT sbt = registry_.credential();
        if (threshold_ == 0 || threshold_ > sbt.MAX_RECORDS()) revert InvalidConfiguration();
        _compactRecords = ERC165Checker.supportsInterface(address(sbt), EvolvingSBT.admissionRecords.selector);
        _batchRevocations = ERC165Checker.supportsInterface(
            address(registry_), type(IContributionRevocationReads).interfaceId
        );

        registry = registry_;
        credential = sbt;
        chainId = block.chainid;
        namespace = registry_.namespace();
        policyId = registry_.policyId();
        eventId = eventId_;
        benefitId = benefitId_;
        threshold = threshold_;
        gateSigner = gateSigner_;
    }

    /// @notice Evaluate every supplied record using the current public state, independently of prior redemption.
    function eligible(uint256 tokenId, uint256[] calldata indices) public view returns (bool) {
        return _qualifiedHolder(tokenId, indices) != address(0);
    }

    function _qualifiedHolder(uint256 tokenId, uint256[] calldata indices) private view returns (address) {
        if (indices.length < threshold || block.chainid != chainId) return address(0);
        // Both reads see the same EVM state. A clean registry can skip even loading the two IDs.
        bool checkIds = !_batchRevocations || registry.hasRevocations(tokenId);
        address holder;
        bytes32[2][] memory ids;
        if (_compactRecords) {
            (holder, ids) = credential.admissionRecords(tokenId, namespace, policyId, indices, checkIds);
            if (ids.length != (checkIds ? indices.length : 0)) return address(0);
        } else {
            (holder, ids) = _legacyRecords(tokenId, indices);
        }
        if (holder == address(0) || !checkIds) return holder;
        if (_batchRevocations) return registry.anyRevoked(tokenId, ids) ? address(0) : holder;

        for (uint256 i; i < ids.length; ++i) {
            (bool claimRevoked,) =
                registry.revocationOf(tokenId, ContributionRevocationRegistry.Target.Claim, ids[i][0]);
            (bool experienceRevoked,) =
                registry.revocationOf(tokenId, ContributionRevocationRegistry.Target.Experience, ids[i][1]);
            if (claimRevoked || experienceRevoked) return address(0);
        }
        return holder;
    }

    /// @dev Read older immutable signed-growth deployments using their original public methods.
    function _legacyRecords(uint256 tokenId, uint256[] calldata indices)
        private
        view
        returns (address holder, bytes32[2][] memory ids)
    {
        if (!credential.isUsable(tokenId, namespace)) return (address(0), ids);
        if (credential.stateOf(tokenId, namespace).policyId != policyId) return (address(0), ids);
        uint256 count = credential.recordCount(tokenId, namespace);
        if (indices.length > count) return (address(0), ids);

        holder = credential.ownerOf(tokenId);
        ids = new bytes32[2][](indices.length);
        uint256 seenExperienceBits;
        for (uint256 i; i < indices.length; ++i) {
            if (indices[i] >= count) return (address(0), ids);
            (EvolvingSBT.Record memory record, bool current) =
                credential.recordAt(tokenId, namespace, indices[i]);
            if (
                !current || record.subject != holder
                    || (record.validUntil != 0 && block.timestamp > record.validUntil)
            ) {
                return (address(0), ids);
            }
            uint256 bit = uint256(1) << (uint256(record.experienceId) & 255);
            // Matching low bytes are only candidates. Always compare the full experience ID.
            if (seenExperienceBits & bit != 0) {
                for (uint256 j; j < i; ++j) {
                    if (ids[j][1] == record.experienceId) return (address(0), ids);
                }
            }
            seenExperienceBits |= bit;
            ids[i] = [record.claimId, record.experienceId];
        }
    }

    /// @notice Digest signed by the event's trusted gate signer for the holder's entrance session.
    function sessionDigest(Session calldata session) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SESSION_TYPEHASH,
                    eventId,
                    benefitId,
                    session.holder,
                    session.entranceId,
                    session.nonce,
                    session.deadline
                )
            )
        );
    }

    function entitlementKey(address holder) public view returns (bytes32) {
        return keccak256(abi.encode(chainId, address(this), eventId, benefitId, holder));
    }

    function consumed(address holder) external view returns (bool) {
        return _consumed[entitlementKey(holder)];
    }

    /// @notice Return the consumed bit for any full-width session nonce.
    function usedSessions(bytes32 nonce) public view returns (bool) {
        return _usedSessionWords[uint256(nonce) >> 8] & _nonceBit(nonce) != 0;
    }

    function _nonceBit(bytes32 nonce) private pure returns (uint256) {
        return uint256(1) << (uint256(nonce) & 255);
    }

    /// @notice Recheck qualification and atomically consume both a gate session and this account's entitlement.
    /// @dev The organizer issues an event-wide unique nonce and a short deadline for each session.
    function redeem(
        uint256 tokenId,
        uint256[] calldata indices,
        Session calldata session,
        bytes calldata gateSignature
    ) external {
        if (msg.sender != session.holder) revert NotHolder();
        if (
            session.entranceId == bytes32(0) || session.nonce == bytes32(0) || session.deadline == 0
                || block.timestamp > session.deadline
        ) revert InvalidSession();
        if (usedSessions(session.nonce)) revert SessionAlreadyUsed();
        bytes32 entitlement = entitlementKey(msg.sender);
        if (_consumed[entitlement]) revert AlreadyConsumed();

        bytes32 digest = sessionDigest(session);
        if (!SignatureChecker.isValidSignatureNowCalldata(gateSigner, digest, gateSignature)) {
            revert InvalidGateSignature();
        }
        address holder = _qualifiedHolder(tokenId, indices);
        if (holder == address(0)) revert Ineligible();
        if (holder != msg.sender) revert NotHolder();

        _usedSessionWords[uint256(session.nonce) >> 8] |= _nonceBit(session.nonce);
        _consumed[entitlement] = true;
        emit Admitted(msg.sender, session.entranceId, digest, tokenId);
    }
}
