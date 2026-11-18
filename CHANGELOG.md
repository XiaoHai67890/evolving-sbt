# Changelog

## Unreleased — v0.2 public contribution admission

- Add an issuer-activated registry for permanent claim and experience revocation, with grant and removal of claim-only delegates.
- Add a public eligibility check and atomic account-scoped redemption shared by an event's entrances.
- Demonstrate two qualifying experiences reduced to one after withdrawal at full SBT capacity, including a failed replay at a second entrance.
- Add a finalized receipt checker and benchmark qualification and redemption at 1, 2 and 32 distinct contributions.
- Batch record validity checks, skip per-record identifier reads on credentials with no revocations, and retain exact revocation checks and support for older deployments.

## 0.1.0 — Initial experimental reference implementation

- Preserve the candidate three-method, one-event interface from the pre-ERC discussion.
- Implement a permanently locked credential with independent namespace state.
- Add a concrete signed growth profile with accepted history, linked corrections, and duplicate accounting checks.
- Check exact predecessor state, sequential revision, policy epochs, operation authority, and deadlines.
- Separate policy operational controls from immutable definitions and enforce namespace lifecycle rules.
- Include a local demonstration, executable tests, implementation documentation, and explicit trust assumptions.

At this milestone the team deferred per-claim revocation, qualification and consumption applications, policy migration, account recovery, protocol adapters and private presentations.
