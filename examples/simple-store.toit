// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import ..src.eeram show *

SDA-PIN := 8
SCL-PIN := 9


main:
  // Initial setup for I2C.
  frequency := 100_000
  sda := gpio.Pin SDA-PIN
  scl := gpio.Pin SCL-PIN
  bus := i2c.Bus --sda=sda --scl=scl --frequency=frequency
  scandevices := bus.scan

  // Establish control device
  error := false
  eeram-sram-device := null
  eeram-controller-device := null
  eeram-driver/Eeram? := null
  if not scandevices.contains Eeram.I2C-CONTROL-ADDRESS:
    print "Eeram controller (0x$(%02x Eeram.I2C-CONTROL-ADDRESS)) not present"
    error = true
  if not scandevices.contains Eeram.I2C-CONTROL-ADDRESS:
    print "Eeram sram (0x$(%02x Eeram.I2C-SRAM-ADDRESS)) not present"
    error = true

  // Error hapened, can't continue
  if error: return

  print "Eeram controller (0x$(%02x Eeram.I2C-CONTROL-ADDRESS)) present"
  print "Eeram sram (0x$(%02x Eeram.I2C-SRAM-ADDRESS)) present"

  eeram-controller-device = bus.device Eeram.I2C-CONTROL-ADDRESS
  eeram-sram-device = bus.device Eeram.I2C-SRAM-ADDRESS

  eeram-driver = Eeram --control=eeram-controller-device --data=eeram-sram-device --capacity=Eeram.CAPACITY-16KBIT

  print "EERAM Driver Started"
  print " - ASE Enabled : $(eeram-driver.ase-enabled)"
  print " - Capacity    : $(eeram-driver.bytes-capacity)"
  print " - Used        : $(eeram-driver.bytes-used)"
  print " - Available   : $(eeram-driver.bytes-available)"
  print " - Has Changed : $(eeram-driver.has-changed)"

  eeram-driver.dump-sram 18

  //eeram-driver["hello"] = "to yooo"
  //eeram-driver["party"] = "starting"
  //eeram-driver["lets"] = "get the hell out of here "
  eeram-driver["TIMEZONE-POSIX-CODE"] = "GMT0BST,M3.5.0/1,M10.5.0"
  eeram-driver["time"] = "$(Time.now)"

  eeram-driver.store
  eeram-driver.dump-sram






  //eeram-driver.store
  //print " - Has Changed : $(eeram-driver.has-changed)"


//  print "Enabling ASE..."
//  eeram-driver.enable-ase
//  print " - ASE Enabled : $(eeram-driver.ase-enabled)"
