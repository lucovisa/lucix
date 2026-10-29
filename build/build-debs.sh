#!/usr/bin/env bash
set -euo pipefail

#пути и версия
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_VERSION="${LUCIX_VERSION:?нужна переменная LUCIX_VERSION}"
DEB_VERSION="${RAW_VERSION//-/\~}"
OUT="$ROOT_DIR/out/debs"

rm -rf "$OUT"
mkdir -p "$OUT"

THEME_DIR="$ROOT_DIR/build/third-party/minegrub"

for pkg in lucix-base lucix-updater lucix-grub-theme; do
  if [[ "$pkg" == "lucix-grub-theme" && ! -d "$THEME_DIR/minegrub-world-selection" ]]; then
    echo "ОШИБКА: тема загрузчика не скачалась, $pkg собрать нельзя (повтори запуск сборки)"
    exit 1
  fi
  tmp="$(mktemp -d)"
  cp -a "$ROOT_DIR/packaging/$pkg/." "$tmp/"
  find "$tmp" -name '__pycache__' -prune -exec rm -rf {} +
  #тема Plymouth: единый источник overlay, старую вложенную папку themes убираем
  if [[ "$pkg" == "lucix-base" ]]; then
    mkdir -p "$tmp/usr/share/plymouth/themes/lucix"
    rm -rf "$tmp/usr/share/plymouth/themes/lucix/themes"
    cp -a "$ROOT_DIR/overlay/usr/share/plymouth/themes/lucix/." "$tmp/usr/share/plymouth/themes/lucix/"
    [[ -f "$tmp/usr/share/plymouth/themes/lucix/f71.png" ]] || { echo "нет кадров заставки в overlay"; exit 1; }
    grep -q 'frame\[' "$tmp/usr/share/plymouth/themes/lucix/lucix.script" || { echo "в overlay старый lucix.script"; exit 1; }
    #скрипт порядка загрузки UEFI
    mkdir -p "$tmp/usr/sbin"
    cp "$ROOT_DIR/overlay/usr/sbin/lucix-boot-first" "$tmp/usr/sbin/lucix-boot-first"
    chmod 0755 "$tmp/usr/sbin/lucix-boot-first"
    #оформление: обои, тема Cinnamon по умолчанию, экран входа
    mkdir -p "$tmp/usr/share/backgrounds/lucix" "$tmp/usr/share/glib-2.0/schemas" "$tmp/etc/lightdm/lightdm-gtk-greeter.conf.d"
    cp "$ROOT_DIR/overlay/usr/share/backgrounds/lucix/lucix.jpg" "$tmp/usr/share/backgrounds/lucix/lucix.jpg"
    cp "$ROOT_DIR/overlay/usr/share/glib-2.0/schemas/90_lucix.gschema.override" "$tmp/usr/share/glib-2.0/schemas/90_lucix.gschema.override"
    cat > "$tmp/etc/lightdm/lightdm-gtk-greeter.conf.d/50-lucix.conf" <<'GREETER'
[greeter]
background=/usr/share/backgrounds/lucix/lucix.jpg
user-background=false
theme-name=Yaru-blue-dark
icon-theme-name=Yaru-blue-dark
font-name=Ubuntu 11
GREETER

    #рабочий стол: скрипт настроек (курсор, скриншоты, панель по центру, доступ Flatpak), автозапуск и тема панели
    mkdir -p "$tmp/usr/share/lucix" "$tmp/etc/xdg/autostart" "$tmp/usr/share/themes/Lucix/cinnamon"
    #каталог экспорта Flatpak должен существовать к моменту входа, иначе значки новых приложений видны только после перезахода
    mkdir -p "$tmp/var/lib/flatpak/exports/share"
    cat > "$tmp/usr/share/lucix/apply-defaults.py" <<'APPLYPY'
#!/usr/bin/env python3
"""Lucix: применяет настройки рабочего стола. У каждого шага своя версия: шаг выполняется один раз,
и повторно только если его версию подняли (так обновление не перетирает то, что ты поменял руками).
Скриншоты как в Windows, панель по центру, доступ Flatpak к папкам, проводник и видео."""
import ast
import json
import os
import shutil
import subprocess
import time

