// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ContributionAdmission } from "../src/ContributionAdmission.sol";
import { ContributionRevocationRegistry } from "../src/ContributionRevocationRegistry.sol";
import { EvolvingSBT } from "../src/EvolvingSBT.sol";
import { IEvolvingSBT } from "../src/interfaces/IEvolvingSBT.sol";
import { Mock1271Wallet } from "./helpers/TestWallets.sol";
import { V02Fixture } from "./helpers/V02Fixture.sol";

abstract contract AdmissionFixture is V02Fixture {
    uint256 internal constant GATE_KEY = 0x6A7E;
    bytes32 internal constant EVENT = keccak256("conference");
    bytes32 internal constant BENEFIT = keccak256("admission");

    function _gate(bytes32 eventId, uint8 threshold) internal returns (ContributionAdmission) {
        return new ContributionAdmission(registry, eventId, BENEFIT, threshold, vm.addr(GATE_KEY));
    }

    function _indices(uint256 count) internal pure returns (uint256[] memory indices) {
        indices = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            indices[i] = i;
        }
    }

    function _session(uint256 nonce) internal view returns (ContributionAdmission.Session memory) {
        return ContributionAdmission.Session(
            holder, keccak256("east entrance"), bytes32(nonce), uint64(block.timestamp + 120)
        );
    }

    function _redeem(
        ContributionAdmission gate,
        uint256[] memory indices,
        ContributionAdmission.Session memory ticket
    ) internal {
        bytes memory signature = _sig(GATE_KEY, gate.sessionDigest(ticket));
        vm.prank(holder);
        gate.redeem(token, indices, ticket, signature);
    }
}

