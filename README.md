# BrowserMaestroTesting

A minimal Android app used as a test target for [Maestro](https://maestro.mobile.dev/) UI test flows, with support for running those flows on real devices via [BrowserStack App Automate](https://www.browserstack.com/app-automate).

The app has a single screen with a button that opens Wikipedia in the device's default browser. The Maestro test flow verifies the full navigation from button tap through to a deep page within the Wikipedia site.

---

## Prerequisites

| Tool | Notes |
|------|-------|
| Android Studio / Android SDK | SDK 26+ required, compile/target SDK 35 |
| Java 17+ | Required by Gradle 8.6 |
| Gradle wrapper | Included — no separate install needed |
| [Maestro CLI](https://maestro.mobile.dev/getting-started/installing-maestro) | For running tests locally |
| `curl`, `jq`, `zip` | Required by the BrowserStack script (`brew install jq`) |

---

## 1. Build the App

Clone the repository and build the debug APK using the Gradle wrapper:

```bash
git clone https://github.com/andresako/browserMaestroTesting.git
cd browserMaestroTesting

./gradlew assembleDebug
```

The APK is output to:

```
app/build/outputs/apk/debug/app-debug.apk
```

To do a clean build:

```bash
./gradlew clean assembleDebug
```

---

## 2. Run the App

### On a connected device or emulator

Build and install directly:

```bash
./gradlew installDebug
```

Then launch **Browser Test App** from the device's app drawer, or run:

```bash
adb shell am start -n com.example.browsermaestrotesting/.MainActivity
```

---

## 3. Run Maestro Tests Locally

Make sure a device or emulator is connected and the app is installed, then:

```bash
# Run a specific flow
maestro test .maestro/01_open_and_interact.yaml

# Run all flows in the directory
maestro test .maestro/
```

### What the test does

The `01_open_and_interact.yaml` flow:

1. Launches the app with a clean state
2. Taps the **"Open external web"** button
3. Waits for the browser to open
4. Asserts Wikipedia loaded
5. Scrolls down to the "Terms of Use" link
6. Taps it and asserts the Terms of Use page loaded

---

## 4. Run Tests on BrowserStack

The `run_browserstack.sh` script handles the full pipeline: builds the APK, uploads it and the test suite to BrowserStack, triggers a run on a real device, and polls for results.

### Required credentials

```bash
export BROWSERSTACK_USERNAME="your_username"
export BROWSERSTACK_ACCESS_KEY="your_access_key"
```

You can find these in your [BrowserStack account settings](https://www.browserstack.com/accounts/settings).

### Run with defaults

```bash
./run_browserstack.sh
```

This builds the APK, uploads everything, and runs the tests on a **Google Pixel 7 (Android 13)**.

### Optional environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BS_DEVICE` | `Google Pixel 7-13.0` | Target device on BrowserStack |
| `BS_PROJECT` | `BrowserMaestroTesting` | Project name shown on the dashboard |
| `SKIP_BUILD` | `false` | Set to `true` to skip `./gradlew assembleDebug` and reuse an existing APK |
| `VERBOSE` | `false` | Set to `true` to print raw API responses |

### Examples

```bash
# Skip rebuild and run on a different device
SKIP_BUILD=true \
BS_DEVICE="Samsung Galaxy S23-13.0" \
./run_browserstack.sh

# Full run with verbose output
BROWSERSTACK_USERNAME=your_user \
BROWSERSTACK_ACCESS_KEY=your_key \
VERBOSE=true \
./run_browserstack.sh
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All tests passed |
| `1` | Tests failed, errored, or timed out |

On failure the raw JSON response from BrowserStack is printed to stdout for debugging.

---

## Project Structure

```
.
├── app/
│   └── src/main/
│       ├── java/com/example/browsermaestrotesting/
│       │   └── MainActivity.kt       # Single-screen Compose app
│       └── AndroidManifest.xml
├── .maestro/
│   └── 01_open_and_interact.yaml     # Maestro test flow
├── run_browserstack.sh               # BrowserStack runner script
├── build.gradle.kts
└── settings.gradle.kts
```
