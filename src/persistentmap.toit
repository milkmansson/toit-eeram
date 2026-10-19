// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import io show BIG-ENDIAN
import encoding.tison
import crypto.crc show Crc16CcittFalse
import .eeram
import i2c
import log
import monitor

/**
A Toit driver library implementing a 'persistent map' using for the Microchip
47L04/47C04/47L16/47C16 SRAM/FLASH IC.

(Wholly dependent on the Eeram driver library.  See the Toitdocs and README.md.)

# Layout
The map lives in a region of the device (all of it by default, see $start and
  $size on the constructors).  The region starts with an 8-byte header:
  - bytes 0-1: magic, 0x45 0x4D ("EM").
  - byte 2: format version (currently 1).
  - byte 3: flags (currently 0).
  - bytes 4-5: size of the encoded map in bytes (big-endian).
  - bytes 6-7: CRC-16/CCITT-FALSE of the encoded map (big-endian).
  The tison-encoded map follows.  Data written in a different layout (for
  example by version 1.x of this library, which used a 4-byte header) is not
  migrated.  It fails validation and is discarded, see $load-state.
*/
class PersistentMap:
  /** $load-state: the region was blank, so the map started empty. */
  static LOAD-NEW     ::= 0
  /** $load-state: the stored map was valid and has been loaded. */
  static LOAD-OK      ::= 1
  /** $load-state: the stored data failed validation and was discarded. */
  static LOAD-CORRUPT ::= 2

  /** The current version of the stored format. */
  static FORMAT-VERSION ::= 1

  // Offsets within the region.
  static MAGIC-OFFSET_      ::= 0x00
  static VERSION-OFFSET_    ::= 0x02
  static FLAGS-OFFSET_      ::= 0x03
  static DATA-SIZE-OFFSET_  ::= 0x04
  static CHECKSUM-OFFSET_   ::= 0x06
  static DATA-START-OFFSET_ ::= 0x08
  static DATA-SIZE-SIZE_    ::= 2
  static CHECKSUM-SIZE_     ::= 2
  static MAGIC_             ::= #[0x45, 0x4D]

  // This many bytes need to be subtracted from available bytes.
  static OVERHEAD-BYTES_    ::= DATA-START-OFFSET_

  // A blank (erased) device reads back as 0xFF.
  static BLANK-MAGIC_ ::= #[0xFF, 0xFF]

  // Original data container.
  data_/Map := {:}
  driver_/Eeram := ?
  logger_/log.Logger := ?
  // The size of the region in bytes.
  capacity_/int := ?
  // The device address of the start of the region.
  start_/int := ?
  auto-flush_/bool := ?
  dirty_/bool := false
  batch-depth_/int := 0
  load-state_/int := LOAD-NEW
  // Serialises the changes of tasks.  Reads of the in-memory map do not need
  // it, as they never yield.
  mutex_ ::= monitor.Mutex

  /**
  Constructs a PersistentMap, creating the $Eeram driver at the same time.

  The $capacity must be $Eeram.CAPACITY-4KBIT or $Eeram.CAPACITY-16KBIT.

  If $auto-store is true, the Auto-Store feature of the device is enabled when
    it is not already (see $enable-ase).  Auto-Store requires a capacitor on the
    VCAP pin.  The datasheet requires Auto-Store to be disabled when there is
    none, so boards without the capacitor must use --no-auto-store, and call
    $disable-ase.

  The map occupies the region of $size bytes at the device address $start.  By
    default the region runs from $start to the end of the device.  Several maps
    can share a device by using separate regions.

  If $auto-flush is true (the default), every change is written to the SRAM
    immediately.  Otherwise changes only reach the SRAM with $flush, $store or
    the end of a $batch.

  See $Eeram.constructor for the $ack-polling option.
  */
  constructor
      --data/i2c.Device
      --control/i2c.Device
      --capacity/int=Eeram.CAPACITY-16KBIT
      --auto-store/bool=true
      --start/int=0
      --size/int?=null
      --auto-flush/bool=true
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
    start_ = start
    capacity_ = validate-region_ capacity start size
    auto-flush_ = auto-flush
    if auto-store and not driver_.ase-enabled: driver_.enable-ase
    map-from-sram_
    logger_.info "driver started (manual creation)"

  /**
  Constructs a PersistentMap for use with an existing $Eeram instance.

  See the other constructor for the $auto-store, $start, $size and $auto-flush
    options.
  */
  constructor driver/Eeram
      --auto-store/bool=true
      --start/int=0
      --size/int?=null
      --auto-flush/bool=true
      --logger/log.Logger=log.default:
    driver_ = driver
    logger_ = logger.with-name "persistentmap"
    start_ = start
    capacity_ = validate-region_ driver.capacity start size
    auto-flush_ = auto-flush
    if auto-store and not driver_.ase-enabled: driver_.enable-ase
    map-from-sram_
    logger_.info "driver started (using existing Eeram object)"

  /**
  Constructs a PersistentMap for the chip on the $bus with the given address
    pin settings.

  The $a1 and $a2 flags tell whether the A1 and A2 pins of the chip are tied
    high.  See `Eeram.from-bus`, and the constructors for the other options.
  */
  constructor.from-bus bus/i2c.Bus
      --a1/bool=false
      --a2/bool=false
      --capacity/int=Eeram.CAPACITY-16KBIT
      --auto-store/bool=true
      --start/int=0
      --size/int?=null
      --auto-flush/bool=true
      --ack-polling/bool=false
      --logger/log.Logger=log.default:
    driver := Eeram.from-bus bus
        --a1=a1
        --a2=a2
        --capacity=capacity
        --ack-polling=ack-polling
        --logger=logger
    return PersistentMap driver
        --auto-store=auto-store
        --start=start
        --size=size
        --auto-flush=auto-flush
        --logger=logger

  static validate-region_ device-capacity/int start/int size/int? -> int:
    if size == null: size = device-capacity - start
    // Room for the header and the smallest encoded map is required.
    if start < 0 or size < OVERHEAD-BYTES_ + 2 or start + size > device-capacity:
      throw "PersistentMap region out of bounds"
    return size

  /**
  Stores the $value for the given $key.

  If the key is already present, overrides the previous value.  Data is sent to
    the SRAM immediately, unless deferred (see $auto-flush and $batch).

  The $key and $value must be supported by tison (see $tison.encode).  Values
    that are changed in place after being stored (for example by adding to a
    list) are only saved by storing them again.

  # Errors
  Throws "PersistentMap capacity exceeded" if the map would no longer fit in
    the region (see $bytes-available).  Also throws if the $key or $value
    cannot be encoded.  In both cases the map is left unchanged.
  */
  operator []= key/any value/any -> none:
    mutex_.do:
      existed := data_.contains key
      previous := data_.get key
      succeeded := false
      try:
        logger_.debug "adding to data map" --tags={"key":key,"data":value}
        data_[key] = value
        // Encoding validates the change, even if the write is deferred.
        frame := frame_
        if auto-flush_ and batch-depth_ == 0:
          write-frame_ frame
          dirty_ = false
        else:
          dirty_ = true
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
    mutex_.do:
      data_.clear
      changed_

  /** Removes the given $key from the map.  The key does not need to exist. */
  remove key/any -> none:
    mutex_.do:
      if not data_.contains key: return
      data_.remove key
      changed_

  /**
  Runs the $block with writes to the SRAM deferred, then writes the map once.

  Use this to change several entries with a single write.  The map is written
    when the $block ends, also if it throws.  Batches can be nested.  Changes
    made by other tasks while the batch runs are deferred too.
  */
  batch [block] -> none:
    batch-depth_++
    try:
      block.call
    finally:
      batch-depth_--
      if batch-depth_ == 0 and auto-flush_: flush

  /** Whether changes exist that were not yet written to the SRAM.  See $flush. */
  pending-flush -> bool:
    return dirty_

  /**
  Writes the map to the SRAM if there are pending changes.

  Does nothing when no changes are pending (see $pending-flush).  This does not
    store to the FLASH of the device, see $store.
  */
  flush -> none:
    mutex_.do: flush_

  flush_ -> none:
    if not dirty_: return
    write-frame_ frame_
    dirty_ = false

  // Called after the in-memory map changed without a validity check of its own.
  changed_ -> none:
    if auto-flush_ and batch-depth_ == 0:
      write-frame_ frame_
      dirty_ = false
    else:
      dirty_ = true

  /** How the map was obtained at start-up or last $recall: $LOAD-NEW, $LOAD-OK or $LOAD-CORRUPT. */
  load-state -> int:
    return load-state_

  /**
  The size of the region of the map, in bytes.

  This includes 8 bytes used for the header.  See $bytes-available.
  */
  bytes-capacity -> int:
    return capacity_

  /** Returns the number of bytes used by the encoded $object (the map by default). */
  bytes-used object/any=data_ -> int:
    return (tison.encode object).size

  /**
  Returns the number of bytes available for map data.

  The 8 bytes used for the header are already deducted.
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

  /**
  Manually trigger the device to write from SRAM to FLASH.

  Pending changes are written to the SRAM first (see $flush).  Note that the
    store covers the whole device, also the regions of other maps.
  */
  store -> none:
    mutex_.do:
      flush_
      driver_.store

  /**
  Manually trigger the device to read data from FLASH into SRAM.

  Will also put data from SRAM into the onboard Map object.  Pending changes are
    discarded.
  */
  recall -> none:
    mutex_.do:
      driver_.recall
      map-from-sram_
      dirty_ = false

  /**
  Builds the frame for the device: header followed by the encoded map.

  Throws if the encoded map does not fit in the region.
  */
  frame_ -> ByteArray:
    data-bytes := tison.encode data_
    max-size := capacity_ - OVERHEAD-BYTES_
    if data-bytes.size > max-size:
      logger_.error "SRAM storage exceeded." --tags={"size":data-bytes.size,"max":max-size}
      throw "PersistentMap capacity exceeded"
    frame := ByteArray OVERHEAD-BYTES_ + data-bytes.size
    frame.replace MAGIC-OFFSET_ MAGIC_
    frame[VERSION-OFFSET_] = FORMAT-VERSION
    frame[FLAGS-OFFSET_] = 0
    BIG-ENDIAN.put-uint16 frame DATA-SIZE-OFFSET_ data-bytes.size
    frame.replace CHECKSUM-OFFSET_ (checksum-ba_ data-bytes)
    frame.replace DATA-START-OFFSET_ data-bytes
    return frame

  // The header and data are contiguous on the device, so they are sent as one
  // frame.
  write-frame_ frame/ByteArray -> none:
    logger_.debug "saving data map to SRAM" --tags={
      "size":"$(frame.size - OVERHEAD-BYTES_)",
      "checksum":BIG-ENDIAN.uint16 frame CHECKSUM-OFFSET_}
    driver_.write-data start_ frame

  discard_ -> none:
    data_.clear
    load-state_ = LOAD-CORRUPT

  /**
  Loads the map from the SRAM device.

  Data that fails validation (magic, version, size, checksum or decoding) is
    discarded and logged as an error.  The map is then empty.
  */
  map-from-sram_ -> none:
    header := driver_.read-data start_ OVERHEAD-BYTES_

    // Quick check to see if new.  An erased device reads back as 0xFF.
    if header[MAGIC-OFFSET_..MAGIC-OFFSET_ + 2] == BLANK-MAGIC_:
      logger_.warn "likely brand new chip" --tags={"magic":"$(header[0..2])"}
      data_.clear
      load-state_ = LOAD-NEW
      return

    if header[MAGIC-OFFSET_..MAGIC-OFFSET_ + 2] != MAGIC_:
      logger_.error "no map found (magic mismatch) - assuming corrupt/empty." --tags={
        "magic":"$(header[0..2])"}
      discard_
      return

    if header[VERSION-OFFSET_] != FORMAT-VERSION:
      logger_.error "unsupported format version - assuming corrupt/empty." --tags={
        "version":header[VERSION-OFFSET_]}
      discard_
      return

    data-size-int := BIG-ENDIAN.uint16 header DATA-SIZE-OFFSET_
    restored-checksum := header[CHECKSUM-OFFSET_..CHECKSUM-OFFSET_ + CHECKSUM-SIZE_]

    // A size that cannot fit in the region means the header is not valid.
    max-size := capacity_ - OVERHEAD-BYTES_
    if data-size-int < 1 or data-size-int > max-size:
      logger_.error "stored size is invalid - assuming corrupt/empty." --tags={
        "size":data-size-int,
        "max":max-size}
      discard_
      return

    logger_.debug "reading back bytes from SRAM" --tags={"bytes":"$(data-size-int)"}
    restored-data := driver_.read-data start_ + DATA-START-OFFSET_ data-size-int

    // Check data against checksum.
    restored-data-checksum := checksum-ba_ restored-data
    if restored-data-checksum != restored-checksum:
      logger_.error "restore checksum failed - assuming corrupt/empty." --tags={
        "stored-checksum":(BIG-ENDIAN.uint16 restored-checksum 0),
        "calculated-checksum":(BIG-ENDIAN.uint16 restored-data-checksum 0)}
      discard_
      return

    // Restore data into a new Map.  Tison-restored object won't take writes.
    restored/any := null
    exception := catch: restored = tison.decode restored-data
    if exception or (restored is not Map):
      logger_.error "restored data could not be decoded - assuming corrupt/empty." --tags={
        "exception":"$exception"}
      discard_
      return

    logger_.debug "restore checksum passed" --tags={
      "stored-checksum":(BIG-ENDIAN.uint16 restored-checksum 0),
      "calculated-checksum":(BIG-ENDIAN.uint16 restored-data-checksum 0)}
    data_ = restored.copy
    load-state_ = LOAD-OK
    logger_.debug "map restored" --tags={"items":"$(data_.size)","bytes":data-size-int}

  /**
  Variant of $Eeram.dump-sram, with defaults suited for PersistentMap.

  The $start is a device address.  It defaults to the start of the region.
  */
  dump-sram start/int?=null --rows/int?=null --cols/int=16 -> none:
    if start == null: start = start_

    // If rows not given, determine the dump size by looking at the data size
    // stored in the header.
    if rows == null:
      header := driver_.read-data start_ OVERHEAD-BYTES_
      if header[MAGIC-OFFSET_..MAGIC-OFFSET_ + 2] != MAGIC_:
        // probably never been used before, or overwritten/corrupt.
        logger_.warn "likely brand new chip, or corrupt" --tags={"magic":"$(header[0..2])"}
        rows = (capacity_ + cols - 1) / cols
      else:
        in-use := BIG-ENDIAN.uint16 header DATA-SIZE-OFFSET_
        // The header precedes the data, so dump it as well.
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
    logger_.warn "wipe checksum" --tags={"bytes":BLANK-MAGIC_}
    driver_.write-data start_ + CHECKSUM-OFFSET_ BLANK-MAGIC_
