// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import ..src.eeram show *
import log

/**
Simple test of the PersistentMap feature of the Eeram driver package.
*/

SDA-PIN := 8
SCL-PIN := 9

print-map map/PersistentMap -> none:
  map.keys.do:
    print " - [$it]: \"$(map[it])\""

main:
  // Initial setup for I2C.
  frequency := 100_000
  sda := gpio.Pin SDA-PIN
  scl := gpio.Pin SCL-PIN
  bus := i2c.Bus --sda=sda --scl=scl --frequency=frequency
  scandevices := bus.scan

  // Establish control and data devices.
  error := false
  eeram-data-device := null
  eeram-controller-device := null
  if not scandevices.contains Eeram.I2C-CONTROL-ADDRESS:
    print "Eeram controller (0x$(%02x Eeram.I2C-CONTROL-ADDRESS)) not present"
    error = true
  if not scandevices.contains Eeram.I2C-DATA-ADDRESS:
    print "Eeram sram (0x$(%02x Eeram.I2C-DATA-ADDRESS)) not present"
    error = true

  // Error hapened, can't continue
  if error: return

  print "Eeram controller (0x$(%02x Eeram.I2C-CONTROL-ADDRESS)) present"
  print "Eeram sram (0x$(%02x Eeram.I2C-DATA-ADDRESS)) present"

  eeram-controller-device = bus.device Eeram.I2C-CONTROL-ADDRESS
  eeram-data-device = bus.device Eeram.I2C-DATA-ADDRESS

  logger := log.default.with-level log.INFO-LEVEL

  p-map := PersistentMap
      --control=eeram-controller-device
      --data=eeram-data-device
      --capacity=Eeram.CAPACITY-16KBIT
      --logger=logger

  print "Driver Started"
  print " - ASE Enabled : $(p-map.ase-enabled)"
  print " - Has Changed : $(p-map.has-changed)"
  print
  print "Enabling ASE..."
  p-map.enable-ase
  print " - ASE Enabled : $(p-map.ase-enabled)"
  print
  print "Existing Data... (has changed : $(p-map.has-changed))"
  print-map p-map
  print
  print "Storing a value..."
  p-map["Some key"] = "some value"
  print
  print "Storing a value (the time)..."
  p-map["time"] = "$(Time.now)"
  print
  print "New Data... (has changed :$(p-map.has-changed))"
  print-map p-map
  print
  print "Storing Data to EEPROM manually..."
  p-map.store
  print
  print "Data now has changed : $(p-map.has-changed)"
  print
  print "< reboot/power off this device and do it again >"
  print
