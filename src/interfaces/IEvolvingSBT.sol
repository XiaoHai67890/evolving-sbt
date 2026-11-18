// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Proposed core interface for ERC-8498, Namespaced State Transitions for SBTs.
interface IEvolvingSBT {
    enum NamespaceStatus {
        Uninitialized,
        Active,
        Suspended,
        Revoked
    }

    struct StateHead {
        uint64 revision;
        bytes32 stateRoot;
        bytes32 policyId;
        NamespaceStatus status;
        uint64 validUntil;
    }

    struct PolicyDefinition {
        bytes32 schemaId;
        bytes32 rulesHash;
        address verifier;
        bytes32 verifierConfigHash;
        bytes32 authorizationHash;
        string specificationURI;
    }

    struct PolicyStatus {
        uint64 epoch;
        bool updatesEnabled;
        bool usesEnabled;
    }

    struct StateUpdate {
        bytes32 stateRoot;
        bytes32 policyId;
        NamespaceStatus status;
        uint64 validUntil;
    }

    struct Transition {
        uint256 tokenId;
        bytes32 namespace;

        uint64 expectedRevision;
        bytes32 expectedStateHash;

        uint64 sourcePolicyEpoch;
        uint64 targetPolicyEpoch;

        StateUpdate nextState;

        bytes32 operationsCommitment;
        uint64 deadline;
    }

    function stateOf(uint256 tokenId, bytes32 namespace) external view returns (StateHead memory);

    function policyOf(bytes32 namespace, bytes32 policyId)
        external
        view
        returns (PolicyDefinition memory definition, PolicyStatus memory status);

    function applyTransition(
        Transition calldata change,
        bytes calldata evidence,
        bytes calldata authorization
    ) external returns (uint64 newRevision);

    event StateTransitioned(
        uint256 indexed tokenId,
        bytes32 indexed namespace,
        uint64 revision,
        bytes32 previousStateHash,
        bytes32 nextStateHash,
        bytes32 policyId,
        bytes32 transitionId
    );
}
