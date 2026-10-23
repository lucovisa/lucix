#!/usr/bin/env bash
set -uo pipefail

#параметры
ISO="${1:?укажи путь к iso}"
OUT="${2:-out/test}"
MAXWAIT="${MAXWAIT:-900}"
MEM="${MEM:-4096}"
SOCK=/tmp/lucix-qemu.sock
TMP="$(mktemp -d)"
QPID=""
mkdir -p "$OUT"

log() { printf '\n==> %s\n' "$*"; }

#скриншот экрана
shot() {
  printf 'screendump %s -f png\n' "$1" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true
  sleep 1
}

#серия скриншотов по секундам
series() {
  local prefix="$1" prev=0 t
  shift
  for t in "$@"; do
    sleep $(( t - prev ))
    prev=$t
    shot "$OUT/$prefix-$(printf '%02d' "$t")s.png"
  done
}

#запуск qemu
start_qemu() {
  rm -f "$SOCK"
  qemu-system-x86_64 -machine q35,accel=kvm:tcg -cpu max -smp 2 -m "$MEM" \
    -display none -vga std -monitor "unix:$SOCK,server,nowait" "$@" &
  QPID=$!
  for _ in $(seq 1 20); do
    [[ -S "$SOCK" ]] && break
    sleep 0.5
  done
}

#остановка qemu
stop_qemu() {
  printf 'quit\n' | socat -t1 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true
  sleep 1
  [[ -n "$QPID" ]] && kill "$QPID" 2>/dev/null || true
  wait "$QPID" 2>/dev/null || true
  QPID=""
}
trap '[[ -n "$QPID" ]] && kill "$QPID" 2>/dev/null; true' EXIT

#загрузчик bios
log "загрузчик bios"
start_qemu -cdrom "$ISO" -boot d
series grub-bios 2 4 6 9
stop_qemu

#загрузчик uefi
OVMF=""
for f in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd; do
  [[ -f "$f" ]] && OVMF="$f" && break
done
if [[ -n "$OVMF" ]]; then
  log "загрузчик uefi"
  start_qemu -bios "$OVMF" -cdrom "$ISO" -boot d
  series grub-uefi 6 9 12 16 22
  stop_qemu
else
  echo "ovmf не найден uefi пропущен"
fi

#полная загрузка
log "полная загрузка"
xorriso -osirrox on -indev "$ISO" \
  -extract /casper/vmlinuz "$TMP/vmlinuz" \
  -extract /casper/initrd "$TMP/initrd"
start_qemu -cdrom "$ISO" -kernel "$TMP/vmlinuz" -initrd "$TMP/initrd" \
  -append "boot=casper console=ttyS0,115200 console=tty0 ---" \
  -serial "file:$OUT/serial.log"

START=$SECONDS
STATE="timeout"
while (( SECONDS - START < MAXWAIT )); do
  sleep 5
  if grep -qE 'Kernel panic|emergency mode|Gave up waiting for root|\(initramfs\)' "$OUT/serial.log" 2>/dev/null; then
    STATE="fatal"
    break
  fi
  #логин появился значит система поднялась
  if grep -q 'login:' "$OUT/serial.log" 2>/dev/null; then
    STATE="ok"
    break
  fi
  if ! kill -0 "$QPID" 2>/dev/null; then
    STATE="qemu-died"
    break
  fi
done
log "загрузка за $(( SECONDS - START )) сек состояние $STATE"

#рабочий стол
if [[ "$STATE" == "ok" ]]; then
  sleep 45
  shot "$OUT/desktop-1.png"
  sleep 30
  shot "$OUT/desktop-2.png"
  SIZE=$(stat -c %s "$OUT/desktop-2.png" 2>/dev/null || echo 0)
  if (( SIZE < 20000 )); then
    STATE="no-desktop"
  fi
else
  shot "$OUT/final.png"
fi
stop_qemu

#итог
log "итог $STATE"
{
  echo "### тест загрузки qemu"
  echo "результат **$STATE**"
  echo
  echo "строки с ошибками из serial.log"
  echo '```'
  grep -E 'FAILED|Failed to start|Kernel panic|emergency mode' "$OUT/serial.log" 2>/dev/null | head -30
  echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

[[ "$STATE" == "ok" ]]