contract ContributionAdmissionTest is AdmissionFixture {
    ContributionAdmission internal conference;
    ContributionAdmission internal workshop;

    function setUp() public override {
        super.setUp();
        conference = _gate(EVENT, 2);
        workshop = _gate(keccak256("workshop"), 1);
    }

    function testApplicationPinsActivatedRegistryAndBoundedThreshold() public {
        ContributionRevocationRegistry inactive =
            new ContributionRevocationRegistry(sbt, NS, policy, issuer, controller);
        address signer = vm.addr(GATE_KEY);
        vm.expectRevert(ContributionAdmission.InvalidConfiguration.selector);
        new ContributionAdmission(inactive, EVENT, BENEFIT, 1, signer);
        vm.expectRevert(ContributionAdmission.InvalidConfiguration.selector);
        new ContributionAdmission(registry, EVENT, BENEFIT, 0, signer);
        vm.expectRevert(ContributionAdmission.InvalidConfiguration.selector);
        new ContributionAdmission(registry, EVENT, BENEFIT, 33, signer);
    }

    function testOnlyTheRegistrySelectedByThisGateControlsEligibility() public {
        EvolvingSBT.Record memory a = _append(1);
        ContributionRevocationRegistry other =
            new ContributionRevocationRegistry(sbt, NS, policy, issuer, controller);
        vm.startPrank(issuer);
        other.activate();
        other.revoke(token, 0, ContributionRevocationRegistry.Target.Experience, a.experienceId);
        vm.stopPrank();
        uint256[] memory selected = _indices(1);
        assertTrue(workshop.eligible(token, selected));
        ContributionAdmission otherEvent =
            new ContributionAdmission(other, EVENT, BENEFIT, 1, vm.addr(GATE_KEY));
        assertFalse(otherEvent.eligible(token, selected));
    }

    function testPublicQualificationValidatesAllSelectedRecordsAndDistinctExperiences() public {
        _append(1);
        _append(2);
        assertTrue(conference.eligible(token, _indices(2)));
        assertFalse(conference.eligible(token, _indices(1)));
        assertFalse(workshop.eligible(token, _indices(0)));
        assertFalse(workshop.eligible(token, _indices(3)));
        assertFalse(workshop.eligible(token, _indices(33)));
        assertFalse(workshop.eligible(type(uint256).max, _indices(1)));
        uint256[] memory reversed = _indices(2);
        reversed[0] = 1;
        reversed[1] = 0;
        assertTrue(conference.eligible(token, reversed));
        reversed[1] = 1;
        assertFalse(conference.eligible(token, reversed));
    }

    function testCorrectionAndExperienceRevocationCoverFutureVersions() public {
        _append(1);
        EvolvingSBT.Record memory original = _append(2);
        vm.prank(issuer);
        registry.revoke(token, 1, ContributionRevocationRegistry.Target.Claim, original.claimId);
        assertFalse(conference.eligible(token, _indices(2)));
        EvolvingSBT.Record memory revised = _correct(original, 3);
        uint256[] memory selected = _indices(2);
        selected[1] = 2;
        assertTrue(conference.eligible(token, selected));
        vm.prank(issuer);
        registry.revoke(token, 1, ContributionRevocationRegistry.Target.Experience, original.experienceId);
        _correct(revised, 4);
        selected[1] = 3;
        assertFalse(conference.eligible(token, selected));
        assertTrue(workshop.eligible(token, _indices(1)));
    }

    function testSupersessionAloneExcludesAnOldClaim() public {
        EvolvingSBT.Record memory original = _append(1);
        _correct(original, 2);
        uint256[] memory selected = _indices(1);
        assertFalse(workshop.eligible(token, selected));
        selected[0] = 1;
        assertTrue(workshop.eligible(token, selected));
    }

    function testNamespaceAndRecordValidityAtInclusiveExpiry() public {
        uint64 expiry = uint64(block.timestamp + 60);
        vm.prank(holder);
        token = sbt.mint();
        EvolvingSBT.Record memory empty;
        _transition(EvolvingSBT.Operation.Initialize, empty, IEvolvingSBT.NamespaceStatus.Active, expiry + 1);
        EvolvingSBT.Record memory finite = _record(1);
        finite.validUntil = expiry;
        _transition(EvolvingSBT.Operation.Append, finite, IEvolvingSBT.NamespaceStatus.Active, expiry + 1);
        _transition(EvolvingSBT.Operation.Append, _record(2), IEvolvingSBT.NamespaceStatus.Active, expiry + 1);
        uint256[] memory both = _indices(2);
        uint256[] memory secondOnly = _indices(1);
        secondOnly[0] = 1;
        vm.warp(expiry);
        assertTrue(conference.eligible(token, both));
        vm.warp(expiry + 1);
        assertFalse(conference.eligible(token, both));
        assertTrue(workshop.eligible(token, secondOnly));
        vm.warp(expiry + 2);
        assertFalse(workshop.eligible(token, secondOnly));
    }

    function testCurrentPolicyControlsAndTokenLiveness() public {
        _append(1);
        uint256[] memory selected = _indices(1);
        vm.prank(controller);
        sbt.setPolicyControls(NS, false, true);
        assertTrue(workshop.eligible(token, selected));
        vm.prank(controller);
        sbt.setPolicyControls(NS, true, false);
        assertFalse(workshop.eligible(token, selected));
        vm.prank(controller);
        sbt.setPolicyControls(NS, true, true);
        EvolvingSBT.Record memory empty;
        _transition(EvolvingSBT.Operation.Suspend, empty, IEvolvingSBT.NamespaceStatus.Suspended, 0);
        assertFalse(workshop.eligible(token, selected));
        _transition(EvolvingSBT.Operation.Resume, empty, IEvolvingSBT.NamespaceStatus.Active, 0);
        assertTrue(workshop.eligible(token, selected));
        vm.prank(holder);
        sbt.burn(token);
        assertFalse(workshop.eligible(token, selected));
    }

    function testStalePreviewAndFailedRedemptionDoNotConsumeEitherKey() public {
        _append(1);
        EvolvingSBT.Record memory b = _append(2);
        uint256[] memory both = _indices(2);
        assertTrue(conference.eligible(token, both));
        ContributionAdmission.Session memory ticket = _session(1);
        bytes memory signature = _sig(GATE_KEY, conference.sessionDigest(ticket));
        bytes32 beforeHead = sbt.hashState(sbt.stateOf(token, NS));
        vm.prank(issuer);
        registry.revoke(token, 1, ContributionRevocationRegistry.Target.Experience, b.experienceId);
        vm.expectRevert(ContributionAdmission.Ineligible.selector);
        vm.prank(holder);
        conference.redeem(token, both, ticket, signature);
        assertEq(sbt.hashState(sbt.stateOf(token, NS)), beforeHead);
        assertFalse(conference.usedSessions(ticket.nonce));
        assertFalse(conference.consumed(holder));
        _append(3);
        both[1] = 2;
        vm.prank(holder);
        conference.redeem(token, both, ticket, signature);
        assertTrue(conference.consumed(holder));
    }

    function testSignatureBindsEntranceLedgerHolderAndDeadline() public {
        _append(1);
        ContributionAdmission.Session memory ticket = _session(1);
        uint256[] memory selected = _indices(1);
        bytes memory signature = _sig(GATE_KEY, workshop.sessionDigest(ticket));
        vm.expectRevert(ContributionAdmission.NotHolder.selector);
        vm.prank(address(0xBEEF));
        workshop.redeem(token, selected, ticket, signature);
        bytes32 entrance = ticket.entranceId;
        ticket.entranceId = keccak256("west entrance");
        vm.expectRevert(ContributionAdmission.InvalidGateSignature.selector);
        vm.prank(holder);
        workshop.redeem(token, selected, ticket, signature);
        ticket.entranceId = entrance;
        ContributionAdmission secondLedger = _gate(keccak256("workshop"), 1);
        vm.expectRevert(ContributionAdmission.InvalidGateSignature.selector);
        vm.prank(holder);
        secondLedger.redeem(token, selected, ticket, signature);
        vm.warp(ticket.deadline + 1);
        vm.expectRevert(ContributionAdmission.InvalidSession.selector);
        vm.prank(holder);
        workshop.redeem(token, selected, ticket, signature);
        assertFalse(workshop.usedSessions(ticket.nonce));
        assertFalse(workshop.consumed(holder));
    }

    function testMatchingGateSessionRequiresOwnershipOfPresentedToken() public {
        _append(1);
        address visitor = makeAddr("visitor");
        ContributionAdmission.Session memory ticket = _session(1);
        ticket.holder = visitor;
        bytes memory signature = _sig(GATE_KEY, workshop.sessionDigest(ticket));
        vm.expectRevert(ContributionAdmission.NotHolder.selector);
        vm.prank(visitor);
        workshop.redeem(token, _indices(1), ticket, signature);
        assertFalse(workshop.usedSessions(ticket.nonce));
        assertFalse(workshop.consumed(visitor));
    }

    function testUnavailableRevocationStatusLeavesSessionAndEntitlementUsable() public {
        _append(1);
        ContributionAdmission.Session memory ticket = _session(1);
        bytes memory signature = _sig(GATE_KEY, workshop.sessionDigest(ticket));
        bytes memory unavailable = abi.encodeWithSignature("RegistryUnavailable()");
        vm.mockCallRevert(
            address(registry), abi.encodeWithSelector(registry.hasRevocations.selector), unavailable
        );
        vm.expectRevert(unavailable);
        vm.prank(holder);
        workshop.redeem(token, _indices(1), ticket, signature);
        assertFalse(workshop.usedSessions(ticket.nonce));
        assertFalse(workshop.consumed(holder));
        vm.clearMockedCalls();
        _redeem(workshop, _indices(1), ticket);
        assertTrue(workshop.consumed(holder));
    }

    function testActiveRevocationFilterCannotFallBackWhenExactChecksAreUnavailable() public {
        _append(1);
        EvolvingSBT.Record memory b = _append(2);
        vm.prank(issuer);
        registry.revoke(token, 1, ContributionRevocationRegistry.Target.Experience, b.experienceId);
        bytes memory unavailable = abi.encodeWithSignature("RegistryUnavailable()");
        vm.mockCallRevert(
            address(registry), abi.encodeWithSelector(registry.anyRevoked.selector), unavailable
        );
        ContributionAdmission.Session memory ticket = _session(1);
        bytes memory signature = _sig(GATE_KEY, workshop.sessionDigest(ticket));
        vm.expectRevert(unavailable);
        vm.prank(holder);
        workshop.redeem(token, _indices(1), ticket, signature);
        assertFalse(workshop.usedSessions(ticket.nonce));
        assertFalse(workshop.consumed(holder));
    }

    function _gateWithReaderSupport(bool batchCredential, bool batchRegistry)
        internal
        returns (ContributionAdmission gate)
    {
        if (!batchCredential) {
            vm.mockCall(
                address(sbt),
                abi.encodeCall(sbt.supportsInterface, (sbt.admissionRecords.selector)),
                abi.encode(false)
            );
        }
        if (!batchRegistry) {
            bytes4 batch = registry.hasRevocations.selector ^ registry.anyRevoked.selector;
            vm.mockCall(
                address(registry), abi.encodeCall(registry.supportsInterface, (batch)), abi.encode(false)
            );
        }
        gate = _gate(EVENT, 2);
        vm.clearMockedCalls();
    }

    function testLegacyReaderDistinguishesTwoExperiencesWithTheSameLowByte() public {
        ContributionAdmission legacy = _gateWithReaderSupport(false, false);
        EvolvingSBT.Record memory a = _record(1);
        a.experienceId = bytes32(uint256(0x12FF));
        EvolvingSBT.Record memory b = _record(2);
        b.experienceId = bytes32(uint256(0x34FF));
        _transition(EvolvingSBT.Operation.Append, a, IEvolvingSBT.NamespaceStatus.Active, 0);
        _transition(EvolvingSBT.Operation.Append, b, IEvolvingSBT.NamespaceStatus.Active, 0);
        uint256[] memory selected = _indices(2);
        assertTrue(legacy.eligible(token, selected));
        selected[0] = 1;
        assertFalse(legacy.eligible(token, selected));
    }

    function testLegacyAndBatchReadersAgreeAcrossRevocationAndCorrection() public {
        ContributionAdmission[4] memory gates = [
            _gateWithReaderSupport(false, false),
            _gateWithReaderSupport(false, true),
            _gateWithReaderSupport(true, false),
            conference
        ];
        _append(1);
        EvolvingSBT.Record memory b = _append(2);
        uint256[] memory selected = _indices(2);
        _assertEligibility(gates, selected, true);
        vm.prank(issuer);
        registry.revoke(token, 1, ContributionRevocationRegistry.Target.Claim, b.claimId);
        _assertEligibility(gates, selected, false);
        _correct(b, 3);
        _assertEligibility(gates, selected, false);
        selected[1] = 2;
        _assertEligibility(gates, selected, true);
        vm.prank(issuer);
        registry.revoke(token, 1, ContributionRevocationRegistry.Target.Experience, b.experienceId);
        _assertEligibility(gates, selected, false);
        selected[1] = 0;
        _assertEligibility(gates, selected, false);
    }

    function _assertEligibility(
        ContributionAdmission[4] memory gates,
        uint256[] memory selected,
        bool expected
    ) internal view {
        for (uint256 i; i < gates.length; ++i) {
            assertEq(gates[i].eligible(token, selected), expected);
        }
    }

    function testIndependentEip712VectorAndFinalEvent() public {
        _append(1);
        ContributionAdmission.Session memory ticket = _session(1);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "GateSession(bytes32 eventId,bytes32 benefitId,address holder,bytes32 entranceId,bytes32 nonce,uint64 deadline)"
                ),
                keccak256("workshop"),
                BENEFIT,
                holder,
                ticket.entranceId,
                ticket.nonce,
                ticket.deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("ContributionAdmission"),
                keccak256("1"),
                block.chainid,
                address(workshop)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        assertEq(workshop.sessionDigest(ticket), digest);
        bytes memory signature = _sig(GATE_KEY, digest);
        uint256[] memory selected = _indices(1);
        vm.warp(ticket.deadline);
        vm.expectEmit(true, true, true, true, address(workshop));
        emit ContributionAdmission.Admitted(holder, ticket.entranceId, digest, token);
        vm.prank(holder);
        workshop.redeem(token, selected, ticket, signature);
        assertTrue(workshop.eligible(token, selected));
        assertTrue(workshop.usedSessions(ticket.nonce));
    }

    function testEntitlementSurvivesNewEntranceSessionAndReplacementCredential() public {
        _append(1);
        ContributionAdmission.Session memory first = _session(1);
        uint256[] memory selected = _indices(1);
        _redeem(workshop, selected, first);
        vm.prank(holder);
        sbt.burn(token);
        token = _mintInitialized();
        _append(2);
        ContributionAdmission.Session memory second = _session(2);
        second.entranceId = keccak256("west entrance");
        bytes memory signature = _sig(GATE_KEY, workshop.sessionDigest(second));
        vm.expectRevert(ContributionAdmission.AlreadyConsumed.selector);
        vm.prank(holder);
        workshop.redeem(token, selected, second, signature);
        assertFalse(workshop.usedSessions(second.nonce));
        _append(3);
        _redeem(conference, _indices(2), second);
        assertTrue(conference.consumed(holder));
    }

    function testTwoOutstandingSessionsOnlyAdmitOnceAndLaterWithdrawalPreservesReceipt() public {
        EvolvingSBT.Record memory a = _append(1);
        ContributionAdmission.Session memory first = _session(1);
        ContributionAdmission.Session memory second = _session(2);
        second.entranceId = keccak256("west entrance");
        bytes memory secondSignature = _sig(GATE_KEY, workshop.sessionDigest(second));
        uint256[] memory selected = _indices(1);
        _redeem(workshop, selected, first);
        vm.expectRevert(ContributionAdmission.AlreadyConsumed.selector);
        vm.prank(holder);
        workshop.redeem(token, selected, second, secondSignature);
        vm.prank(issuer);
        registry.revoke(token, 0, ContributionRevocationRegistry.Target.Experience, a.experienceId);
        assertFalse(workshop.eligible(token, selected));
        assertTrue(workshop.consumed(holder));
        assertTrue(workshop.usedSessions(first.nonce));
        assertFalse(workshop.usedSessions(second.nonce));
    }

    function testSessionNonceCannotBeRecycledForAnotherHolder() public {
        _append(1);
        ContributionAdmission.Session memory first = _session(1);
        _redeem(workshop, _indices(1), first);
        holder = makeAddr("second holder");
        token = _mintInitialized();
        _append(2);
        ContributionAdmission.Session memory sameNonce = _session(1);
        bytes memory signature = _sig(GATE_KEY, workshop.sessionDigest(sameNonce));
        vm.expectRevert(ContributionAdmission.SessionAlreadyUsed.selector);
        vm.prank(holder);
        workshop.redeem(token, _indices(1), sameNonce, signature);
        assertFalse(workshop.consumed(holder));
    }

    function testNonceBitsRemainIndependentAcrossHoldersAndBuckets() public {
        uint256 prefix = uint256(keccak256("north entrance sessions")) & ~uint256(255);
        uint256[3] memory nonces = [prefix + 254, prefix + 255, prefix + 256];
        for (uint256 i; i < nonces.length; ++i) {
            holder = address(uint160(100 + i));
            token = _mintInitialized();
            _append(1);
            assertFalse(workshop.usedSessions(bytes32(nonces[i])));
            _redeem(workshop, _indices(1), _session(nonces[i]));
            assertTrue(workshop.consumed(holder));
        }
        for (uint256 i; i < nonces.length; ++i) {
            assertTrue(workshop.usedSessions(bytes32(nonces[i])));
        }
        assertFalse(workshop.usedSessions(bytes32(prefix + 253)));
        assertFalse(workshop.usedSessions(bytes32(prefix + 257)));
    }

    function testContractGateSignerIsCheckedAtUseTime() public {
        _append(1);
        Mock1271Wallet signer = new Mock1271Wallet(vm.addr(GATE_KEY));
        ContributionAdmission gate = new ContributionAdmission(registry, EVENT, BENEFIT, 1, address(signer));
        ContributionAdmission.Session memory ticket = _session(1);
        bytes memory signature = _sig(GATE_KEY, gate.sessionDigest(ticket));
        signer.disableSignatures();
        vm.expectRevert(ContributionAdmission.InvalidGateSignature.selector);
        vm.prank(holder);
        gate.redeem(token, _indices(1), ticket, signature);
        assertFalse(gate.consumed(holder));
    }
}

