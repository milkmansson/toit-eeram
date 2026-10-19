// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import i2c
import ..src.eeram show Eeram
import ..src.persistentmap show PersistentMap
import ..src.persistentcounter show PersistentCounter

/**
Example of the bus-level factory, a map in part of the device, batched
  changes, and a persistent counter.

The counter lives in the first 8 bytes of the device and the map in the rest.
*/

SDA-PIN ::= 8
SCL-PIN ::= 9

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN --frequency=400_000

  // Find chips by their address pin settings.
  print "Chips found: $(Eeram.scan bus)"

  // Both I2C addresses are derived from the pin settings.  Here A1 and A2 are
  // tied low.
  eeram := Eeram.from-bus bus --capacity=Eeram.CAPACITY-16KBIT

  boots := PersistentCounter eeram --address=0
  boots.increment
  print "Boot number $(boots.value)"

  settings := PersistentMap eeram --start=PersistentCounter.SIZE
  print "Map loaded: state $(settings.load-state) (0 new, 1 ok, 2 corrupt)"

  // One write to the SRAM for all three changes.
  settings.batch:
    settings["name"] = "lamp"
    settings["brightness"] = 80
    settings["boots"] = boots.value
  print "Map: $(settings)"
