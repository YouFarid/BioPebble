#include <Adafruit_TinyUSB.h>
#include <bluefruit.h>
#include <Wire.h>
#include "MAX30105.h"
#include "spo2_algorithm.h"
#include "LSM6DS3.h"

// This sketch runs the XIAO as a BLE sensor.
// It reads:
// - MAX30102 red/IR values for pulse + SpO2
// - built-in IMU for motion
// - LiPo battery voltage
// Then it sends one JSON line to the phone app.

#ifndef PIN_VBAT
#error "PIN_VBAT is not defined for this board package."
#endif

// Main sensor objects.
MAX30105 particleSensor;
LSM6DS3 imu(I2C_MODE, 0x6A);

// Custom BLE service used by the Flutter app.
BLEService healthService = BLEService("19b10000-e8f2-537e-4f6c-d104768a1214");
BLECharacteristic telemetryCharacteristic = BLECharacteristic("19b10001-e8f2-537e-4f6c-d104768a1214");

// SparkFun's SpO2 algorithm wants 100 red and IR samples.
#if defined(__AVR_ATmega328P__) || defined(__AVR_ATmega168__)
uint16_t irBuffer[100];
uint16_t redBuffer[100];
#else
uint32_t irBuffer[100];
uint32_t redBuffer[100];
#endif

int32_t bufferLength = 100;
int32_t spo2 = 0;
int8_t validSPO2 = 0;
int32_t heartRate = 0;
int8_t validHeartRate = 0;

long latestIrValue = 0;
long latestRedValue = 0;
bool initialSamplesReady = false;

// Heart-rate cleanup settings.
// The MAX algorithm can produce a random-looking value when the finger moves,
// so the app only receives BPM after the readings settle down.
const byte HR_STABLE_COUNT = 2;
const int HR_MIN = 45;
const int HR_MAX = 145;
const int HR_CLOSE_ENOUGH = 20;
const unsigned long CONTACT_WARMUP_MS = 15000;
int recentHr[HR_STABLE_COUNT] = { 0, 0 };
byte recentHrCount = 0;
byte recentHrIndex = 0;
unsigned long contactStartedAt = 0;
bool hadFingerLastLoop = false;
int filteredHeartRate = 0;

// Rough LiPo percentage table for a single-cell 3.7V battery.
// This is not perfect, but it is good enough for "low / medium / full".
float batteryVoltageToPercent(float voltage) {
  if (voltage >= 4.20) return 100;
  if (voltage >= 4.15) return 95;
  if (voltage >= 4.11) return 90;
  if (voltage >= 4.08) return 85;
  if (voltage >= 4.02) return 80;
  if (voltage >= 3.98) return 70;
  if (voltage >= 3.92) return 60;
  if (voltage >= 3.87) return 50;
  if (voltage >= 3.82) return 40;
  if (voltage >= 3.79) return 30;
  if (voltage >= 3.74) return 20;
  if (voltage >= 3.68) return 10;
  if (voltage >= 3.50) return 5;
  return 0;
}

// The XIAO battery monitor reads a divided-down battery voltage.
// The 1510/510 multiplier comes from the XIAO battery divider.
float readBatteryVoltage() {
#ifdef VBAT_ENABLE
  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, LOW);
  delay(3);
#endif

  long rawSum = 0;
  const int samples = 8;
  for (int index = 0; index < samples; index++) {
    rawSum += analogRead(PIN_VBAT);
    delay(1);
  }

  float rawAverage = rawSum / (float)samples;
  float adcVoltage = rawAverage * (3.6 / 4096.0);
  return adcVoltage * 1510.0 / 510.0;
}

// Wait for one fresh MAX30102 sample.
// This prevents the code from hanging forever if the sensor stops responding.
bool waitForMaxSample() {
  unsigned long start = millis();
  while (particleSensor.available() == false) {
    particleSensor.check();
    if (millis() - start > 1000) {
      return false;
    }
  }
  return true;
}

// Clear the small heart-rate filter whenever contact is lost or restarted.
void resetHeartFilter() {
  recentHrCount = 0;
  recentHrIndex = 0;
  filteredHeartRate = 0;
  for (byte i = 0; i < HR_STABLE_COUNT; i++) {
    recentHr[i] = 0;
  }
}

