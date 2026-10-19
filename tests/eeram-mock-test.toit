// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

/**
Tests the Eeram and PersistentMap classes against a simulated chip.  No
  hardware is needed.

Run from the root of the package with:
```
toit tests/eeram-mock-test.toit
```

The simulation ($MockEeramChip) follows the datasheet closely enough to catch
  the mistakes that matter: accesses while the device is busy, wrap-around at
  the end of the array, writes into protected blocks, and data lost at
  power-down.
*/

import crypto.crc show Crc16CcittFalse
import encoding.tison
import expect show *
import log
import ..src.eeram show *
import ..src.persistentmap show *
import .mock-eeram

QUIET ::= log.default.with-level log.FATAL-LEVEL

make-eeram chip/MockEeramChip --ack-polling/bool=false -> Eeram:
  return Eeram
      --data=(MockEeramDevice chip --no-control)
      --control=(MockEeramDevice chip --control)
      --capacity=chip.capacity
      --ack-polling=ack-polling
      --logger=QUIET

make-map chip/MockEeramChip --auto-store/bool=true -> PersistentMap:
  return PersistentMap
      --data=(MockEeramDevice chip --no-control)
      --control=(MockEeramDevice chip --control)
      --capacity=chip.capacity
      --auto-store=auto-store
      --logger=QUIET

expect-throws [block] -> none:
  exception := catch: block.call
  expect (exception != null)

expect-bytes-equal expected/ByteArray actual/ByteArray -> none:
  expect-equals expected.size actual.size
  expected.size.repeat: expect-equals expected[it] actual[it]

/** Writes a size, checksum and payload frame to the chip, as the driver does. */
write-frame chip/MockEeramChip payload/ByteArray -> none:
  crc := Crc16CcittFalse
  crc.add payload
  checksum := crc.get
  chip.sram[0] = payload.size >> 8
  chip.sram[1] = payload.size & 0xFF
  chip.sram.replace 2 checksum
  chip.sram.replace 4 payload

main:
  test-data-round-trip
  test-bounds
  test-ase
  test-block-protection
  test-store-recall
  test-event
  test-dump-near-end
  test-ack-polling
  test-power-up
  test-map-basics
  test-map-frame-layout
  test-map-single-write
  test-map-persistence
  test-map-no-auto-store
  test-map-recall
  test-map-capacity
  test-map-unencodable
  test-map-corrupt
  print "All eeram tests passed."

test-data-round-trip:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  expect (not eeram.has-changed)
  eeram.write-data 0x10 #[1, 2, 3, 4]
  expect-bytes-equal #[1, 2, 3, 4] (eeram.read-data 0x10 4)
  expect eeram.has-changed

