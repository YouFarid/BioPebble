# BioPebble

BioPebble is a small wearable health monitor prototype I built using a Seeed XIAO nRF52840 Sense, a MAX30102 heart-rate sensor, a LiPo battery, and a Flutter phone app.

The idea is basically a tiny BLE health tracker. It reads pulse/SpO2-ish data from the MAX30102, motion data from the XIAO's built-in IMU, battery voltage, and sends everything to a phone over Bluetooth.

This is a school/prototype project, not a medical device.

---

## What it can do

- Connect to a phone over Bluetooth Low Energy
- Show heart rate when the MAX30102 has a decent signal
- Show experimental SpO2 values
- Show battery voltage and rough battery percent
- Read motion from the XIAO Sense IMU
- Estimate activity / stillness
- Estimate steps and cadence
- Show signal/contact quality
- Display raw IR and red sensor values for debugging
- Show a nicer Flutter dashboard with graphs and cards

Some values are rough estimates, especially steps, calories, stress/readiness, and SpO2. They are mostly there to make the prototype more complete and easier to demo.

---

## Hardware used

- Seeed Studio XIAO nRF52840 Sense
- MAX30102 pulse sensor breakout
- 3.7V 150 mAh LiPo battery
- Small perfboard
- USB-C cable

I originally tested a BMP388 barometer and a coin vibration motor too, but they are not part of the current version.

---

## Wiring

### MAX30102

| MAX30102 | XIAO |
|---|---|
| VCC | 3V3 |
| GND | GND |
| SDA | D4 / SDA |
| SCL | D5 / SCL |
| INT | not connected |

### Battery

| Battery | XIAO |
|---|---|
| Red wire | BAT+ |
| Black wire | BAT- |
| White wire | not connected |

The white wire is probably a temperature sense wire. I taped it off and did not use it.

---

## Arduino firmware

Firmware file:

```text
arduino/xiao_health_ble/xiao_health_ble.ino
```

On my Windows setup, Arduino did not like the space in the folder name `Health Monitor`, so I also used this copy when uploading:

```text
C:\ArduinoProjects\xiao_health_ble\xiao_health_ble.ino
```

### Arduino libraries

Install these in Arduino IDE:

- Adafruit TinyUSB Library
- SparkFun MAX3010x Pulse and Proximity Sensor Library
- Seeed Arduino LSM6DS3

Board:

```text
Seeed XIAO nRF52840 Sense
```

The firmware uses `bluefruit.h` for BLE, not `ArduinoBLE`.

---

## BLE info

Device name:

```text
Tiny Health
```

Service UUID:

```text
19b10000-e8f2-537e-4f6c-d104768a1214
```

Characteristic UUID:

```text
19b10001-e8f2-537e-4f6c-d104768a1214
```

The XIAO sends JSON lines like this:

```json
{
  "ir": 150000,
  "red": 120000,
  "finger": true,
  "bpm": 78,
  "avgBpm": 78,
  "hrValid": 1,
  "spo2": 98,
  "spo2Valid": 1,
  "motion": 1.00,
  "batV": 3.88,
  "batPct": 50
}
```

---

## Flutter app

Flutter app folder:

```text
health_monitor_app/
```

Main app code:

```text
health_monitor_app/lib/main.dart
```

Packages used:

- flutter_blue_plus
- permission_handler

Run the app:

```bash
cd health_monitor_app
flutter pub get
flutter run
```

Build APK:

```bash
flutter build apk --debug
```

APK output:

```text
health_monitor_app/build/app/outputs/flutter-apk/app-debug.apk
```

---

## Notes on accuracy

The MAX30102 is very sensitive to placement. A lot of the project ended up being about getting stable contact, not just writing code.

Things that helped:

- cover the sensor from room light
- keep finger/contact pressure steady
- avoid moving while measuring
- use a black gasket or foam around the sensor
- ignore the first few seconds after contact starts
- filter out obviously bad readings

The app shows a lot of signal/contact info because bad contact was one of the biggest issues.

---

## Enclosure idea

The best enclosure idea so far is a small "palm pebble" or finger/palm clip:

- electronics on top
- MAX30102 facing the skin
- black gasket around the sensor
- elastic or Velcro strap for pressure
- USB-C still accessible

A normal ring would look cool, but with this board size it would probably be bulky and harder to get reliable readings.

---

## Limitations

- Not a medical device
- Heart rate can jump if the sensor moves
- SpO2 is experimental
- Step counting is rough
- Battery percent is estimated from voltage
- Sleep tracking would need a much better enclosure
- The current prototype is still pretty hand-built

---

## Future improvements

- Better 3D-printed enclosure
- Smaller custom PCB
- Better optical gasket
- Add vibration motor
- Add BMP388 later for altitude/stairs
- Save sessions locally in the app
- Export data to CSV
- Add settings to tune MAX30102 brightness/filtering

