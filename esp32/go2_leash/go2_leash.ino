// go2_leash — BLE "leash" + one-gesture remote for the Go2 / dimOS on the Pi.
// Advertises as "go2-leash" ~10x/s. Manufacturer data = FF FF <state> <seq> <posture> <cm> <count>
//   state:   1 = FOLLOW, 0 = STOP (BOOT button GPIO0 toggles; LED GPIO2 on = FOLLOW). Boots in STOP.
//   posture: 0 = no command yet · 1 = SIT · 2 = STAND. One gesture: hold a hand 5–40 cm over the sensor
//            for HOLD_MS -> posture flips (first flip = SIT, since the dog is normally standing).
//            The hand must then be away for REARM_MS before the next flip, so a held hand never repeats.
//   cm:      latest hand distance (0 = no echo). count: increments on every flip (the Pi acts on a new count).
// Wiring (same as wave_follow / distance_dexterity): TK50/HC-SR04 VCC->3V3, GND->GND, TRIG->GPIO5, ECHO->GPIO18.
// BUTTON_FLIPS_POSTURE (build flag, default 0): BOOT flips posture like a gesture instead of toggling
// FOLLOW/STOP; state = 1 while BOOT is held (hold-to-walk dead-man for the phone app), and the LED is on
// while posture = SIT. It also reads bare touch pins (no wiring; the slider/theremin layout, measured on
// our first board): a finger on the G32-G13 edge = state 1 (forward), on G4/G15 = state 2 (backward),
// both edges = 0. Release reads as 0 at once. Do not touch the pins during boot (baseline). The sonar is
// skipped in this mode. For a bare board (no sensor):
//   arduino-cli compile --fqbn esp32:esp32:esp32 --build-property "build.extra_flags=-DBUTTON_FLIPS_POSTURE=1" go2_leash
#include <BLEDevice.h>
#include <BLEAdvertising.h>

#ifndef BUTTON_FLIPS_POSTURE
#define BUTTON_FLIPS_POSTURE 0
#endif

const int BTN_PIN = 0, LED_PIN = 2, TRIG_PIN = 5, ECHO_PIN = 18;
const unsigned long ADV_UPDATE_MS = 100, DEBOUNCE_MS = 250, PING_MS = 60;
const unsigned long ECHO_TIMEOUT_US = 30000, TRIGGER_PULSE_US = 500;  // TK50 needs the long trigger
const unsigned long HOLD_MS = 500;   // hand present this long -> flip
const unsigned long REARM_MS = 500;  // hand absent this long -> ready for the next flip
const int MISS_TOLERANCE = 3;        // consecutive missed echoes before the hand counts as gone
const float MIN_CM = 5.0, MAX_CM = 40.0;

BLEAdvertising *adv;
uint8_t state = 0, seq = 0, posture = 0, cmByte = 0, count = 0;
bool handPresent = false, armed = true;
int misses = 0;
unsigned long presentSince = 0, absentSince = 0, lastUpdate = 0, lastPress = 0, lastPing = 0;
int lastBtn = HIGH;

#if BUTTON_FLIPS_POSTURE
const int FWD_PADS[] = {32, 33, 27, 14, 12, 13};   // one edge, as measured for the slider
const int BACK_PADS[] = {4, 15};                   // the other edge (G2 is the LED, G0 is BOOT)
const int NFWD = sizeof(FWD_PADS) / sizeof(FWD_PADS[0]), NBACK = sizeof(BACK_PADS) / sizeof(BACK_PADS[0]);
const float ON_FRAC = 0.35f;                       // touched below 35% of baseline (~95% drop measured)
const unsigned long TOUCH_MS = 20;
int fwdBase[NFWD], backBase[NBACK];
int touchAgree = 0, touchDir = 0, candDir = 0;
unsigned long lastTouch = 0;

bool anyTouched(const int *pins, const int *base, int n) {
  for (int i = 0; i < n; i++) if (touchRead(pins[i]) < base[i] * ON_FRAC) return true;
  return false;
}

void calibrateTouch() {
  long f[NFWD] = {0}, k[NBACK] = {0};
  for (int r = 0; r < 40; r++) {
    for (int i = 0; i < NFWD; i++) f[i] += touchRead(FWD_PADS[i]);
    for (int i = 0; i < NBACK; i++) k[i] += touchRead(BACK_PADS[i]);
    delay(20);
  }
  for (int i = 0; i < NFWD; i++) fwdBase[i] = f[i] / 40;
  for (int i = 0; i < NBACK; i++) backBase[i] = k[i] / 40;
  Serial.print("touch baselines fwd");
  for (int i = 0; i < NFWD; i++) Serial.printf(" G%d=%d", FWD_PADS[i], fwdBase[i]);
  Serial.print(" back");
  for (int i = 0; i < NBACK; i++) Serial.printf(" G%d=%d", BACK_PADS[i], backBase[i]);
  Serial.println();
}

