// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import i2c
import ..src.eeram show Eeram

/**
Example of using the Eeram driver directly as a small battery-free memory.

Shows byte and typed access, store/recall, and block protection.
*/

SDA-PIN ::= 8
SCL-PIN ::= 9

main:
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN --frequency=400_000
  eeram := Eeram.from-bus bus --capacity=Eeram.CAPACITY-16KBIT

  // Raw bytes.
  eeram.write-data 0x00 #[1, 2, 3, 4]
  print "Bytes: $(eeram.read-data 0x00 4)"

  // Typed values (big-endian).
  eeram.write-uint16 0x10 0xBEEF
  eeram.write-float64 0x18 21.5
  print "uint16: 0x$(%04x (eeram.read-uint16 0x10))"
  print "float64: $(eeram.read-float64 0x18)"

  // SRAM writes cost no EEPROM endurance.  Only a store does, and it is
  // skipped when nothing changed.
  print "Changed since last store: $(eeram.has-changed)"
  eeram.store
  print "Changed after store: $(eeram.has-changed)"

  // Protect the upper quarter of the array against writes.
  eeram.enable-block-protection --portion=Eeram.BP-UPPER-1-4-PROTECTED
  print "Protected: $(eeram.block-protection-enabled)"
  eeram.disable-block-protection
