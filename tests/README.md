# Tests

`eeram-mock-test.toit` runs the `Eeram`, `PersistentMap` and `PersistentCounter`
classes against a simulated chip (`mock-eeram.toit`).  No hardware is needed.

## Running
From the root of the package:
```
toit tests/eeram-mock-test.toit
```
or `make test`, which is also what the CI workflow
(`.github/workflows/ci.yml`) runs.

## The simulated chip
`MockEeramChip` follows the datasheet closely enough to catch the mistakes that
matter:
- accesses while the device is busy (it does not acknowledge during a store, a
  recall or a STATUS write),
- wrap-around at the end of the array,
- writes into block-protected areas,
- data lost at power-down unless it was stored.

`MockEeramDevice` presents it as an `i2c.Device`.

## What is covered
- `Eeram`: data round trip, bounds, ASE, block protection, store and recall,
  event flag, dump, acknowledge polling, power-up wait, typed accessors,
  address helpers.
- `PersistentMap`: basic map use, frame layout (header), single write per
  change, persistence, no-auto-store, recall, capacity, unencodable values,
  corrupt data, load state, regions, deferred flush, batching, tasks.
- `PersistentCounter`: persistence, wrap-around, validation.