// 1 forward, 2 backward, 0 none. Two agreeing reads to start; release is immediate.
void readTouch(unsigned long now) {
  if (now - lastTouch < TOUCH_MS) return;
  lastTouch = now;
  bool f = anyTouched(FWD_PADS, fwdBase, NFWD), k = anyTouched(BACK_PADS, backBase, NBACK);
  int d = (f && !k) ? 1 : (k && !f) ? 2 : 0;
  if (d == 0) { touchDir = 0; touchAgree = 0; candDir = 0; return; }
  if (d == candDir) touchAgree++; else { candDir = d; touchAgree = 1; }
  if (touchAgree >= 2 && touchDir != d) {
    touchDir = d;
    Serial.printf("touch -> %s\n", d == 1 ? "FORWARD" : "BACKWARD");
  }
}
#endif

float readCm() {
  digitalWrite(TRIG_PIN, LOW); delayMicroseconds(4);
  digitalWrite(TRIG_PIN, HIGH); delayMicroseconds(TRIGGER_PULSE_US);
  digitalWrite(TRIG_PIN, LOW);
  unsigned long us = pulseIn(ECHO_PIN, HIGH, ECHO_TIMEOUT_US);
  return us ? us / 58.0 : 0;
}

void setAdvData() {
  BLEAdvertisementData d;
  d.setFlags(0x06);
  d.setName("go2-leash");
  String m;
  m += (char)0xFF; m += (char)0xFF; m += (char)state; m += (char)seq; m += (char)posture; m += (char)cmByte; m += (char)count;
  d.setManufacturerData(m);
  adv->setAdvertisementData(d);
}

void setup() {
  Serial.begin(115200);
  pinMode(BTN_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT); digitalWrite(LED_PIN, LOW);
  pinMode(TRIG_PIN, OUTPUT); pinMode(ECHO_PIN, INPUT);
  BLEDevice::init("go2-leash");
  adv = BLEDevice::getAdvertising();
  adv->setMinInterval(0x50);
  adv->setMaxInterval(0xA0);
  setAdvData();
  adv->start();
#if BUTTON_FLIPS_POSTURE
  calibrateTouch();
#endif
  Serial.printf("go2-leash up, MAC %s, state STOP\n", BLEDevice::getAddress().toString().c_str());
}

void loop() {
  unsigned long now = millis();

  int b = digitalRead(BTN_PIN);
#if BUTTON_FLIPS_POSTURE
  readTouch(now);
  state = (b == LOW) ? 1 : touchDir;   // raw held state, no debounce: release must stop at once
#endif
  if (b == LOW && lastBtn == HIGH && now - lastPress >= DEBOUNCE_MS) {
    lastPress = now;
#if BUTTON_FLIPS_POSTURE
    posture = (posture == 1) ? 2 : 1;
    count++;
    digitalWrite(LED_PIN, posture == 1 ? HIGH : LOW);
    Serial.printf("button flip -> %s (#%u)\n", posture == 1 ? "SIT" : "STAND", count);
#else
    state = !state;
    digitalWrite(LED_PIN, state ? HIGH : LOW);
    Serial.printf("state %s\n", state ? "FOLLOW" : "STOP");
#endif
  }
  lastBtn = b;

  if (!BUTTON_FLIPS_POSTURE && now - lastPing >= PING_MS) {
    lastPing = now;
    float cm = readCm();
    cmByte = (cm > 0 && cm < 255) ? (uint8_t)cm : 0;
    bool inBand = cm >= MIN_CM && cm <= MAX_CM;
    misses = inBand ? 0 : misses + 1;
    bool present = inBand || (handPresent && misses < MISS_TOLERANCE);
    if (present && !handPresent) presentSince = now;
    if (!present && handPresent) absentSince = now;
    handPresent = present;
    if (!handPresent && !armed && now - absentSince >= REARM_MS) armed = true;
    if (handPresent && armed && now - presentSince >= HOLD_MS) {
      armed = false;
      posture = (posture == 1) ? 2 : 1;
      count++;
      Serial.printf("flip -> %s (#%u, %.0f cm)\n", posture == 1 ? "SIT" : "STAND", count, cm);
    }
  }

  if (now - lastUpdate >= ADV_UPDATE_MS) {
    lastUpdate = now;
    seq++;
    adv->stop();
    setAdvData();
    adv->start();
  }
}