HOME = os.path.expanduser("~")
MARK = os.path.join(HOME, ".config", "lucix", "defaults-applied")
LOG = os.path.join(HOME, ".cache", "lucix-defaults.log")


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%F %T"), msg))
    except OSError:
        pass


def q(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def gs(*args):
    p = subprocess.run(["gsettings"] + list(args), capture_output=True, text=True)
    if p.returncode != 0:
        log("gsettings %s -> %s" % (" ".join(args), p.stderr.strip()))
    return p.returncode, p.stdout.strip()


def gs_list(schema, key):
    rc, out = gs("get", schema, key)
    if rc != 0:
        return None
    if out.startswith("@as"):
        out = out[3:].strip()
    try:
        return list(ast.literal_eval(out))
    except (ValueError, SyntaxError):
        return None


def flatpak():
    if not shutil.which("flatpak"):
        log("flatpak не найден")
        return
    folders = ("xdg-desktop", "xdg-documents", "xdg-download", "xdg-music",
               "xdg-pictures", "xdg-videos", "/media", "/run/media", "/mnt")
    cmd = ["flatpak", "override", "--user"] + ["--filesystem=%s" % f for f in folders]
    p = subprocess.run(cmd, capture_output=True, text=True)
    log("flatpak override rc=%s %s" % (p.returncode, p.stderr.strip()))
    #отдельным вызовом: Flatpak-приложения должны видеть установленные пользователем курсоры
    cmd = ["flatpak", "override", "--user", "--filesystem=xdg-data/icons:ro", "--filesystem=~/.icons:ro"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    log("flatpak override (курсоры) rc=%s %s" % (p.returncode, p.stderr.strip()))
    #без этого каталога значки пользовательских Flatpak-приложений видны только после перезахода
    os.makedirs(os.path.join(HOME, ".local", "share", "flatpak", "exports", "share"), exist_ok=True)


def ini_set(path, section, values):
    """меняет только нужные ключи в ini, остальное (в т.ч. кнопки Flameshot) не трогает"""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    head = "[%s]" % section
    start = next((i for i, l in enumerate(lines) if l.strip() == head), None)
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(head)
        lines += ["%s=%s" % kv for kv in values.items()]
    else:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
        for k, v in values.items():
            for i in range(start + 1, end):
                if lines[i].split("=", 1)[0].strip() == k:
                    lines[i] = "%s=%s" % (k, v)
                    break
            else:
                lines.insert(start + 1, "%s=%s" % (k, v))
                end += 1
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def flameshot_config():
    ini_set(os.path.join(HOME, ".config", "flameshot", "flameshot.ini"), "General", {
        "showHelp": "false",
        "showStartupLaunchMessage": "false",
        "showDesktopNotification": "false",
        "disabledTrayIcon": "true",
    })


def region_command():
    """как в Windows: выделил область и она сразу в буфере (если эта версия Flameshot умеет)"""
    try:
        p = subprocess.run(["flameshot", "gui", "--help"], capture_output=True, text=True, timeout=10)
        text = p.stdout + p.stderr
    except Exception:
        text = ""
    if "accept-on-select" in text:
        return "flameshot gui --accept-on-select -c"
    log("эта версия Flameshot без --accept-on-select, область копируется по Enter")
    return "flameshot gui -c"


KB = "org.cinnamon.desktop.keybindings"
KB_ITEM = KB + ".custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/%s/"


def screenshots():
    if not shutil.which("flameshot"):
        log("flameshot не установлен, скриншоты настрою позже")
        return False
    items = (
        ("lucix-shot", "Скриншот области", region_command(), ["<Shift><Super>s", "Print"]),
        ("lucix-shot-full", "Скриншот всего экрана", "flameshot full -c", ["<Control>Print"]),
    )
    flameshot_config()
    for key in ("screenshot", "screenshot-clip"):
        gs("set", KB + ".media-keys", key, "[]")
    lst = gs_list(KB, "custom-list") or []
    lst = [x for x in lst if x != "__dummy__"]
    for ident, name, cmd, binding in items:
        schema = KB_ITEM % ident
        gs("set", schema, "name", q(name))
        gs("set", schema, "command", q(cmd))
        gs("set", schema, "binding", str(binding))
        if ident not in lst:
            lst.append(ident)
    gs("set", KB, "custom-list", str(lst))


CENTER = ["menu@cinnamon.org", "panel-launchers@cinnamon.org", "grouped-window-list@cinnamon.org"]


def panel():
    lst = gs_list("org.cinnamon", "enabled-applets")
    if not lst:
        log("список апплетов не прочитан")
        return
    rows = []
    for e in lst:
        p = e.split(":")
        if len(p) < 5:
            log("странная запись апплета %s, панель не трогаю" % e)
            return
        rows.append({"panel": p[0], "zone": p[1], "order": int(p[2]) if p[2].isdigit() else 0,
                     "uuid": p[3], "inst": ":".join(p[4:])})
    target = None
    for uuid in ("grouped-window-list@cinnamon.org", "menu@cinnamon.org", "panel-launchers@cinnamon.org"):
        for r in rows:
            if r["uuid"] == uuid:
                target = r["panel"]
                break
        if target:
            break
    if not target:
        log("на панели нет меню и списка окон, не трогаю")
        return
    for r in rows:
        if r["panel"] == target and r["uuid"] in CENTER:
            r["zone"] = "center"

    def sort_key(r):
        if r["panel"] == target and r["zone"] == "center" and r["uuid"] in CENTER:
            return (CENTER.index(r["uuid"]), r["order"])
        return (0, r["order"])

    out, groups = [], {}
    for r in rows:
        groups.setdefault((r["panel"], r["zone"]), []).append(r)
    for (pn, zone), items in groups.items():
        for i, r in enumerate(sorted(items, key=sort_key)):
            out.append("%s:%s:%d:%s:%s" % (pn, zone, i, r["uuid"], r["inst"]))
    gs("set", "org.cinnamon", "enabled-applets", str(out))


def theme():
    if os.path.isfile("/usr/share/themes/Lucix/cinnamon/cinnamon.css"):
        gs("set", "org.cinnamon.theme", "name", q("Lucix"))


def nemo():
    """проводник ближе к Windows: подробный список, дерево папок слева, полный путь, сначала папки"""
    values = (
        ("org.nemo.preferences", "default-folder-viewer", "'list-view'"),
        ("org.nemo.preferences", "ignore-view-metadata", "true"),
        ("org.nemo.preferences", "sort-directories-first", "true"),
        ("org.nemo.preferences", "show-full-path-titles", "true"),
        ("org.nemo.preferences", "date-format", "'iso'"),
        ("org.nemo.window-state", "start-with-sidebar", "true"),
        ("org.nemo.window-state", "side-pane-view", "'tree'"),
        ("org.nemo.window-state", "start-with-toolbar", "true"),
        ("org.nemo.window-state", "start-with-status-bar", "true"),
        ("org.nemo.list-view", "default-visible-columns", "['name', 'date_modified', 'type', 'size']"),
    )
    for schema, key, val in values:
        gs("set", schema, key, val)


def templates():
    """правый клик, Создать документ, Текстовый документ (как «Создать» в Windows)"""
    p = subprocess.run(["xdg-user-dir", "TEMPLATES"], capture_output=True, text=True)
    d = p.stdout.strip()
    if not d or d == HOME:
        d = os.path.join(HOME, "Templates")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "Текстовый документ.txt")
    if not os.path.exists(path):
        open(path, "w").close()


VIDEO_MIMES = ("video/mp4", "video/x-matroska", "video/webm", "video/x-msvideo", "video/quicktime",
               "video/mpeg", "video/x-flv", "video/ogg", "video/3gpp")


def videos():
    if not os.path.isfile("/usr/share/applications/vlc.desktop"):
        log("VLC ещё не установлен, видео по умолчанию настрою позже")
        return False
    p = subprocess.run(["xdg-mime", "default", "vlc.desktop"] + list(VIDEO_MIMES), capture_output=True, text=True)
    log("xdg-mime rc=%s %s" % (p.returncode, p.stderr.strip()))


STEPS = (
    ("flatpak", 2, flatpak),
    ("screenshots", 1, screenshots),
    ("panel", 1, panel),
    ("theme", 1, theme),
    ("nemo", 1, nemo),
    ("templates", 1, templates),
    ("videos", 1, videos),
)


def load_marks():
    try:
        with open(MARK, encoding="utf-8") as f:
            raw = f.read().strip()
    except OSError:
        return {}
    if raw.startswith("{"):
        try:
            return dict(json.loads(raw))
        except ValueError:
            return {}
    if raw.isdigit():  # старый формат: одна цифра на всё
        n = int(raw)
        marks = {}
        if n >= 2:
            marks.update(flatpak=1, panel=1, theme=1)
        marks["screenshots"] = 1 if n >= 3 else 0
        return marks
    return {}


def main():
    marks = load_marks()
    changed = False
    for name, version, fn in STEPS:
        if marks.get(name, 0) >= version:
            continue
        log("шаг %s версии %s" % (name, version))
        try:
            if fn() is False:
                continue  # сейчас нельзя, повторим при следующем входе
        except Exception as e:
            log("ошибка в %s: %r" % (name, e))
            continue
        marks[name] = version
        changed = True
    if not changed:
        return
    os.makedirs(os.path.dirname(MARK), exist_ok=True)
    with open(MARK, "w", encoding="utf-8") as f:
        json.dump(marks, f)
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "Lucix", "Настройки рабочего стола обновлены"])


