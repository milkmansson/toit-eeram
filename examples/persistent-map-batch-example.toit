// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import i2c
import ..src.eeram show Eeram
import ..src.persistentmap show PersistentMap

/**
Example of deferring the writes of a PersistentMap.

By default every change is sent to the SRAM at once, as the whole map in one
  I2C transfer.  When several entries change together, that is repeated for
  each change.  There are two ways to send the map only once:
  - $PersistentMap.batch: the map is written when the block ends.
  - `--no-auto-flush` with $PersistentMap.flush: the map is written when asked.

Neither wears the EEPROM.  SRAM writes cost bus time only, and the EEPROM is
  only used by a store.  Changes are validated immediately in all modes, so a
  value that can not be encoded or does not fit still throws at the line that
  caused it.
*/

SDA-PIN ::= 8
SCL-PIN ::= 9

ENTRIES ::= 20

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN --frequency=400_000
  eeram := Eeram.from-bus bus --capacity=Eeram.CAPACITY-16KBIT

  // 1. Default: one SRAM write per change.
  pmap := PersistentMap eeram
  pmap.clear
  start := Time.monotonic-us
  ENTRIES.repeat: | i/int | pmap["key-$i"] = i
  immediate-us := Time.monotonic-us - start
  print "Immediate writes: $(ENTRIES) changes took $(immediate-us / 1000) ms"

  // 2. batch: the same changes, one SRAM write when the block ends.
  pmap.clear
  start = Time.monotonic-us
  pmap.batch:
    ENTRIES.repeat: | i/int | pmap["key-$i"] = i
    // Inside the batch, the map in memory is current, but the SRAM is not yet.
    if pmap.pending-flush: print "Pending inside the batch: $(pmap.pending-flush)"
  batched-us := Time.monotonic-us - start
  print "Batched: $(ENTRIES) changes took $(batched-us / 1000) ms"
  print "Pending after the batch: $(pmap.pending-flush)"

  // Batches can be nested: only the outermost one writes.  The map is also
  // written if the block throws, so changes made before the error are kept.

  // 3. --no-auto-flush: nothing is written until flush (or store) is called.
  // Useful when changes arrive over time, and a periodic write is enough.
  lazy := PersistentMap eeram --no-auto-flush
  lazy["a"] = 1
  lazy["b"] = 2
  print "Pending with --no-auto-flush: $(lazy.pending-flush)"
  lazy.flush
  print "Pending after flush: $(lazy.pending-flush)"

  // store writes pending changes to the SRAM first, then stores the SRAM to the
  // EEPROM.  This is the only step that uses an EEPROM store cycle.
  lazy["c"] = 3
  lazy.store
  print "Pending after store: $(lazy.pending-flush)"
