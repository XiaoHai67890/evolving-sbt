// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IEvolvingSBT } from "./interfaces/IEvolvingSBT.sol";
import { IERC5192 } from "./interfaces/IERC5192.sol";

/// @notice Experimental, transparent, bounded reference profile for the candidate interface.
/// @dev Evidence is trusted issuer recognition, not a trustless proof of external chain history.
///      No proxies, policy migration, private claims, or external revocation registry in v0.1.
contract EvolvingSBT is ERC721, Ownable, EIP712, ReentrancyGuard, IEvolvingSBT, IERC5192 {
    uint256 public constant MAX_RECORDS = 32;
    bytes32 public constant PROFILE_ID = keccak256("evolving-sbt.signed-growth.v1");
    bytes32 public constant SCHEMA_ID = keccak256(
        "Record(bytes32 claimId,bytes32 experienceId,address subject,bytes32 contentHash,uint64 validUntil,bytes32 replaces)"
    );
    bytes32 public constant RULES_HASH =
        keccak256("evolving-sbt.signed-growth.v1:bounded32:append-correct:issuer:controller:no-migration");
    bytes32 public constant STATE_UPDATE_TYPEHASH =
        keccak256("StateUpdate(bytes32 stateRoot,bytes32 policyId,uint8 status,uint64 validUntil)");
    bytes32 public constant TRANSITION_TYPEHASH = keccak256(
        "Transition(uint256 tokenId,bytes32 namespace,uint64 expectedRevision,bytes32 expectedStateHash,uint64 sourcePolicyEpoch,uint64 targetPolicyEpoch,StateUpdate nextState,bytes32 operationsCommitment,uint64 deadline)StateUpdate(bytes32 stateRoot,bytes32 policyId,uint8 status,uint64 validUntil)"
    );

    enum Operation {
        Initialize,
        Append,
        Correct,
        Suspend,
        Resume,
        Revoke,
        Extend
    }

    struct Record {
        bytes32 claimId;
        bytes32 experienceId;
        address subject;
        bytes32 contentHash;
        uint64 validUntil;
        bytes32 replaces;
    }

    struct Evidence {
        Operation operation;
        Record record;
    }

    struct Authorization {
        bytes authoritySignature;
        bytes holderSignature;
    }

    struct NamespacePolicy {
        bytes32 policyId;
        address issuer;
        address controller;
        PolicyDefinition definition;
        PolicyStatus live;
    }

    // Every accepted record has the immutable token holder as its subject.
    struct StoredRecord {
        bytes32 claimId;
        bytes32 experienceId;
        bytes32 contentHash;
        uint64 validUntil;
        bytes32 replaces;
    }

    struct Growth {
        StoredRecord[] records;
        mapping(bytes32 => uint256) claimIndexPlusOne;
        // One bit per historical index. The two masks share one storage slot.
        uint32 superseded;
        uint32 expiring;
        mapping(bytes32 => bool) credited;
        bytes32 recordsRoot;
        bytes32 creditedActionsRoot;
    }

    uint256 private _nextTokenId = 1;
    mapping(bytes32 => NamespacePolicy) private _policies;
    mapping(uint256 => mapping(bytes32 => StateHead)) private _heads;
    mapping(uint256 => mapping(bytes32 => Growth)) private _growth;

    error Soulbound();
    error NotHolder();
    error InvalidNamespace();
    error NamespaceAlreadyRegistered();
    error UnknownPolicy();
    error InvalidAuthority();
    error NotController();
    error UpdatesDisabled();
    error EpochMismatch();
    error WrongPredecessor();
    error DeadlineExpired();
    error BadOperationsCommitment();
    error InvalidAuthorization();
    error HolderConsentRequired();
    error InvalidNextState();
    error InvalidOperation();
    error InvalidRecord();
    error WrongSubject();
    error DuplicateClaim();
    error DuplicateExperience();
    error InvalidCorrection();
    error RecordLimitReached();
    error MigrationUnsupported();
    error NamespaceTerminated();
    error InvalidValidity();

    event NamespaceRegistered(
        bytes32 indexed namespace, bytes32 indexed policyId, address issuer, address controller
    );
    event PolicyControlsChanged(
        bytes32 indexed namespace,
        bytes32 indexed policyId,
        uint64 epoch,
        bool updatesEnabled,
        bool usesEnabled
    );

    constructor(address admin)
        ERC721("Evolving SBT Reference", "ESBT")
        Ownable(admin)
        EIP712("EvolvingSBT", "1")
    { }

    /// @notice Mint to the caller. This is consent, not a proof of personhood or uniqueness.
    function mint() external nonReentrant returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);
        emit Locked(tokenId);
    }

    function burn(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotHolder();
        _burn(tokenId);
    }

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IEvolvingSBT).interfaceId || interfaceId == type(IERC5192).interfaceId
            || interfaceId == this.admissionRecords.selector || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    /// @notice Register one immutable policy for a namespace; existing policies cannot be replaced.
    function registerNamespace(
        bytes32 namespace,
        address issuer,
        address controller,
        string calldata specificationURI
    ) external onlyOwner returns (bytes32 policyId) {
        if (namespace == bytes32(0)) revert InvalidNamespace();
        if (_policies[namespace].policyId != bytes32(0)) revert NamespaceAlreadyRegistered();
        if (issuer == address(0) || controller == address(0) || issuer == controller) {
            revert InvalidAuthority();
        }
        bytes32 configHash = keccak256(abi.encode(PROFILE_ID, MAX_RECORDS, issuer, controller));
        bytes32 authHash = keccak256(abi.encode(issuer, controller));
        policyId = keccak256(
            abi.encode(
                namespace,
                SCHEMA_ID,
                RULES_HASH,
                address(this),
                configHash,
                authHash,
                keccak256(bytes(specificationURI))
            )
        );
        NamespacePolicy storage p = _policies[namespace];
        p.policyId = policyId;
        p.issuer = issuer;
        p.controller = controller;
        p.definition =
            PolicyDefinition(SCHEMA_ID, RULES_HASH, address(this), configHash, authHash, specificationURI);
        p.live = PolicyStatus(1, true, true);
        emit NamespaceRegistered(namespace, policyId, issuer, controller);
    }

    /// @notice Mutable operational controls do not change the immutable policy definition.
    function setPolicyControls(bytes32 namespace, bool updatesEnabled, bool usesEnabled) external {
        NamespacePolicy storage p = _policy(namespace);
        if (msg.sender != p.controller) revert NotController();
        if (p.live.updatesEnabled == updatesEnabled && p.live.usesEnabled == usesEnabled) return;
        p.live.epoch += 1;
        p.live.updatesEnabled = updatesEnabled;
        p.live.usesEnabled = usesEnabled;
        emit PolicyControlsChanged(namespace, p.policyId, p.live.epoch, updatesEnabled, usesEnabled);
    }

    function stateOf(uint256 tokenId, bytes32 namespace) external view returns (StateHead memory) {
        _requireOwned(tokenId);
        _policy(namespace);
        return _heads[tokenId][namespace];
    }

    function policyOf(bytes32 namespace, bytes32 policyId)
        external
        view
        returns (PolicyDefinition memory definition, PolicyStatus memory status)
    {
        NamespacePolicy storage p = _policy(namespace);
        if (p.policyId != policyId) revert UnknownPolicy();
        return (p.definition, p.live);
    }

    function policyIdOf(bytes32 namespace) external view returns (bytes32) {
        return _policy(namespace).policyId;
    }

    function hashState(StateHead memory head) public pure returns (bytes32) {
        return keccak256(abi.encode(head));
    }

    function transitionDigest(Transition memory change) public view returns (bytes32) {
        bytes32 nextHash = keccak256(
            abi.encode(
                STATE_UPDATE_TYPEHASH,
                change.nextState.stateRoot,
                change.nextState.policyId,
                change.nextState.status,
                change.nextState.validUntil
            )
        );
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TRANSITION_TYPEHASH,
                    change.tokenId,
                    change.namespace,
                    change.expectedRevision,
                    change.expectedStateHash,
                    change.sourcePolicyEpoch,
                    change.targetPolicyEpoch,
                    nextHash,
                    change.operationsCommitment,
                    change.deadline
                )
            )
        );
    }

    /// @notice Build the deterministic next root. This does not validate signatures or live controls.
    function previewTransition(
        uint256 tokenId,
        bytes32 namespace,
        Evidence memory evidence,
        NamespaceStatus status,
        uint64 validUntil
    ) public view returns (StateUpdate memory) {
        address holder = _requireOwned(tokenId);
        NamespacePolicy storage p = _policy(namespace);
        _validateOperation(tokenId, namespace, holder, evidence, status, validUntil);
        return StateUpdate(_nextRoot(tokenId, namespace, evidence), p.policyId, status, validUntil);
    }

    function applyTransition(
        Transition calldata change,
        bytes calldata evidence,
        bytes calldata authorization
    ) external nonReentrant returns (uint64 newRevision) {
        (Evidence memory operation, StateUpdate memory expected) = _checkTransition(change, evidence);
        bytes32 digest = transitionDigest(change);
        _checkAuthorization(change, operation.operation, digest, authorization);
        StateHead storage previous = _heads[change.tokenId][change.namespace];
        bytes32 previousHash = hashState(previous);
        newRevision = previous.revision + 1;
        _recordOperation(change.tokenId, change.namespace, operation);
        StateHead memory next = StateHead(
            newRevision, expected.stateRoot, expected.policyId, expected.status, expected.validUntil
        );
        _heads[change.tokenId][change.namespace] = next;
        emit StateTransitioned(
            change.tokenId,
            change.namespace,
            newRevision,
            previousHash,
            hashState(next),
            next.policyId,
            digest
        );
    }

    function _checkTransition(Transition calldata change, bytes calldata evidence)
        internal
        view
        returns (Evidence memory operation, StateUpdate memory expected)
    {
        _requireOwned(change.tokenId);
        NamespacePolicy storage p = _policy(change.namespace);
        StateHead storage previous = _heads[change.tokenId][change.namespace];
        if (change.nextState.policyId != p.policyId) revert MigrationUnsupported();
        if (change.expectedRevision != previous.revision || change.expectedStateHash != hashState(previous)) {
            revert WrongPredecessor();
        }
        if (change.deadline == 0 || block.timestamp > change.deadline) revert DeadlineExpired();
        if (!p.live.updatesEnabled) revert UpdatesDisabled();
        if (
            change.targetPolicyEpoch != p.live.epoch
                || change.sourcePolicyEpoch != (previous.revision == 0 ? 0 : p.live.epoch)
        ) revert EpochMismatch();
        if (change.operationsCommitment != keccak256(evidence)) revert BadOperationsCommitment();
        operation = abi.decode(evidence, (Evidence));
        expected = previewTransition(
            change.tokenId, change.namespace, operation, change.nextState.status, change.nextState.validUntil
        );
        if (change.nextState.stateRoot != expected.stateRoot) revert InvalidNextState();
    }

    function _checkAuthorization(
        Transition calldata change,
        Operation operation,
        bytes32 digest,
        bytes calldata authorization
    ) internal view {
        NamespacePolicy storage p = _policies[change.namespace];
        Authorization memory signatures = abi.decode(authorization, (Authorization));
        address authority =
            operation == Operation.Append || operation == Operation.Correct ? p.issuer : p.controller;
        if (!SignatureChecker.isValidSignatureNow(authority, digest, signatures.authoritySignature)) {
            revert InvalidAuthorization();
        }
        address holder = _requireOwned(change.tokenId);
        if (
            operation == Operation.Initialize && msg.sender != holder
                && !SignatureChecker.isValidSignatureNow(holder, digest, signatures.holderSignature)
        ) revert HolderConsentRequired();
    }

    function recordCount(uint256 tokenId, bytes32 namespace) external view returns (uint256) {
        _requireOwned(tokenId);
        _policy(namespace);
        return _growth[tokenId][namespace].records.length;
    }

    /// @notice Read a historical record; `active` means only that it has not been superseded.
    /// @dev Applications must separately check record expiry, namespace validity, and eligibility rules.
    function recordAt(uint256 tokenId, bytes32 namespace, uint256 index)
        external
        view
        returns (Record memory record, bool active)
    {
        address holder = _requireOwned(tokenId);
        _policy(namespace);
        Growth storage g = _growth[tokenId][namespace];
        StoredRecord storage stored = g.records[index];
        record = Record({
            claimId: stored.claimId,
            experienceId: stored.experienceId,
            subject: holder,
            contentHash: stored.contentHash,
            validUntil: stored.validUntil,
            replaces: stored.replaces
        });
        return (record, (g.superseded & _recordBit(index)) == 0);
    }

    /// @notice Read the current holder and [claimId, experienceId] pairs for a public admission check.
    /// @dev Checks the signed-growth profile only. Consumers must still check external revocations.
    ///      At most one version of any experience is current, so distinct current indices are distinct experiences.
    ///      A zero holder means the entire selection is invalid. Callers may supply indices in any order.
    ///      With includeIds=false the same checks return an empty array, saving identifier reads.
    function admissionRecords(
        uint256 tokenId,
        bytes32 namespace,
        bytes32 expectedPolicy,
        uint256[] calldata indices,
        bool includeIds
    ) external view returns (address holder, bytes32[2][] memory ids) {
        holder = _ownerOf(tokenId);
        StateHead storage head = _heads[tokenId][namespace];
        if (
            holder == address(0) || head.policyId != expectedPolicy
                || !_namespaceUsable(head, _policies[namespace]) || indices.length == 0
                || indices.length > MAX_RECORDS
        ) return (address(0), ids);

        Growth storage g = _growth[tokenId][namespace];
        uint256 count = g.records.length;
        if (indices.length > count) return (address(0), ids);
        uint32 excluded = g.superseded;
        uint32 expiring = g.expiring;
        if (includeIds) ids = new bytes32[2][](indices.length);
        for (uint256 i; i < indices.length; ++i) {
            uint256 index = indices[i];
            uint32 bit = _recordBit(index);
            if (index >= count || (excluded & bit) != 0) return (address(0), new bytes32[2][](0));
            if ((expiring & bit) != 0 && block.timestamp > g.records[index].validUntil) {
                return (address(0), new bytes32[2][](0));
            }
            // Append assigns a fresh experience; correction supersedes its single current version.
            // Every record is bound to this immutable holder at acceptance and token IDs are never reused.
            excluded |= bit;
            if (includeIds) {
                StoredRecord storage record = g.records[index];
                ids[i] = [record.claimId, record.experienceId];
            }
        }
    }

    function isCredited(uint256 tokenId, bytes32 namespace, bytes32 experienceId)
        external
        view
        returns (bool)
    {
        _requireOwned(tokenId);
        _policy(namespace);
        return _growth[tokenId][namespace].credited[experienceId];
    }

    /// @notice Namespace-level validity only. Individual record validity still needs application checks.
    function isUsable(uint256 tokenId, bytes32 namespace) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) return false;
        return _namespaceUsable(_heads[tokenId][namespace], _policy(namespace));
    }

    function _namespaceUsable(StateHead storage h, NamespacePolicy storage p) private view returns (bool) {
        return p.live.usesEnabled && h.status == NamespaceStatus.Active
            && (h.validUntil == 0 || block.timestamp <= h.validUntil);
    }

    /// @dev MAX_RECORDS bounds every stored index. An index beyond the 32-bit range yields zero.
    function _recordBit(uint256 index) private pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(uint256(1) << index);
    }

    function hashRecord(Record memory record) public pure returns (bytes32) {
        return keccak256(abi.encode(record));
    }

    function _policy(bytes32 namespace) internal view returns (NamespacePolicy storage p) {
        p = _policies[namespace];
        if (p.policyId == bytes32(0)) revert UnknownPolicy();
    }

    function _validateOperation(
        uint256 tokenId,
        bytes32 namespace,
        address holder,
        Evidence memory evidence,
        NamespaceStatus status,
        uint64 validUntil
    ) internal view {
        StateHead storage h = _heads[tokenId][namespace];
        Operation op = evidence.operation;
        if (h.status == NamespaceStatus.Revoked) revert NamespaceTerminated();
        if (op == Operation.Initialize) {
            if (h.revision != 0 || status != NamespaceStatus.Active) revert InvalidOperation();
            if (validUntil != 0 && validUntil <= block.timestamp) revert InvalidValidity();
        } else {
            if (h.revision == 0) revert InvalidOperation();
            if (op == Operation.Append || op == Operation.Correct) {
                if (h.status != NamespaceStatus.Active || status != h.status || validUntil != h.validUntil) {
                    revert InvalidOperation();
                }
                _validateRecord(tokenId, namespace, holder, evidence);
                return;
            }
            if (op == Operation.Suspend) {
                if (h.status != NamespaceStatus.Active || status != NamespaceStatus.Suspended) {
                    revert InvalidOperation();
                }
            } else if (op == Operation.Resume) {
                if (h.status != NamespaceStatus.Suspended || status != NamespaceStatus.Active) {
                    revert InvalidOperation();
                }
            } else if (op == Operation.Revoke) {
                if (status != NamespaceStatus.Revoked) revert InvalidOperation();
            } else if (op == Operation.Extend) {
                if (
                    status != h.status || h.validUntil == 0 || validUntil == 0 || validUntil <= h.validUntil
                        || validUntil <= block.timestamp
                ) revert InvalidValidity();
            } else {
                revert InvalidOperation();
            }
            if (op != Operation.Extend && validUntil != h.validUntil) revert InvalidValidity();
        }
        // Lifecycle operations cannot smuggle arbitrary claim material into their commitment.
        Record memory empty;
        if (hashRecord(evidence.record) != hashRecord(empty)) revert InvalidRecord();
    }

    function _validateRecord(uint256 tokenId, bytes32 namespace, address holder, Evidence memory evidence)
        internal
        view
    {
        Record memory r = evidence.record;
        Growth storage g = _growth[tokenId][namespace];
        if (g.records.length >= MAX_RECORDS) revert RecordLimitReached();
        if (r.claimId == bytes32(0) || r.experienceId == bytes32(0) || r.contentHash == bytes32(0)) {
            revert InvalidRecord();
        }
        if (r.subject != holder) revert WrongSubject();
        if (g.claimIndexPlusOne[r.claimId] != 0) revert DuplicateClaim();
        if (evidence.operation == Operation.Append) {
            if (r.replaces != bytes32(0)) revert InvalidRecord();
            if (g.credited[r.experienceId]) revert DuplicateExperience();
        } else {
            uint256 oldIndex = g.claimIndexPlusOne[r.replaces];
            if (
                oldIndex == 0 || (g.superseded & _recordBit(oldIndex - 1)) != 0
                    || g.records[oldIndex - 1].experienceId != r.experienceId
            ) revert InvalidCorrection();
        }
    }

    function _nextRoot(uint256 tokenId, bytes32 namespace, Evidence memory evidence)
        internal
        view
        returns (bytes32)
    {
        Growth storage g = _growth[tokenId][namespace];
        bytes32 recordsRoot = g.recordsRoot;
        bytes32 actionsRoot = g.creditedActionsRoot;
        uint64 count = uint64(g.records.length);
        bool adds = evidence.operation == Operation.Append || evidence.operation == Operation.Correct;
        if (adds) {
            recordsRoot = keccak256(abi.encode(recordsRoot, hashRecord(evidence.record)));
            ++count;
            if (evidence.operation == Operation.Append) {
                actionsRoot = keccak256(abi.encode(actionsRoot, evidence.record.experienceId));
            }
        }
        bytes32 statuses;
        uint32 superseded = g.superseded;
        for (uint256 i; i < g.records.length; ++i) {
            bytes32 id = g.records[i].claimId;
            bool active = (superseded & _recordBit(i)) == 0
                && !(evidence.operation == Operation.Correct && evidence.record.replaces == id);
            statuses = keccak256(abi.encode(statuses, id, active));
        }
        if (adds) statuses = keccak256(abi.encode(statuses, evidence.record.claimId, true));
        return keccak256(abi.encode(PROFILE_ID, recordsRoot, count, statuses, actionsRoot));
    }

    function _recordOperation(uint256 tokenId, bytes32 namespace, Evidence memory evidence) internal {
        if (evidence.operation != Operation.Append && evidence.operation != Operation.Correct) return;
        Growth storage g = _growth[tokenId][namespace];
        Record memory r = evidence.record;
        if (evidence.operation == Operation.Correct) {
            g.superseded |= _recordBit(g.claimIndexPlusOne[r.replaces] - 1);
        } else {
            g.credited[r.experienceId] = true;
            g.creditedActionsRoot = keccak256(abi.encode(g.creditedActionsRoot, r.experienceId));
        }
        if (r.validUntil != 0) g.expiring |= _recordBit(g.records.length);
        g.records
            .push(
                StoredRecord({
                    claimId: r.claimId,
                    experienceId: r.experienceId,
                    contentHash: r.contentHash,
                    validUntil: r.validUntil,
                    replaces: r.replaces
                })
            );
        g.claimIndexPlusOne[r.claimId] = g.records.length;
        g.recordsRoot = keccak256(abi.encode(g.recordsRoot, hashRecord(r)));
    }
}