bool motionLooksBad(float motion, float gyroX, float gyroY, float gyroZ) {
  // PPG hates movement. A quick twist can create fake pulse peaks.
  return fabs(motion - 1.0) > 0.12 ||
         fabs(gyroX) > 40 ||
         fabs(gyroY) > 40 ||
         fabs(gyroZ) > 40;
}

// Returns true only when the heart rate looks stable enough to send.
// Rules:
// 1. finger must be detected
// 2. wait a short warm-up after contact starts
// 3. reject motion artifacts
// 4. keep only realistic BPM values
// 5. require a couple readings to agree
bool updateHeartFilter(bool fingerDetected, bool motionArtifact) {
  if (!fingerDetected) {
    hadFingerLastLoop = false;
    contactStartedAt = 0;
    resetHeartFilter();
    return false;
  }

  if (!hadFingerLastLoop) {
    hadFingerLastLoop = true;
    contactStartedAt = millis();
    resetHeartFilter();
    return false;
  }

  if (millis() - contactStartedAt < CONTACT_WARMUP_MS) {
    return false;
  }

  if (motionArtifact || !validHeartRate || heartRate < HR_MIN || heartRate > HR_MAX) {
    return false;
  }

  recentHr[recentHrIndex] = heartRate;
  recentHrIndex = (recentHrIndex + 1) % HR_STABLE_COUNT;
  if (recentHrCount < HR_STABLE_COUNT) {
    recentHrCount++;
  }

  if (recentHrCount < HR_STABLE_COUNT) {
    return false;
  }

  int minHr = recentHr[0];
  int maxHr = recentHr[0];
  int sumHr = 0;
  for (byte i = 0; i < HR_STABLE_COUNT; i++) {
    minHr = min(minHr, recentHr[i]);
    maxHr = max(maxHr, recentHr[i]);
    sumHr += recentHr[i];
  }

  if (maxHr - minHr > HR_CLOSE_ENOUGH) {
    return false;
  }

  filteredHeartRate = sumHr / HR_STABLE_COUNT;
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(3000);

  Serial.println("BOOT: Tiny Health BLE firmware");

  // 12-bit ADC is needed for the battery reading.
  analogReadResolution(12);

  // All sensors share the I2C bus.
  Wire.begin();
  Wire.setClock(100000);

  // Start MAX30102.
  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println("MAX30102 not found.");
    while (1) {
      delay(1000);
    }
  }

  byte ledBrightness = 60;
  byte sampleAverage = 4;
  byte ledMode = 2;
  byte sampleRate = 100;
  int pulseWidth = 411;
  int adcRange = 4096;

  // MAX30102 tuning values.
  // Change these first if the optical signal is too weak or too strong.
  particleSensor.setup(ledBrightness, sampleAverage, ledMode, sampleRate, pulseWidth, adcRange);
  Serial.println("MAX30102 configured.");

  // Start the XIAO Sense IMU.
  if (imu.begin() == 0) {
    Serial.println("IMU configured.");
  } else {
    Serial.println("IMU not found.");
  }

  // Start BLE and create the custom telemetry characteristic.
  Bluefruit.begin();
  Bluefruit.setName("Tiny Health");
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);

  healthService.begin();

  telemetryCharacteristic.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  telemetryCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  telemetryCharacteristic.setMaxLen(244);
  telemetryCharacteristic.begin();
  telemetryCharacteristic.write("{\"status\":\"boot\"}\n");

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(healthService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);

  Serial.println("BLE advertising as Tiny Health");
}

