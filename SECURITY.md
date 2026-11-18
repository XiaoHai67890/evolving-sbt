# Security and trust assumptions

This repository is an experimental reference implementation. It has not received an independent security audit and is not a claim that the broader private-credential system described in the discussion is complete.

## Trust boundaries

**Recognized authorities.** A valid signature authenticates an authority's authorization. It does not prove that an off-chain task happened, establish the economic meaning of a transaction, or make a malicious authority truthful. Consumers choose which deployments, namespaces, policies, and authorities they trust.

**Experience identifiers.** Duplicate accounting checks compare the stable identifiers assigned by the issuer within a single credential and namespace. They cannot recognize two different identifiers for the same real-world action, or establish uniqueness across tokens. The issuer is trusted to assign identifiers consistently.

**Policy administration.** Policy definitions and operational controls have different roles. Consumers must check both the accepted namespace state and the policy's current `usesEnabled` setting. A successful historical transition is not an unconditional statement of present eligibility.

**Contract authorities.** Authority addresses are immutable in a registered policy, but ERC-1271 accounts may change signature-validation behavior, implementation, or control outside this contract. The implementation evaluates contract signatures at submission time and does not pin that external account behavior or synchronize its changes with policy epochs. Distinct issuer and controller addresses do not establish independent human control.

**Subject attribution.** This version binds experiences to the credential's account and identity domain. It does not prove human uniqueness, prevent multiple accounts, or prevent sharing or selling control of an account. Permanent token locking is not a proof that control cannot be shared.

**Privacy.** Storage, calldata, signatures, state commitments, and events are public. Hashing a record does not hide low-entropy contents or prevent linkage. Do not submit personal data or secrets to this reference deployment. There is no ZK circuit, private presentation, or anonymity set in v0.1.

**Current validity.** The v0.2 admission contract consults both the namespace lifecycle and its external revocation registry at use time. An issuer can withdraw a record even if the SBT head stays fixed or updates are paused. Expiration takes effect with the block timestamp. A cached result can become stale between preview and redemption.

Historical admission permits expired records and an expired namespace that still has `Active` status may accept growth. `recordAt` reports whether a claim is nonsuperseded, not whether it is presently valid. `isUsable` checks namespace usability, not an application's complete qualification predicate. A consumer must perform the additional record and application checks.

**Availability and scale.** The concrete profile keeps a bounded public history. Its capacity and cost are implementation limits, not an unbounded growth guarantee. The future private profile needs an independent material-delivery and witness-availability design.

The 32-record limit includes corrections. Exhausting it prevents further append and correction operations. Suspension, namespace revocation, and other lifecycle operations remain available; deployments needing future correction must preserve capacity. There is no pruning or policy migration escape hatch in v0.1.

**Trust in the registry.** The organizer pins the chain, ledger, SBT, namespace, policy and issuer-activated registry for the event. An issuer can activate more than one registry. Switching registries or deploying separate admission ledgers for two entrances can split revocation or consumption history. A claim delegate can irrevocably withdraw an accepted version until removed. Removing the delegate affects future calls. Only the issuer can withdraw an entire experience.

**Admission and the physical entrance.** Every entrance for one event benefit shares a single ledger. The signer issues unique nonces with short deadlines. The holder submits the session using the same account that owns the credential. A confirmed redemption remains spent after a new session or a replacement credential. This binds one benefit to one account. Terminals trust their RPC endpoint, match the canonical finalized event to their own outstanding session and durably close it before triggering admission. A read-only receipt lookup can return the same success on multiple queries.

**Public disclosure.** In v0.2 observers can link the holder, record indices, entrance and admission transaction. Privacy-preserving proofs and witness delivery are outside this profile.

## Properties to preserve

- Authorization binds the chain, contract, credential, namespace, exact predecessor, requested next state, applicable policies and epochs, operation commitment, and deadline.
- Namespace authority cannot be reused as authority over a different namespace.
- An append cannot silently change lifecycle state, extend validity, or migrate policies.
- Corrections retain historical records and the stable experience identifier; new claim IDs do not create new experiences.
- Failed transitions leave no partial state or accounting changes.
- Revisions, epochs, and credential identities cannot reset and reactivate earlier authorizations.
- The concrete profile must validate the state it commits; an authorized arbitrary-root setter is not an equivalent implementation.
- Redemption rechecks eligibility and consumes a stable account entitlement and a session nonce in the same transaction.

## Reporting

For reproducible issues in this public prototype, open a GitHub issue with the affected commit, the violated property, and a minimal test. Do not include real private keys or private credential data. The repository does not operate a bug-bounty program or promise a private disclosure channel.
