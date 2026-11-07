#!/usr/bin/env python3
"""Fetch a 1inch V6.1 quote and locally check its calldata against W-2 guards.

This script never signs or broadcasts a transaction. It reads only ONEINCH_APIKEY
and SEPOLIA_RPC_URL from .env (or their process-environment overrides).
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CHAIN_ID = 1
NATIVE_MARKER = int("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", 16)
SWAP_SELECTOR = bytes.fromhex("07ed2379")
PARTIAL_FILL_FLAG = 1
ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "configs" / "sepolia.json"
ENV_PATH = ROOT / ".env"
FIXTURE_DIR = ROOT / "test" / "fixtures" / "1inch"


def read_env_value(name: str) -> str | None:
    if name in os.environ:
        return os.environ[name]
    if not ENV_PATH.is_file():
        return None
    for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        match = re.match(rf"^\s*(?:export\s+)?{re.escape(name)}\s*=\s*(.*?)\s*$", line)
        if match:
            value = match.group(1)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value
    return None


def read_api_key() -> str:
    name = "ONEINCH_APIKEY"
    value = read_env_value(name)
    if not value:
        raise RuntimeError(f"{name} is missing or empty in .env and process environment")
    return value


def parse_address(value: str, label: str) -> int:
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
        raise ValueError(f"{label} must be a 20-byte 0x-prefixed address")
    return int(value, 16)


def word(data: bytes, index: int) -> int:
    start = index * 32
    if start + 32 > len(data):
        raise ValueError("truncated ABI word")
    return int.from_bytes(data[start : start + 32], "big")


def decode_swap(calldata_hex: str) -> dict[str, int | str]:
    if not calldata_hex.startswith("0x"):
        raise ValueError("API transaction data is not 0x-prefixed")
    calldata = bytes.fromhex(calldata_hex[2:])
    if calldata[:4] != SWAP_SELECTOR:
        raise ValueError(f"unexpected selector 0x{calldata[:4].hex()}; expected 0x{SWAP_SELECTOR.hex()}")
    args = calldata[4:]
    if len(args) < 10 * 32:
        raise ValueError("truncated swap arguments")

    data_offset = word(args, 8)
    if data_offset % 32 or data_offset + 32 > len(args):
        raise ValueError("invalid route-data ABI offset")

    desc = args[32 : 32 + 7 * 32]
    return {
        "src_token": word(desc, 0),
        "dst_token": word(desc, 1),
        "src_receiver": word(desc, 2),
        "dst_receiver": word(desc, 3),
        "amount": word(desc, 4),
        "min_return": word(desc, 5),
        "flags": word(desc, 6),
        "executor": f"0x{word(args, 0):040x}",
    }


def fetch_latest_block(rpc_url: str) -> int:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}).encode()
    request = urllib.request.Request(
        rpc_url, data=payload, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if "error" in result or "result" not in result:
        raise RuntimeError("Sepolia RPC did not return a block number")
    return int(result["result"], 16)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="sender", required=True, help="vault/caller address for the 1inch route")
    parser.add_argument("--src", required=True, help="source token address; use address(0) for native ETH")
    parser.add_argument("--dst", required=True, help="destination token address")
    parser.add_argument("--amount", required=True, type=int, help="source amount in raw token units")
    parser.add_argument("--min-return", required=True, type=int, help="typed minimum output in raw token units")
    parser.add_argument("--slippage", required=True, type=float, help="1inch slippage percentage, e.g. 1 for 1%%")
    args = parser.parse_args()

    sender = parse_address(args.sender, "--from")
    src = parse_address(args.src, "--src")
    dst = parse_address(args.dst, "--dst")
    if args.amount <= 0 or args.min_return < 0 or not (0 < args.slippage <= 50):
        parser.error("amount must be positive, min-return nonnegative, and slippage in (0, 50]")

    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    router = config["deployment"]["oneInchRouter"].lower()
    params = urllib.parse.urlencode(
        {
            "src": args.src,
            "dst": args.dst,
            "amount": str(args.amount),
            "from": args.sender,
            "origin": args.sender,
            "receiver": args.sender,
            "slippage": str(args.slippage),
            "disableEstimate": "true",
            "allowPartialFill": "false",
        }
    )
    endpoint = f"https://api.1inch.com/swap/v6.1/{CHAIN_ID}/swap?{params}"
    request = urllib.request.Request(
        endpoint,
        headers={"Authorization": f"Bearer {read_api_key()}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            quote = json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            error_body = json.loads(exc.read())
        except (ValueError, OSError):
            error_body = {}
        details = []
        for key in ("code", "description", "requestId"):
            value = error_body.get(key)
            if isinstance(value, str) and value:
                details.append(f"{key}={value}")
        request_id = exc.headers.get("X-Request-Id") if exc.headers else None
        if request_id and not any(detail.startswith("requestId=") for detail in details):
            details.append(f"requestId={request_id}")
        suffix = f" ({'; '.join(details)})" if details else ""
        raise RuntimeError(f"1inch API returned HTTP {exc.code}{suffix}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"could not reach 1inch API: {exc.reason}") from None

    tx = quote.get("tx")
    if not isinstance(tx, dict) or not isinstance(tx.get("data"), str) or not isinstance(tx.get("to"), str):
        raise RuntimeError("1inch response did not include tx.to and tx.data")
    if tx["to"].lower() != router:
        raise RuntimeError("API transaction target does not match configs/sepolia.json router")

    decoded = decode_swap(tx["data"])
    normal_src = 0 if decoded["src_token"] == NATIVE_MARKER else decoded["src_token"]
    normal_dst = 0 if decoded["dst_token"] == NATIVE_MARKER else decoded["dst_token"]
    checks = {
        "source token binds to --src": normal_src == src,
        "destination token binds to --dst": normal_dst == dst,
        "destination receiver is --from": decoded["dst_receiver"] == sender,
        "amount binds to --amount": decoded["amount"] == args.amount,
        "router minReturn meets --min-return": decoded["min_return"] >= args.min_return,
        "partial-fill flag is clear (bit 0 assumption)": decoded["flags"] & PARTIAL_FILL_FLAG == 0,
    }
    for description, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'} {description}")
    if not all(checks.values()):
        return 1

    rpc_url = read_env_value("SEPOLIA_RPC_URL")
    if not rpc_url:
        raise RuntimeError("SEPOLIA_RPC_URL is missing or empty in .env and process environment")
    block_number = fetch_latest_block(rpc_url)
    fixture = {
        "blockNumber": block_number,
        "from": args.sender,
        "srcToken": args.src,
        "dstToken": args.dst,
        "amount": str(args.amount),
        "minReturn": str(args.min_return),
        "tx": {"to": tx["to"], "data": tx["data"]},
    }
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    fixture_path = FIXTURE_DIR / f"sepolia-{block_number}.json"
    fixture_path.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
    print(f"Saved calldata fixture: {fixture_path.relative_to(ROOT)}")
    print(f"Recorded block: {block_number}; no transaction was signed or broadcast")
    print("Note: this checks the encoded fields off-chain; it does not execute the W-2 Solidity library.")
    print("The partial-fill flag bit must be confirmed against verified router source.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, KeyError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