contract ContributionAdmissionGasTest is AdmissionFixture {
    function setUp() public override {
        super.setUp();
        for (uint256 id = 1; id <= 32; ++id) {
            _append(id);
        }
    }

    function _measure(uint8 size) internal {
        ContributionAdmission gate = _gate(EVENT, size);
        uint256[] memory selected = _indices(size);
        ContributionAdmission.Session memory ticket = _session(1);
        bytes memory signature = _sig(GATE_KEY, gate.sessionDigest(ticket));
        vm.cool(address(sbt));
        vm.cool(address(registry));
        vm.cool(address(gate));
        uint256 beforePreview = gasleft();
        bool qualifies = gate.eligible(token, selected);
        uint256 previewGas = beforePreview - gasleft();
        assertTrue(qualifies);
        vm.cool(address(sbt));
        vm.cool(address(registry));
        vm.cool(address(gate));
        vm.prank(holder);
        uint256 beforeRedemption = gasleft();
        gate.redeem(token, selected, ticket, signature);
        uint256 redemptionGas = beforeRedemption - gasleft();
        assertTrue(gate.consumed(holder));
        emit log_named_uint("eligible gas", previewGas);
        emit log_named_uint("redeem gas", redemptionGas);
        // Keep the common path below budget as the selection grows from 1 to 32.
        assertLt(previewGas, 25_000 + uint256(size) * 450, "preview gas regression");
        assertLt(redemptionGas, 84_000 + uint256(size) * 450, "redemption gas regression");
    }

    function testGasOneContribution() public {
        _measure(1);
    }

    function testGasTwoContributions() public {
        _measure(2);
    }

    function testGasThirtyTwoContributions() public {
        _measure(32);
    }
}
