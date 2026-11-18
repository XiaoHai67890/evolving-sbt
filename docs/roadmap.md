# Implementation milestones

These milestones are an implementation plan, not a claim of ERC acceptance or a schedule commitment.

## v0.1 — Evidence-authorized state evolution

The first reference profile uses a non-transferable credential with independent namespaces and real signed authorizations. It implements the candidate reading and transition interface, exact-predecessor checks, monotonically increasing revisions and policy epochs, explicit lifecycle permissions, bounded accepted history, linked corrections, and stable experience identifiers for accounting.

The acceptance criterion is a reproducible local example and meaningful rejection tests. A reviewer should be able to establish why a transition was accepted and why a competing, unauthorized, stale, duplicate, or malformed transition is rejected.

The implementation is transparent. All submitted data and state are observable. The selected issuer is trusted to recognize experiences; arbitrary on-chain history is not independently verified.

## v0.2 — Current qualification and application consumption

The signed growth profile now has an [issuer-operated registry](../src/ContributionRevocationRegistry.sol) and a [public qualification and redemption contract](../src/ContributionAdmission.sol). The registry supports claim-only delegates and issuer-only withdrawal of an entire experience. An activity reads the registry at redemption even if the holder has never updated the SBT after withdrawal.

All entrances for the same benefit share one deployment. The holder's account and event benefit identify the entitlement throughout SBT updates, credential replacement and regenerated sessions. Account migration requires a separate recovery design.

The [A/B walkthrough](../script/DemoV02.s.sol) demonstrates external withdrawal after capacity exhaustion, a rejected stale preview and one admission across two entrances. The [acceptance tests](../test/ContributionAdmission.t.sol) also cover expiry, disabled use and replay. The [profile design](v0.2-revocation-and-admission.zh-CN.md) records the measured qualification and redemption costs.

## v0.3 — Private presentations

Implement a real proof relation and verifier. A presentation must connect recognized claims to the current accepted credential state, current local record status, external non-revocation dependencies, and one consistent subject. A holder's possession of unrelated valid claims is insufficient.

The profile also needs a current credential registry, lifecycle synchronization, witness delivery and refresh rules, and a defined privacy boundary. It must explain which identifiers, events, timing, and application interactions remain linkable.

Acceptance requires positive and negative proof tests plus measured proving and verification costs. A mock verifier or a public hash does not satisfy this milestone.

## Later work

- Protocol adapters for particular authenticated sources, including their attribution rules and action boundaries.
- Cross-chain finality and source-authentication policies.
- Policy migration preserving history, current status, deduplication, revocation dependencies, and stable subject bindings.
- Scalable accumulators and authenticated record-status structures replacing the 32-record public-history bound, with continuity proofs for accepted records and accounting.
- Recovery through stable smart-account control, including invalidation of pending authorizations.
- Additional independent implementations and shared test vectors.
- Incorporate interoperability feedback and independent implementation results into the [ERC-8498 draft](https://github.com/ethereum/ERCs/pull/2171).

Each addition should preserve the distinction between core interoperability, a particular verification profile, and an application's eligibility policy.
