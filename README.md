# Toit Library for a Microchip 47L04/47C04/47L16/47C16 4/16Kbit IC.
Toit Driver Library for a Microchip EERAM module - a flash backed ram module,
which copies data from SRAM to FLASH when it senses power off.

![Several 47L16 PDIP ICs](images/47l16s.jpg)

## About the Device
The Microchip Technology 47L04/47C04/47L16/47C16 (47XXX) is a 4/16 Kbit SRAM
with EEPROM backup. The device utilizes the I2C serial interface. The 47XXX
provides infinite read and write cycles to the SRAM while EEPROM cells provide
high-endurance nonvolatile storage of data. With an external capacitor, SRAM
data is automatically transferred to the EEPROM upon loss of power. Data can
also be transferred manually by using either the 'Hardware Store' pin or
software control. Upon power-up, the EEPROM data is automatically recalled to
the SRAM. Recall can also be initiated through software control.
([datasheet](https://ww1.microchip.com/downloads/en/DeviceDoc/47L04_47C04_47L16_47C16_DS20005371D.pdf))

> [!TIP]
> This device is made to store persistent data that could be written at
> rates high enough to cause damage to typical flash memory.  If the intended
> use case is for data that is saved once and not saved again, then Toit's
> [bucket feature](https://libs.toit.io/system/storage/class-Bucket) is probably
> more than enough, with fewer electrical requirements.

## Quick Start Information
Use the following steps to get operational quickly:
- Follow Wiring Diagrams to get the device connected correctly.



## Issues
If there are any issues, changes, or any other kind of feedback, please
[raise an issue](https://github.com/milkmansson/toit-ina226/issues). Feedback is
welcome and appreciated!

## Disclaimer
- This driver has been written and tested with an IC directly (pictured).
  Other modules do exist and may behave differenly.
- All trademarks belong to their respective owners.
- No warranties for this work, express or implied.

## Credits
- [Florian](https://github.com/floitsch) for the tireless help and encouragement
- The wider Toit developer team (past and present) for a truly excellent product

## About Toit
One would assume you are here because you know what Toit is.  If you dont:
> Toit is a high-level, memory-safe language, with container/VM technology built
> specifically for microcontrollers (not a desktop language port). It gives fast
> iteration (live reloads over Wi-Fi in seconds), robust serviceability, and
> performance that’s far closer to C than typical scripting options on the
> ESP32. [[link](https://toitlang.org/)]
- [Review on Soracom](https://soracom.io/blog/internet-of-microcontrollers-made-easy-with-toit-x-soracom/)
- [Review on eeJournal](https://www.eejournal.com/article/its-time-to-get-toit)
