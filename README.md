# Evolving SBT with Namespaced State Transitions

An experimental reference implementation of a proposed interface for a non-transferable credential whose independently governed namespaces can evolve through evidence-authorized state transitions.

This repository accompanies the [ERC-8498 proposal](https://github.com/ethereum/ERCs/pull/2171). The v0.2 reference profile adds public revocation and admission alongside the proposed core interface.

[Ethereum Magicians discussion](https://ethereum-magicians.org/t/erc-8498-namespaced-state-transitions-for-sbts/30361) · [Implementation specification](docs/specification.md) · [Design discussion](docs/discussion.md) · [Roadmap](docs/roadmap.md) · [Security and trust assumptions](SECURITY.md)

v0.1 用签名验证经历的追加和纠错。v0.2 让机构逐条撤回认可，活动方用同一份历史重算资格，并在入场时核销一次权益。公开演示覆盖 A、B 两项贡献、容量耗尽后的撤销，以及两个入口共用同一本核销账。[中文方案与复现步骤](docs/v0.2-revocation-and-admission.zh-CN.md)

## What this repository tests

The proposed interoperability boundary is small:

| Candidate method or event | Meaning |
|---|---|
| `stateOf(tokenId, namespace)` | Read the currently accepted state head. |
| `policyOf(namespace, policyId)` | Discover the immutable rule definition and its live operational controls. |
| `applyTransition(change, evidence, authorization)` | Submit an authorized transition from an exact predecessor. |
| `StateTransitioned(...)` | Observe an accepted revision and its state hashes. |

The full candidate ABI is in [`IEvolvingSBT.sol`](src/interfaces/IEvolvingSBT.sol). Minting, policy administration, profile helpers, and record inspection are implementation-specific additions, not additional proposed core methods.

A namespace is a semantic and authorization boundary. Two namespaces in the same credential can recognize different authorities and maintain independent histories. A later revision is not necessarily a higher score: correction, suspension, expiration, and revocation can reduce current usability while history remains recorded.

## v0.1 scope

The first profile uses real signed authorizations and a bounded, transparent record history. It checks the actual proposed transition; it does not accept an arbitrary administrator-supplied root or use a verifier that always returns `true`. The lifetime limit is 32 accepted records per credential and namespace, including corrections, so correction capacity must be planned.

| Implemented in the first reference profile | Deferred at the v0.1 milestone |
|---|---|
| ERC-721 credential with permanent ERC-5192 locking | One-person-one-credential or proof of humanity |
| Independent namespace state and policy discovery | Universal action taxonomy or reputation formula |
| Exact predecessor, sequential revision, deadline, and policy-epoch checks | Cross-chain history verification and protocol adapters |
| Signed operation authorization and holder consent for initialization | General verifier plug-in interoperability |
| Append-only accepted records and linked corrections | Policy migration |
| Stable experience identifiers and duplicate accounting checks | Independent per-claim issuer revocation registry |
| Namespace lifecycle and policy operational controls | Qualification applications and one-time entitlement consumption |
| Holder burn and non-reused credential identifiers | Account recovery integration |
| Deterministically checked public state commitments | ZK presentations, anonymous membership, and private witness management |

Signature verification establishes that a recognized authority authorized a particular statement and state change. It does not independently prove that a community task occurred or that a transaction on another protocol represents a qualifying contribution. The issuer must assign stable experience identifiers consistently; deduplication prevents reuse of the same identifier within a token and namespace, not dishonest recognition under different identifiers. Applications must accept the relevant issuer, deployment, and policy.

Record inclusion and current qualification are separate. Historical expired records may be admitted, and an expired namespace can continue accumulating records while its lifecycle status remains active. Consumers must check current namespace usability and record validity when making a decision. No balance, contribution count, or reputation score is automatically produced by this profile.

## Run locally

Install [Foundry](https://getfoundry.sh/introduction/installation/), then:

```sh
git clone --recurse-submodules https://github.com/XiaoHai67890/evolving-sbt.git
cd evolving-sbt
forge build
forge test
forge script script/Demo.s.sol:Demo
forge script script/DemoV02.s.sol:DemoV02
```

Both demos use local simulation and generated test keys. The first registers contribution and education namespaces, initializes a credential, and demonstrates signed growth and correction. The v0.2 demo fills all 32 history slots, pauses updates, revokes B, and asserts the outcome at two activities and two entrances.

For a checkout created without submodules, run `git submodule update --init --recursive`. The repository pins Solidity 0.8.30, the Cancun EVM target, OpenZeppelin Contracts 5.7.0, and forge-std 1.17.0. See [foundry.toml](foundry.toml) for the compiler and test configuration.

## v0.2 public contribution admission

The issuer activates a [revocation registry](src/ContributionRevocationRegistry.sol) tied to an existing SBT deployment, namespace and policy. It can appoint or remove a delegate for individual claim versions. Only the issuer can permanently withdraw a whole experience. Both actions preserve the original records and consume no SBT history slots. At full capacity a new corrected record still requires a fresh slot.

The organizer selects a trusted registry, event, benefit, threshold and session signer when deploying the [admission contract](src/ContributionAdmission.sol). All entrances for that benefit use the same deployment. Two calls cover the holder journey.

| Call | Observable result |
|---|---|
| `eligible(tokenId, indices)` | Reads current namespace usability, holder, policy, record versions, expiry and both revocation levels. Every selected experience must be distinct and valid. The result is a preview at the state queried. |
| `redeem(tokenId, indices, session, gateSignature)` | The holder submits a signed entrance session. The contract rechecks qualification and atomically consumes the nonce and that account's entitlement. A failed transaction consumes neither. |

`consumed(holder)` answers whether the account already used the event benefit. A holder can remain qualified after admission. Entrances match the finalized `Admitted` event to their pending session before opening. The [terminal receipt checker](script/check-admission.py) reads a trusted RPC endpoint. Run `python3 script/check-admission.py --help` for its inputs. Terminals must persist the handling of their own sessions to open only once for a confirmed receipt.

This profile reveals the account and submitted record indices. Private presentations are a v0.3 milestone. On new deployments the gate checks the selected records in one call. A registry with no withdrawals for the token can confirm that fact in one read. Older deployments remain usable through their original record and revocation queries.

To measure whole-transaction gas, run `forge build` followed by `python3 script/admission-gas.py`. The benchmark starts a local Anvil node and measures admission with and without a prior withdrawal. See the [Chinese design and cost comparison](docs/v0.2-revocation-and-admission.zh-CN.md#本地复现与实测).

## Read the implementation

- [`src/interfaces/IEvolvingSBT.sol`](src/interfaces/IEvolvingSBT.sol): candidate core interface from the discussion.
- [`src/`](src): concrete non-transferable credential and signed growth profile.
- [`test/`](test): executable behavior, rejection cases, and regression tests.
- [`script/Demo.s.sol`](script/Demo.s.sol): reproducible local walkthrough.
- [`docs/specification.md`](docs/specification.md): concrete v0.1 encoding, authorization, lifecycle, and state-transition rules.
- [`docs/discussion.md`](docs/discussion.md): the broader proposal, including future privacy and application profiles.

The [v0.1 specification](docs/specification.md), [v0.2 design](docs/v0.2-revocation-and-admission.zh-CN.md) and executable tests document the current reference profiles.

## Relationship to existing standards

The implementation uses [ERC-721](https://eips.ethereum.org/EIPS/eip-721) with [ERC-5192](https://eips.ethereum.org/EIPS/eip-5192) permanent locking as its token base. The proposed extension explores common semantics for independently governed namespace state, policy discovery, and predecessor-bound updates.

[ERC-5727](https://eips.ethereum.org/EIPS/eip-5727) already provides dynamic issuance, revocation, and verification functionality. This proposal is not premised on existing SBT standards being universally static. This repository does not claim [ERC-5484](https://eips.ethereum.org/EIPS/eip-5484) or ERC-5727 compatibility: their lifecycle and metadata requirements need a separate compatibility analysis. The comparison and rationale are recorded in the [published design discussion](docs/discussion.md).

## Contributing

Review the [implementation specification](docs/specification.md), reproduce the demo, and bring concrete interoperability or security findings to GitHub issues or the [Magicians thread](https://ethereum-magicians.org/t/erc-8498-namespaced-state-transitions-for-sbts/30361). Include the expected behavior, observed behavior, and a minimal test where possible. Changes to the candidate ABI should explain the effect on independent consumers and distinguish core requirements from profile-specific behavior.

This code has not received an independent security audit. Read [SECURITY.md](SECURITY.md) before adapting it for a deployment with real credentials or entitlements.
