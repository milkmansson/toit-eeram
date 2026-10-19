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
  // Default starting address locations for the data/types.
  static DATA-SIZE-ADDRESS_     ::= 0x00
  static DATA-SIZE-SIZE_        ::= 2
  static DATA-CHECKSUM-ADDRESS_ ::= 0x02
  static DATA-CHECKSUM-SIZE_    ::= 2
  static DATA-START-ADDRESS_    ::= 0x04

  // This many bytes need to be subtracted from available bytes.
  static OVERHEAD-BYTES_        ::= DATA-SIZE-SIZE_ + DATA-CHECKSUM-SIZE_

  // DEFAULT DATA
  static DEFAULT-DATA_ ::= #[0xFF, 0xFF]

  // Original data container.
  data_/Map := {:}
  driver_/Eeram := ?
  logger_/log.Logger := ?
  capacity_/int := ?

  /**
  Constructs a PersistentMap, creating the $Eeram driver at the same time.

  The $capacity must be $Eeram.CAPACITY-4KBIT or $Eeram.CAPACITY-16KBIT.

  If $auto-store is true, the Auto-Store feature of the device is enabled when
    it is not already (see $enable-ase).  Auto-Store requires a capacitor on the
    VCAP pin.  The datasheet requires Auto-Store to be disabled when there is
    none, so boards without the capacitor must use --no-auto-store, and call
    $disable-ase.

  See $Eeram.constructor for the $ack-polling option.
  */
  constructor
      --data/i2c.Device
      --control/i2c.Device
      --capacity/int=Eeram.CAPACITY-16KBIT
      --auto-store/bool=true
      --ack-polling/bool=false
      --logger/log.Logger=log.default:
    assert: capacity == Eeram.CAPACITY-4KBIT or capacity == Eeram.CAPACITY-16KBIT
    driver_ = Eeram
      --control=control
      --data=data
      --capacity=capacity
      --ack-polling=ack-polling
      --logger=logger
    logger_ = logger.with-name "persistentmap"
    if auto-store and not driver_.ase-enabled: driver_.enable-ase
    capacity_ = capacity
    map-from-sram_
    logger_.info "driver started (manual creation)"

  /**
  Constructs a PersistentMap for use with an existing $Eeram instance.

  See the other constructor for the $auto-store option.
  */
  constructor driver/Eeram --auto-store/bool=true --logger/log.Logger=log.default:
    driver_ = driver
    logger_ = logger.with-name "persistentmap"
    if auto-store and not driver_.ase-enabled: driver_.enable-ase
    capacity_ = driver.capacity
    map-from-sram_
    logger_.info "driver started (using existing Eeram object)"

  /**
  Stores the $value for the given $key.

  If the key is already present, overrides the previous value.  Data will be
    sent to the SRAM immediately.

  The $key and $value must be supported by tison (see $tison.encode).  Values
    that are changed in place after being stored (for example by adding to a
    list) are only saved by storing them again.

  # Errors
  Throws "PersistentMap capacity exceeded" if the map would no longer fit on
    the device (see $bytes-available).  Also throws if the $key or $value
    cannot be encoded.  In both cases the map is left unchanged.
  */
  operator []= key/any value/any -> none:
    existed := data_.contains key
    previous := data_.get key
    succeeded := false
    try:
      logger_.debug "adding to data map" --tags={"key":key,"data":value}
      data_[key] = value
      map-to-sram_
      succeeded = true
    finally:
      if not succeeded:
        // Roll back, so the map in memory keeps matching the SRAM content.
        if existed: data_[key] = previous
        else: data_.remove key

  /**
  Retrieves a value for the given $key, if it exists.

  Throws "missing key from data map" if the $key does not exist.  See $get and
    $contains for variants that do not throw.
  */
  operator [] key/any -> any?:
    if data_.contains key:
      return data_[key]
    else:
      logger_.error "missing key from data map" --tags={"key":key}
      throw "missing key from data map"

  /** Returns the value for the given $key, or null if it does not exist. */
  get key/any -> any?:
    return data_.get key

  /** Returns the value for the given $key, or the result of $if-absent. */
  get key/any [--if-absent] -> any:
    if not data_.contains key:
      return if-absent.call
    return data_[key]

  /** Whether the map contains the given $key. */
  contains key/any -> bool:
    return data_.contains key

  /** The number of entries in the map. */
  size -> int:
    return data_.size

  /** Whether the map has no entries. */
  is-empty -> bool:
    return data_.is-empty

  /** Invokes the $block on each key/value pair of the map. */
  do [block] -> none:
    data_.do: | key value | block.call key value

  /** The keys of the map, as a list. */
  keys -> List:
    return data_.keys

  /** The values of the map, as a list. */
  values -> List:
    return data_.values

  /** Removes all entries from the map. */
  clear -> none:
    data_.clear
    map-to-sram_

  /** Removes the given $key from the map.  The key does not need to exist. */
  remove key/any -> none:
    if not data_.contains key: return
    data_.remove key
    map-to-sram_

  /**
  The capacity of the device, in bytes.

  This includes 4 bytes used to store the data size and checksum.  See
    $bytes-available.
  */
  bytes-capacity -> int:
    return capacity_

  /** Returns the number of bytes used by the encoded $object (the map by default). */
  bytes-used object/any=data_ -> int:
    return (tison.encode object).size

  /**
  Returns the number of bytes available for map data.

  The 4 bytes used to store the data size and checksum are already deducted.
  */
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

  /**
  Stores the current map in the SRAM device.

  Throws if the encoded map does not fit on the device.  Nothing is written
    in that case.
  */
  map-to-sram_ -> none:
    data-bytes := tison.encode data_
    max-size := bytes-capacity - OVERHEAD-BYTES_
    if data-bytes.size > max-size:
      logger_.error "SRAM storage exceeded." --tags={"size":data-bytes.size,"max":max-size}
      throw "PersistentMap capacity exceeded"

    // The size, checksum and data are contiguous on the device, so they are
    // sent as one frame.  Offsets in the frame equal the device addresses,
    // as the frame starts at the first address.
    checksum := checksum-ba_ data-bytes
    frame := ByteArray OVERHEAD-BYTES_ + data-bytes.size
    BIG-ENDIAN.put-uint16 frame DATA-SIZE-ADDRESS_ data-bytes.size
    frame.replace DATA-CHECKSUM-ADDRESS_ checksum
    frame.replace DATA-START-ADDRESS_ data-bytes
    logger_.debug "saving data map to SRAM" --tags={
      "size":"$(data-bytes.size)",
      "checksum":BIG-ENDIAN.uint16 checksum 0}
    driver_.write-data DATA-SIZE-ADDRESS_ frame

  /**
  Loads the map from the SRAM device.

  Data that fails validation (size, checksum or decoding) is discarded and
    logged as an error.  The map is then empty.
  */
  map-from-sram_ -> none:
    data-size-bytes := driver_.read-data DATA-SIZE-ADDRESS_ DATA-SIZE-SIZE_
    data-size-int := BIG-ENDIAN.uint16 data-size-bytes 0

    // Quick check to see if new.  An erased device reads back as 0xFF.
    if data-size-bytes == DEFAULT-DATA_:
      // probably never been used before, or overwritten/corrupt.
      logger_.warn "likely brand new chip" --tags={"size-ba":"$(data-size-bytes)"}
      data_.clear
      return

    // A size that cannot fit on the device means the header is not valid.
    max-size := bytes-capacity - OVERHEAD-BYTES_
    if data-size-int < 1 or data-size-int > max-size:
      logger_.error "stored size is invalid - assuming corrupt/empty." --tags={
        "size":data-size-int,
        "max":max-size}
      data_.clear
      return

    // Read data bytes (and checksum bytes) back from device.
    logger_.debug "reading back bytes from SRAM" --tags={"bytes":"$(data-size-int)"}
    restored-checksum := driver_.read-data DATA-CHECKSUM-ADDRESS_ DATA-CHECKSUM-SIZE_
    restored-data := driver_.read-data DATA-START-ADDRESS_ data-size-int

    // Check data against checksum.
    restored-data-checksum := checksum-ba_ restored-data
    if restored-data-checksum != restored-checksum:
      logger_.error "restore checksum failed - assuming corrupt/empty." --tags={
        "stored-checksum":(BIG-ENDIAN.uint16 restored-checksum 0),
        "calculated-checksum":(BIG-ENDIAN.uint16 restored-data-checksum 0)}
      data_.clear
      return

    // Restore data into a new Map.  Tison-restored object won't take writes.
    restored/any := null
    exception := catch: restored = tison.decode restored-data
    if exception or (restored is not Map):
      logger_.error "restored data could not be decoded - assuming corrupt/empty." --tags={
        "exception":"$exception"}
      data_.clear
      return

    logger_.debug "restore checksum passed" --tags={
      "stored-checksum":(BIG-ENDIAN.uint16 restored-checksum 0),
      "calculated-checksum":(BIG-ENDIAN.uint16 restored-data-checksum 0)}
    data_ = restored.copy
    logger_.debug "map restored" --tags={"items":"$(data_.size)","bytes":data-size-int}

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
        in-use := BIG-ENDIAN.uint16 data-size-bytes 0
        // The size and checksum precede the data, so dump them as well.
        rows = (in-use + OVERHEAD-BYTES_ + cols - 1) / cols

    print " - Capacity    : $(bytes-capacity)"
    print " - Used        : $(bytes-used)"
    print " - Available   : $(bytes-available)"
    driver_.dump-sram start --rows=rows --cols=cols

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
