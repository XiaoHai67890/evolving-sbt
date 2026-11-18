// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { EvolvingSBT } from "../src/EvolvingSBT.sol";
import { IEvolvingSBT } from "../src/interfaces/IEvolvingSBT.sol";

/// @notice Local simulation only: `forge script script/Demo.s.sol:Demo`.
/// @dev There is deliberately no broadcast call. These public example keys must never hold assets.
contract Demo is Script {
    uint256 internal constant ADMIN_KEY = 0xAD11;
    uint256 internal constant HOLDER_KEY = 0xA11CE;
    uint256 internal constant COMMUNITY_ISSUER_KEY = 0xB0B;
    uint256 internal constant COMMUNITY_CONTROLLER_KEY = 0xCA11;
    uint256 internal constant EDUCATION_ISSUER_KEY = 0xB0B2;
    uint256 internal constant EDUCATION_CONTROLLER_KEY = 0xCA112;
    bytes32 internal constant COMMUNITY = keccak256("community.contributions");
    bytes32 internal constant EDUCATION = keccak256("education.qualifications");

    EvolvingSBT internal sbt;
    uint256 internal tokenId;
    address internal holder;

    function run() external virtual returns (EvolvingSBT deployed) {
        holder = vm.addr(HOLDER_KEY);
        address admin = vm.addr(ADMIN_KEY);
        sbt = new EvolvingSBT(admin);
        vm.startPrank(admin);
        sbt.registerNamespace(
            COMMUNITY,
            vm.addr(COMMUNITY_ISSUER_KEY),
            vm.addr(COMMUNITY_CONTROLLER_KEY),
            "ipfs://example-community-profile-v1"
        );
        sbt.registerNamespace(
            EDUCATION,
            vm.addr(EDUCATION_ISSUER_KEY),
            vm.addr(EDUCATION_CONTROLLER_KEY),
            "ipfs://example-education-profile-v1"
        );
        vm.stopPrank();
        vm.prank(holder);
        tokenId = sbt.mint();
        EvolvingSBT.Record memory empty;
        _advance(COMMUNITY, EvolvingSBT.Operation.Initialize, empty, COMMUNITY_CONTROLLER_KEY);
        _advance(EDUCATION, EvolvingSBT.Operation.Initialize, empty, EDUCATION_CONTROLLER_KEY);

        EvolvingSBT.Record memory contribution = EvolvingSBT.Record({
            claimId: keccak256("contribution-claim-v1"),
            experienceId: keccak256("community-task-42"),
            subject: holder,
            contentHash: keccak256("task-42: completed documentation review"),
            validUntil: 0,
            replaces: bytes32(0)
        });
        _advance(COMMUNITY, EvolvingSBT.Operation.Append, contribution, COMMUNITY_ISSUER_KEY);
        EvolvingSBT.Record memory qualification = EvolvingSBT.Record({
            claimId: keccak256("qualification-claim-v1"),
            experienceId: keccak256("course-completion-7"),
            subject: holder,
            contentHash: keccak256("course-7: completed"),
            validUntil: 0,
            replaces: bytes32(0)
        });
        _advance(EDUCATION, EvolvingSBT.Operation.Append, qualification, EDUCATION_ISSUER_KEY);
        bytes32 educationBefore = sbt.hashState(sbt.stateOf(tokenId, EDUCATION));

        EvolvingSBT.Record memory correction = EvolvingSBT.Record({
            claimId: keccak256("contribution-claim-v2"),
            experienceId: contribution.experienceId,
            subject: holder,
            contentHash: keccak256("task-42: completed documentation review and translation"),
            validUntil: 0,
            replaces: contribution.claimId
        });
        _advance(COMMUNITY, EvolvingSBT.Operation.Correct, correction, COMMUNITY_ISSUER_KEY);
        require(sbt.hashState(sbt.stateOf(tokenId, EDUCATION)) == educationBefore, "namespace changed");

        EvolvingSBT.Record memory duplicate = EvolvingSBT.Record({
            claimId: keccak256("attempted-second-credit"),
            experienceId: contribution.experienceId,
            subject: holder,
            contentHash: contribution.contentHash,
            validUntil: 0,
            replaces: bytes32(0)
        });
        EvolvingSBT.Evidence memory duplicateEvidence =
            EvolvingSBT.Evidence(EvolvingSBT.Operation.Append, duplicate);
        try sbt.previewTransition(
            tokenId, COMMUNITY, duplicateEvidence, IEvolvingSBT.NamespaceStatus.Active, 0
        ) returns (
            IEvolvingSBT.StateUpdate memory
        ) {
            revert("duplicate experience unexpectedly accepted");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(EvolvingSBT.DuplicateExperience.selector)),
                "unexpected rejection"
            );
            console2.log("Duplicate experience rejected: one experience cannot earn a second credit.");
        }

        console2.log("LOCAL SIMULATION ONLY: no transactions are broadcast.");
        console2.log(
            "Transparent signed-issuer profile; this demo does not prove external chain history or use ZK."
        );
        console2.log("SBT contract", address(sbt));
        console2.log("Holder", holder);
        console2.log("Token ID", tokenId);
        console2.log("Permanently locked", sbt.locked(tokenId));
        _printHead("Community", COMMUNITY);
        _printHead("Education", EDUCATION);
        (, bool originalActive) = sbt.recordAt(tokenId, COMMUNITY, 0);
        (, bool replacementActive) = sbt.recordAt(tokenId, COMMUNITY, 1);
        console2.log("Original community claim is not superseded", originalActive);
        console2.log("Replacement community claim is not superseded", replacementActive);
        console2.log(
            "Original experience remains credited",
            sbt.isCredited(tokenId, COMMUNITY, contribution.experienceId)
        );
        return sbt;
    }

    function _advance(
        bytes32 namespace,
        EvolvingSBT.Operation operation,
        EvolvingSBT.Record memory record,
        uint256 key
    ) internal {
        IEvolvingSBT.StateHead memory head = sbt.stateOf(tokenId, namespace);
        bytes32 policyId = sbt.policyIdOf(namespace);
        (, IEvolvingSBT.PolicyStatus memory controls) = sbt.policyOf(namespace, policyId);
        EvolvingSBT.Evidence memory decoded = EvolvingSBT.Evidence(operation, record);
        bytes memory evidence = abi.encode(decoded);
        IEvolvingSBT.Transition memory change = IEvolvingSBT.Transition({
            tokenId: tokenId,
            namespace: namespace,
            expectedRevision: head.revision,
            expectedStateHash: sbt.hashState(head),
            sourcePolicyEpoch: head.revision == 0 ? 0 : controls.epoch,
            targetPolicyEpoch: controls.epoch,
            nextState: sbt.previewTransition(
                tokenId, namespace, decoded, IEvolvingSBT.NamespaceStatus.Active, 0
            ),
            operationsCommitment: keccak256(evidence),
            deadline: uint64(block.timestamp + 1 hours)
        });
        bytes32 digest = sbt.transitionDigest(change);
        bytes memory authorization = abi.encode(
            EvolvingSBT.Authorization({
                authoritySignature: _sign(key, digest),
                holderSignature: head.revision == 0 ? _sign(HOLDER_KEY, digest) : bytes("")
            })
        );
        // A relayer submits; controller/issuer authority and holder consent come from signatures.
        vm.prank(address(0xBEEF));
        sbt.applyTransition(change, evidence, authorization);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _printHead(string memory label, bytes32 namespace) internal view {
        IEvolvingSBT.StateHead memory head = sbt.stateOf(tokenId, namespace);
        console2.log(label);
        console2.log("  Revision", head.revision);
        console2.log("  Historical record count", sbt.recordCount(tokenId, namespace));
        console2.log("  Namespace usable", sbt.isUsable(tokenId, namespace));
        console2.log("  State root");
        console2.logBytes32(head.stateRoot);
    }
}
