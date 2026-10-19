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
import ..src.persistentcounter show *
import .mock-eeram

QUIET ::= log.default.with-level log.FATAL-LEVEL

make-eeram chip/MockEeramChip --ack-polling/bool=false -> Eeram:
  return Eeram
      --data=(MockEeramDevice chip --no-control)
      --control=(MockEeramDevice chip --control)
      --capacity=chip.capacity
      --ack-polling=ack-polling
      --logger=QUIET

make-map chip/MockEeramChip --auto-store/bool=true --start/int=0 --size/int?=null --auto-flush/bool=true -> PersistentMap:
  return PersistentMap
      --data=(MockEeramDevice chip --no-control)
      --control=(MockEeramDevice chip --control)
      --capacity=chip.capacity
      --auto-store=auto-store
      --start=start
      --size=size
      --auto-flush=auto-flush
      --logger=QUIET

expect-throws [block] -> none:
  exception := catch: block.call
  expect (exception != null)

expect-bytes-equal expected/ByteArray actual/ByteArray -> none:
  expect-equals expected.size actual.size
  expected.size.repeat: expect-equals expected[it] actual[it]

/** Writes a header and payload frame to the chip, as the driver does. */
write-frame chip/MockEeramChip payload/ByteArray --version/int=1 -> none:
  crc := Crc16CcittFalse
  crc.add payload
  checksum := crc.get
  chip.sram[0] = 0x45
  chip.sram[1] = 0x4D
  chip.sram[2] = version
  chip.sram[3] = 0
  chip.sram[4] = payload.size >> 8
  chip.sram[5] = payload.size & 0xFF
  chip.sram.replace 6 checksum
  chip.sram.replace 8 payload

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
  test-typed-accessors
  test-address-helpers
  test-load-state
  test-map-region
  test-map-deferred-flush
  test-map-batch
  test-map-tasks
  test-counter
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
  expect-equals 0x45 chip.sram[0]
  expect-equals 0x4D chip.sram[1]
  expect-equals 1 chip.sram[2]
  expect-equals 0 chip.sram[3]
  expect-equals payload.size ((chip.sram[4] << 8) | chip.sram[5])
  crc := Crc16CcittFalse
  crc.add payload
  checksum := crc.get
  expect-bytes-equal checksum chip.sram[6..8]
  expect-bytes-equal payload chip.sram[8..8 + payload.size]

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
  chip.sram[8] = chip.sram[8] ^ 0x01
  expect (make-map chip).is-empty

  // A size that can not fit on the device is rejected without reading.
  chip = MockEeramChip 0x800
  pmap = make-map chip
  pmap["a"] = "hello"
  chip.sram[4] = 0x7F
  chip.sram[5] = 0xFF
  expect (make-map chip).is-empty

  // A size of zero is rejected.
  chip = MockEeramChip 0x800
  pmap = make-map chip
  pmap["a"] = "hello"
  chip.sram[4] = 0
  chip.sram[5] = 0
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

test-typed-accessors:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  eeram.write-uint8 0 0xAB
  expect-equals 0xAB (eeram.read-uint8 0)
  eeram.write-uint16 2 0xBEEF
  expect-equals 0xBEEF (eeram.read-uint16 2)
  expect-equals 0xBE chip.sram[2]
  eeram.write-uint32 4 0xDEADBEEF
  expect-equals 0xDEADBEEF (eeram.read-uint32 4)
  eeram.write-int32 8 -12345
  expect-equals -12345 (eeram.read-int32 8)
  eeram.write-float64 16 3.25
  expect-equals 3.25 (eeram.read-float64 16)
  expect-equals "OUT_OF_BOUNDS" (catch: eeram.read-uint32 0x7FE)
  expect-equals "OUT_OF_BOUNDS" (catch: eeram.write-float64 0x7FC 1.0)

test-address-helpers:
  expect-equals 0x50 (Eeram.data-address-for)
  expect-equals 0x52 (Eeram.data-address-for --a1)
  expect-equals 0x54 (Eeram.data-address-for --a2)
  expect-equals 0x56 (Eeram.data-address-for --a1 --a2)
  expect-equals 0x18 (Eeram.control-address-for)
  expect-equals 0x1A (Eeram.control-address-for --a1)
  expect-equals 0x1C (Eeram.control-address-for --a2)
  expect-equals 0x1E (Eeram.control-address-for --a1 --a2)

