// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import serial.device as serial
import serial.registers as registers
import encoding.tison
import gpio
import log
import io show LITTLE-ENDIAN
import io show BIG-ENDIAN
import i2c

/**
A Toit driver library for the Microchip 47L04/47C04/47L16/47C16 SRAM/FLASH IC.

The Microchip Technology 47XXX is a 4/16 Kbit SRAM with EEPROM backup. The
device utilizes the I2C serial interface. The 47XXX provides infinite read and
write cycles to the SRAM while EEPROM cells provide high-endurance nonvolatile
storage of data. With an external capacitor, SRAM data is automatically
transferred to the EEPROM upon loss of power. Data can also be transferred
manually by using either the 'Hardware Store' pin or software control. Upon
power-up, the EEPROM data is automatically recalled to the SRAM. Recall can also
be initiated through software control.
([datasheet](https://ww1.microchip.com/downloads/en/DeviceDoc/47L04_47C04_47L16_47C16_DS20005371D.pdf))
*/

class Eeram:
  static I2C-SRAM-ADDRESS    := 0x50
  static I2C-CONTROL-ADDRESS := 0x18

  // I2C Addresses for SRAM Data Registers (opcode 1010).
  // A2=0 A1=0 → 0x50
  // A2=0 A1=1 → 0x52
  // A2=1 A1=0 → 0x54
  // A2=1 A1=1 → 0x56

  // I2C Addresses for Control Registers (opcode 0011).
  // A2=0 A1=0 → 0x18
  // A2=0 A1=1 → 0x1A
  // A2=1 A1=0 → 0x1C
  // A2=1 A1=1 → 0x1E

  static CAPACITY-4KBIT := 0x0200   // 0x01FF
  static CAPACITY-16KBIT := 0x0800  // 0x07FF

  static PULSE-PIN-TIME_ := Duration --ms=50

  static REG-STATUS_  ::= 0x00
  static REG-COMMAND_ ::= 0x55

  static STATUS-CHANGED_ ::= 0b10000000  // Whether the SRAM has been written since last store or recall operation.
  static STATUS-BP-MASK_ ::= 0b00011100  // Write Protection Bits (See Datasheet - not implemented in this driver).
  static STATUS-ASE_     ::= 0b00000010  // Whether Auto Store is Enabled.
  static STATUS-EVENT_   ::= 0b00000001  // Whether an external event has been detected on the HS pin.

  static BP-ALL-UNPROTECTED     ::= 0b000
  static BP-ALL-WRITE-PROTECTED ::= 0b111

  static COMMAND-STORE_  ::= 0b00110011  // Executes a Software Store command.
  static COMMAND-RECALL_ ::= 0b11011101  // Executes a Software Recall command.

  static DEFAULT-REGISTER-WIDTH_ ::= 8

  static DATA-SIZE-ADDRESS_ ::= #[0, 0]
  static DATA-START-ADDRESS_ ::= #[0, 2]


  sram-data_/i2c.Device := ?
  sram-control_/registers.Registers := ?
  logger_/log.Logger := ?
  capacity_/int := ?
  hardware-store_/gpio.Pin? := null

  data_/Map := {:}

  /** Class Constructor */
  constructor
      --data/i2c.Device
      --control/serial.Device
      --capacity/int=CAPACITY-16KBIT
      --hs-pin/gpio.Pin?=null
      --logger/log.Logger=log.default:
    assert: capacity == CAPACITY-4KBIT or capacity == CAPACITY-16KBIT

    logger_ = logger.with-name "Eeram"
    sram-data_ = data
    sram-control_ = control.registers

    // Two bytes are used to store the size of the data being written.
    capacity_ = capacity

    // Ensure 'hardware-store' pin is set to off.
    if hs-pin is gpio.Pin:
      hardware-store_ = hs-pin
      hardware-store_.set 0

    // Log status of chip at startup.
    if ase-enabled: logger_.info "ase enabled"
    else: logger_.warn "ase disabled"

    // pull data from sram.
    from-eeram_

  /**
  Stores value in the location for the given key.

  If the key is already present, overrides the previous value.  Data will be
    sent to the Eeram device immediately.
  */
  operator []= key/any value/any -> none:
    logger_.debug "adding to data map" --tags={"key":key,"data":value}
    data_[key] = value
    if bytes-used >= bytes-capacity:
      logger_.error "eeeram storage exceeded."
      return
    to-eeram_

  /**
  Retrieves a value map for the given key.
  */
  operator [] key/any -> any?:
    if data_.contains key:
      logger_.debug "retrieving from data map" --tags={"key":key}
      return data_[key]
    else:
      logger_.error "missing key from data map" --tags={"key":key}
      return null

  /** Return the current capacity only (in KB). */
  /* 2 bytes used to store the data size for later reads */
  bytes-capacity -> int:
    return capacity_ - 2

  /** Returns the number of bytes used */
  bytes-used object/any=data_ -> int:
    return (tison.encode object).size

  /** Returns the number of bytes available */
  /* 2 bytes used to store the data size for later reads */
  bytes-available -> int:
    return bytes-capacity - bytes-used - 2

  /** Force a store from RAM to FLASH using hardware request. */
  hardware-store -> none:
    if hardware-store_ is gpio.Pin:
      logger_.info "hardware-store requested" --tags={"pin-pulse-time-ms": PULSE-PIN-TIME_.in-ms}
      hardware-store_.set 1
      sleep PULSE-PIN-TIME_
      hardware-store_.set 0
    else:
      logger_.error "hardware-store requested, but no gpio pin set"

  /**
  Enables the Auto-Store mechanism.

  To enable this feature, a capacitor must be placed on the V CAP pin and
    ensure the ASE bit in the STATUS register is set to '1' (this function).

  For interest: the capacitor is charged through the VCC pin. When the 47XXX
    detects a power-down event, the device automatically switches to the
    capacitor for power and initiates the Auto-Store operation. Even if power
    is restored, the 47XXX cannot be accessed for (TSTORE) time after the
    Auto-Store is initiated.
  */
  enable-ase -> none:
    write-register_ REG-STATUS_ 1 --mask=STATUS-ASE_

  /**
  Disables the Auto-Store mechanism.

  Does the opposite of $enable-ase.  (See $enable-ase.)
  */
  disable-ase -> none:
    write-register_ REG-STATUS_ 0 --mask=STATUS-ASE_

  /** Whether the Auto-Store mechanism is enabled. */
  ase-enabled -> bool:
    raw/int := read-register_ REG-STATUS_ --mask=STATUS-ASE_
    return raw == 1

  /** Stores the current map in the SRAM device. */
  to-eeram_ -> none:
    data-bytes := tison.encode data_
    data-size-ba := ByteArray 2
    BIG-ENDIAN.put-uint16 data-size-ba 00 data-bytes.size
    logger_.debug "saving data map to eeram" --tags={"size":"$(data-bytes.size)"}
    sram-data_.write-address DATA-SIZE-ADDRESS_ data-size-ba
    sram-data_.write-address DATA-START-ADDRESS_ data-bytes


  /** Stores the current map in the SRAM device. */
  from-eeram_ -> none:
    data-size-ba := sram-data_.read-address DATA-SIZE-ADDRESS_ 2
    data-size := BIG-ENDIAN.uint16 data-size-ba 00
    if data-size-ba == #[0xff, 0xff]:
      // probably never been used before, or overwritten/corrupt.
      logger_.error "cannot read back - likely brand new chip" --tags={"size-ba":"$(data-size-ba)"}
      return

    logger_.debug "reading back bytes from sram" --tags={"size":"$(data-size)"}
    restored-map := tison.decode (sram-data_.read-address DATA-START-ADDRESS_ data-size)
    data_.clear
    //restored-map.keys.do:
    //  data_[it] = restored-map[it]
    data_ = restored-map.copy
    logger_.debug "map restored" --tags={"size":"$(data_.size)"}


  /** Whether the data in SRAM has a write that is not yet in EEPROM. */
  has-changed -> bool:
    raw/int := read-register_ REG-STATUS_ --mask=STATUS-CHANGED_
    return raw == 1

  /** Forces immediate write from SRAM into EEPROM. */
  store -> none:
    write-register_ REG-COMMAND_ COMMAND-STORE_

  /** Forces immediate read from EEPROM into SRAM. */
  recall -> none:
    write-register_ REG-COMMAND_ COMMAND-RECALL_

  /**
  Reads the given register with the supplied mask.
  */
  read-register_ register/int -> any
      --mask/int=0xFF
      --offset/int=(mask.count-trailing-zeros)
      --device/registers.Registers=sram-control_:

    raw-value := device.read-u8 register
    if mask == 0xFFFF and offset == 0:
      return raw-value
    else:
      masked-value := (raw-value & mask) >> offset
      return masked-value

  /**
  Writes the given register with the supplied mask.
  */
  write-register_ register/int value/any -> none
      --mask/int=0xFF
      --offset/int=(mask.count-trailing-zeros)
      --device/registers.Registers=sram-control_:

    max/int := mask >> offset
    assert: ((value & ~max) == 0)

    if (mask == 0xFF) and (offset == 0):
      device.write-u8 register (value & 0xFF)
    else:
      new-value/int := device.read-u8 register
      new-value     &= ~mask
      new-value     |= (value << offset)
      device.write-u8 register new-value

  /**
  Dumps memory content in a hex-editor style screen dump. */

  dump-sram start/int=0 --rows/int?=null --cols/int=16:
    // Round down to the nearest $cols boundary.
    start = (start / cols) * cols

    // If rows not given, determine the dump size by looking at the int16 (data
    // size variable) stored in at $DATA-SIZE-ADDRESS_.
    if rows == null:
      size-data := sram-data_.read-address DATA-SIZE-ADDRESS_ 2
      size := BIG-ENDIAN.uint16 size-data 00
      rows = (size + cols - 1) / cols

    assert: 0 <= start <= capacity_
    assert: (start + rows * cols) <= capacity_

    print " - Has Changed : $has-changed"
    rows.repeat: | r/int |
      addr := start + (r * cols)
      addr-ba := ByteArray 2
      BIG-ENDIAN.put-uint16 addr-ba 00 addr
      data := sram-data_.read-address addr-ba cols
      converted-string := render-ascii_ data

      line := "0x$(%02x addr): $data   $converted-string"
      print line

  /** Converts byte array cell to printable ascii string, or with a '.'. */
  byte-to-ascii_ byte/int -> string:
    if byte >= 32 and byte <= 126:
      return #[byte].to-string
    return "."

  /**
  Renders a byte-arry into a printable string.

  Walks a byte array and uses $byte-to-ascii_ to convert each cell to
    printable ascii string.  ($byte-to-ascii_ replaces unprintable characters
    with a full stop.)
  */
  render-ascii_ bytes -> string:
    str-output := ""
    bytes.do: | b/int |
      str-output += byte-to-ascii_ b
    return str-output
