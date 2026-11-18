// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { EvolvingSBT } from "../../src/EvolvingSBT.sol";
import { IEvolvingSBT } from "../../src/interfaces/IEvolvingSBT.sol";
import { ContributionRevocationRegistry } from "../../src/ContributionRevocationRegistry.sol";

/// @dev Exercises the public modules against a real credential with signed growth transitions.
abstract contract V02Fixture is Test {
    uint256 internal constant HOLDER_KEY = 0xA11CE;
    uint256 internal constant ISSUER_KEY = 0xB0B;
    uint256 internal constant CONTROLLER_KEY = 0xCA11;
    bytes32 internal constant NS = keccak256("community.contributions");

    EvolvingSBT internal sbt;
    ContributionRevocationRegistry internal registry;
    address internal holder;
    address internal issuer;
    address internal controller;
    bytes32 internal policy;
    uint256 internal token;

    function setUp() public virtual {
        holder = vm.addr(HOLDER_KEY);
        issuer = vm.addr(ISSUER_KEY);
        controller = vm.addr(CONTROLLER_KEY);
        sbt = new EvolvingSBT(address(this));
        policy = sbt.registerNamespace(NS, issuer, controller, "ipfs://community-profile-v1");
        registry = new ContributionRevocationRegistry(sbt, NS, policy, issuer, controller);
        vm.prank(issuer);
        registry.activate();
        token = _mintInitialized();
    }

    function _mintInitialized() internal returns (uint256 tokenId) {
        vm.prank(holder);
        tokenId = sbt.mint();
        EvolvingSBT.Record memory empty;
        _transitionFor(
            tokenId, EvolvingSBT.Operation.Initialize, empty, IEvolvingSBT.NamespaceStatus.Active, 0
        );
    }

    function _record(uint256 id) internal view returns (EvolvingSBT.Record memory record) {
        record.claimId = keccak256(abi.encode("claim", id));
        record.experienceId = keccak256(abi.encode("experience", id));
        record.subject = holder;
        record.contentHash = keccak256(abi.encode("content", id));
    }

    function _append(uint256 id) internal returns (EvolvingSBT.Record memory record) {
        record = _record(id);
        IEvolvingSBT.StateHead memory head = sbt.stateOf(token, NS);
        _transition(EvolvingSBT.Operation.Append, record, head.status, head.validUntil);
    }

    function _correct(EvolvingSBT.Record memory prior, uint256 newId)
        internal
        returns (EvolvingSBT.Record memory record)
    {
        record = _record(newId);
        record.experienceId = prior.experienceId;
        record.replaces = prior.claimId;
        IEvolvingSBT.StateHead memory head = sbt.stateOf(token, NS);
        _transition(EvolvingSBT.Operation.Correct, record, head.status, head.validUntil);
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _transition(
        EvolvingSBT.Operation operation,
        EvolvingSBT.Record memory record,
        IEvolvingSBT.NamespaceStatus status,
        uint64 namespaceExpiry
    ) internal {
        _transitionFor(token, operation, record, status, namespaceExpiry);
    }

    function _transitionFor(
        uint256 tokenId,
        EvolvingSBT.Operation operation,
        EvolvingSBT.Record memory record,
        IEvolvingSBT.NamespaceStatus status,
        uint64 namespaceExpiry
    ) internal {
        IEvolvingSBT.StateHead memory head = sbt.stateOf(tokenId, NS);
        (, IEvolvingSBT.PolicyStatus memory controls) = sbt.policyOf(NS, policy);
        EvolvingSBT.Evidence memory evidence = EvolvingSBT.Evidence(operation, record);
        bytes memory data = abi.encode(evidence);
        IEvolvingSBT.Transition memory change = IEvolvingSBT.Transition({
            tokenId: tokenId,
            namespace: NS,
            expectedRevision: head.revision,
            expectedStateHash: sbt.hashState(head),
            sourcePolicyEpoch: head.revision == 0 ? 0 : controls.epoch,
            targetPolicyEpoch: controls.epoch,
            nextState: sbt.previewTransition(tokenId, NS, evidence, status, namespaceExpiry),
            operationsCommitment: keccak256(data),
            deadline: uint64(block.timestamp + 1 hours)
        });
        uint256 key = operation == EvolvingSBT.Operation.Append || operation == EvolvingSBT.Operation.Correct
            ? ISSUER_KEY
            : CONTROLLER_KEY;
        bytes memory auth = abi.encode(EvolvingSBT.Authorization(_sig(key, sbt.transitionDigest(change)), ""));
        vm.prank(holder);
        sbt.applyTransition(change, data, auth);
    }
}
