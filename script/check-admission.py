"""Check one outstanding entrance session using the terminal's trusted Ethereum RPC endpoint.

Only CONFIRMED authorizes the terminal to consume its outstanding session and open once.
Exit codes: 0 confirmed, 1 rejected, 2 pending, 3 RPC/format error. This read-only
check can be retried. The terminal owns the expected values and local open-once state.
"""

import argparse
import json
import re
import sys
from http.client import HTTPException
from urllib.request import Request, urlopen


# keccak256("Admitted(address,bytes32,bytes32,uint256)")
ADMITTED_TOPIC = "0xa2a353d1b6bfccedea3812330a5e6db15082817d75c8859056e626b7e0b61450"


def fixed_hex(value, size):
    if not re.fullmatch(r"0x[0-9a-fA-F]{%d}" % (2 * size), value):
        raise ValueError(f"expected a {size}-byte hex value")
    return value.lower()


def uint256(value):
    number = int(value, 0)
    if not 0 <= number < 2**256:
        raise ValueError("expected a uint256")
    return number


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = Request(url, data=body, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=10) as response:
        result = json.load(response)
    if "error" in result or result.get("id") != 1:
        raise ValueError(f"{method} failed")
    return result["result"]


def check(call, args):
    if int(call("eth_chainId", []), 16) != args.chain_id:
        return 1, "REJECTED: wrong chain"
    receipt = call("eth_getTransactionReceipt", [args.transaction])
    if receipt is None:
        return 2, "PENDING: receipt unavailable"
    if fixed_hex(receipt["transactionHash"], 32) != args.transaction:
        return 1, "REJECTED: receipt belongs to another transaction"
    block_hash = fixed_hex(receipt["blockHash"], 32)
    height = int(receipt["blockNumber"], 16)
    finalized = call("eth_getBlockByNumber", ["finalized", False])
    if finalized is None:
        return 2, "PENDING: waiting for finalized block"
    finalized_height = int(finalized["number"], 16)
    finalized_hash = fixed_hex(finalized["hash"], 32)
    if finalized_height < height:
        return 2, "PENDING: waiting for finalized block"
    canonical = call("eth_getBlockByNumber", [hex(height), False])
    if canonical is None or int(canonical["number"], 16) != height or fixed_hex(canonical["hash"], 32) != block_hash:
        return 2, "PENDING: receipt block is not canonical"
    if finalized_height == height and finalized_hash != block_hash:
        return 2, "PENDING: inconsistent finalized block"
    index = int(receipt["transactionIndex"], 16)
    transactions = canonical["transactions"]
    if not 0 <= index < len(transactions) or fixed_hex(transactions[index], 32) != args.transaction:
        return 2, "PENDING: transaction missing from canonical block"
    if int(receipt["status"], 16) != 1:
        return 1, "REJECTED: transaction reverted"

    topics = [ADMITTED_TOPIC, "0x" + args.holder[2:].zfill(64), args.entrance, args.session_digest]
    matches = 0
    for log in receipt["logs"]:
        if fixed_hex(log["address"], 20) != args.ledger or [topic.lower() for topic in log["topics"]] != topics:
            continue
        if (log.get("removed", False) is False
                and fixed_hex(log["transactionHash"], 32) == args.transaction
                and int(log["transactionIndex"], 16) == index
                and fixed_hex(log["blockHash"], 32) == block_hash
                and int(log["blockNumber"], 16) == height
                and int(fixed_hex(log["data"], 32), 16) == args.token_id):
            matches += 1
    if matches != 1:
        return 1, "REJECTED: expected one matching admission event"
    return 0, f"CONFIRMED: admission finalized at block {height}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--chain-id", required=True, type=uint256)
    parser.add_argument("--token-id", required=True, type=uint256)
    for name, size in (("ledger", 20), ("holder", 20), ("entrance", 32),
                       ("session-digest", 32), ("transaction", 32)):
        parser.add_argument("--" + name, required=True, type=lambda value, size=size: fixed_hex(value, size))
    args = parser.parse_args()
    if not args.rpc_url.startswith(("http://", "https://")):
        parser.error("expected an HTTP(S) RPC URL")
    try:
        code, result = check(lambda method, params: rpc(args.rpc_url, method, params), args)
    except (HTTPException, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"UNAVAILABLE: {error}", file=sys.stderr)
        return 3
    print(result)
    return code


if __name__ == "__main__":
    try:
        result = main()
    except SystemExit as error:
        # argparse uses 2 for invalid input; reserve that exit code for a pending receipt.
        if error.code == 2:
            sys.exit(3)
        raise
    sys.exit(result)