test-bounds:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  expect-equals "OUT_OF_BOUNDS" (catch: eeram.write-data 0x7FE #[1, 2, 3])
  expect-equals "OUT_OF_BOUNDS" (catch: eeram.read-data 0x7FE 3)
  expect-equals "OUT_OF_BOUNDS" (catch: eeram.write-data (-1) #[1])
  // Nothing wrapped around to address 0, and nothing reached the device.
  expect-equals 0xFF chip.sram[0]
  expect-equals 0 chip.data-write-count
  // Writing exactly up to the end is fine.
  eeram.write-data 0x7FD #[1, 2, 3]
  expect-equals 3 chip.sram[0x7FF]

  small := MockEeramChip 0x200
  small-eeram := make-eeram small
  expect-equals "OUT_OF_BOUNDS" (catch: small-eeram.write-data 0x1FE #[1, 2, 3])
  small-eeram.write-data 0x1FD #[1, 2, 3]
  expect-equals 3 small.sram[0x1FF]

test-ase:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  expect (not eeram.ase-enabled)
  writes := chip.status-write-count
  eeram.enable-ase
  expect eeram.ase-enabled
  expect-equals (writes + 1) chip.status-write-count
  // Already enabled: no STATUS write cycle is started.
  eeram.enable-ase
  expect-equals (writes + 1) chip.status-write-count
  eeram.disable-ase
  expect (not eeram.ase-enabled)

test-block-protection:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  eeram.enable-block-protection --portion=Eeram.BP-UPPER-1-4-PROTECTED
  expect-equals Eeram.BP-UPPER-1-4-PROTECTED eeram.block-protection-value
  expect eeram.block-protection-enabled
  // The upper quarter of a 16 Kbit device starts at 0x600.
  eeram.write-data 0x5FF #[1]
  expect-throws: eeram.write-data 0x600 #[1]
  // Changing another STATUS bit keeps the protection setting.
  eeram.enable-ase
  expect-equals Eeram.BP-UPPER-1-4-PROTECTED eeram.block-protection-value
  eeram.disable-block-protection
  expect (not eeram.block-protection-enabled)
  expect eeram.ase-enabled
  eeram.write-data 0x600 #[1]

test-store-recall:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  eeram.write-data 0 #[10, 20, 30]
  expect eeram.has-changed
  eeram.store
  expect-equals 1 chip.store-count
  expect (not eeram.has-changed)
  // Nothing changed, so no second Store (it would only wear the EEPROM).
  eeram.store
  expect-equals 1 chip.store-count
  eeram.write-data 0 #[99]
  eeram.recall
  expect-equals 1 chip.recall-count
  expect-bytes-equal #[10, 20, 30] (eeram.read-data 0 3)
  expect (not eeram.has-changed)

test-event:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  expect (not eeram.event-detected)
  chip.raise-event
  expect eeram.event-detected
  eeram.clear-event
  expect (not eeram.event-detected)

test-dump-near-end:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  // Asks for more rows than are left.  Must stop at the end of the device.
  eeram.dump-sram 0x7E0 --rows=10

test-ack-polling:
  // A device that takes longer than the fixed wait: the fixed wait runs out
  // too early, so the next access is refused.
  slow := MockEeramChip 0x800
  slow.store-ms = 60
  eeram := make-eeram slow
  eeram.write-data 0 #[1]
  eeram.store
  expect-throws: eeram.has-changed

  // With polling the driver waits until the device responds.
  slow2 := MockEeramChip 0x800
  slow2.store-ms = 60
  polling := make-eeram slow2 --ack-polling
  polling.write-data 0 #[1]
  polling.store
  expect (not polling.has-changed)
  expect (slow2.nak-count > 0)

  // A device that never recovers makes polling give up.
  stuck := MockEeramChip 0x800
  stuck.store-ms = 5_000
  giving-up := make-eeram stuck --ack-polling
  giving-up.write-data 0 #[1]
  expect-throws: giving-up.store

  // Normal operations work in polling mode too.
  fast := MockEeramChip 0x800
  fast-polling := make-eeram fast --ack-polling
  fast-polling.enable-ase
  expect fast-polling.ase-enabled
  fast-polling.write-data 0 #[7]
  fast-polling.store
  fast-polling.recall
  expect-bytes-equal #[7] (fast-polling.read-data 0 1)

test-power-up:
  // The constructor waits for the Auto-Recall of the device to finish.
  chip := MockEeramChip 0x800 --power-up-busy-ms=20
  eeram := make-eeram chip
  expect (not eeram.ase-enabled)

  // A device that never responds fails the constructor.
  stuck := MockEeramChip 0x800 --power-up-busy-ms=60_000
  expect-throws: make-eeram stuck

test-map-basics:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  expect pmap.is-empty
  pmap["a"] = 1
  pmap["b"] = "two"
  expect-equals 2 pmap.size
  expect-equals 1 pmap["a"]
  expect-equals "two" pmap["b"]
  expect (pmap.contains "a")
  expect (not (pmap.contains "z"))
  expect-equals null (pmap.get "z")
  expect-equals 1 (pmap.get "a")
  expect-equals 7 (pmap.get "z" --if-absent=: 7)
  expect-throws: pmap["z"]
  expect-equals 2 pmap.keys.size
  expect-equals 2 pmap.values.size
  pairs := {:}
  pmap.do: | key value | pairs[key] = value
  expect-equals 1 pairs["a"]
  expect-equals "two" pairs["b"]
  pmap.remove "a"
  expect (not (pmap.contains "a"))
  // Removing a missing key is fine.
  pmap.remove "nothing"
  pmap.clear
  expect pmap.is-empty

test-map-frame-layout:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  pmap["a"] = 1
  payload := tison.encode {"a": 1}
  expect-equals payload.size ((chip.sram[0] << 8) | chip.sram[1])
  crc := Crc16CcittFalse
  crc.add payload
  checksum := crc.get
  expect-bytes-equal checksum chip.sram[2..4]
  expect-bytes-equal payload chip.sram[4..4 + payload.size]

test-map-single-write:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  before := chip.data-write-count
  pmap["x"] = 1
  // Size, checksum and data go out as one transaction.
  expect-equals (before + 1) chip.data-write-count
  pmap.remove "missing"
  expect-equals (before + 1) chip.data-write-count

test-map-persistence:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  expect pmap.ase-enabled
  pmap["name"] = "lamp"
  pmap["count"] = 42
  chip.power-cycle
  again := make-map chip
  expect-equals "lamp" again["name"]
  expect-equals 42 again["count"]

test-map-no-auto-store:
  chip := MockEeramChip 0x800
  pmap := make-map chip --no-auto-store
  expect (not pmap.ase-enabled)
  pmap["k"] = 1
  // Without Auto-Store the change is lost at power-down.
  chip.power-cycle
  again := make-map chip --no-auto-store
  expect again.is-empty
  again["k"] = 2
  again.store
  chip.power-cycle
  stored := make-map chip --no-auto-store
  expect-equals 2 stored["k"]

test-map-recall:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  pmap["a"] = 1
  pmap.store
  pmap["a"] = 2
  expect-equals 2 pmap["a"]
  pmap.recall
  expect-equals 1 pmap["a"]

test-map-capacity:
  chip := MockEeramChip 0x200
  pmap := make-map chip
  pmap["small"] = 1
  big-bytes := ByteArray 600
  big-bytes.fill 'x'
  big := big-bytes.to-string
  expect-equals "PersistentMap capacity exceeded" (catch: pmap["big"] = big)
  expect-equals 1 pmap.size
  expect (not (pmap.contains "big"))
  // Replacing a value by one that does not fit leaves the old value.
  expect-throws: pmap["small"] = big
  expect-equals 1 pmap["small"]
  // The device still holds the last good state.
  again := make-map chip
  expect-equals 1 again.size
  expect-equals 1 again["small"]

  // Fill the map until it is full.
  full-chip := MockEeramChip 0x200
  full := make-map full-chip
  added := 0
  200.repeat: | i/int |
    if (catch: full["key-$i"] = i) == null: added += 1
  expect (added > 10)
  expect (full.bytes-available >= 0)
  reloaded := make-map full-chip
  expect-equals full.size reloaded.size

test-map-unencodable:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  pmap["a"] = 1
  expect-throws: pmap["bad"] = (:: 1)
  expect (not (pmap.contains "bad"))
  expect-equals 1 pmap.size
  // The map keeps working.
  pmap["b"] = 2
  expect-equals 2 pmap.size

test-map-corrupt:
  // A flipped data bit fails the checksum.
  chip := MockEeramChip 0x800
  pmap := make-map chip
  pmap["a"] = "hello"
  chip.sram[4] = chip.sram[4] ^ 0x01
  expect (make-map chip).is-empty

  // A size that can not fit on the device is rejected without reading.
  chip = MockEeramChip 0x800
  pmap = make-map chip
  pmap["a"] = "hello"
  chip.sram[0] = 0x7F
  chip.sram[1] = 0xFF
  expect (make-map chip).is-empty

  // A size of zero is rejected.
  chip = MockEeramChip 0x800
  pmap = make-map chip
  pmap["a"] = "hello"
  chip.sram[0] = 0
  chip.sram[1] = 0
  expect (make-map chip).is-empty

  // The test helper that blanks the checksum.
  chip = MockEeramChip 0x800
  pmap = make-map chip
  pmap["a"] = "hello"
  pmap.blank-checksum
  expect (make-map chip).is-empty

  // A good checksum over data that is not a map.
  chip = MockEeramChip 0x800
  write-frame chip (tison.encode [1, 2, 3])
  expect (make-map chip).is-empty

  // A good checksum over data that can not be decoded.
  chip = MockEeramChip 0x800
  write-frame chip #[0xFF, 0xFE, 0xFD, 0xFC]
  expect (make-map chip).is-empty

  // A frame written by other means is accepted.
  chip = MockEeramChip 0x800
  write-frame chip (tison.encode {"x": 5})
  expect-equals 5 (make-map chip)["x"]
