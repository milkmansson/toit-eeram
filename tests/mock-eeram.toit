// Copyright (C) 2026 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import i2c
import io
import serial

/**
A simulated 47L04/47C04/47L16/47C16, for testing the driver without hardware.

The simulation follows the datasheet (DS20005371D):
- The device does not acknowledge (the access throws) while it executes a
  Store, a Recall or a STATUS register write cycle, and during the Auto-Recall
  after power-up.
- Sequential reads and writes wrap around at the end of the array.
- Writes into the block selected by the BP bits are not acknowledged.
- The AM bit is set by SRAM writes and cleared by Store and Recall.
- Auto-Store runs at power-down when ASE and AM are both set.
- The Software Store command runs regardless of the AM and ASE bits.

The EEPROM of a new device is assumed to read 0xFF.  The datasheet does not say
  so, but the driver relies on it to detect a blank device.

Use $MockEeramDevice to give the driver access to a chip.
*/
class MockEeramChip:
  capacity/int
  sram/ByteArray := ByteArray 0
  eeprom/ByteArray := ByteArray 0

  /** Duration of a Store in ms.  The datasheet maximum, unless changed. */
  store-ms/int := 25

  /** Duration of a Recall in ms.  The datasheet maximum, unless changed. */
  recall-ms/int := 5

  /** Duration of a STATUS register write cycle in ms. */
  twc-ms/int := 1

  /** Time in microseconds (monotonic) until which the device is busy. */
  busy-until-us/int := 0

  /** Number of Store operations executed. */
  store-count/int := 0

  /** Number of Recall operations executed. */
  recall-count/int := 0

  /** Number of STATUS register writes. */
  status-write-count/int := 0

  /** Number of SRAM write transactions. */
  data-write-count/int := 0

  /** Number of accesses refused because the device was busy. */
  nak-count/int := 0

  // Nonvolatile STATUS bits: BP2..BP0 (bits 4-2), ASE (bit 1), EVENT (bit 0).
  nv-status_/int := 0
  array-modified_/bool := false

  constructor .capacity --power-up-busy-ms/int=0:
    sram = ByteArray capacity
    eeprom = ByteArray capacity
    sram.fill 0xFF
    eeprom.fill 0xFF
    if capacity == 0x200:
      store-ms = 8
      recall-ms = 2
    busy-until-us = Time.monotonic-us + (power-up-busy-ms * 1000)

  /** The STATUS register value. */
  status -> int:
    value := nv-status_
    if array-modified_: value |= 0x80
    return value

  /** Simulates the HS pin detecting an event. */
  raise-event -> none:
    nv-status_ |= 0x01

  /**
  Simulates removing and restoring power.

  Runs the Auto-Store if enabled and needed, then the Auto-Recall.  The device
    is busy for $power-up-busy-ms afterwards.
  */
  power-cycle --power-up-busy-ms/int=0 -> none:
    if ((nv-status_ & 0x02) != 0) and array-modified_: eeprom.replace 0 sram
    sram.replace 0 eeprom
    array-modified_ = false
    busy-until-us = Time.monotonic-us + (power-up-busy-ms * 1000)

  /** The first address that is write-protected, or the capacity if none. */
  protected-start -> int:
    bp := (nv-status_ >> 2) & 0b111
    if bp == 0: return capacity
    if bp == 7: return 0
    // BP 1 to 6 protect the upper 1/64, 1/32, 1/16, 1/8, 1/4 and 1/2.
    divisor := 128 >> bp
    return capacity - (capacity / divisor)

  check-ready_ -> none:
    if Time.monotonic-us < busy-until-us:
      nak-count += 1
      throw "I2C_NAK"

  set-busy_ ms/int -> none:
    busy-until-us = Time.monotonic-us + (ms * 1000)

  control-read register/int size/int -> ByteArray:
    check-ready_
    if register != 0x00 or size != 1: throw "UNSUPPORTED"
    return #[status]

  control-write register/int bytes/ByteArray -> none:
    check-ready_
    if register == 0x00:
      if bytes.size < 1: throw "I2C_NAK"
      // Any data byte is valid.  The last one is written.  AM is read-only.
      nv-status_ = bytes[bytes.size - 1] & 0x1F
      status-write-count += 1
      set-busy_ twc-ms
    else if register == 0x55:
      // Exactly one data byte, and only the two commands are valid.
      if bytes.size != 1: throw "I2C_NAK"
      if bytes[0] == 0x33:
        eeprom.replace 0 sram
        array-modified_ = false
        store-count += 1
        set-busy_ store-ms
      else if bytes[0] == 0xDD:
        sram.replace 0 eeprom
        array-modified_ = false
        recall-count += 1
        set-busy_ recall-ms
      else:
        throw "I2C_NAK"
    else:
      throw "I2C_NAK"

  data-write address-bytes/ByteArray bytes/ByteArray -> none:
    check-ready_
    address := ((address-bytes[0] << 8) | address-bytes[1]) % capacity
    data-write-count += 1
    bytes.size.repeat: | i/int |
      location := (address + i) % capacity
      if location >= protected-start: throw "I2C_NAK"
      sram[location] = bytes[i]
      array-modified_ = true

  data-read address-bytes/ByteArray size/int -> ByteArray:
    check-ready_
    address := ((address-bytes[0] << 8) | address-bytes[1]) % capacity
    result := ByteArray size
    size.repeat: | i/int |
      result[i] = sram[(address + i) % capacity]
    return result

/**
An I2C device of a $MockEeramChip.

Use one instance with --control for the control registers, and one with
  --no-control for the SRAM array.
*/
class MockEeramDevice implements i2c.Device:
  chip_/MockEeramChip := ?
  control_/bool := ?
  address/int := 0
  address-bit-size/int := 7

  constructor .chip_ --control/bool:
    control_ = control
    if control: address = 0x18
    else: address = 0x50

  registers --byte-size/int=1 --byte-order/io.ByteOrder=io.BIG-ENDIAN -> serial.Registers:
    throw "UNSUPPORTED"

  write bytes/ByteArray -> none:
    throw "UNSUPPORTED"

  write bytes/ByteArray [failure] -> none:
    throw "UNSUPPORTED"

  write-reg register/int bytes/ByteArray -> none:
    if not control_: throw "UNSUPPORTED"
    chip_.control-write register bytes

  write-reg register/int bytes/ByteArray [failure] -> none:
    write-reg register bytes

  write-address address/ByteArray bytes/ByteArray -> none:
    if control_: throw "UNSUPPORTED"
    chip_.data-write address bytes

  write-address address/ByteArray bytes/ByteArray [failure] -> none:
    write-address address bytes

  read size/int -> ByteArray:
    throw "UNSUPPORTED"

  read size/int [failure] -> ByteArray:
    throw "UNSUPPORTED"

  read-into buffer/ByteArray size/int=buffer.size -> none:
    throw "UNSUPPORTED"

  read-reg register/int size/int -> ByteArray:
    if not control_: throw "UNSUPPORTED"
    return chip_.control-read register size

  read-reg register/int size/int [failure] -> ByteArray:
    return read-reg register size

  read-address address/ByteArray size/int -> ByteArray:
    if control_: throw "UNSUPPORTED"
    return chip_.data-read address size

  read-address address/ByteArray size/int [failure] -> ByteArray:
    return read-address address size

  write-read tx-buffer/io.Data size/int -> ByteArray:
    throw "UNSUPPORTED"

  write-read-into --tx-buffer/io.Data --rx-buffer/ByteArray size/int=rx-buffer.size -> none:
    throw "UNSUPPORTED"

  close -> none:
    // Nothing to release.
