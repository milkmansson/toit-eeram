// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import i2c
import ..src.eeram show *
import ..src.persistentmap show *
import log

/**
Simple test of the PersistentMap feature of the Eeram driver package.

Creates the I2C devices by hand, to show what the driver needs.  (See
  persistent-extras-example.toit for the shorter `from-bus` form.)

Set $VERBOSE to dump the SRAM at each step, so the content can be seen in the
  datastore.  Set $DUMP-ONLY to only print the existing map and a dump, without
  changing anything.
*/

SDA-PIN ::= 8
SCL-PIN ::= 9

VERBOSE ::= false
DUMP-ONLY ::= false

print-map map/PersistentMap -> none:
  map.keys.do:
    print " - [$it]: \"$(map[it])\""

main:
  // Setup logger, and desired log level.
  logger := log.default.with-level log.INFO-LEVEL
  logger = logger.with-name "example"

  // Initial setup for I2C.
  frequency := 100_000
  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN --frequency=frequency
  scandevices := bus.scan

  // Establish control and data devices.
  error := false
  if not scandevices.contains Eeram.I2C-CONTROL-ADDRESS:
    logger.info "Eeram controller (0x$(%02x Eeram.I2C-CONTROL-ADDRESS)) not present"
    error = true
  if not scandevices.contains Eeram.I2C-DATA-ADDRESS:
    logger.info "Eeram sram (0x$(%02x Eeram.I2C-DATA-ADDRESS)) not present"
    error = true

  // Error happened, can't continue.
  if error: return

  logger.info "Eeram controller (0x$(%02x Eeram.I2C-CONTROL-ADDRESS)) present"
  logger.info "Eeram sram (0x$(%02x Eeram.I2C-DATA-ADDRESS)) present"

  eeram-controller-device := bus.device Eeram.I2C-CONTROL-ADDRESS
  eeram-data-device := bus.device Eeram.I2C-DATA-ADDRESS

  p-map := PersistentMap
      --control=eeram-controller-device
      --data=eeram-data-device
      --capacity=Eeram.CAPACITY-16KBIT
      --logger=logger

  print "Driver Started"
  print " - ASE Enabled : $(p-map.ase-enabled)"
  print " - Has Changed : $(p-map.has-changed)"
  print

  if DUMP-ONLY:
    print "Map Content:"
    print-map p-map
    print "Dump SRAM"
    p-map.dump-sram
    return

  if VERBOSE: p-map.dump-sram
  if not p-map.ase-enabled:
    print "Enabling ASE..."
    p-map.enable-ase
    print " - ASE Enabled : $(p-map.ase-enabled)"
    print

  print "Existing Data... (has changed : $(p-map.has-changed))"
  print-map p-map
  if VERBOSE: p-map.dump-sram
  print
  print "Storing a value..."
  p-map["new-key"] = "some new value"
  print
  print "Storing a value (the time)..."
  p-map["last-run-time"] = "$(Time.now)"
  print
  print "Data NOW... (has changed : $(p-map.has-changed))"
  print-map p-map
  print
  print "Storing Data to EEPROM manually..."
  p-map.store
  print
  print "Data now has changed : $(p-map.has-changed)"
  if VERBOSE: p-map.dump-sram
  print
  print "< reboot/power off this device and do it again >"
  print
