"""Unit tests of the synthetic dataset."""

import random
import re
from itertools import islice

import dataset

SAMPLE_SIZE = 20_000
SHARE_TOLERANCE = 0.02


def sample() -> list[dataset.Record]:
    return list(islice(dataset.records(random.Random(42)), SAMPLE_SIZE))


def test_the_families_come_in_production_proportions() -> None:
    # Arrange
    records = sample()

    # Act
    small_share = sum(record.kind == "small_hash" for record in records) / SAMPLE_SIZE
    medium_share = sum(record.kind == "medium_hash" for record in records) / SAMPLE_SIZE

    # Assert
    assert abs(small_share - dataset.SMALL_HASH_SHARE) < SHARE_TOLERANCE
    assert abs(medium_share - dataset.MEDIUM_HASH_SHARE) < SHARE_TOLERANCE


def test_a_small_hash_key_starts_with_one_of_the_shared_prefixes() -> None:
    # Act
    record = dataset.small_hash_record(random.Random(1))

    # Assert
    assert re.fullmatch(r"small_hash:group-\d:\d{4}:\d{19}", record.key)
    assert record.fields is not None
    assert {"d", "r", "p"} <= record.fields.keys()
    assert len(record.fields["d"]) == 64


def test_a_small_hash_is_small_and_never_expires() -> None:
    # Arrange
    rng = random.Random(7)

    # Act
    records = [dataset.small_hash_record(rng) for _ in range(1000)]

    # Assert
    assert all(record.ttl_seconds is None for record in records)
    assert 100 < sum(record.size for record in records) / len(records) < 300


def test_the_same_seed_writes_the_same_data() -> None:
    # Act
    first = list(islice(dataset.records(random.Random(3)), 50))
    second = list(islice(dataset.records(random.Random(3)), 50))

    # Assert
    assert first == second


def test_short_lived_and_large_list_keys_expire() -> None:
    # Arrange
    rng = random.Random(5)

    # Act
    short_lived = dataset.short_lived_record(rng)
    large_list = dataset.large_list_record(rng)

    # Assert
    assert short_lived.ttl_seconds == dataset.SHORT_LIVED_TTL_SECONDS
    assert large_list.ttl_seconds == dataset.SECONDS_PER_DAY
    assert large_list.size > dataset.LARGE_LIST_ITEM_BYTES
