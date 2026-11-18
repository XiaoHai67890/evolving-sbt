"""Terminal-side checks for finalized, canonical and unambiguous admission events."""

import runpy
import unittest
from pathlib import Path
from types import SimpleNamespace


CHECKER = runpy.run_path(str(Path(__file__).resolve().parents[1] / "script/check-admission.py"))


class CheckAdmissionTest(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(
            chain_id=31337, token_id=1, holder="0x" + "11" * 20, ledger="0x" + "22" * 20,
            entrance="0x" + "33" * 32, session_digest="0x" + "44" * 32, transaction="0x" + "55" * 32,
        )
        block_hash = "0x" + "66" * 32
        self.block = {"number": "0x9", "hash": block_hash, "transactions": [self.args.transaction]}
        self.finalized = self.block.copy()
        location = {
            "transactionHash": self.args.transaction, "transactionIndex": "0x0",
            "blockHash": block_hash, "blockNumber": self.block["number"],
        }
        self.log = dict(location, address=self.args.ledger, removed=False, data="0x" + "01".zfill(64))
        self.log["topics"] = [
            CHECKER["ADMITTED_TOPIC"], "0x" + self.args.holder[2:].zfill(64),
            self.args.entrance, self.args.session_digest,
        ]
        self.receipt = dict(location, status="0x1", logs=[self.log])

    def rpc(self, method, params):
        if method == "eth_chainId":
            return hex(31337)
        if method == "eth_getTransactionReceipt":
            self.assertEqual(params, [self.args.transaction])
            return self.receipt
        self.assertEqual(method, "eth_getBlockByNumber")
        return self.finalized if params[0] == "finalized" else self.block

    def result(self):
        return CHECKER["check"](self.rpc, self.args)[0]

    def test_finalized_exact_event(self):
        self.assertEqual(self.result(), 0)

    def test_finality_and_canonical_inclusion(self):
        self.finalized["number"] = "0x8"
        self.assertEqual(self.result(), 2)
        self.finalized["number"] = "0x9"
        self.finalized["hash"] = "0x" + "77" * 32
        self.assertEqual(self.result(), 2)
        self.finalized = self.block.copy()
        self.block["transactions"] = []
        self.assertEqual(self.result(), 2)
        self.block["hash"] = "0x" + "88" * 32
        self.assertEqual(self.result(), 2)

    def test_ambiguous_and_removed_events(self):
        self.receipt["logs"].append(self.log.copy())
        self.assertEqual(self.result(), 1)
        self.receipt["logs"].pop()
        self.log["removed"] = True
        self.assertEqual(self.result(), 1)

    def test_event_must_belong_to_receipt(self):
        for key, invalid in (("transactionHash", "0x" + "77" * 32), ("transactionIndex", "0x1"),
                             ("blockHash", "0x" + "88" * 32), ("blockNumber", "0xa")):
            with self.subTest(field=key):
                self.log[key] = invalid
                self.assertEqual(self.result(), 1)
                self.log[key] = self.receipt[key]

    def test_only_local_session_and_successful_transaction(self):
        for field in ("ledger", "holder", "entrance", "session_digest", "token_id", "chain_id"):
            with self.subTest(field=field):
                original = getattr(self.args, field)
                different = original + 1 if isinstance(original, int) else "0x" + "0" * (len(original) - 2)
                setattr(self.args, field, different)
                self.assertEqual(self.result(), 1)
                setattr(self.args, field, original)
        self.receipt["status"] = "0x0"
        self.assertEqual(self.result(), 1)
        self.receipt = None
        self.assertEqual(self.result(), 2)


if __name__ == "__main__":
    unittest.main()
