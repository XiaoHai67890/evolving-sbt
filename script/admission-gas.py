"""Measure successful redemption receipts on a disposable local Cancun Anvil chain.

Run forge build, then python3 script/admission-gas.py. To compare builds, pass
--artifacts /path/to/old/out. The optional --sbt-artifacts and --registry-artifacts
override just those two contracts, for testing older deployments with a new gate.
"""

import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time


MNEMONIC = "test test test test test test test test test test test junk"
ISSUER_ACCOUNT = 0
CONTROLLER_ACCOUNT = 1
ZERO = "0x" + "00" * 32
EVIDENCE = "(uint8,(bytes32,bytes32,address,bytes32,uint64,bytes32))"
TRANSITION = "(uint256,bytes32,uint64,bytes32,uint64,uint64,(bytes32,bytes32,uint8,uint64),bytes32,uint64)"
SESSION = "(address,bytes32,bytes32,uint64)"


def cast(*args):
    return subprocess.check_output(["cast", *map(str, args)], text=True).strip()


@contextmanager
def local_chain():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "anvil.log"
        with path.open("w") as log:
            node = subprocess.Popen(
                ["anvil", "--host", "127.0.0.1", "--port", "0", "--hardfork", "cancun",
                 "--chain-id", "31337", "--timestamp", "1700000000", "--mnemonic", MNEMONIC],
                stdout=log, stderr=subprocess.STDOUT,
            )
            try:
                for _ in range(100):
                    listening = re.search(r"Listening on (127\.0\.0\.1:\d+)", path.read_text())
                    if listening:
                        yield "http://" + listening.group(1)
                        return
                    if node.poll() is not None:
                        break
                    time.sleep(0.05)
                raise RuntimeError("Local Anvil failed to start")
            finally:
                node.terminate()
                node.wait(timeout=5)


def benchmark(url, args):
    def transact(sender, *params):
        receipt = json.loads(cast("send", "--rpc-url", url, "--unlocked", "--from", sender,
                                  "--gas-limit", 14_000_000, "--json", *params))
        if int(receipt["status"], 16) != 1:
            operation = "deployment" if params[0] == "--create" else params[1].split("(")[0]
            raise RuntimeError(f"{operation} reverted in transaction {receipt['transactionHash']}")
        return receipt

    def deploy(artifacts, name, types, *values):
        artifact = artifacts / (name + ".sol") / (name + ".json")
        creation = json.loads(artifact.read_text())["bytecode"]["object"]
        data = creation + cast("abi-encode", "f(" + types + ")", *values)[2:]
        receipt = transact(issuer, "--create", data)
        deploy_gas.setdefault(name, int(receipt["gasUsed"], 16))
        return receipt["contractAddress"]

    def send(sender, to, signature, *values):
        receipt = transact(sender, to, signature, *values)
        return int(receipt["gasUsed"], 16)

    def view(to, signature, *values):
        return cast("call", "--rpc-url", url, to, signature, *values)

    def sign(account, digest):
        return cast("wallet", "sign", "--no-hash", "--mnemonic", MNEMONIC, "--mnemonic-index", account, digest)

    def gate(threshold):
        return deploy(args.artifacts, "ContributionAdmission", "address,bytes32,bytes32,uint8,address",
                      registry, event, benefit, threshold, issuer)

    def redeem(size):
        ledger = gate(size)
        selection = "[" + ",".join(map(str, range(size))) + "]"
        session = f"({holder},{entrance},{nonce},{deadline})"
        digest = view(ledger, f"sessionDigest({SESSION})", session)
        signature = sign(ISSUER_ACCOUNT, digest)
        return send(holder, ledger, f"redeem(uint256,uint256[],{SESSION},bytes)", 1, selection, session, signature)

    issuer, controller, holder = json.loads(cast("rpc", "--rpc-url", url, "eth_accounts"))[:3]
    deploy_gas = {}

    def keccak(value):
        return cast("keccak", value)

    ns, event, benefit = map(keccak, ("community.contributions", "workshop", "admission"))
    entrance, nonce = map(keccak, ("north entrance", "visit"))
    deadline = 2**40
    sbt = deploy(args.sbt_artifacts or args.artifacts, "EvolvingSBT", "address", issuer)
    send(issuer, sbt, "registerNamespace(bytes32,address,address,string)", ns, issuer, controller, "example-v02")
    policy = view(sbt, "policyIdOf(bytes32)", ns)
    registry = deploy(args.registry_artifacts or args.artifacts, "ContributionRevocationRegistry",
                      "address,bytes32,bytes32,address,address", sbt, ns, policy, issuer, controller)
    send(issuer, registry, "activate()")
    observer = gate(1)
    send(holder, sbt, "mint()")

    issuance = {}
    for revision in range(33):
        op = int(revision > 0)
        i = revision - 1
        record_expiry = deadline if args.finite_first and revision == 1 else 0
        if op:
            record = (keccak(f"claim{i}"), keccak(f"experience{i}"), holder, keccak(f"content{i}"), record_expiry, ZERO)
        else:
            record = (ZERO, ZERO, "0x" + "00" * 20, ZERO, 0, ZERO)
        evidence = f"({op},({','.join(map(str, record))}))"
        raw = cast("abi-encode", f"f({EVIDENCE})", evidence)
        head = view(sbt, "stateOf(uint256,bytes32)", 1, ns)
        update = view(sbt, f"previewTransition(uint256,bytes32,{EVIDENCE},uint8,uint64)", 1, ns, evidence, 1, 0)
        root, policy_id, status, expiry = ["0x" + update[j:j + 64] for j in range(2, len(update), 64)]
        next_state = f"({root},{policy_id},{int(status,16)},{int(expiry,16)})"
        change = f"(1,{ns},{revision},{keccak(head)},{op},1,{next_state},{keccak(raw)},{deadline})"
        digest = view(sbt, f"transitionDigest({TRANSITION})", change)
        authority = CONTROLLER_ACCOUNT if revision == 0 else ISSUER_ACCOUNT
        auth = cast("abi-encode", "f((bytes,bytes))", f"({sign(authority, digest)},0x)")
        gas = send(holder, sbt, f"applyTransition({TRANSITION},bytes,bytes)", change, raw, auth)
        if revision in (0, 1, 2, 32):
            issuance[revision] = gas

    clean = {size: redeem(size) for size in (1, 2, 32)}
    first = send(issuer, registry, "revoke(uint256,uint256,uint8,bytes32)", 1, 31, 1, keccak("experience31"))
    if int(view(observer, "eligible(uint256,uint256[])", 1, "[31]"), 16):
        raise RuntimeError("A withdrawn experience qualified")
    after_revoke = {size: redeem(size) for size in (2, 31)}
    second = send(issuer, registry, "revoke(uint256,uint256,uint8,bytes32)", 1, 31, 0, keccak("claim31"))
    print(json.dumps(dict(redeem=clean, redeem_after_withdrawal=after_revoke, revoke=[first, second],
                          deployment=deploy_gas, apply=issuance), indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=Path(__file__).resolve().parents[1] / "out")
    parser.add_argument("--sbt-artifacts", type=Path)
    parser.add_argument("--registry-artifacts", type=Path)
    parser.add_argument("--finite-first", action="store_true", help="Give the first contribution a finite expiry.")
    options = parser.parse_args()
    with local_chain() as endpoint:
        benchmark(endpoint, options)