if __name__ == "__main__":
    main()
APPLYPY
    mkdir -p "$tmp/usr/share/nemo/actions"
    cat > "$tmp/usr/share/lucix/install-cursor.py" <<'CURSORPY'
#!/usr/bin/env python3
"""Lucix: установка курсора мыши из архива (zip, tar.gz, tar.xz, tar.bz2).
Понимает курсоры для Linux (папка cursors) и наборы Windows (.cur, .ani, Install.inf): их конвертирует.
Запускается из файлового менеджера: правый клик по архиву, «Установить как курсор мыши»."""
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

TITLE = "Курсор мыши"
SIZES = (24, 32, 48, 64)

#роль в Windows -> (имя курсора в Linux, дополнительные имена)
ROLES = {
    "arrow": ("left_ptr", ["default", "arrow", "top_left_arrow", "left_arrow"]),
    "help": ("help", ["question_arrow", "whats_this", "left_ptr_help"]),
    "appstarting": ("left_ptr_watch", ["progress", "half-busy"]),
    "wait": ("watch", ["wait"]),
    "crosshair": ("crosshair", ["cross", "tcross", "cross_reverse", "diamond_cross"]),
    "ibeam": ("text", ["xterm", "ibeam"]),
    "nwpen": ("pencil", []),
    "no": ("not-allowed", ["crossed_circle", "forbidden", "no-drop", "dnd-no-drop", "circle"]),
    "sizens": ("ns-resize", ["sb_v_double_arrow", "size_ver", "v_double_arrow", "double_arrow", "row-resize",
                             "split_v", "n-resize", "s-resize", "top_side", "bottom_side"]),
    "sizewe": ("ew-resize", ["sb_h_double_arrow", "size_hor", "h_double_arrow", "col-resize", "split_h",
                             "e-resize", "w-resize", "left_side", "right_side"]),
    "sizenwse": ("nwse-resize", ["size_fdiag", "bd_double_arrow", "nw-resize", "se-resize",
                                 "top_left_corner", "bottom_right_corner"]),
    "sizenesw": ("nesw-resize", ["size_bdiag", "fd_double_arrow", "ne-resize", "sw-resize",
                                 "top_right_corner", "bottom_left_corner"]),
    "sizeall": ("move", ["fleur", "all-scroll", "size_all", "grabbing", "closedhand", "dnd-move"]),
    "uparrow": ("up_arrow", ["center_ptr"]),
    "hand": ("pointer", ["hand2", "hand1", "pointing_hand", "openhand", "grab"]),
    "person": ("person", []),
    "pin": ("pin", []),
}
#если Install.inf нет: роль по имени файла
STEMS = {
    "pointer": "arrow", "arrow": "arrow", "normal": "arrow", "default": "arrow",
    "help": "help", "work": "appstarting", "working": "appstarting", "progress": "appstarting",
    "busy": "wait", "wait": "wait", "cross": "crosshair", "crosshair": "crosshair", "precision": "crosshair",
    "text": "ibeam", "ibeam": "ibeam", "handwriting": "nwpen", "pen": "nwpen",
    "unavailiable": "no", "unavailable": "no", "no": "no",
    "vert": "sizens", "vertical": "sizens", "horz": "sizewe", "horizontal": "sizewe",
    "dgn1": "sizenwse", "dgn2": "sizenesw", "move": "sizeall", "alternate": "uparrow",
    "link": "hand", "hand": "hand", "person": "person", "pin": "pin",
}


