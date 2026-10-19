# Toit Library for a Microchip 47L04/47C04/47L16/47C16 4/16Kbit EERAM IC.
Toit Driver Library for a Microchip EERAM module - a flash backed ram module,
which copies data from SRAM to FLASH when it senses power off.

![Several 47L16 PDIP ICs](images/47l16s.jpeg)

## About the Device
The Microchip Technology 47L04/47C04/47L16/47C16 (47XXX) is a 4/16 Kbit SRAM
with EEPROM backup. The device utilizes the I2C serial interface. The 47XXX
provides infinite read and write cycles to the SRAM while EEPROM cells provide
high-endurance nonvolatile storage of data. With an external capacitor, SRAM
data is automatically transferred to the EEPROM upon loss of power. Data can
also be transferred manually by using either the 'Hardware Store' pin or
software control. Upon power-up, the EEPROM data is automatically recalled to
the SRAM. Recall can also be initiated through software control.
[[datasheet](https://ww1.microchip.com/downloads/en/DeviceDoc/47L04_47C04_47L16_47C16_DS20005371D.pdf)]

> [!TIP]
> This device is made to store persistent data that could be written at
> rates high enough to cause damage to typical flash memory.  If the intended
> use case is for data that is saved once and not changed often, then Toit's
> [bucket storage feature](https://libs.toit.io/system/storage/class-Bucket) is
> probably more than enough.  It writes to the ESP32 flash directly, which is
> simpler and requires fewer components.
>
> | This chip (EERAM) | Toit flash bucket (ESP32 NVS) |
> | - | - |
> | SRAM writes are not limited: "Infinite read and write cycles to SRAM". Only a store wears the EEPROM, which is rated at "1,000,000 Store cycles" (at +25 °C). | Every write goes to flash: "Typical flash lifetime is 100 k erase cycles." NVS has "flash wear leveling by design", and one sector erase can cover up to 126 small values. |
> | Estimated lifetime with one store per power-off, whatever the update rate:  A store a minute ≈ 1.9 years, a store an hour ≈ 114 years, a store a day ≈ 2,700 years. | Estimated lifetime for a small value written every second ≈ 5 months, every minute ≈ 24 years, every hour ≈ 1,400 years. |
> <details>
>
> <summary>How estimates were established...</summary>
>
> The lifetimes are estimates.  The flash figures use the model from the
> Espressif FAQ: one 4096-byte sector, 126 entries per sector, 100 k erase
> cycles and small values.  Several sectors in the NVS partition extend them.
> Larger values or a fuller partition shorten them ("The actual factor is lower
> in practice").  The flash chip on a given board has its own datasheet figure,
> and 100 k is only the typical value.  Toit flash buckets use NVS
> (`flash-kv-init_ "nvs" "toit" false` in Toit's
> [storage.toit](https://github.com/toitlang/toit/blob/master/system/extensions/esp32/storage.toit)).
> Sources: the EERAM datasheet linked above,
> [Espressif FAQ on NVS](https://docs.espressif.com/projects/esp-faq/en/latest/software-framework/storage/nvs.html),
> [ESP-IDF NVS documentation](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s2/api-reference/storage/nvs_flash.html).
>
> </details>



### Device Types
These IC's come in two voltage flavours and two size flavours.  Note that the
`L` and `C` indicate the supply voltage:
| Part # | Size (Density) | Voltage Range |
| - | - | - |
| `47L04` | 4Kbit | 2.7-3.6V |
| `47C04` | 4Kbit | 4.5-5.5V |
| `47L16` | 16Kbit | 2.7-3.6V |
| `47C16` | 16Kbit | 4.5-5.5V |

There are different capacities and model numbers available from different
manufacturers.


## Features/Operation

### Device Wiring
The IC requires a power capacitor.  A decoupling capacitor is also recommended.
There are no built-in pull up resistors either.  The datasheet shows that the
device will function without a power capacitor, however if power is removed
during a store operation, the data may become corrupt.  The datasheet gives
example wiring diagrams, and makes recommendations about the capacitor types
and values that are best to use.

### Auto Store Enable (ASE)
> [!WARNING]
> When the device is first used out of the box, the 'Auto Store Enable' (ASE)
> feature is disabled.  Until this is enabled the automatic save feature will
> not happen.  This is enabled automatically in the `PersistentMap` class (see
> the caution below), but not in the main `Eeram` driver.

> [!CAUTION]
> Auto-Store needs a capacitor on the VCAP pin.  The datasheet states: "If a
> capacitor is not connected to the VCAP pin, then the VCAP pin must be
> connected to VCC and the Auto-Store feature must be disabled by writing the
> ASE bit to a '0' to prevent data corruption in the EEPROM array when power
> is lost."  On boards without the capacitor, construct `PersistentMap` with
> `--no-auto-store` and call `disable-ase`.

ASE can be configured using `driver.enable-ase` or using `driver.disable-ase`.
The current setting can be determined using `driver.ase-enabled`.

### Library Classes
The library comes in the form of three classes:
* `Eeram` class:  The code implementing the Eeram features.
* `PersistentMap` class (`import eeram.persistentmap`):  Implements an Eeram-
  backed Toit `Map` object (utilises the `Eeram` class.)
* `PersistentCounter` class (`import eeram.persistentcounter`):  A 32-bit
  counter kept in the SRAM, with a complement for validation.  Like any SRAM
  data, its value survives power loss only if the SRAM is stored to the EEPROM
  (Auto-Store, or `store`).

### Specific Functions
| class | functions | description | EEPROM wear |
| - | - | - | - |
| `Eeram` | `read-data`, `write-data` | Read or write bytes at an address of the SRAM array.  Throws `OUT_OF_BOUNDS` instead of wrapping around at the end of the device. | None (SRAM only). |
| `Eeram` | `store`, `recall`, `has-changed` | Copy SRAM to EEPROM or back, and report whether the SRAM changed since the last store or recall.  `store` does nothing when there is no change. | `store` uses one store cycle.  `recall` and `has-changed` use none. |
| `Eeram` | `enable-ase`, `disable-ase`, `ase-enabled` | Control the Auto-Store feature. | The ASE bit is nonvolatile, so a change is a STATUS write cycle (skipped when unchanged).  Reading uses none. |
| `Eeram` | `enable-block-protection`, `disable-block-protection`, `block-protection-enabled`, `block-protection-value` | Write-protect the upper part of the array. | As for ASE: the BP bits are nonvolatile. |
| `Eeram` | `event-detected`, `clear-event` | Read and clear the flag set by the HS (Hardware Store) pin. | As for ASE: the EVENT bit is nonvolatile. |
| `Eeram` | `from-bus`, `scan`, `data-address-for`, `control-address-for` | Create the driver from an `i2c.Bus` and the A1/A2 pin settings (`--a1`, `--a2`), so the two I2C addresses of the chip cannot be mismatched.  `scan` lists chips found. | None. |
| `Eeram` | `read-uint8`/`16`/`32`, `read-int32`, `read-float64` and the matching `write-` functions | Typed big-endian access at an address. | None (SRAM only). |
| `Eeram` | `dump-sram` | Print a hex-editor style dump, for troubleshooting. | None. |
| `PersistentMap` | `[]`, `[]=`, `get`, `contains`, `remove`, `clear` | Map access.  `[]=` saves to the SRAM immediately. | None (SRAM only) until a store happens. |
| `PersistentMap` | `keys`, `values`, `do`, `size`, `is-empty` | Map iteration and size. | None. |
| `PersistentMap` | `store`, `recall`, `has-changed`, `enable-ase`, `disable-ase`, `ase-enabled` | Same as the `Eeram` functions of that name. | Same as the `Eeram` functions. |
| `PersistentMap` | `batch`, `flush`, `pending-flush`, `--no-auto-flush` | Defer SRAM writes and write the map once.  `store` flushes first. | None (fewer SRAM writes). |
| `PersistentMap` | `load-state` | `LOAD-NEW`, `LOAD-OK` or `LOAD-CORRUPT`, from start-up or the last `recall`. | None. |
| `PersistentMap` | `bytes-capacity`, `bytes-used`, `bytes-available` | Space accounting for the map region, including the 8 bytes of header. | None. |
| `PersistentMap` | `dump-sram` | Dump of the occupied part of the SRAM. | None. |
| `PersistentCounter` | `value`, `increment`, `set`, `reset`, `was-valid` | 32-bit counter, saved to the SRAM on each change. | None (SRAM only) until a store happens. |

### EEPROM wear
- SRAM reads and writes do not wear the EEPROM: "Infinite read and write cycles
  to SRAM".
- A store copies the SRAM into the EEPROM.  The datasheet rates the EEPROM at
  "1,000,000 Store cycles" (at +25 °C).  A store happens on `store`, on the HS
  pin, and at power-off when ASE is enabled: "the Auto-Store will only be
  initiated if the AM bit in the STATUS register is set to a '1'", that is, if
  the SRAM changed.
- The datasheet gives no endurance figure for the nonvolatile STATUS bits (ASE,
  BP, EVENT).  The driver skips a STATUS write when the bit already has the
  requested value, and skips `store` when nothing changed.
- Estimated lifetimes are in the tip at the top.

### Timing
The device does not acknowledge while it runs a Store, a Recall or a STATUS
register write cycle.  By default the driver sleeps for the worst-case time
from the datasheet (plus margin) after each of these.  Constructing `Eeram` or
`PersistentMap` with `--ack-polling` ends the wait as soon as the device
acknowledges again ("Acknowledge Polling" in the datasheet).  This is
experimental and off by default.

The constructors also wait (up to 100 ms) for the device to respond, as it
cannot be accessed while its Auto-Recall at power-up runs.

### PersistentMap behaviour
- The map is encoded with tison and saved after an 8 byte header: magic
  (`EM`), format version, flags, 2 byte size and a CRC-16 (CCITT-FALSE)
  checksum.  Keys and values must be supported by tison.
- Data written by the earlier 4 byte header format is not migrated.  It fails
  the magic check, is discarded, and `load-state` reports `LOAD-CORRUPT`.
- At startup, stored data that fails the magic, version, size, checksum or
  decoding checks is discarded and logged as an error.  The map then starts
  empty.  A blank chip gives `LOAD-NEW`.
- `--start` and `--size` place the map in part of the device, so several maps
  (or a map and a `PersistentCounter`) can share one chip.  `store` covers the
  whole device.
- `--no-auto-flush` or `batch` defer SRAM writes, so several changes are sent
  once.  Changes are still validated immediately.  See
  [persistent-map-batch-example.toit](examples/persistent-map-batch-example.toit).
- Tasks: bus access and map changes are serialised with a mutex, so several
  tasks can share one driver.  A `batch` defers the writes of other tasks too.
  A task may read the in-memory map while another task's write is in
  progress; a failed write is rolled back afterwards.
- `[]=` throws `PersistentMap capacity exceeded` when the encoded map no longer
  fits on the device.  The map is left unchanged.
- A value changed in place (for example a list that has an item added) is only
  saved when it is assigned with `[]=` again.

## Example
Please see the [examples](examples/) folder.  In principle, the device has two
I2C devices, the controller, and the memory device.  The controller receives
instructions such as `store` and `recall` (pushing data between SRAM and EEPROM)
and enabling ASE.  The usage pattern is thus:
```toit
import i2c
import eeram show Eeram
import eeram.persistentmap show PersistentMap

SDA-PIN := 8
SCL-PIN := 9

// Initial setup for I2C.
frequency := 400_000
bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN --frequency=frequency
scandevices := bus.scan

// Shortest form: both I2C addresses come from the A1/A2 pin settings.
eeram-short := Eeram.from-bus bus --a1=false --a2=false

// Or, establish control and data devices by hand.
if not scandevices.contains Eeram.I2C-CONTROL-ADDRESS:
  print "Eeram CONTROLLER not present"
  return
if not scandevices.contains Eeram.I2C-DATA-ADDRESS:
  print "Eeram SRAM not present"
  return

eeram-controller-device := bus.device Eeram.I2C-CONTROL-ADDRESS
eeram-data-device := bus.device Eeram.I2C-DATA-ADDRESS

// To use the device as a 'PersistentMap':
pmap := PersistentMap
      --control=eeram-controller-device
      --data=eeram-data-device
      --capacity=Eeram.CAPACITY-16KBIT

// To use the device as a memory device:
eeram := Eeram
      --control=eeram-controller-device
      --data=eeram-data-device
      --capacity=Eeram.CAPACITY-16KBIT

```

## Tests
The driver is tested against a simulated chip, so no hardware is needed.  See
[tests/README.md](tests/README.md).

## Issues
If there are any issues, changes, or any other kind of feedback, please
[raise an issue](https://github.com/milkmansson/toit-eeram/issues). Feedback is
welcome and appreciated!

## Disclaimer
- This driver has been written and tested with an IC directly (pictured).
  Other modules do exist and may behave differently.
- All trademarks belong to their respective owners.
- No warranties for this work, express or implied.

## Credits
- [Florian](https://github.com/floitsch) for the tireless help and encouragement
- The wider Toit developer team (past and present) for a truly excellent product
- AI has been used to test/check code against registers/datasheets etc, and help
  further develop the driver.

## About Toit
One would assume you are here because you know what Toit is.  If you dont:
> Toit is a high-level, memory-safe language, with container/VM technology built
> specifically for microcontrollers (not a desktop language port). It gives fast
> iteration (live reloads over Wi-Fi in seconds), robust serviceability, and
> performance that’s far closer to C than typical scripting options on the
> ESP32. [[link](https://toitlang.org/)]
- [Review on Soracom](https://soracom.io/blog/internet-of-microcontrollers-made-easy-with-toit-x-soracom/)
- [Review on eeJournal](https://www.eejournal.com/article/its-time-to-get-toit)
