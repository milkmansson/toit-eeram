// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import io show BIG-ENDIAN
import .eeram

/**
A persistent 32-bit counter on the Microchip 47L04/47C04/47L16/47C16 SRAM/FLASH IC.

The counter is kept at a fixed address on the device as the value, followed by
  its bitwise complement.  Both are written in a single transfer, and are
  compared at start-up to detect a counter that was not saved completely or was
  overwritten.  Increments only touch the SRAM, so they do not wear the FLASH.
  The device stores the SRAM to FLASH on power loss (when Auto-Store is enabled
  and a capacitor is fitted), or on $Eeram.store.

The counter wraps around to 0 after 4294967295.
*/
class PersistentCounter:
  /** The number of bytes the counter uses on the device. */
  static SIZE ::= 8

  driver_/Eeram
  address_/int
  value_/int := 0
  valid_/bool := false

  /**
  Constructs a counter at the given $address of the $driver.

  If the stored data is not a valid counter (blank chip, or overwritten), the
    counter starts at $initial and $was-valid is false.
  */
  constructor driver/Eeram --address/int --initial/int=0:
    if not 0 <= address <= driver.capacity - SIZE: throw "OUT_OF_BOUNDS"
    driver_ = driver
    address_ = address
    bytes := driver.read-data address SIZE
    stored := BIG-ENDIAN.uint32 bytes 0
    complement := BIG-ENDIAN.uint32 bytes 4
    if (stored ^ complement) == 0xFFFFFFFF:
      value_ = stored
      valid_ = true
    else:
      set initial

  /** Whether the stored data was a valid counter when the counter was constructed. */
  was-valid -> bool:
    return valid_

  /** The current value. */
  value -> int:
    return value_

  /** Increments the counter by $by, and returns the new value. */
  increment --by/int=1 -> int:
    set (value_ + by) & 0xFFFFFFFF
    return value_

  /** Sets the counter to the $new-value (0 to 4294967295). */
  set new-value/int -> none:
    if not 0 <= new-value <= 0xFFFFFFFF: throw "OUT_OF_RANGE"
    bytes := ByteArray SIZE
    BIG-ENDIAN.put-uint32 bytes 0 new-value
    BIG-ENDIAN.put-uint32 bytes 4 (new-value ^ 0xFFFFFFFF)
    driver_.write-data address_ bytes
    value_ = new-value

  /** Sets the counter to 0. */
  reset -> none:
    set 0
