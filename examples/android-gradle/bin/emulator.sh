#!/usr/bin/env bash
# An Android emulator inside the sandbox, started on demand - for running the Baseline Profile journey
# (`./gradlew :app:android:generateBaselineProfile`) or any instrumented test without a phone.
#
#   emulator.sh start     # boot headless (installing anything missing), wait until it's ready
#   emulator.sh status
#   emulator.sh screenshot out.png   # what's on the emulator's screen right now
#   emulator.sh stop
#
# How it works, what it's for and how to debug it: .claude/EMULATOR.md. Run it INSIDE the sandbox.
# The emulator, the system image and the virtual device are baked into the image (ai-sandbox-configuration/Dockerfile), so
# `start` just boots it (~20 s). If one is missing - a container from an image built before they were
# added, or another EMULATOR_API - `start` installs it first (~1.5 GB, and only for that container).
#
# Two things here are not obvious, and both are why this script exists rather than a one-line command:
#
# - /dev/kvm is root:<the host's kvm gid> inside the container and `dev` isn't in that group, so without
#   a fix the emulator falls back to software CPU emulation, far too slow to drive an app. The sandbox is
#   --privileged and `dev` has passwordless sudo, so the device node is opened up (this container's copy
#   only - the host's is untouched).
# - The emulator's software GLES path (gfxstream + SwiftShader) segfaults in its render thread while
#   drawing DiceFive, silently killing the emulator (exit status 139, no crash report) a few seconds
#   after the app opens - it shows up as `adb: device offline`. Its Vulkan path doesn't, so the app's UI
#   renderer is switched to Vulkan after boot (debug.hwui.renderer=skiavk, which resets on every boot, so
#   this script sets it every time). The app draws correctly under it.
# The waits are built on a predicate (is_up), only ever a condition; and adb's answers are read through command
# substitutions whose failure is an empty answer - "not up yet", or a blank in a status line.
# shellcheck disable=SC2310,SC2312
set -euo pipefail

# EMULATOR_API comes from the image (ai-sandbox-configuration/Dockerfile ENV), where it is chosen - it follows compileSdk - and
# the value here is only the fallback for a shell without it. The dependency update script keeps the two in
# step with each other and with compileSdk.
api="${EMULATOR_API:-37.0}"
avd_name="${EMULATOR_AVD_NAME:-sandbox-api${api}}"
image="system-images;android-${api};google_apis;x86_64"
memory_mb="${EMULATOR_MEMORY_MB:-4096}"
cores="${EMULATOR_CORES:-4}"
sdk="${ANDROID_HOME:?ANDROID_HOME is not set - run this inside the sandbox}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-${HOME}/.android/avd}"
log="${HOME}/.android/emulator-${avd_name}.log"

is_up() { [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; }

ensure_kvm() {
  [[ -e /dev/kvm ]] || { echo "No /dev/kvm: the sandbox host must pass it through (the sandbox runs --privileged)." >&2; exit 1; }
  if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "[emulator] opening /dev/kvm to this user (this container only)..."
    sudo chmod 666 /dev/kvm
  fi
}

# The SDK is root-owned in the image, so packages go in through sudo - and the installer, run as root,
# unpacks them without the other-users read/execute bits the emulator then needs.
ensure_packages() {
  if [[ -x "${sdk}/emulator/emulator" && -d "${sdk}/system-images/android-${api}/google_apis/x86_64" ]]; then
    return
  fi
  echo "[emulator] installing the emulator and the API ${api} system image (~1.5 GB to download)..."
  # `android sdk install` replaces the deprecated sdkmanager; it asks nothing, so no `yes |`. The
  # `|| true` stays: the directory check after the permissions fix is what decides, not the exit code.
  sudo -E env "PATH=${PATH}" "${sdk}/cmdline-tools/latest/bin/android" sdk install --sdk="${sdk}" \
    "emulator" "${image}" </dev/null >/dev/null || true
  sudo chmod -R a+rX "${sdk}/emulator" "${sdk}/system-images"
  sudo find "${sdk}/emulator" -type f -perm -u+x -exec chmod a+x {} +
  if [[ ! -x "${sdk}/emulator/emulator" || ! -d "${sdk}/system-images/android-${api}/google_apis/x86_64" ]]; then
    echo "[emulator] installing ${image} failed (is it published? see 'android sdk list')." >&2
    exit 1
  fi
}

ensure_avd() {
  if [[ -d "${ANDROID_AVD_HOME}/${avd_name}.avd" ]]; then
    return
  fi
  echo "[emulator] creating the virtual device '${avd_name}'..."
  mkdir -p "${ANDROID_AVD_HOME}"
  echo no | "${sdk}/cmdline-tools/latest/bin/avdmanager" create avd -n "${avd_name}" -k "${image}" -d pixel_6 --force >/dev/null
}

start() {
  if is_up; then
    echo "[emulator] already running: $(adb devices | awk 'NR==2 {print $1}')"
    return
  fi
  ensure_kvm
  ensure_packages
  ensure_avd

  adb kill-server >/dev/null 2>&1 || true
  mkdir -p "$(dirname "${log}")"
  echo "[emulator] booting '${avd_name}' (log: ${log})..."
  # setsid + redirected stdio: detached from this shell, so it outlives the command that started it.
  # -timezone: the guest's clock in the host's zone (TZ, which sandbox.sh passes in), not the emulator's UTC default.
  local zone=()
  [[ -n "${TZ-}" ]] && zone=(-timezone "${TZ}")
  setsid nohup "${sdk}/emulator/emulator" -avd "${avd_name}" \
    -no-window -no-audio -no-boot-anim -no-snapshot \
    -gpu swiftshader_indirect -memory "${memory_mb}" -cores "${cores}" \
    ${zone[@]+"${zone[@]}"} \
    >"${log}" 2>&1 </dev/null &
  disown

  local waited=0
  until is_up; do
    sleep 3
    waited=$((waited + 3))
    if (( waited > 300 )); then
      echo "[emulator] did not finish booting in 5 minutes; see ${log}" >&2
      exit 1
    fi
  done

  # See the header: without this the app crashes the emulator. Root is available on google_apis images.
  adb root >/dev/null 2>&1 || true
  adb wait-for-device
  adb shell setprop debug.hwui.renderer skiavk
  echo "[emulator] ready: $(adb devices | awk 'NR==2 {print $1}'), Android $(adb shell getprop ro.build.version.release | tr -d '\r')."
}

stop() {
  if adb devices 2>/dev/null | grep -q '^emulator-'; then
    adb emu kill >/dev/null 2>&1 || true
    echo "[emulator] stopped."
  else
    echo "[emulator] not running."
  fi
}

screenshot() {
  local out="${1:?usage: $0 screenshot <file.png>}"
  is_up || { echo "[emulator] not running - start it first." >&2; exit 1; }
  adb exec-out screencap -p >"${out}"
  echo "[emulator] saved ${out}"
}

status() {
  if is_up; then
    echo "running: $(adb devices | awk 'NR==2 {print $1}'), renderer $(adb shell getprop debug.hwui.renderer | tr -d '\r')"
  else
    echo "not running"
    exit 1
  fi
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  screenshot) screenshot "${2:-}" ;;
  *) echo "usage: $0 start|stop|status|screenshot <file.png>" >&2; exit 2 ;;
esac
