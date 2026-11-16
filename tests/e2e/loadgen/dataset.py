"""Fills Kvrocks with synthetic data shaped like a production workload.

The keys fall into four families, in the proportions and sizes of a real instance:

- about 90 % are small hashes, `small_hash:<group>:<period>:<id>`, with 3 to 5 short
  fields and no TTL;
- a few percent are medium hashes keyed by a SHA-256, a few hundred bytes each and growing
  with the number of versions they hold;
- the rest are short-lived strings and a handful of large lists kept for a day.

Values are random, so that RocksDB cannot compress them away. Prints a JSON report.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import time
import uuid
from collections.abc import Iterator
from dataclasses import dataclass

import redis
from redis.backoff import NoBackoff
from redis.retry import Retry

BYTES_PER_GIB = 1024**3
PIPELINE_SIZE = 500
# RocksDB stores the prefix that consecutive keys share only once, so the number of distinct
# prefixes changes the size on disk: small hash keys spread over GROUPS x PERIODS of them.
GROUPS = 8
PERIODS = ("2601", "2602", "2603", "2604", "2605", "2606", "2607", "2608", "2609", "2610")
SECONDS_PER_DAY = 86_400

# Share of each family among the keys written.
SMALL_HASH_SHARE = 0.90
MEDIUM_HASH_SHARE = 0.07
SHORT_LIVED_SHARE = 0.029
# What remains (0.1 %) are large lists.

MAX_REFERENCES = 3
MAX_VERSIONS = 5
LARGE_LIST_ITEMS = 5
LARGE_LIST_ITEM_BYTES = 30_000
SHORT_LIVED_TTL_SECONDS = 3_600


@dataclass(frozen=True)
class Record:
    """One key to write, with the bytes it carries, key included."""

    key: str
    kind: str
    fields: dict[str, str] | None = None
    value: str | None = None
    items: list[str] | None = None
    ttl_seconds: int | None = None

    @property
    def size(self) -> int:
        """Bytes of key and payload, as sent over the wire."""
        payload = 0
        if self.fields is not None:
            payload = sum(len(name) + len(value) for name, value in self.fields.items())
        if self.value is not None:
            payload = len(self.value)
        if self.items is not None:
            payload = sum(len(item) for item in self.items)
        return len(self.key) + payload


def random_hex(rng: random.Random, length: int) -> str:
    """Returns `length` random hexadecimal characters."""
    return f"{rng.getrandbits(length * 4):0{length}x}"


def small_hash_record(rng: random.Random) -> Record:
    """A small hash with one-letter field names, written once and never expired."""
    key = (
        f"small_hash:group-{rng.randrange(GROUPS)}:{rng.choice(PERIODS)}:"
        f"{rng.randrange(10**18, 10**19)}"
    )
    references = "|".join(
        str(uuid.UUID(int=rng.getrandbits(128))) for _ in range(rng.randint(0, MAX_REFERENCES))
    )
    fields = {"d": random_hex(rng, 64), "r": references, "p": str(rng.choice((0, 0, 0, 5, 10)))}
    if rng.random() < 0.5:
        fields["g"] = "" if rng.random() < 0.7 else f"label-{rng.randrange(100)}"
        fields["t"] = "" if rng.random() < 0.8 else str(rng.randrange(1000))
    return Record(key=key, kind="small_hash", fields=fields)


def medium_hash_record(rng: random.Random) -> Record:
    """A hash keyed by a SHA-256 that lists the versions of a stored object."""
    key = random_hex(rng, 64)
    versions = {
        random_hex(rng, 64): {"version": number, "location": "archive-rollover-0001"}
        for number in range(1, rng.randint(1, MAX_VERSIONS) + 1)
    }
    fields = {
        "refs": "|".join(random_hex(rng, 32) for _ in range(rng.randint(1, 3))),
        "version": str(len(versions)),
        "priority": str(rng.choice((0, 5))),
        "versions": json.dumps(versions),
        "date": time.strftime(
            "%Y-%m-%d %H:%M:%S", time.gmtime(rng.randrange(1_700_000_000, 1_800_000_000))
        ),
        "path": f"objects/{key}.bin",
    }
    return Record(key=key, kind="medium_hash", fields=fields)


def short_lived_record(rng: random.Random) -> Record:
    """A status flag: a SHA-256 key, a tiny value, an expiry."""
    return Record(
        key=random_hex(rng, 64),
        kind="short_lived",
        value=str(rng.randrange(1, 4)),
        ttl_seconds=SHORT_LIVED_TTL_SECONDS,
    )


def large_list_record(rng: random.Random) -> Record:
    """A list of a few large JSON documents, kept for a day."""
    items = [
        json.dumps({"id": random_hex(rng, 16), "body": random_hex(rng, LARGE_LIST_ITEM_BYTES)})
        for _ in range(LARGE_LIST_ITEMS)
    ]
    return Record(
        key=f"large_list:{uuid.UUID(int=rng.getrandbits(128))}",
        kind="large_list",
        items=items,
        ttl_seconds=SECONDS_PER_DAY,
    )


def records(rng: random.Random) -> Iterator[Record]:
    """An endless stream of records, in production proportions."""
    while True:
        draw = rng.random()
        if draw < SMALL_HASH_SHARE:
            yield small_hash_record(rng)
        elif draw < SMALL_HASH_SHARE + MEDIUM_HASH_SHARE:
            yield medium_hash_record(rng)
        elif draw < SMALL_HASH_SHARE + MEDIUM_HASH_SHARE + SHORT_LIVED_SHARE:
            yield short_lived_record(rng)
        else:
            yield large_list_record(rng)


def queue(pipe: redis.client.Pipeline, record: Record) -> None:
    """Adds the commands that write one record to a pipeline."""
    if record.fields is not None:
        pipe.hset(record.key, items=[part for pair in record.fields.items() for part in pair])
    elif record.items is not None:
        pipe.rpush(record.key, *record.items)
    else:
        pipe.set(record.key, record.value or "")
    if record.ttl_seconds is not None:
        pipe.expire(record.key, record.ttl_seconds)


def parse_args() -> argparse.Namespace:
    """Parses the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="write endpoint")
    parser.add_argument("--port", type=int, default=6379)
    parser.add_argument(
        "--gigabytes", type=float, required=True, help="bytes to send, keys included"
    )
    parser.add_argument("--seed", type=int, default=0, help="the same seed writes the same data")
    return parser.parse_args()


def main() -> None:
    """Writes until the target size is reached, then prints the JSON report."""
    args = parse_args()
    client = redis.Redis(
        host=args.host,
        port=args.port,
        password=os.environ.get("KVROCKS_PASSWORD") or None,
        socket_timeout=30,
        retry=Retry(NoBackoff(), 0),
    )
    target = int(args.gigabytes * BYTES_PER_GIB)
    written = 0
    keys: dict[str, int] = {}
    started = time.monotonic()
    pipe = client.pipeline(transaction=False)
    stream = records(random.Random(args.seed))
    while written < target:
        for _ in range(PIPELINE_SIZE):
            record = next(stream)
            queue(pipe, record)
            written += record.size
            keys[record.kind] = keys.get(record.kind, 0) + 1
        pipe.execute()
    elapsed = time.monotonic() - started
    report = {
        "bytes": written,
        "keys": keys,
        "seconds": round(elapsed, 1),
        "mebibytes_per_second": round(written / (1024**2) / elapsed, 1),
    }
    print(json.dumps(report))


if __name__ == "__main__":
    main()