def say(text):
    print(text)
    if shutil.which("zenity"):
        subprocess.run(["zenity", "--info", "--no-markup", "--width=420", "--title=" + TITLE, "--text=" + text])
    elif shutil.which("notify-send"):
        subprocess.run(["notify-send", TITLE, text])


def ask_apply(name):
    if not shutil.which("zenity"):
        return True
    r = subprocess.run(["zenity", "--question", "--no-markup", "--width=420", "--title=" + TITLE,
                        "--text=Курсор «%s» установлен. Применить сейчас?" % name,
                        "--ok-label=Применить", "--cancel-label=Не сейчас"])
    return r.returncode == 0


def apply_theme(name):
    for schema in ("org.cinnamon.desktop.interface", "org.gnome.desktop.interface"):
        subprocess.run(["gsettings", "set", schema, "cursor-theme", "'%s'" % name.replace("'", "")])


def find_linux_themes(root):
    found = set()
    for d, dirs, files in os.walk(root):
        if os.path.basename(d) == "cursors" and (files or dirs):
            found.add(os.path.dirname(d))
    return sorted(found)


# ---------- конвертер курсоров Windows ----------

def read_cur(data):
    """возвращает (картинка RGBA, (x, y) точка клика) для самого крупного изображения в .cur"""
    from PIL import IcoImagePlugin
    if len(data) < 6 or data[2:4] not in (b"\x01\x00", b"\x02\x00"):
        raise ValueError("это не .cur")
    fixed = data[:2] + b"\x01\x00" + data[4:]  # Pillow читает только ICO, формат у .cur тот же
    ico = IcoImagePlugin.IcoFile(io.BytesIO(fixed))
    size = max(ico.sizes(), key=lambda s: s[0] * s[1])
    hot = (0, 0)
    if data[2:4] == b"\x02\x00":
        # точка клика лежит в заголовке файла (у иконок на её месте другие поля), читаем сами
        for i in range(struct.unpack_from("<H", data, 4)[0]):
            w, h, _, _, hx, hy, _, _ = struct.unpack_from("<BBBBHHII", data, 6 + 16 * i)
            if (w or 256, h or 256) == tuple(size):
                hot = (hx, hy)
                break
    return ico.getimage(size).convert("RGBA"), hot