test-load-state:
  chip := MockEeramChip 0x800
  expect-equals PersistentMap.LOAD-NEW (make-map chip).load-state
  pmap := make-map chip
  pmap["a"] = 1
  expect-equals PersistentMap.LOAD-OK (make-map chip).load-state
  // Blank checksum: corrupt.
  pmap.blank-checksum
  expect-equals PersistentMap.LOAD-CORRUPT (make-map chip).load-state

  // Foreign data: magic mismatch.
  chip = MockEeramChip 0x800
  chip.sram[0] = 0x12
  chip.sram[1] = 0x34
  expect-equals PersistentMap.LOAD-CORRUPT (make-map chip).load-state

  // Old 4-byte layout (size, checksum, data) is not migrated.
  chip = MockEeramChip 0x800
  payload := tison.encode {"a": 1}
  chip.sram[1] = payload.size
  chip.sram.replace 4 payload
  old := make-map chip
  expect old.is-empty
  expect-equals PersistentMap.LOAD-CORRUPT old.load-state

  // Unknown version.
  chip = MockEeramChip 0x800
  write-frame chip (tison.encode {"a": 1}) --version=2
  expect-equals PersistentMap.LOAD-CORRUPT (make-map chip).load-state

  // Recall refreshes the state.
  chip = MockEeramChip 0x800
  pmap = make-map chip
  pmap["a"] = 1
  pmap.store
  pmap.recall
  expect-equals PersistentMap.LOAD-OK pmap.load-state

test-map-region:
  chip := MockEeramChip 0x800
  first := make-map chip --start=0 --size=0x100
  second := make-map chip --start=0x100 --size=0x100
  first["name"] = "one"
  second["name"] = "two"
  expect-equals 0x45 chip.sram[0]
  expect-equals 0x45 chip.sram[0x100]
  chip.power-cycle
  first = make-map chip --start=0 --size=0x100
  second = make-map chip --start=0x100 --size=0x100
  expect-equals "one" first["name"]
  expect-equals "two" second["name"]
  expect-equals 0x100 first.bytes-capacity

  // A region limits the map.
  big-bytes := ByteArray 300
  big-bytes.fill 'x'
  expect-equals "PersistentMap capacity exceeded" (catch: first["big"] = big-bytes.to-string)
  // Nothing spilled into the other region.
  expect-equals "two" second["name"]

  expect-throws: make-map chip --start=0x7F8 --size=0x100
  expect-throws: make-map chip --start=-1
  expect-throws: make-map chip --start=0 --size=4

test-map-deferred-flush:
  chip := MockEeramChip 0x800
  pmap := make-map chip --no-auto-flush
  before := chip.data-write-count
  pmap["a"] = 1
  pmap["b"] = 2
  expect-equals before chip.data-write-count
  expect pmap.pending-flush
  expect-equals 1 pmap["a"]
  // Validation still happens immediately.
  expect-throws: pmap["bad"] = (:: 1)
  expect (not (pmap.contains "bad"))
  pmap.flush
  expect-equals (before + 1) chip.data-write-count
  expect (not pmap.pending-flush)
  // Nothing pending: no write.
  pmap.flush
  expect-equals (before + 1) chip.data-write-count
  expect-equals 2 (make-map chip).size

  // Store flushes first.
  pmap["c"] = 3
  pmap.store
  expect (not pmap.pending-flush)
  chip.power-cycle
  expect-equals 3 (make-map chip).size

  // Recall discards pending changes.
  pmap = make-map chip --no-auto-flush
  pmap["d"] = 4
  pmap.recall
  expect (not pmap.pending-flush)
  expect (not (pmap.contains "d"))

test-map-batch:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  before := chip.data-write-count
  pmap.batch:
    pmap["a"] = 1
    pmap["b"] = 2
    pmap.remove "a"
    expect pmap.pending-flush
    expect-equals before chip.data-write-count
  expect-equals (before + 1) chip.data-write-count
  expect (not pmap.pending-flush)
  expect-equals 1 (make-map chip).size

  // Nested batches write once, at the end of the outer one.
  before = chip.data-write-count
  pmap.batch:
    pmap.batch:
      pmap["c"] = 3
    expect-equals before chip.data-write-count
  expect-equals (before + 1) chip.data-write-count

  // A throwing block still writes what was changed.
  exception := catch:
    pmap.batch:
      pmap["d"] = 4
      throw "boom"
  expect-equals "boom" exception
  expect-equals 3 (make-map chip).size

test-map-tasks:
  chip := MockEeramChip 0x800
  pmap := make-map chip
  done := 0
  4.repeat: | n/int |
    task::
      20.repeat: | i/int | pmap["k-$n-$i"] = i
      done++
  while done < 4: sleep --ms=5
  expect-equals 80 pmap.size
  // The device holds the complete final state.
  expect-equals 80 (make-map chip).size

test-counter:
  chip := MockEeramChip 0x800
  eeram := make-eeram chip
  counter := PersistentCounter eeram --address=0x20
  expect (not counter.was-valid)
  expect-equals 0 counter.value
  expect-equals 1 counter.increment
  expect-equals 6 (counter.increment --by=5)
  eeram.store
  chip.power-cycle
  again := PersistentCounter (make-eeram chip) --address=0x20
  expect again.was-valid
  expect-equals 6 again.value
  // Wraps at 32 bits.
  again.set 0xFFFFFFFF
  expect-equals 0 again.increment
  // A broken complement is detected.
  chip.sram[0x27] = chip.sram[0x27] ^ 0x01
  broken := PersistentCounter (make-eeram chip) --address=0x20 --initial=9
  expect (not broken.was-valid)
  expect-equals 9 broken.value
  expect-equals "OUT_OF_BOUNDS" (catch: PersistentCounter (make-eeram chip) --address=0x7FC)
