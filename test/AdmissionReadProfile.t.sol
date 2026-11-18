// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { EvolvingSBT } from "../src/EvolvingSBT.sol";
import { IEvolvingSBT } from "../src/interfaces/IEvolvingSBT.sol";
import { V02Fixture } from "./helpers/V02Fixture.sol";

contract AdmissionReadProfileTest is V02Fixture {
    function testHistoricalRecordEncodingAndHashSurviveCorrection() public {
        EvolvingSBT.Record memory original = _record(17);
        original.validUntil = uint64(block.timestamp + 500);
        _transition(EvolvingSBT.Operation.Append, original, IEvolvingSBT.NamespaceStatus.Active, 0);
        EvolvingSBT.Record memory replacement = _record(18);
        replacement.experienceId = original.experienceId;
        replacement.replaces = original.claimId;
        replacement.validUntil = original.validUntil + 99;
        _transition(EvolvingSBT.Operation.Correct, replacement, IEvolvingSBT.NamespaceStatus.Active, 0);

        (EvolvingSBT.Record memory storedOriginal, bool originalIsCurrent) = sbt.recordAt(token, NS, 0);
        (EvolvingSBT.Record memory storedReplacement, bool replacementIsCurrent) = sbt.recordAt(token, NS, 1);
        assertFalse(originalIsCurrent);
        assertTrue(replacementIsCurrent);
        assertEq(abi.encode(storedOriginal), abi.encode(original));
        assertEq(abi.encode(storedReplacement), abi.encode(replacement));
        assertEq(sbt.hashRecord(storedOriginal), keccak256(abi.encode(original)));
        assertEq(sbt.hashRecord(storedReplacement), keccak256(abi.encode(replacement)));
    }

    function testOptionalBatchReturnsHistoricalIdsInSelectionOrder() public {
        EvolvingSBT.Record memory first = _append(1);
        EvolvingSBT.Record memory second = _append(2);
        uint256[] memory indices = new uint256[](2);
        indices[0] = 1;
        (address owner, bytes32[2][] memory ids) = sbt.admissionRecords(token, NS, policy, indices, true);
        assertTrue(sbt.supportsInterface(sbt.admissionRecords.selector));
        assertEq(owner, holder);
        assertEq(ids.length, 2);
        assertEq(ids[0][0], second.claimId);
        assertEq(ids[0][1], second.experienceId);
        assertEq(ids[1][0], first.claimId);
        assertEq(ids[1][1], first.experienceId);

        (owner, ids) = sbt.admissionRecords(token, NS, policy, indices, false);
        assertEq(owner, holder);
        assertEq(ids.length, 0);
        (owner, ids) = sbt.admissionRecords(token, NS, keccak256("other policy"), indices, false);
        assertEq(owner, address(0));
        assertEq(ids.length, 0);
        indices[1] = 1;
        _assertRejected(indices);
        indices[1] = type(uint256).max;
        _assertRejected(indices);
        _assertRejected(new uint256[](0));
        _assertRejected(new uint256[](33));
    }

    function testLastRecordBitsTrackCorrectionAndInclusiveExpiry() public {
        for (uint256 id = 1; id <= 30; ++id) {
            _append(id);
        }
        EvolvingSBT.Record memory old = _append(31);
        EvolvingSBT.Record memory latest = _record(32);
        latest.replaces = old.claimId;
        latest.experienceId = old.experienceId;
        latest.validUntil = uint64(block.timestamp + 60);
        _transition(EvolvingSBT.Operation.Correct, latest, IEvolvingSBT.NamespaceStatus.Active, 0);
        uint256[] memory selected = new uint256[](1);
        selected[0] = 30;
        _assertRejected(selected);
        (, bool current) = sbt.recordAt(token, NS, 30);
        assertFalse(current);
        selected[0] = 31;
        vm.warp(latest.validUntil);
        (address owner, bytes32[2][] memory ids) = sbt.admissionRecords(token, NS, policy, selected, true);
        assertEq(owner, holder);
        assertEq(ids[0][0], latest.claimId);
        assertEq(ids[0][1], old.experienceId);
        (owner, ids) = sbt.admissionRecords(token, NS, policy, selected, false);
        assertEq(owner, holder);
        assertEq(ids.length, 0);
        vm.warp(latest.validUntil + 1);
        _assertRejected(selected);
        selected[0] = 29;
        (owner,) = sbt.admissionRecords(token, NS, policy, selected, false);
        assertEq(owner, holder);
    }

    function _assertRejected(uint256[] memory indices) internal view {
        (address owner, bytes32[2][] memory ids) = sbt.admissionRecords(token, NS, policy, indices, true);
        assertEq(owner, address(0));
        assertEq(ids.length, 0);
        (owner, ids) = sbt.admissionRecords(token, NS, policy, indices, false);
        assertEq(owner, address(0));
        assertEq(ids.length, 0);
    }
}