def read_ani(data):
    """возвращает список кадров (картинка, точка клика, задержка в мс)"""
    if data[:4] != b"RIFF" or data[8:12] != b"ACON":
        raise ValueError("это не .ani")
    pos, end = 12, len(data)
    icons, rates, seq, disp = [], None, None, 6
    while pos + 8 <= end:
        cid, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"anih" and size >= 36:
            disp = struct.unpack_from("<9I", body, 0)[7]
        elif cid == b"rate":
            rates = list(struct.unpack("<%dI" % (size // 4), body[:size // 4 * 4]))
        elif cid == b"seq ":
            seq = list(struct.unpack("<%dI" % (size // 4), body[:size // 4 * 4]))
        elif cid == b"LIST" and body[:4] == b"fram":
            p = 4
            while p + 8 <= len(body):
                sid, ssz = body[p:p + 4], struct.unpack_from("<I", body, p + 4)[0]
                if sid == b"icon":
                    icons.append(body[p + 8:p + 8 + ssz])
                p += 8 + ssz + (ssz & 1)
        pos += 8 + size + (size & 1)
    if not icons:
        raise ValueError("в .ani нет кадров")
    cache = {}
    steps = seq if seq else list(range(len(icons)))
    frames = []
    for n, i in enumerate(steps):
        if i >= len(icons):
            continue
        if i not in cache:
            cache[i] = read_cur(icons[i])
        jif = rates[n] if rates and n < len(rates) else disp
        frames.append((cache[i][0], cache[i][1], max(1, round(jif * 1000 / 60))))
    return frames


def build_xcursor(frames):
    """frames: [(картинка RGBA, (x, y), задержка мс)] -> байты файла Xcursor с несколькими размерами"""
    from PIL import Image
    native = frames[0][0].height
    chunks = []
    for s in SIZES:
        for im, (hx, hy), delay in frames:
            if s == native:
                r, rx, ry = im, hx, hy
            else:
                k = s / native
                r = im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS)
                rx, ry = round(hx * k), round(hy * k)
            rx, ry = min(max(rx, 0), r.width - 1), min(max(ry, 0), r.height - 1)
            pix = bytearray()
            for red, green, blue, a in struct.iter_unpack("<4B", r.tobytes()):
                pix += struct.pack("<I", (a << 24) | ((red * a // 255) << 16) | ((green * a // 255) << 8) | (blue * a // 255))
            head = struct.pack("<9I", 36, 0xfffd0002, s, 1, r.width, r.height, rx, ry, delay)
            chunks.append((s, head + bytes(pix)))
    toc_end = 16 + 12 * len(chunks)
    out = bytearray(b"Xcur" + struct.pack("<3I", 16, 0x10000, len(chunks)))
    pos = toc_end
    for s, c in chunks:
        out += struct.pack("<3I", 0xfffd0002, s, pos)
        pos += len(c)
    for _, c in chunks:
        out += c
    return bytes(out)


def parse_inf(path):
    """роли Windows -> имена файлов по Install.inf (если он есть)"""
    try:
        raw = open(path, "rb").read()
    except OSError:
        return {}
    text = None
    for enc in ("utf-16", "utf-8-sig", "cp1251", "latin-1"):
        try:
            text = raw.decode(enc)
            if "[" in text:
                break
        except UnicodeError:
            continue
    if not text:
        return {}
    strings, section = {}, ""
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            section = s.lower()
        elif section == "[strings]" and "=" in s:
            k, v = s.split("=", 1)
            strings[k.strip().lower()] = v.strip().strip('"')
    roles = {}
    rx = re.compile(r'HKCU\s*,\s*"Control Panel\\Cursors"\s*,\s*(\w+)\s*,[^,]*,\s*"[^"]*%(\w+)%"\s*$', re.I)
    for line in text.splitlines():
        m = rx.match(line.strip())
        if m and m.group(2).lower() in strings:
            roles[m.group(1).lower()] = strings[m.group(2).lower()]
    return roles


def find_windows_dir(root):
    best, best_n = None, 0
    for d, _, files in os.walk(root):
        n = sum(1 for f in files if f.lower().endswith((".cur", ".ani")))
        if n > best_n:
            best, best_n = d, n
    return best


def convert_windows(src, out_dir, name):
    files = {f.lower(): f for f in os.listdir(src)}
    roles = {}
    for role, fname in parse_inf(os.path.join(src, files["install.inf"])).items() if "install.inf" in files else []:
        if fname.lower() in files:
            roles[role] = files[fname.lower()]
    for low, real in files.items():
        stem = os.path.splitext(low)[0]
        if low.endswith((".cur", ".ani")) and stem in STEMS and STEMS[stem] not in roles:
            roles[STEMS[stem]] = real
    cdir = os.path.join(out_dir, "cursors")
    os.makedirs(cdir, exist_ok=True)
    done = 0
    for role, fname in roles.items():
        if role not in ROLES:
            continue
        data = open(os.path.join(src, fname), "rb").read()
        try:
            frames = read_ani(data) if fname.lower().endswith(".ani") else [(*read_cur(data), 50)]
        except Exception as e:
            print("пропускаю %s: %s" % (fname, e))
            continue
        main, aliases = ROLES[role]
        with open(os.path.join(cdir, main), "wb") as f:
            f.write(build_xcursor(frames))
        for a in aliases:
            link = os.path.join(cdir, a)
            if not os.path.lexists(link):
                os.symlink(main, link)
        done += 1
    if not done:
        raise ValueError("не удалось прочитать ни один курсор")
    with open(os.path.join(out_dir, "index.theme"), "w", encoding="utf-8") as f:
        f.write("[Icon Theme]\nName=%s\nInherits=Adwaita\n" % name)
    return done


TR = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
              ["a", "b", "v", "g", "d", "e", "yo", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t",
               "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]))


def safe_name(s):
    s = "".join(TR.get(c, c) for c in s.lower())
    s = re.sub(r"[^a-z0-9._-]+", "-", s).strip("-._")
    return s or "cursor"


def main():
    if len(sys.argv) < 2:
        say("Выбери архив с курсором (zip, tar.gz, tar.xz).")
        return 1
    archive = sys.argv[1]
    stem = os.path.basename(archive)
    for ext in (".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".txz", ".tbz2", ".zip", ".tar", ".gz", ".xz", ".bz2"):
        if stem.lower().endswith(ext):
            stem = stem[:-len(ext)]
            break
    dest_root = os.path.join(os.path.expanduser("~"), ".local", "share", "icons")
    with tempfile.TemporaryDirectory() as tmp:
        try:
            try:
                shutil.unpack_archive(archive, tmp, filter="data")
            except TypeError:
                shutil.unpack_archive(archive, tmp)
        except Exception as e:
            say("Не удалось распаковать архив:\n%s" % e)
            return 1
        names = []
        os.makedirs(dest_root, exist_ok=True)
        for t in find_linux_themes(tmp):
            name = stem if os.path.abspath(t) == os.path.abspath(tmp) else os.path.basename(t)
            name = name.replace("/", "_").strip() or stem
            target = os.path.join(dest_root, name)
            if os.path.exists(target):
                shutil.rmtree(target, ignore_errors=True)
            shutil.copytree(t, target, symlinks=True)
            idx = os.path.join(target, "index.theme")
            if not os.path.isfile(idx):
                with open(idx, "w", encoding="utf-8") as f:
                    f.write("[Icon Theme]\nName=%s\n" % name)
            names.append(name)
        if not names:
            wdir = find_windows_dir(tmp)
            if not wdir:
                say("В архиве нет курсоров: ни для Linux (папка cursors), ни для Windows (.cur, .ani).")
                return 1
            try:
                import PIL  # noqa: F401
            except ImportError:
                say("Для курсоров Windows нужен пакет python3-pil. Он ставится при обновлении Lucix.")
                return 1
            name = "Win-" + safe_name(stem)
            target = os.path.join(dest_root, name)
            build = os.path.join(tmp, "_converted")
            try:
                count = convert_windows(wdir, build, name)
            except Exception as e:
                say("Не удалось конвертировать курсоры Windows:\n%s" % e)
                return 1
            if os.path.exists(target):
                shutil.rmtree(target, ignore_errors=True)
            shutil.copytree(build, target, symlinks=True)
            print("конвертировано курсоров: %d" % count)
            names.append(name)
    if len(names) == 1:
        if ask_apply(names[0]):
            apply_theme(names[0])
    else:
        say("Установлено курсоров: %d (%s).\nВыбрать: Параметры системы → Темы → Указатель мыши." % (len(names), ", ".join(names)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
CURSORPY
    cat > "$tmp/usr/share/nemo/actions/lucix-install-cursor.nemo_action" <<'NEMOACTION'
[Nemo Action]
Name=Установить как курсор мыши
Comment=Установить набор курсоров из архива
Exec=python3 /usr/share/lucix/install-cursor.py %F
Icon-Name=input-mouse
Selection=s
Extensions=zip;tar;gz;tgz;xz;txz;bz2;tbz2;
Quote=double
NEMOACTION
    cat > "$tmp/etc/xdg/autostart/lucix-apply-defaults.desktop" <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=Lucix desktop defaults
Exec=python3 /usr/share/lucix/apply-defaults.py
X-GNOME-Autostart-Delay=5
OnlyShowIn=X-Cinnamon;
NoDisplay=true
AUTOSTART
    cat > "$tmp/usr/share/themes/Lucix/cinnamon/cinnamon.css" <<'THEMECSS'
/* Lucix: стандартная тема Cinnamon, но панель прозрачная, а центр панели тёмная плашка */
@import url("/usr/share/cinnamon/theme/cinnamon.css");

#panel, .panel-top, .panel-bottom, .panel-left, .panel-right {
  background-color: transparent;
  background-gradient-start: transparent;
  background-gradient-end: transparent;
  border-width: 0px;
  box-shadow: none;
}

#panelCenter {
  background-color: rgba(20, 22, 28, 0.80);
  border-radius: 16px;
  border: 1px solid rgba(255, 255, 255, 0.10);
  padding: 0px 10px;
}
THEMECSS
    #рекомендованные пакеты: flameshot (скриншоты), python3-pil (конвертер курсоров), vlc и кодеки (видео mp4), flatpak (приложения из магазина) (если пакета нет, обновление не падает)
    sed -i 's/^Recommends: .*/&, flameshot, python3-pil, vlc, ffmpegthumbnailer, gstreamer1.0-libav, flatpak/' "$tmp/DEBIAN/control"
    grep -q '^Recommends: .*flameshot' "$tmp/DEBIAN/control" || { echo "не удалось дописать Recommends"; exit 1; }
  fi
  find "$tmp" -name '*.pyc' -delete
  sed -i "s/@VERSION@/$DEB_VERSION/" "$tmp/DEBIAN/control"

  #файлы темы и лицензия автора
  if [[ "$pkg" == "lucix-grub-theme" ]]; then
    mkdir -p "$tmp/boot/grub/themes" "$tmp/usr/share/doc/lucix-grub-theme"
    cp -a "$THEME_DIR/minegrub-world-selection" "$tmp/boot/grub/themes/minegrub-world-selection"
    cp "$THEME_DIR/LICENSE" "$tmp/usr/share/doc/lucix-grub-theme/copyright"
    echo "Source: https://github.com/Lxtharia/minegrub-world-sel-theme (MIT)" > "$tmp/usr/share/doc/lucix-grub-theme/SOURCE"
    #настройки темы последним drop-in, чтобы их не перебили другие файлы grub.d
    mkdir -p "$tmp/etc/default/grub.d"
    cat > "$tmp/etc/default/grub.d/99-lucix-theme.cfg" <<'GRUBTHEME'
# Lucix: тема GRUB и показ Windows в меню (читается последней, поэтому другие настройки её не перебьют)
GRUB_TERMINAL_OUTPUT=gfxterm
GRUB_GFXMODE=auto
GRUB_THEME=/boot/grub/themes/minegrub-world-selection/theme.txt
GRUB_DISABLE_OS_PROBER=false
GRUBTHEME
  fi

  #права на скрипты
  find "$tmp/DEBIAN" -type f \( -name postinst -o -name postrm -o -name preinst -o -name prerm \) -exec chmod 0755 {} +
  chmod 0755 "$tmp/DEBIAN"
  [[ -f "$tmp/usr/bin/lucix-update" ]] && chmod 0755 "$tmp/usr/bin/lucix-update"
  [[ -f "$tmp/usr/bin/lucix-diag" ]] && chmod 0755 "$tmp/usr/bin/lucix-diag"
  [[ -d "$tmp/etc/skel" ]] && find "$tmp/etc/skel" -type f -name '*.desktop' -exec chmod 0755 {} +
  [[ -f "$tmp/usr/lib/lucix/lucix-helper" ]] && chmod 0755 "$tmp/usr/lib/lucix/lucix-helper"

  dpkg-deb --root-owner-group --build "$tmp" "$OUT/${pkg}_${RAW_VERSION}_all.deb"
  rm -rf "$tmp"
done

( cd "$OUT" && sha256sum ./*.deb | sed 's| \./| |' > SHA256SUMS )
ls -lh "$OUT"
