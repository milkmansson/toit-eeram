// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import gpio
import log
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
  static I2C-DATA-ADDRESS    := 0x50
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

  static INTER-I2C-SLEEP-TIME_ := Duration --ms=30
  static STORE-WAIT_ := Duration --ms=30
  static RECALL-WAIT_ := Duration --ms=10

  static REG-STATUS_  ::= 0x00
  static REG-COMMAND_ ::= 0x55

  static STATUS-CHANGED_ ::= 0b10000000  // Whether the SRAM has been written since last store or recall operation.
  static STATUS-BP-MASK_ ::= 0b00011100  // Write Protection Bits (See Datasheet - not implemented in this driver).
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

  sram-data_/i2c.Device := ?
  sram-control_/i2c.Device := ?
  logger_/log.Logger := ?
  capacity_/int := ?

  /** Class Constructor */
  constructor
      --data/i2c.Device
      --control/i2c.Device
      --capacity/int=CAPACITY-16KBIT
      --logger/log.Logger=log.default:
    assert: capacity == CAPACITY-4KBIT or capacity == CAPACITY-16KBIT

    logger_ = logger.with-name "eeram"
    sram-data_ = data
    sram-control_ = control

    // Two bytes are used to store the size of the data being written.
    capacity_ = capacity

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

  enable-block-protection --portion/int=BP-ALL-WRITE-PROTECTED -> none:
    assert: 0 <= portion <= 7
    write-register_ REG-STATUS_ portion --mask=STATUS-BP-MASK_

  disable-block-protection -> none:
    enable-block-protection --portion=BP-NONE-WRITE-PROTECTED

  block-protection-value -> int:
    return read-register_ REG-STATUS_ --mask=STATUS-BP-MASK_

  block-protection-enabled -> bool:
    return block-protection-value != 0

  /** Whether the data in SRAM has a write that is not yet in EEPROM. */
  has-changed -> bool:
    raw/int := read-register_ REG-STATUS_ --mask=STATUS-CHANGED_
    return raw == 1

  /** Forces immediate write from SRAM into EEPROM. */
  // A fixed sleep of 30 ms to guard against issues due to the device not
  // supporting normal methods of delayed ACKs. See the Datasheet on
  // "Acknowledge Polling".
  store -> none:
    if not has-changed:
      logger_.debug "store not necessary - not changed"
      return
    write-register_ REG-COMMAND_ COMMAND-STORE_
    sleep STORE-WAIT_
    logger_.debug "read SRAM into EEPROM"

  /** Forces immediate read from EEPROM into SRAM. */
  // A fixed sleep of 10 ms to guard against issues due to the device not
  // supporting normal methods of delayed ACKs. See the Datasheet on
  // "Acknowledge Polling".
  recall -> none:
    write-register_ REG-COMMAND_ COMMAND-RECALL_
    sleep RECALL-WAIT_
    logger_.debug "read EEPROM into SRAM"

  write-data address/int bytes/ByteArray -> none:
    assert: 0 <= address <= (capacity_ - bytes.size)
    assert: (address + bytes.size) <= capacity_
    address-ba := ByteArray 2
    BIG-ENDIAN.put-uint16 address-ba 00 address
    sram-data_.write-address address-ba bytes

  read-data address/int num-bytes/int -> ByteArray:
//    print "address: $address num-bytes:$num-bytes max-read:$(capacity_ - num-bytes)"
    assert: 0 <= address <= (capacity_ - num-bytes)
    assert: (address + num-bytes) <= capacity_
    address-ba := ByteArray 2
    BIG-ENDIAN.put-uint16 address-ba 00 address
    return sram-data_.read-address address-ba num-bytes

  /**
  Reads the given register with the supplied mask.
  */
  read-register_ register/int -> any
      --mask/int=0xFF
      --offset/int=(mask.count-trailing-zeros)
      --device/i2c.Device=sram-control_:

    //raw-value := device.read-u8 register
    raw-value := (device.read-reg register 1)[0]
    if mask == 0xFF and offset == 0:
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
      --device/i2c.Device=sram-control_:

    max/int := mask >> offset
    assert: ((value & ~max) == 0)

    if (mask == 0xFF) and (offset == 0):
      //device.write-u8 register (value & 0xFF)
      device.write-reg register #[(value & 0xFF)]
    else:
      //new-value/int := device.read-u8 register
      new-value := (device.read-reg register 1)[0]
      new-value     &= ~mask
      new-value     |= (value << offset)
      //device.write-u8 register new-value
      device.write-reg register #[new-value]

    // Required due to the device not acknowledging during Store and Recall
    // operations, nor during internal STATUS register write cycles.  Control is
    // passed back to the system before the ACK arrives.  If a subsequent
    // operation is attempted before the ACK arrives, the bus errors out and
    // sometimes doesn't recover.
    sleep INTER-I2C-SLEEP-TIME_

  /**
  Dumps memory content in a hex-editor style screen dump for troubleshooting.

  Displays $rows of data, starting at $start, with each row having $cols columns.
    Display starts at the nearest $cols boundary. ($start will go back to the
    nearest boundary before the indicated start address).
  */
  dump-sram start/int=0 --rows/int --cols/int=16:
    assert: 0 < cols
    size/int := 0

    // Start at the nearest $cols boundary, less than the start.
    start = (start / cols) * cols

    assert: 0 <= start <= (capacity_ - cols)
    //assert: start + (rows * cols) <= capacity_

    print " - ASE Enabled : $(ase-enabled)"
    print " - Has Changed : $has-changed"
    rows.repeat: | r/int |
      addr := start + (r * cols)
      addr-ba := ByteArray 2
      BIG-ENDIAN.put-uint16 addr-ba 00 addr
      data := sram-data_.read-address addr-ba cols
      converted-string := render-ascii_ data

      print " 0x$(%04x addr): $data   $converted-string"

    sleep INTER-I2C-SLEEP-TIME_

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
