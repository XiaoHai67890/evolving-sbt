// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console2 } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { Demo } from "./Demo.s.sol";
import { EvolvingSBT } from "../src/EvolvingSBT.sol";
import { IEvolvingSBT } from "../src/interfaces/IEvolvingSBT.sol";
import { ContributionRevocationRegistry } from "../src/ContributionRevocationRegistry.sol";
import { ContributionAdmission } from "../src/ContributionAdmission.sol";

/// @notice Run locally with `forge script script/DemoV02.s.sol:DemoV02`.
contract DemoV02 is Demo {
    bytes32 internal constant A = keccak256("community/docs-review");
    bytes32 internal constant B = keccak256("community/organize-workshop");
    address internal constant VERSION_REVOKER = address(0xDE1E);
    uint256 internal constant GATE_KEY = 0x6A7E;

    ContributionRevocationRegistry internal registry;
    ContributionAdmission internal conference;
    ContributionAdmission internal workshop;

    function run() external override returns (EvolvingSBT) {
        console2.log("v0.2 local simulation | public records | no broadcasting");
        _setUpActivities();
        _addAndCorrectContributions();
        uint256 count = sbt.recordCount(tokenId, COMMUNITY);
        uint256[] memory both = _pair(count - 1);
        vm.prank(vm.addr(COMMUNITY_CONTROLLER_KEY));
        sbt.setPolicyControls(COMMUNITY, false, true);
        (, IEvolvingSBT.PolicyStatus memory controls) = sbt.policyOf(COMMUNITY, sbt.policyIdOf(COMMUNITY));
        require(!controls.updatesEnabled && controls.usesEnabled, "unexpected policy controls");
        require(count == 32 && conference.eligible(tokenId, both), "morning preview should pass");
        require(!conference.consumed(holder) && !workshop.consumed(holder), "preview consumed admission");
        console2.log("Morning preview: 32 history entries, 2 distinct contributions, conference eligible.");
        console2.log("Updates paused; policy use remains enabled. Neither admission has been consumed.");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3 hours);
        _withdrawB(both);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3 hours);
        _tryBothEntrances(both);
        return sbt;
    }

    function _setUpActivities() internal {
        address issuer = vm.addr(COMMUNITY_ISSUER_KEY);
        address controller = vm.addr(COMMUNITY_CONTROLLER_KEY);
        holder = vm.addr(HOLDER_KEY);
        address admin = vm.addr(ADMIN_KEY);
        sbt = new EvolvingSBT(admin);
        vm.prank(admin);
        bytes32 policyId = sbt.registerNamespace(COMMUNITY, issuer, controller, "ipfs://example-community-v1");
        registry = new ContributionRevocationRegistry(sbt, COMMUNITY, policyId, issuer, controller);
        vm.startPrank(issuer);
        registry.activate();
        registry.setClaimRevoker(VERSION_REVOKER, true);
        vm.stopPrank();
        bytes32 benefit = keccak256("admission");
        address gateSigner = vm.addr(GATE_KEY);
        conference = new ContributionAdmission(registry, keccak256("conference"), benefit, 2, gateSigner);
        workshop = new ContributionAdmission(registry, keccak256("workshop"), benefit, 1, gateSigner);
        vm.prank(holder);
        tokenId = sbt.mint();
        EvolvingSBT.Record memory empty;
        _advance(COMMUNITY, EvolvingSBT.Operation.Initialize, empty, COMMUNITY_CONTROLLER_KEY);
        console2.log("Issuer activated the registry and delegated claim-only revocation.");
    }

    function _addAndCorrectContributions() internal {
        _accept(EvolvingSBT.Operation.Append, _record(A, 1, bytes32(0)));
        EvolvingSBT.Record memory previous = _record(B, 1, bytes32(0));
        _accept(EvolvingSBT.Operation.Append, previous);
        require(conference.eligible(tokenId, _pair(1)), "A and B should initially qualify");
        uint256 limit = sbt.MAX_RECORDS();
        // With A at index 0, B's version number equals its record index.
        for (uint256 version = 2; version < limit; ++version) {
            vm.prank(VERSION_REVOKER);
            registry.revoke(
                tokenId, version - 1, ContributionRevocationRegistry.Target.Claim, previous.claimId
            );
            if (version == 2) {
                require(!conference.eligible(tokenId, _pair(1)), "B's withdrawn version still qualifies");
                require(workshop.eligible(tokenId, _onlyA()), "A should remain usable");
                console2.log("Claim revoker withdrew B1: A qualifies alone, conference no longer eligible.");
            }
            EvolvingSBT.Record memory replacement = _record(B, version, previous.claimId);
            _accept(EvolvingSBT.Operation.Correct, replacement);
            if (version == 2) {
                require(conference.eligible(tokenId, _pair(2)), "B's valid replacement should qualify");
                require(!conference.eligible(tokenId, _pair(1)), "superseded B1 still usable");
                console2.log("Issuer corrected B1 to B2: 3 historical entries, A and B count once each.");
            }
            previous = replacement;
        }
        EvolvingSBT.Evidence memory overflow =
            EvolvingSBT.Evidence(EvolvingSBT.Operation.Correct, _record(B, limit, previous.claimId));
        _expectFailure(
            holder,
            address(sbt),
            abi.encodeCall(
                sbt.previewTransition, (tokenId, COMMUNITY, overflow, IEvolvingSBT.NamespaceStatus.Active, 0)
            ),
            EvolvingSBT.RecordLimitReached.selector
        );
        console2.log("Capacity reached: the SBT rejects another correction before updates are paused.");
    }

    function _withdrawB(uint256[] memory both) internal {
        uint256 bIndex = both[1];
        IEvolvingSBT.StateHead memory beforeHead = sbt.stateOf(tokenId, COMMUNITY);
        bytes memory withdrawB = abi.encodeCall(
            registry.revoke, (tokenId, bIndex, ContributionRevocationRegistry.Target.Experience, B)
        );
        _expectFailure(
            VERSION_REVOKER,
            address(registry),
            withdrawB,
            ContributionRevocationRegistry.Unauthorized.selector
        );
        console2.log("Claim-only revoker denied permission to withdraw B as an entire experience.");

        address issuer = vm.addr(COMMUNITY_ISSUER_KEY);
        vm.prank(issuer);
        registry.setClaimRevoker(VERSION_REVOKER, false);
        (EvolvingSBT.Record memory recordA,) = sbt.recordAt(tokenId, COMMUNITY, 0);
        _expectFailure(
            VERSION_REVOKER,
            address(registry),
            abi.encodeCall(
                registry.revoke, (tokenId, 0, ContributionRevocationRegistry.Target.Claim, recordA.claimId)
            ),
            ContributionRevocationRegistry.Unauthorized.selector
        );
        console2.log("Issuer removed the delegate; its subsequent request to withdraw claim A was denied.");

        vm.prank(issuer);
        registry.revoke(tokenId, bIndex, ContributionRevocationRegistry.Target.Experience, B);
        (bool withdrawn, uint256 atBlock) =
            registry.revocationOf(tokenId, ContributionRevocationRegistry.Target.Experience, B);
        require(withdrawn && atBlock == block.number, "B withdrawal missing");
        IEvolvingSBT.StateHead memory afterHead = sbt.stateOf(tokenId, COMMUNITY);
        require(sbt.hashState(beforeHead) == sbt.hashState(afterHead), "withdrawal changed the SBT head");
        require(afterHead.revision == 33 && sbt.recordCount(tokenId, COMMUNITY) == 32, "history changed");
        (EvolvingSBT.Record memory originalB, bool originalCurrent) = sbt.recordAt(tokenId, COMMUNITY, 1);
        (EvolvingSBT.Record memory latestB, bool latestCurrent) = sbt.recordAt(tokenId, COMMUNITY, bIndex);
        require(originalB.experienceId == B && !originalCurrent, "original B history lost");
        require(
            latestB.experienceId == B && latestCurrent && sbt.isCredited(tokenId, COMMUNITY, B),
            "latest B history lost"
        );
        require(
            !conference.eligible(tokenId, both) && workshop.eligible(tokenId, _onlyA()),
            "wrong current qualification"
        );
        console2.log("Issuer withdrew experience B without the holder. A remains usable.");
        console2.log(
            "History 32 -> 32; revision 33 -> 33; state root unchanged; usable contributions 2 -> 1."
        );
    }

    function _tryBothEntrances(uint256[] memory both) internal {
        (ContributionAdmission.Session memory session, bytes memory signature) =
            _gateSession(conference, keccak256("main entrance"), keccak256("conference visit"));
        _expectFailure(
            holder,
            address(conference),
            abi.encodeCall(conference.redeem, (tokenId, both, session, signature)),
            ContributionAdmission.Ineligible.selector
        );
        require(
            !conference.consumed(holder) && !conference.usedSessions(session.nonce),
            "failed attempt consumed state"
        );
        console2.log("Conference refused the morning evidence; its session and admission remain unspent.");

        uint256[] memory onlyA = _onlyA();
        (session, signature) =
            _gateSession(workshop, keccak256("north entrance"), keccak256("workshop visit 1"));
        vm.recordLogs();
        vm.prank(holder);
        workshop.redeem(tokenId, onlyA, session, signature);
        _verifyAdmissionEvent(session);
        require(
            workshop.consumed(holder) && workshop.usedSessions(session.nonce), "workshop admission missing"
        );
        console2.log(
            "Workshop north entrance matched its admission event; session and account admission consumed."
        );

        (session, signature) =
            _gateSession(workshop, keccak256("south entrance"), keccak256("workshop visit 2"));
        _expectFailure(
            holder,
            address(workshop),
            abi.encodeCall(workshop.redeem, (tokenId, onlyA, session, signature)),
            ContributionAdmission.AlreadyConsumed.selector
        );
        require(
            workshop.eligible(tokenId, onlyA) && !workshop.usedSessions(session.nonce),
            "second attempt changed qualification or session"
        );
        console2.log(
            "Workshop south entrance rejected a fresh session: A still qualifies, admission already used."
        );
    }

    function _verifyAdmissionEvent(ContributionAdmission.Session memory session) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "expected one admission event");
        Vm.Log memory admission = logs[0];
        require(
            admission.emitter == address(workshop) && admission.topics.length == 4
                && admission.topics[0] == ContributionAdmission.Admitted.selector
                && admission.topics[1] == bytes32(uint256(uint160(holder)))
                && admission.topics[2] == session.entranceId
                && admission.topics[3] == workshop.sessionDigest(session)
                && abi.decode(admission.data, (uint256)) == tokenId,
            "admission event does not match north entrance session"
        );
    }

    function _record(bytes32 experience, uint256 version, bytes32 replaces)
        internal
        view
        returns (EvolvingSBT.Record memory)
    {
        return EvolvingSBT.Record({
            claimId: keccak256(abi.encode(experience, version)),
            experienceId: experience,
            subject: holder,
            contentHash: keccak256(abi.encode("recognized contribution", experience, version)),
            validUntil: 0,
            replaces: replaces
        });
    }

    function _accept(EvolvingSBT.Operation operation, EvolvingSBT.Record memory record) internal {
        _advance(COMMUNITY, operation, record, COMMUNITY_ISSUER_KEY);
    }

    function _pair(uint256 bIndex) internal pure returns (uint256[] memory indices) {
        indices = new uint256[](2);
        indices[1] = bIndex;
    }

    function _onlyA() internal pure returns (uint256[] memory) {
        // A is the record at index zero.
        return new uint256[](1);
    }

    function _gateSession(ContributionAdmission gate, bytes32 entrance, bytes32 nonce)
        internal
        view
        returns (ContributionAdmission.Session memory session, bytes memory signature)
    {
        session = ContributionAdmission.Session(holder, entrance, nonce, uint64(block.timestamp + 5 minutes));
        signature = _sign(GATE_KEY, gate.sessionDigest(session));
    }

    function _expectFailure(address sender, address target, bytes memory callData, bytes4 selector) internal {
        vm.prank(sender);
        (bool success, bytes memory reason) = target.call(callData);
        require(
            !success && keccak256(reason) == keccak256(abi.encodeWithSelector(selector)),
            "unexpected call result"
        );
    }
}
