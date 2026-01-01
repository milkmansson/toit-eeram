// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import io show BIG-ENDIAN
import encoding.tison
import crypto.crc show Crc16CcittFalse
import .eeram
import i2c
import log

/**
A Toit driver library implementing a 'persistent map' using for the Microchip
47L04/47C04/47L16/47C16 SRAM/FLASH IC.

(Wholly dependent on the Eeram driver library.  See the Toitdocs and README.md.)
*/


class PersistentMap:
  // Default ztarting address locations for the data/types.
  static DATA-SIZE-ADDRESS_     ::= 0x00
  static DATA-SIZE-SIZE_        ::= 2
  static DATA-CHECKSUM-ADDRESS_ ::= 0x02
  static DATA-CHECKSUM-SIZE_    ::= 2
  static DATA-START-ADDRESS_    ::= 0x04

  // This many bytes need to be subtracted from available bytes.
  static OVERHEAD-BYTES_        ::= DATA-SIZE-SIZE_ + DATA-CHECKSUM-SIZE_

  // DEFAULT DATA
  DEFAULT-DATA_ := #[0xFF, 0xFF]

  // Original data container.
  data_/Map := {:}
  driver_/Eeram := ?
  logger_/log.Logger := ?
  capacity_/int := ?
  used_/int := 0 // to-do

  /** Constructor creating Eemap instance at the same time. */
  constructor
      --data/i2c.Device
      --control/i2c.Device
      --capacity/int=Eeram.CAPACITY-16KBIT
      --logger/log.Logger=log.default:
    assert: capacity == Eeram.CAPACITY-4KBIT or capacity == Eeram.CAPACITY-16KBIT
    driver_ = Eeram
      --control=control
      --data=data
      --capacity=capacity
      --logger=logger
    logger_ = logger.with-name "persistentmap"
    if not driver_.ase-enabled: driver_.enable-ase
    capacity_ = capacity
    map-from-sram_
    logger_.info "driver started (manual creation)"

  /** Constructor for use with an existing Eemap instance. */
  constructor driver/Eeram --logger/log.Logger=log.default:
    driver_ = driver
    logger_ = logger.with-name "persistentmap"
    if not driver_.ase-enabled: driver_.enable-ase
    capacity_ = driver.capacity
    map-from-sram_
    logger_.info "driver started (using existing Eeram objcet)"

  /**
  Stores the $value for the given $key.

  If the key is already present, overrides the previous value.  Data will be
    sent to the SRAM immediately.
  */
  operator []= key/any value/any -> none:
    if bytes-used >= bytes-capacity:
      logger_.error "SRAM storage exceeded."
      return
    logger_.debug "adding to data map" --tags={"key":key,"data":value}
    data_[key] = value
    map-to-sram_

  /**
  Retrieves a value for the given $key, if it exists.
  */
  operator [] key/any -> any?:
    if data_.contains key:
      return data_[key]
    else:
      logger_.error "missing key from data map" --tags={"key":key}
      throw "missing key from data map"

  get key/any [--if-absent] -> any:
    if not data_.contains key:
      return if-absent.call
    return data_[key]

  do [block] -> none:
    data_.do:
      block.call it

  keys -> List:
    return data_.keys

  clear -> none:
    data_.clear
    map-to-sram_

  remove key/any -> none:
    data_.remove key
    map-to-sram_

  /** Return the current capacity only (in KB). */
  /* $OVERHEAD-BYTES_ bytes used to store the data size/crc. */
  bytes-capacity -> int:
    return capacity_

  /** Returns the number of bytes used */
  bytes-used object/any=data_ -> int:
    return (tison.encode object).size

  /** Returns the number of bytes available, minus overheads. */
  /* $OVERHEAD-BYTES_ bytes used to store the data size/crc. */
  bytes-available -> int:
    return bytes-capacity - bytes-used - OVERHEAD-BYTES_

  /**
  Whether 'Auto Store Enable' is enabled.

  See $enable-ase and $disable-ase.
  */
  ase-enabled -> bool:
    return driver_.ase-enabled

  /**
  Enables 'Auto Store Enable'.

  When enabled, the device will store SRAM to FLASH on power loss. Setting is
    persistent.
  */
  enable-ase -> none:
    driver_.enable-ase

  /**
  Disables 'Auto Store Enable'.

  When disabled, the device will not store SRAM to FLASH automatically. Setting
    is persistent.
  */
  disable-ase -> none:
    driver_.disable-ase

  /** Whether data in the SRAM has changed (compared to onboard FLASH). */
  has-changed -> bool:
    return driver_.has-changed

  /** Manually trigger the device to write from SRAM to FLASH. */
  store -> none:
    driver_.store

  /**
  Manually trigger the device to read data from FLASH into SRAM.

  Will also put data from SRAM into the onboard Map object. */
  recall -> none:
    driver_.recall
    map-from-sram_

  /** Stores the current map in the SRAM device. */
  map-to-sram_ -> none:
    data-bytes := tison.encode data_
    data-size-bytes := ByteArray DATA-SIZE-SIZE_
    BIG-ENDIAN.put-uint16 data-size-bytes 00 data-bytes.size
    data-checksum-bytes := checksum-ba_ data-bytes
    logger_.debug "saving data map to SRAM" --tags={
      "size":"$(data-bytes.size)",
      "checksum":BIG-ENDIAN.uint16 data-checksum-bytes 00}
    driver_.write-data DATA-SIZE-ADDRESS_ data-size-bytes
    driver_.write-data DATA-CHECKSUM-ADDRESS_ data-checksum-bytes
    driver_.write-data DATA-START-ADDRESS_ data-bytes

  /** Stores the current map in the SRAM device. */
  map-from-sram_ -> none:
    restored-checksum := driver_.read-data DATA-CHECKSUM-ADDRESS_ DATA-CHECKSUM-SIZE_
    data-size-bytes := driver_.read-data DATA-SIZE-ADDRESS_ DATA-SIZE-SIZE_
    data-size-int := BIG-ENDIAN.uint16 data-size-bytes 00

    // Quick check to see if new corrupt.
    if (data-size-bytes == DEFAULT-DATA_) or (restored-checksum == DEFAULT-DATA_):
      // probably never been used before, or overwritten/corrupt.
      logger_.warn "likely brand new chip" --tags={"size-ba":"$(data-size-bytes)"}
      return

    // Read data bytes (and checksum bytes) back from device.
    logger_.debug "reading back bytes from SRAM" --tags={"size":"$(data-size-int)"}
    restored-data := driver_.read-data DATA-START-ADDRESS_ data-size-int

    // Check data against checksum.
    restored-data-chacksum := checksum-ba_ restored-data
    if restored-data-chacksum != restored-checksum:
      logger_.error "restore checksum failed - assuming corrupt/empty." --tags={
        "stored-checksum":(BIG-ENDIAN.int16 restored-checksum 00),
        "calculated-checksum":(BIG-ENDIAN.int16 restored-data-chacksum 00)}
      data_.clear
      return

    // Restore data into a new Map.  Tison-restored object won't take writes.
    logger_.debug "restore checksum passed" --tags={
      "stored-checksum":(BIG-ENDIAN.int16 restored-checksum 00),
      "calculated-checksum":(BIG-ENDIAN.int16 restored-data-chacksum 00)}
    restored-map := tison.decode restored-data
    data_.clear
    data_ = restored-map.copy
    logger_.debug "map restored" --tags={"size":"$(data_.size)"}
    used_ = data_.size

  /**
  Variant of $Eeram.dump-sram, with defaults suited for PersistentMap.
  */
  dump-sram start/int=0 --rows/int?=null --cols/int=16 -> none:
    // If rows not given, determine the dump size by looking at the data size
    // variable) stored as an int16 at $DATA-SIZE-ADDRESS_.

    if rows == null:
      data-size-bytes := driver_.read-data DATA-SIZE-ADDRESS_ DATA-SIZE-SIZE_
      data-checksum-bytes := driver_.read-data DATA-CHECKSUM-ADDRESS_ DATA-CHECKSUM-SIZE_
      if (data-size-bytes == DEFAULT-DATA_) and (data-checksum-bytes == DEFAULT-DATA_):
        // probably never been used before, or overwritten/corrupt.
        logger_.warn "likely brand new chip, or corrupt" --tags={"size-ba":"$(data-size-bytes)"}
        rows = (capacity_ + cols - 1) / cols
      else:
        in-use := BIG-ENDIAN.uint16 data-size-bytes 00
        rows = (in-use + cols - 1) / cols

    print " - Capacity    : $(bytes-capacity)"
    print " - Used        : $(bytes-used)"
    print " - Available   : $(bytes-available)"
    driver_.dump-sram start --rows=rows

  stringify -> string:
    return "$data_"

  /** Data checksum in ByteArray format, used to store on the device.  */
  checksum-ba_ bytes/ByteArray -> ByteArray:
    checksum := Crc16CcittFalse
    checksum.add bytes
    output := checksum.get
    return output

  /**
  Test function that overwrites checksum data.

  Used to fake corruption. CAUTION: any data on the device will be lost. */
  blank-checksum -> none:
    logger_.warn "wipe checksum" --tags={"bytes":DEFAULT-DATA_}
    driver_.write-data DATA-CHECKSUM-ADDRESS_ DEFAULT-DATA_
