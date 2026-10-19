// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import log
import io show BIG-ENDIAN
import i2c
import monitor


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
  /** I2C address of the SRAM array, with the A2 and A1 pins low. */
  static I2C-DATA-ADDRESS    ::= 0x50
  /** I2C address of the control registers, with the A2 and A1 pins low. */
  static I2C-CONTROL-ADDRESS ::= 0x18

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

  /** Capacity in bytes of the 47L04 and 47C04 (4 Kbit, addresses 0x000-0x1FF). */
  static CAPACITY-4KBIT ::= 0x0200
  /** Capacity in bytes of the 47L16 and 47C16 (16 Kbit, addresses 0x000-0x7FF). */
  static CAPACITY-16KBIT ::= 0x0800

  // The device does not acknowledge during Store, Recall and STATUS register
  // write cycles.  Datasheet maximums (AC Characteristics): TWC 1 ms, TSTORE
  // 25 ms (16 Kbit) or 8 ms (4 Kbit), TRECALL 5 ms (16 Kbit) or 2 ms (4 Kbit).
  // The waits below add margin to those maximums.
  static STATUS-WRITE-WAIT_ ::= Duration --ms=5
  static STORE-WAIT-4KBIT_ ::= Duration --ms=10
  static STORE-WAIT-16KBIT_ ::= Duration --ms=30
  static RECALL-WAIT-4KBIT_ ::= Duration --ms=5
  static RECALL-WAIT-16KBIT_ ::= Duration --ms=10

  // Acknowledge polling gives up after this many times the wait above.
  static ACK-POLL-FACTOR_ ::= 3

  // After power-up the device does not respond until its Auto-Recall has
  // finished (TRECALL, 5 ms at most).  The timeout is far above that, so that
  // slow supply ramps are tolerated, but a missing device still fails quickly.
  static POWER-UP-TIMEOUT_ ::= Duration --ms=100

  static REG-STATUS_  ::= 0x00
  static REG-COMMAND_ ::= 0x55

  static STATUS-CHANGED_ ::= 0b10000000  // Whether the SRAM has been written since last store or recall operation.
  static STATUS-BP-MASK_ ::= 0b00011100  // Write Protection Bits (See Datasheet).
  static STATUS-ASE_     ::= 0b00000010  // Whether Auto Store is Enabled.
  static STATUS-EVENT_   ::= 0b00000001  // Whether an external event has been detected on the HS pin.

  static BP-NONE-WRITE-PROTECTED ::= 0b000 // Entire array is not write-protected
  static BP-UPPER-1-64-PROTECTED ::= 0b001 // Upper 1/64 of array is write-protected
  static BP-UPPER-1-32-PROTECTED ::= 0b010 // Upper 1/32 of array is write-protected
  static BP-UPPER-1-16-PROTECTED ::= 0b011 // Upper 1/16 of array is write-protected
  static BP-UPPER-1-8-PROTECTED  ::= 0b100 // Upper 1/8 of array is write-protected
  static BP-UPPER-1-4-PROTECTED  ::= 0b101 // Upper 1/4 of array is write-protected
  static BP-UPPER-1-2-PROTECTED  ::= 0b110 // Upper 1/2 of array is write-protected
  static BP-ALL-WRITE-PROTECTED  ::= 0b111 // Entire array is write-protected

  static COMMAND-STORE_  ::= 0b00110011  // Executes a Software Store command.
  static COMMAND-RECALL_ ::= 0b11011101  // Executes a Software Recall command.

  /**
  Returns the I2C address of the SRAM array for the given address pin settings.

  The $a1 and $a2 flags tell whether the A1 and A2 pins of the chip are tied
    high.  The result is one of 0x50, 0x52, 0x54 and 0x56.  The control
    registers of the same chip are at $control-address-for.
  */
  static data-address-for --a1/bool=false --a2/bool=false -> int:
    address := I2C-DATA-ADDRESS
    if a1: address |= 0b010
    if a2: address |= 0b100
    return address

  /**
  Returns the I2C address of the control registers for the given address pin
    settings.

  The $a1 and $a2 flags tell whether the A1 and A2 pins of the chip are tied
    high.  The result is one of 0x18, 0x1A, 0x1C and 0x1E.  The SRAM array of
    the same chip is at $data-address-for.
  */
  static control-address-for --a1/bool=false --a2/bool=false -> int:
    address := I2C-CONTROL-ADDRESS
    if a1: address |= 0b010
    if a2: address |= 0b100
    return address

  /**
  Constructs an Eeram driver for the chip on the $bus with the given address
    pin settings.

  The $a1 and $a2 flags tell whether the A1 and A2 pins of the chip are tied
    high.  Both I2C devices of the chip (the SRAM array and the control
    registers) are derived from them, so they can not be mismatched.

  Throws if either device does not respond on the bus.  See the main constructor
    for the other arguments.
  */
  constructor.from-bus bus/i2c.Bus
      --a1/bool=false
      --a2/bool=false
      --capacity/int=CAPACITY-16KBIT
      --ack-polling/bool=false
      --logger/log.Logger=log.default:
    data-address := data-address-for --a1=a1 --a2=a2
    control-address := control-address-for --a1=a1 --a2=a2
    if not bus.test data-address:
      throw "EERAM SRAM array not found at 0x$(%02x data-address)"
    if not bus.test control-address:
      throw "EERAM control registers not found at 0x$(%02x control-address)"
    return Eeram
        --data=(bus.device data-address)
        --control=(bus.device control-address)
        --capacity=capacity
        --ack-polling=ack-polling
        --logger=logger

  /**
  Finds the chips on the $bus.

  Returns a list with one map per chip found, with the boolean keys "a1" and
    "a2" (the address pin settings, as used by `Eeram.from-bus`).  A chip is found when
    both its SRAM array and its control registers respond.
  */
  static scan bus/i2c.Bus -> List:
    found := []
    [false, true].do: | a1/bool |
      [false, true].do: | a2/bool |
        data-address := data-address-for --a1=a1 --a2=a2
        control-address := control-address-for --a1=a1 --a2=a2
        if (bus.test data-address) and (bus.test control-address):
          found.add {"a1": a1, "a2": a2}
    return found

  sram-data_/i2c.Device := ?
  sram-control_/i2c.Device := ?
  logger_/log.Logger := ?
  capacity_/int := ?
  ack-polling_/bool := ?

  // Serialises the bus transactions of tasks.  Held for a whole register
  // access, including the wait for the device to become ready again.
  mutex_ ::= monitor.Mutex

  /**
  Constructs an Eeram driver.

  The $data device is the SRAM array (see $I2C-DATA-ADDRESS) and the $control
    device is the control registers (see $I2C-CONTROL-ADDRESS).  The $capacity
    must be $CAPACITY-4KBIT or $CAPACITY-16KBIT.

  The constructor waits for the device to respond, as the device cannot be
    accessed while its Auto-Recall at power-up runs.  It throws the I2C error if
    the device does not respond within 100 ms.

  If $ack-polling is true, the wait after a Store, Recall or STATUS register
    write ends as soon as the device acknowledges again (see "Acknowledge
    Polling" in the datasheet), instead of always lasting the full worst-case
    time.  An error is thrown if the device does not respond within three times
    the worst-case time.  This is experimental, and is off by default.
  */
  constructor
      --data/i2c.Device
      --control/i2c.Device
      --capacity/int=CAPACITY-16KBIT
      --ack-polling/bool=false
      --logger/log.Logger=log.default:
    assert: capacity == CAPACITY-4KBIT or capacity == CAPACITY-16KBIT

    logger_ = logger.with-name "eeram"
    sram-data_ = data
    sram-control_ = control

    // Two bytes are used to store the size of the data being written.
    capacity_ = capacity
    ack-polling_ = ack-polling

    // The device does not respond while its Auto-Recall at power-up runs.
    power-up-error := poll-ready_ POWER-UP-TIMEOUT_
    if power-up-error: throw power-up-error

    // Log status of chip at startup.
    if not ase-enabled: logger_.warn "ase disabled"

  /**
  The IC's capacity (as given in constructor).

  If the device is written to at an address higher than exists on the device, the
    device will automatically loop and continue to write without warning,
    overwriting the data at the beginning of the device.  This value is used as
    a guard to prevent writing past the devices end capacity.

  This value is not checked  - there is no reliable way in software to tell
    which chip model is attached.
  */
  capacity -> int:
    return capacity_

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

  /**
  Enables write protection for the given $portion of the array.

  The $portion is one of the BP-* constants, for example
    $BP-UPPER-1-4-PROTECTED.  The protected range is at the top of the array
    (see "Protected Array Address Locations" in the datasheet).  The setting is
    nonvolatile.

  The device does not acknowledge writes into a protected block, so such a
    write is expected to fail with an I2C error.
  */
  enable-block-protection --portion/int=BP-ALL-WRITE-PROTECTED -> none:
    assert: 0 <= portion <= 7
    write-register_ REG-STATUS_ portion --mask=STATUS-BP-MASK_

  /** Disables write protection of the array.  See $enable-block-protection. */
  disable-block-protection -> none:
    enable-block-protection --portion=BP-NONE-WRITE-PROTECTED

  /**
  The current block protection setting, as one of the BP-* constants.

  See $enable-block-protection.
  */
  block-protection-value -> int:
    return read-register_ REG-STATUS_ --mask=STATUS-BP-MASK_

  /** Whether any part of the array is write-protected. */
  block-protection-enabled -> bool:
    return block-protection-value != 0

  /** Whether the data in SRAM has a write that is not yet in EEPROM. */
  has-changed -> bool:
    raw/int := read-register_ REG-STATUS_ --mask=STATUS-CHANGED_
    return raw == 1

  /**
  Whether an external event has been detected on the HS (Hardware Store) pin.

  The flag is nonvolatile.  See $clear-event.
  */
  event-detected -> bool:
    raw/int := read-register_ REG-STATUS_ --mask=STATUS-EVENT_
    return raw == 1

  /** Clears the flag reported by $event-detected. */
  clear-event -> none:
    write-register_ REG-STATUS_ 0 --mask=STATUS-EVENT_

  /**
  Forces immediate write from SRAM into EEPROM.

  Does nothing if the SRAM has not changed since the last store or recall (see
    $has-changed), which avoids needless EEPROM wear.  Otherwise blocks for the
    worst-case store time of the device, during which the device does not
    acknowledge.
  */
  store -> none:
    if not has-changed:
      logger_.debug "store not necessary - not changed"
      return
    write-register_ REG-COMMAND_ COMMAND-STORE_ --wait=store-wait_
    logger_.debug "read SRAM into EEPROM"

  /**
  Forces immediate read from EEPROM into SRAM.

  Blocks for the worst-case recall time of the device, during which the device
    does not acknowledge.
  */
  recall -> none:
    write-register_ REG-COMMAND_ COMMAND-RECALL_ --wait=recall-wait_
    logger_.debug "read EEPROM into SRAM"

  /** Worst-case store time (with margin) for the configured capacity. */
  store-wait_ -> Duration:
    if capacity_ == CAPACITY-4KBIT: return STORE-WAIT-4KBIT_
    return STORE-WAIT-16KBIT_

  /** Worst-case recall time (with margin) for the configured capacity. */
  recall-wait_ -> Duration:
    if capacity_ == CAPACITY-4KBIT: return RECALL-WAIT-4KBIT_
    return RECALL-WAIT-16KBIT_

  /**
  Polls the device until it acknowledges, or until the $timeout has passed.

  Reads the STATUS register, which has no side effects.  A device that is busy
    does not acknowledge, which makes the read fail.

  Returns null once the device responds, otherwise the last error.
  */
  poll-ready_ timeout/Duration -> any:
    start-us := Time.monotonic-us
    while true:
      error := catch: sram-control_.read-reg REG-STATUS_ 1
      if not error: return null
      if (Time.monotonic-us - start-us) > timeout.in-us: return error
      sleep --ms=1

  /**
  Waits until the device is ready again after an operation during which it does
    not acknowledge.

  Sleeps for the $wait.  When using acknowledge polling, it polls the device
    instead, and throws if the device does not respond within $ACK-POLL-FACTOR_
    times the $wait.
  */
  wait-ready_ wait/Duration -> none:
    if not ack-polling_:
      sleep wait
      return
    error := poll-ready_ (Duration --us=(wait.in-us * ACK-POLL-FACTOR_))
    if error: throw error

  /**
  Writes the $bytes into the SRAM, starting at $address.

  Throws "OUT_OF_BOUNDS" if the write would pass the end of the device.  The
    device would otherwise wrap around to address 0 and overwrite the data
    there.

  The device does not acknowledge writes into a block that is write-protected
    (see $enable-block-protection), so such a write is expected to fail with an
    I2C error.
  */
  write-data address/int bytes/ByteArray -> none:
    if not (0 <= address <= (capacity_ - bytes.size)): throw "OUT_OF_BOUNDS"
    address-ba := ByteArray 2
    BIG-ENDIAN.put-uint16 address-ba 0 address
    mutex_.do:
      sram-data_.write-address address-ba bytes

  /**
  Reads $num-bytes bytes from the SRAM, starting at $address.

  Throws "OUT_OF_BOUNDS" if the read would pass the end of the device.  The
    device would otherwise wrap around to address 0.
  */
  read-data address/int num-bytes/int -> ByteArray:
    if not (0 <= address <= (capacity_ - num-bytes)): throw "OUT_OF_BOUNDS"
    address-ba := ByteArray 2
    BIG-ENDIAN.put-uint16 address-ba 0 address
    mutex_.do:
      return sram-data_.read-address address-ba num-bytes
    unreachable

  /**
  Reads an unsigned 8-bit value at the $address.

  Throws "OUT_OF_BOUNDS" if the $address is past the end of the device.
  */
  read-uint8 address/int -> int:
    return BIG-ENDIAN.uint8 (read-data address 1) 0

  /** Writes the unsigned 8-bit $value at the $address.  See $read-uint8. */
  write-uint8 address/int value/int -> none:
    bytes := ByteArray 1
    BIG-ENDIAN.put-uint8 bytes 0 value
    write-data address bytes

  /**
  Reads an unsigned 16-bit value (big-endian) at the $address.

  Throws "OUT_OF_BOUNDS" if the value would pass the end of the device.
  */
  read-uint16 address/int -> int:
    return BIG-ENDIAN.uint16 (read-data address 2) 0

  /** Writes the unsigned 16-bit $value (big-endian) at the $address. */
  write-uint16 address/int value/int -> none:
    bytes := ByteArray 2
    BIG-ENDIAN.put-uint16 bytes 0 value
    write-data address bytes

  /**
  Reads an unsigned 32-bit value (big-endian) at the $address.

  Throws "OUT_OF_BOUNDS" if the value would pass the end of the device.
  */
  read-uint32 address/int -> int:
    return BIG-ENDIAN.uint32 (read-data address 4) 0

  /** Writes the unsigned 32-bit $value (big-endian) at the $address. */
  write-uint32 address/int value/int -> none:
    bytes := ByteArray 4
    BIG-ENDIAN.put-uint32 bytes 0 value
    write-data address bytes

  /**
  Reads a signed 32-bit value (big-endian) at the $address.

  Throws "OUT_OF_BOUNDS" if the value would pass the end of the device.
  */
  read-int32 address/int -> int:
    return BIG-ENDIAN.int32 (read-data address 4) 0

  /** Writes the signed 32-bit $value (big-endian) at the $address. */
  write-int32 address/int value/int -> none:
    bytes := ByteArray 4
    BIG-ENDIAN.put-int32 bytes 0 value
    write-data address bytes

  /**
  Reads a 64-bit float (big-endian) at the $address.

  Throws "OUT_OF_BOUNDS" if the value would pass the end of the device.
  */
  read-float64 address/int -> float:
    return BIG-ENDIAN.float64 (read-data address 8) 0

  /** Writes the 64-bit float $value (big-endian) at the $address. */
  write-float64 address/int value/float -> none:
    bytes := ByteArray 8
    BIG-ENDIAN.put-float64 bytes 0 value
    write-data address bytes

  /**
  Reads the given register with the supplied mask.
  */
  read-register_ register/int -> any
      --mask/int=0xFF
      --offset/int?=null
      --device/i2c.Device=sram-control_:
    if not offset: offset = mask.count-trailing-zeros

    mutex_.do:
      raw-value := (device.read-reg register 1)[0]
      if mask == 0xFF and offset == 0:
        return raw-value
      else:
        masked-value := (raw-value & mask) >> offset
        return masked-value
    unreachable

  /**
  Writes the given register with the supplied mask.

  Waits for the $wait duration afterwards (see $wait-ready_), as the device does
    not acknowledge while it executes a Store, a Recall or a STATUS register
    write cycle.  If the register already holds the requested value, nothing is
    written and no wait takes place.
  */
  write-register_ register/int value/any -> none
      --mask/int=0xFF
      --offset/int?=null
      --device/i2c.Device=sram-control_
      --wait/Duration=STATUS-WRITE-WAIT_:
    if not offset: offset = mask.count-trailing-zeros
    max/int := mask >> offset
    assert: ((value & ~max) == 0)

    mutex_.do:
      if (mask == 0xFF) and (offset == 0):
        device.write-reg register #[(value & 0xFF)]
      else:
        current := (device.read-reg register 1)[0]
        new-value := (current & ~mask) | (value << offset)
        // A STATUS register write triggers an internal write cycle, so skip it
        // when nothing changes.
        if new-value == current: return
        device.write-reg register #[new-value]

      // Required due to the device not acknowledging during Store and Recall
      // operations, nor during internal STATUS register write cycles.  Control
      // is passed back to the system before the ACK arrives.  If a subsequent
      // operation is attempted before the ACK arrives, the bus errors out and
      // sometimes doesn't recover.  The lock is held meanwhile, so tasks do
      // not run into the busy device.
      wait-ready_ wait

  /**
  Dumps memory content in a hex-editor style screen dump for troubleshooting.

  Displays $rows of data, starting at $start, with each row having $cols columns.
    Display starts at the nearest $cols boundary. ($start will go back to the
    nearest boundary before the indicated start address).  The dump stops at
    the end of the device.
  */
  dump-sram start/int=0 --rows/int --cols/int=16 -> none:
    assert: 0 < cols

    // Start at the nearest $cols boundary, less than the start.
    start = (start / cols) * cols

    if not (0 <= start <= (capacity_ - cols)): throw "OUT_OF_BOUNDS"

    // Do not read past the end of the device.
    max-rows := (capacity_ - start) / cols
    if rows > max-rows: rows = max-rows

    print " - ASE Enabled : $(ase-enabled)"
    print " - Has Changed : $has-changed"
    rows.repeat: | r/int |
      addr := start + (r * cols)
      data := read-data addr cols
      converted-string := render-ascii_ data

      print " 0x$(%04x addr): $data   $converted-string"

  /**
  Renders a byte-array into a printable string.

  Replaces unprintable characters with a full stop.
  */
  render-ascii_ bytes/ByteArray -> string:
    output := ByteArray bytes.size
    bytes.size.repeat: | i/int |
      byte := bytes[i]
      if 32 <= byte <= 126: output[i] = byte
      else: output[i] = '.'
    return output.to-string