void loop() {
  // First pass: fill the first 100-sample buffer.
  // The SparkFun/Maxim algorithm needs this before it can calculate anything.
  if (!initialSamplesReady) {
    for (byte i = 0; i < bufferLength; i++) {
      if (!waitForMaxSample()) {
        Serial.println("Waiting for MAX30102 samples...");
        delay(500);
        return;
      }

      redBuffer[i] = particleSensor.getRed();
      irBuffer[i] = particleSensor.getIR();
      latestRedValue = redBuffer[i];
      latestIrValue = irBuffer[i];
      particleSensor.nextSample();
    }

    maxim_heart_rate_and_oxygen_saturation(
      irBuffer,
      bufferLength,
      redBuffer,
      &spo2,
      &validSPO2,
      &heartRate,
      &validHeartRate
    );

    initialSamplesReady = true;
  }

  // After the first buffer, keep the newest 75 samples...
  for (byte i = 25; i < 100; i++) {
    redBuffer[i - 25] = redBuffer[i];
    irBuffer[i - 25] = irBuffer[i];
  }

  // ...then add 25 new samples. This matches SparkFun's SpO2 example.
  for (byte i = 75; i < 100; i++) {
    if (!waitForMaxSample()) {
      Serial.println("Waiting for MAX30102 samples...");
      delay(500);
      return;
    }

    redBuffer[i] = particleSensor.getRed();
    irBuffer[i] = particleSensor.getIR();
    latestRedValue = redBuffer[i];
    latestIrValue = irBuffer[i];
    particleSensor.nextSample();
  }

  // Calculate HR and SpO2 from the current 100-sample window.
  maxim_heart_rate_and_oxygen_saturation(
    irBuffer,
    bufferLength,
    redBuffer,
    &spo2,
    &validSPO2,
    &heartRate,
    &validHeartRate
  );

  // Basic contact check. It only means "something reflective is there",
  // so the heart filter still has to decide if the reading is believable.
  bool fingerDetected = latestIrValue >= 50000;

  // Read motion. This is used by the app and also rejects bad pulse windows.
  float accelX = imu.readFloatAccelX();
  float accelY = imu.readFloatAccelY();
  float accelZ = imu.readFloatAccelZ();
  float gyroX = imu.readFloatGyroX();
  float gyroY = imu.readFloatGyroY();
  float gyroZ = imu.readFloatGyroZ();
  float motion = sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);
  bool motionArtifact = motionLooksBad(motion, gyroX, gyroY, gyroZ);
  bool outputHeartRateValid = updateHeartFilter(fingerDetected, motionArtifact);
  bool outputSpo2Valid = outputHeartRateValid && validSPO2 && spo2 >= 80 && spo2 <= 100;
  int outputHeartRate = outputHeartRateValid ? filteredHeartRate : 0;
  int outputSpo2 = outputSpo2Valid ? spo2 : 0;

  // Battery status for the app.
  float batteryVoltage = readBatteryVoltage();
  int batteryPercent = (int)batteryVoltageToPercent(batteryVoltage);

  // Build one line of JSON. The Flutter app reads one full line at a time.
  char payload[244];
  snprintf(
    payload,
    sizeof(payload),
    "{\"ms\":%lu,\"ir\":%ld,\"red\":%ld,\"finger\":%s,\"bpm\":%d,\"avgBpm\":%d,"
    "\"hrValid\":%d,\"spo2\":%d,\"spo2Valid\":%d,"
    "\"ax\":%.3f,\"ay\":%.3f,\"az\":%.3f,\"gx\":%.2f,\"gy\":%.2f,\"gz\":%.2f,"
    "\"motion\":%.3f,\"batV\":%.3f,\"batPct\":%d}\n",
    millis(),
    latestIrValue,
    latestRedValue,
    fingerDetected ? "true" : "false",
    outputHeartRate,
    outputHeartRate,
    outputHeartRateValid ? 1 : 0,
    outputSpo2,
    outputSpo2Valid ? 1 : 0,
    accelX,
    accelY,
    accelZ,
    gyroX,
    gyroY,
    gyroZ,
    motion,
    batteryVoltage,
    batteryPercent
  );

  // Update BLE value and notify the phone if connected.
  telemetryCharacteristic.write(payload);
  if (Bluefruit.connected()) {
    telemetryCharacteristic.notify((uint8_t *)payload, strlen(payload));
  }

  // Serial output is mainly for debugging/calibration.
  Serial.print(payload);
}

// BLE callbacks are just for Serial Monitor debugging.
void connectCallback(uint16_t connHandle) {
  (void)connHandle;
  Serial.println("BLE connected");
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void)connHandle;
  (void)reason;
  Serial.println("BLE disconnected");
}
