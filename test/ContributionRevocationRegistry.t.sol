// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EvolvingSBT } from "../src/EvolvingSBT.sol";
import { ContributionRevocationRegistry as Registry } from "../src/ContributionRevocationRegistry.sol";
import { V02Fixture } from "./helpers/V02Fixture.sol";

contract ContributionRevocationRegistryTest is V02Fixture {
    address internal constant DELEGATE = address(0xDE1E);

    function testConfigurationBindsRegisteredPolicyAndBothAuthorities() public {
        assertEq(address(registry.credential()), address(sbt));
        assertEq(registry.namespace(), NS);
        assertEq(registry.policyId(), policy);
        assertEq(registry.issuer(), issuer);
        assertEq(registry.controller(), controller);
        assertEq(registry.chainId(), block.chainid);
        assertTrue(registry.activated());

        vm.expectRevert(Registry.InvalidConfiguration.selector);
        new Registry(sbt, NS, policy, controller, issuer);
        vm.expectRevert(EvolvingSBT.UnknownPolicy.selector);
        new Registry(sbt, NS, bytes32(uint256(1)), issuer, controller);
        vm.expectRevert(Registry.InvalidConfiguration.selector);
        new Registry(EvolvingSBT(address(0)), NS, policy, issuer, controller);
    }

    function testIssuerMustActivateAndActivationIsPermanent() public {
        Registry pending = new Registry(sbt, NS, policy, issuer, controller);
        vm.prank(controller);
        vm.expectRevert(Registry.Unauthorized.selector);
        pending.activate();
        vm.startPrank(issuer);
        vm.expectRevert(Registry.Inactive.selector);
        pending.setClaimRevoker(DELEGATE, true);
        vm.expectRevert(Registry.Inactive.selector);
        pending.revoke(token, 0, Registry.Target.Claim, bytes32(0));
        vm.expectEmit(true, false, false, false, address(pending));
        emit Registry.Activated(issuer);
        pending.activate();
        vm.expectRevert(Registry.AlreadyActivated.selector);
        pending.activate();
        vm.expectRevert(Registry.InvalidAccount.selector);
        pending.setClaimRevoker(address(0), true);
        vm.stopPrank();
    }

    function testDelegatePermissionsAndRemovalCheckedAtExecution() public {
        EvolvingSBT.Record memory a = _append(1);
        EvolvingSBT.Record memory b = _append(2);
        vm.prank(holder);
        vm.expectRevert(Registry.Unauthorized.selector);
        registry.revoke(token, 0, Registry.Target.Claim, a.claimId);
        vm.prank(controller);
        vm.expectRevert(Registry.Unauthorized.selector);
        registry.revoke(token, 0, Registry.Target.Experience, a.experienceId);

        vm.expectEmit(true, false, false, true, address(registry));
        emit Registry.ClaimRevokerSet(DELEGATE, true);
        vm.prank(issuer);
        registry.setClaimRevoker(DELEGATE, true);
        assertTrue(registry.claimRevokers(DELEGATE));
        vm.startPrank(DELEGATE);
        vm.expectRevert(Registry.Unauthorized.selector);
        registry.setClaimRevoker(holder, true);
        vm.expectRevert(Registry.Unauthorized.selector);
        registry.revoke(token, 1, Registry.Target.Experience, b.experienceId);
        vm.expectEmit(true, true, true, true, address(registry));
        emit Registry.Revoked(token, Registry.Target.Claim, a.claimId, DELEGATE);
        registry.revoke(token, 0, Registry.Target.Claim, a.claimId);
        vm.stopPrank();

        vm.prank(issuer);
        registry.setClaimRevoker(DELEGATE, false);
        assertFalse(registry.claimRevokers(DELEGATE));
        vm.prank(DELEGATE);
        vm.expectRevert(Registry.Unauthorized.selector);
        registry.revoke(token, 1, Registry.Target.Claim, b.claimId);
        _assertEntry(token, Registry.Target.Claim, a.claimId, true, block.number);
        _assertEntry(token, Registry.Target.Claim, b.claimId, false, 0);
    }

    function testOnlyAcceptedIdsCanBeRevokedForTheirSelectedKindAndIndex() public {
        EvolvingSBT.Record memory a = _append(1);
        vm.startPrank(issuer);
        vm.expectRevert(Registry.RecordIdMismatch.selector);
        registry.revoke(token, 0, Registry.Target.Experience, a.claimId);
        vm.expectRevert(Registry.RecordIdMismatch.selector);
        registry.revoke(token, 0, Registry.Target.Claim, a.experienceId);
        vm.expectRevert();
        registry.revoke(token, 1, Registry.Target.Claim, a.claimId);
        vm.expectRevert();
        registry.revoke(token + 1, 0, Registry.Target.Claim, a.claimId);
        vm.stopPrank();
        _assertEntry(token, Registry.Target.Claim, a.claimId, false, 0);
    }

    function testSupersededRecordIdentifiesWholeExperienceAndWithdrawalRemainsAfterCorrection() public {
        EvolvingSBT.Record memory original = _append(1);
        EvolvingSBT.Record memory correction = _correct(original, 2);
        uint256 atBlock = block.number;
        vm.prank(issuer);
        registry.revoke(token, 0, Registry.Target.Experience, original.experienceId);
        _correct(correction, 3);
        vm.roll(atBlock + 10);
        vm.prank(issuer);
        vm.expectRevert(Registry.AlreadyRevoked.selector);
        registry.revoke(token, 2, Registry.Target.Experience, original.experienceId);
        _assertEntry(token, Registry.Target.Experience, original.experienceId, true, atBlock);
        _assertEntry(token, Registry.Target.Claim, correction.claimId, false, 0);
        assertEq(sbt.recordCount(token, NS), 3);
        assertTrue(sbt.isCredited(token, NS, original.experienceId));
        vm.prank(holder);
        sbt.burn(token);
        _assertEntry(token, Registry.Target.Experience, original.experienceId, true, atBlock);
    }

    function testSameIdOnAnotherCredentialAnotherNamespaceAndOtherTargetIsIndependent() public {
        EvolvingSBT.Record memory record = _record(1);
        record.experienceId = record.claimId;
        _transition(EvolvingSBT.Operation.Append, record, sbt.stateOf(token, NS).status, 0);
        vm.prank(issuer);
        registry.revoke(token, 0, Registry.Target.Claim, record.claimId);
        _assertEntry(token, Registry.Target.Experience, record.claimId, false, 0);
        uint256 otherToken = _mintInitialized();
        _transitionFor(
            otherToken, EvolvingSBT.Operation.Append, record, sbt.stateOf(otherToken, NS).status, 0
        );
        _assertEntry(otherToken, Registry.Target.Claim, record.claimId, false, 0);

        bytes32 otherNS = keccak256("other");
        bytes32 otherPolicy = sbt.registerNamespace(otherNS, issuer, controller, "ipfs://other");
        Registry other = new Registry(sbt, otherNS, otherPolicy, issuer, controller);
        vm.prank(issuer);
        other.activate();
        (bool revoked,) = other.revocationOf(token, Registry.Target.Claim, record.claimId);
        assertFalse(revoked);
        vm.prank(issuer);
        vm.expectRevert();
        other.revoke(token, 0, Registry.Target.Claim, record.claimId);
    }

    function testCapacityAndUpdatePauseDoNotBlockWithdrawalOrChangeHead() public {
        EvolvingSBT.Record memory a = _append(1);
        EvolvingSBT.Record memory b = _append(2);
        for (uint256 i = 3; i <= 32; ++i) {
            b = _correct(b, i);
        }
        vm.prank(controller);
        sbt.setPolicyControls(NS, false, true);
        bytes32 head = sbt.hashState(sbt.stateOf(token, NS));
        vm.prank(issuer);
        registry.revoke(token, 1, Registry.Target.Experience, b.experienceId);
        assertEq(sbt.hashState(sbt.stateOf(token, NS)), head);
        assertEq(sbt.recordCount(token, NS), 32);
        assertTrue(sbt.isUsable(token, NS));
        _assertEntry(token, Registry.Target.Experience, b.experienceId, true, block.number);
        _assertEntry(token, Registry.Target.Experience, a.experienceId, false, 0);
    }

    function testWrongChainRejectedAndBlockZeroDistinguishableFromAbsent() public {
        EvolvingSBT.Record memory a = _append(1);
        vm.roll(0);
        vm.prank(issuer);
        registry.revoke(token, 0, Registry.Target.Claim, a.claimId);
        _assertEntry(token, Registry.Target.Claim, a.claimId, true, 0);
        _assertEntry(token, Registry.Target.Experience, a.experienceId, false, 0);
        uint256 initialChain = block.chainid;
        vm.chainId(initialChain + 1);
        vm.expectRevert(Registry.WrongChain.selector);
        registry.revocationOf(token, Registry.Target.Claim, a.claimId);
        vm.prank(issuer);
        vm.expectRevert(Registry.WrongChain.selector);
        registry.revoke(token, 0, Registry.Target.Experience, a.experienceId);
        vm.chainId(initialChain);
        _assertEntry(token, Registry.Target.Claim, a.claimId, true, 0);
    }

    function testRevocationFilterRequiresExactIdAndCorrectTargetOnCollision() public {
        EvolvingSBT.Record memory a = _record(1);
        a.claimId = bytes32(uint256(0x10ff));
        a.experienceId = bytes32(uint256(0x2200));
        EvolvingSBT.Record memory b = _record(2);
        b.claimId = bytes32(uint256(0x30ff));
        b.experienceId = bytes32(uint256(0x4400));
        _transition(EvolvingSBT.Operation.Append, a, sbt.stateOf(token, NS).status, 0);
        _transition(EvolvingSBT.Operation.Append, b, sbt.stateOf(token, NS).status, 0);

        bytes32[2][] memory pair = new bytes32[2][](1);
        pair[0] = [b.claimId, b.experienceId];
        assertFalse(registry.hasRevocations(token));
        assertFalse(registry.anyRevoked(token, pair));
        vm.startPrank(issuer);
        registry.revoke(token, 0, Registry.Target.Claim, a.claimId);
        registry.revoke(token, 0, Registry.Target.Experience, a.experienceId);
        vm.stopPrank();
        assertTrue(registry.hasRevocations(token));
        assertFalse(registry.hasRevocations(token + 1));
        assertFalse(registry.anyRevoked(token, pair));
        pair[0] = [a.experienceId, a.claimId];
        assertFalse(registry.anyRevoked(token, pair));
        pair[0] = [a.claimId, b.experienceId];
        assertTrue(registry.anyRevoked(token, pair));
        pair[0] = [b.claimId, a.experienceId];
        assertTrue(registry.anyRevoked(token, pair));
        assertFalse(registry.anyRevoked(token + 1, pair));
    }

    function _assertEntry(uint256 tokenId, Registry.Target kind, bytes32 id, bool revoked, uint256 atBlock)
        internal
        view
    {
        (bool actual, uint256 recordedAt) = registry.revocationOf(tokenId, kind, id);
        assertEq(actual, revoked);
        assertEq(recordedAt, atBlock);
    }
}
