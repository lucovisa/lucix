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
  #необязательная установка KDE Plasma из списка приложений (с защитой экрана входа)
  if [[ "$pkg" == "lucix-updater" ]]; then
    python3 - "$tmp" <<'PYUPDATER'
import json, re, sys

root = sys.argv[1]
helper = root + "/usr/lib/lucix/lucix-helper"
apps = root + "/usr/share/lucix/apps.json"

FUNCS = '''#KDE-приложения и обновление Flatpak после установки драйвера
PLASMA_EXTRAS = ["dolphin", "konsole", "kate", "ark", "okular", "kde-spectacle", "plasma-systemmonitor",
                 "kscreen", "plasma-nm", "plasma-pa", "powerdevil", "bluedevil", "kio-extras", "ffmpegthumbs",
                 "kde-config-gtk-style", "breeze-gtk-theme", "xdg-desktop-portal-kde", "xdg-desktop-portal-gtk",
                 "keyd", "vlc"]


def flatpak_refresh():
    if shutil.which("flatpak"):
        run(["flatpak", "update", "-y", "--noninteractive"])


def post_plasma_extras():
    avail = []
    for pkg in PLASMA_EXTRAS:
        r = subprocess.run(["apt-cache", "policy", pkg], capture_output=True, text=True)
        cand = [l for l in r.stdout.splitlines() if "Candidate:" in l]
        if cand and "(none)" not in cand[0]:
            avail.append(pkg)
        else:
            say("package not available, skipped: %s" % pkg)
    if not avail:
        return True
    return run(["apt-get"] + APT_OPTS + ["install", "--no-install-recommends"] + avail) == 0


'''

h = open(helper, encoding="utf-8").read()
if "def post_plasma_extras" not in h:
    assert h.count("POST = {\n") == 1, "в хелпере не найден блок POST"
    h = h.replace("POST = {\n", FUNCS + 'POST = {\n    "plasma-extras": post_plasma_extras,\n', 1)
    #после установки драйвера NVIDIA Flatpak-приложениям (Steam и др.) нужно подходящее расширение драйвера
    m = re.search(r"def drivers_install\(snap\):\n.*?\n\n\n", h, re.S)
    assert m, "в хелпере не найден drivers_install"
    body = m.group(0)
    assert body.count('        say("DONE reboot is needed")\n') == 2
    h = h.replace(body, body.replace('        say("DONE reboot is needed")\n',
                                     '        flatpak_refresh()\n        say("DONE reboot is needed")\n'))
    open(helper, "w", encoding="utf-8").write(h)

d = json.load(open(apps, encoding="utf-8"))
if not any(a.get("id") == "kde-apps" for a in d["apps"]):
    d["apps"].append({
        "id": "kde-apps",
        "name": ["KDE apps (editor, archiver, viewers)", "Приложения KDE (редактор, архиватор, просмотр)"],
        "desc": ["Kate, Dolphin, Konsole, Ark, Okular, Spectacle and the other Plasma basics",
                 "Kate (текстовые документы), Dolphin, Konsole, Ark, Okular, Spectacle и остальная база Plasma"],
        "default": True,
        "check": {"apt": ["kate", "dolphin", "konsole", "ark"]},
        "steps": [{"method": "post", "name": "plasma-extras"}]})
json.dump(d, open(apps, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYUPDATER
    #вкладка «Система»: показываем список обновляемых пакетов, а не только их число
    python3 - "$tmp" <<'PYGUI'
import sys
p = sys.argv[1] + "/usr/bin/lucix-update"
s = open(p, encoding="utf-8").read()
if "sys_view" not in s:
    a = "        box.pack_start(self.sys_label, False, False, 0)\n"
    assert s.count(a) == 1, "в окне не найден sys_label"
    s = s.replace(a, a + '''        self.sys_view = Gtk.TextView()
        self.sys_view.set_editable(False)
        self.sys_view.set_monospace(True)
        sys_scroll = Gtk.ScrolledWindow()
        sys_scroll.set_min_content_height(220)
        sys_scroll.add(self.sys_view)
        box.pack_start(sys_scroll, True, True, 0)
''')
    b = "            GLib.idle_add(self.sys_checked, len(lines))\n"
    assert s.count(b) == 1, "в окне не найден вызов sys_checked"
    s = s.replace(b, '''            names = []
            for l in lines:
                parts = l.split(" ")
                names.append("%s  %s" % (parts[0].split("/", 1)[0], parts[1] if len(parts) > 1 else ""))
            flat = []
            if shutil.which("flatpak"):
                try:
                    fr = subprocess.run(["flatpak", "remote-ls", "--updates", "--columns=name,version"],
                                        capture_output=True, text=True, timeout=120)
                    flat = [x.strip() for x in fr.stdout.splitlines() if x.strip()]
                except Exception:
                    flat = []
            listing = ""
            if names:
                listing += "Ubuntu:\\n  " + "\\n  ".join(names) + "\\n"
            if flat:
                listing += "Flatpak:\\n  " + "\\n  ".join(flat) + "\\n"
            GLib.idle_add(self.sys_checked, len(names) + len(flat), listing or t("uptodate"))
''')
    c = '''    def sys_checked(self, count):
        self.set_busy(False)
        self.sys_label.set_text(t("sys_count") % count)
'''
    assert s.count(c) == 1, "в окне не найден sys_checked"
    s = s.replace(c, '''    def sys_checked(self, count, listing=""):
        self.set_busy(False)
        self.sys_label.set_text(t("sys_count") % count)
        self.sys_view.get_buffer().set_text(listing)
''')
    if "\nimport shutil" not in s:
        assert "\nimport subprocess" in s, "нет import subprocess"
        s = s.replace("\nimport subprocess", "\nimport shutil\nimport subprocess", 1)
    open(p, "w", encoding="utf-8").write(s)

if "что реально установлено сейчас" not in s:
    old_ri = '''def read_installed():
    try:
        with open(STATE, encoding="utf-8") as f:
            return set(json.load(f).get("installed", []))
    except Exception:
        return set()
'''
    assert s.count(old_ri) == 1, "в окне не найден read_installed"
    new_ri = '''def read_installed():
    """что реально установлено сейчас, а не что записано в файле (приложение могли удалить вручную)"""
    recorded = set()
    try:
        with open(STATE, encoding="utf-8") as f:
            recorded = set(json.load(f).get("installed", []))
    except Exception:
        pass
    flat = set()
    if shutil.which("flatpak"):
        try:
            r = subprocess.run(["flatpak", "list", "--app", "--columns=application"],
                               capture_output=True, text=True, timeout=30)
            flat = {x.strip() for x in r.stdout.splitlines() if x.strip()}
        except Exception:
            pass

    def dpkg_good(pkgs):
        try:
            r = subprocess.run(["dpkg-query", "-W", "-f=${Package} ${Status}\\n"] + list(pkgs),
                               capture_output=True, text=True, timeout=30)
        except Exception:
            return set()
        return {l.split()[0] for l in r.stdout.splitlines() if l.strip().endswith("install ok installed")}

    result = set()
    for app in load_catalog():
        checked, ok = False, True
        for st in app.get("steps", []):
            m = st.get("method")
            if m == "flatpak":
                checked, ok = True, ok and st.get("ref") in flat
            elif m == "apt":
                pk = st.get("packages", [])
                checked, ok = True, ok and all(p in dpkg_good(pk) for p in pk)
            elif m == "github_deb":
                token = st.get("repo", "").split("/")[-1].split("-")[0]
                checked, ok = True, ok and bool(token) and bool(dpkg_good([token + "*"]))
        extra = app.get("check", {}).get("apt")
        if extra:
            checked, ok = True, ok and all(p in dpkg_good(extra) for p in extra)
        if (ok if checked else app["id"] in recorded):
            result.add(app["id"])
    return result
'''
    s = s.replace(old_ri, new_ri)
    open(p, "w", encoding="utf-8").write(s)
PYGUI
  fi
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
    #оформление: обои и экран входа
    mkdir -p "$tmp/usr/share/backgrounds/lucix" "$tmp/etc/lightdm/lightdm-gtk-greeter.conf.d"
    cp "$ROOT_DIR/overlay/usr/share/backgrounds/lucix/lucix.jpg" "$tmp/usr/share/backgrounds/lucix/lucix.jpg"
    cat > "$tmp/etc/lightdm/lightdm-gtk-greeter.conf.d/50-lucix.conf" <<'GREETER'
[greeter]
background=/usr/share/backgrounds/lucix/lucix.jpg
user-background=false
theme-name=Breeze-Dark
icon-theme-name=breeze-dark
font-name=Ubuntu 11
indicators=~host;~spacer;~clock;~spacer;~layout;~session;~a11y;~power
GREETER

    #рабочий стол Plasma: скрипт настроек и автозапуск
    mkdir -p "$tmp/usr/share/lucix" "$tmp/etc/xdg/autostart"
    #каталог экспорта Flatpak должен существовать к моменту входа, иначе значки новых приложений видны только после перезахода
    mkdir -p "$tmp/var/lib/flatpak/exports/share"
    mkdir -p "$tmp/usr/share/kio/servicemenus"
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


LOG = os.path.join(os.path.expanduser("~"), ".cache", "lucix-cursor.log")


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def apply_theme(name):
    """применяет курсор; возвращает текст ошибки или пустую строку"""
    err = ""
    if shutil.which("plasma-apply-cursortheme"):
        listed = subprocess.run(["plasma-apply-cursortheme", "--list-themes"], capture_output=True, text=True).stdout
        p = subprocess.run(["plasma-apply-cursortheme", name], capture_output=True, text=True)
        log("список тем: %s" % listed.replace("\n", " ")[:300])
        log("применение %s: rc=%s out=%s err=%s" % (name, p.returncode, p.stdout.strip(), p.stderr.strip()))
        if p.returncode != 0:
            err = (p.stderr or p.stdout).strip() or "plasma-apply-cursortheme вернул ошибку"
    else:
        err = "не найдена команда plasma-apply-cursortheme"
    if shutil.which("gsettings"):  # для GTK-приложений
        subprocess.run(["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", "'%s'" % name.replace("'", "")])
    return err


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
            err = apply_theme(names[0])
            if err:
                say("Курсор установлен, но применить сразу не вышло:\n%s\n\nВыбери его вручную: Параметры системы, Внешний вид, Курсоры. Подробности в %s" % (err, LOG))
    else:
        say("Установлено курсоров: %d (%s).\nВыбрать: Параметры системы → Темы → Указатель мыши." % (len(names), ", ".join(names)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
CURSORPY
    cat > "$tmp/usr/share/kio/servicemenus/lucix-install-cursor.desktop" <<'DOLPHINCURSOR'
[Desktop Entry]
Type=Service
MimeType=application/zip;application/x-compressed-tar;application/x-xz-compressed-tar;application/x-bzip-compressed-tar;application/gzip;application/x-tar;
Actions=lucixCursor
X-KDE-Priority=TopLevel

[Desktop Action lucixCursor]
Name=Установить как курсор мыши
Icon=input-mouse
Exec=python3 /usr/share/lucix/install-cursor.py %f
DOLPHINCURSOR
    cat > "$tmp/usr/share/kio/servicemenus/lucix-open-admin.desktop" <<'DOLPHINADMIN'
[Desktop Entry]
Type=Service
MimeType=inode/directory;
Actions=lucixAdmin
X-KDE-Priority=TopLevel

[Desktop Action lucixAdmin]
Name=Открыть от имени администратора
Icon=dialog-password
Exec=sh -c 'pkexec env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" dolphin --new-window "$1"' sh %f
DOLPHINADMIN
    cat > "$tmp/usr/share/lucix/apply-plasma.py" <<'PLASMAPY'
#!/usr/bin/env python3
"""Lucix: настройки сеанса KDE Plasma. Запускается только внутри Plasma.
У каждого шага своя версия: он выполняется один раз и не трогает то, что ты поменяешь руками.
Шаг, который сейчас сделать нельзя, повторяется при следующем входе."""
import json
import os
import shutil
import subprocess
import time

HOME = os.path.expanduser("~")
MARK = os.path.join(HOME, ".config", "lucix", "plasma-applied")
LOG = os.path.join(HOME, ".cache", "lucix-plasma.log")


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%F %T"), msg))
    except OSError:
        pass


def run(*cmd, timeout=60):
    try:
        p = subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        log("%s -> %r" % (" ".join(cmd), e))
        return 1
    out = p.stdout.strip().replace("\n", " ")[:200]
    log("%s -> rc=%s %s %s" % (" ".join(cmd)[:160], p.returncode, p.stderr.strip(), out))
    return p.returncode


HOME_APPS = ("org.mozilla.firefox", "com.google.Chrome", "com.discordapp.Discord")


def flatpak():
    """доступ к дискам и своим курсорам для всех; домашняя папка целиком только браузерам и Discord (Steam от неё ломается)"""
    if not shutil.which("flatpak"):
        log("flatpak не найден, настрою позже")
        return False
    run("flatpak", "override", "--user", "--nofilesystem=home", "--nofilesystem=host",
        "--filesystem=/media", "--filesystem=/run/media", "--filesystem=/mnt",
        "--filesystem=xdg-data/icons:ro", "--filesystem=~/.icons:ro")
    for ref in HOME_APPS:
        run("flatpak", "override", "--user", "--filesystem=home", ref)
    run("flatpak", "override", "--user", "--nofilesystem=home", "--nofilesystem=host", "com.valvesoftware.Steam")
    #без этого каталога значки пользовательских Flatpak-приложений видны только после перезахода
    os.makedirs(os.path.join(HOME, ".local", "share", "flatpak", "exports", "share"), exist_ok=True)


def focus():
    """окно из «Показать в папке» выходит на передний план, а не прячется за остальными"""
    if not shutil.which("kwriteconfig6"):
        return False
    run("kwriteconfig6", "--file", "kwinrc", "--group", "Windows", "--key", "FocusStealingPreventionLevel", "0")
    run("dbus-send", "--session", "--dest=org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure")


def wallpaper():
    if not shutil.which("plasma-apply-wallpaperimage"):
        return False
    if run("plasma-apply-wallpaperimage", "/usr/share/backgrounds/lucix/lucix.jpg") != 0:
        return False


def colors():
    if not shutil.which("plasma-apply-colorscheme"):
        return False
    if run("plasma-apply-colorscheme", "BreezeDark") != 0:
        return False


def kickoff():
    """значок Lucix на кнопке меню приложений"""
    if not shutil.which("dbus-send"):
        return False
    js = ('var n = 0; var ps = panels(); for (var i = 0; i < ps.length; i++) {'
          ' var ws = ps[i].widgets("org.kde.plasma.kickoff");'
          ' for (var j = 0; j < ws.length; j++) { ws[j].currentConfigGroup = ["General"];'
          ' ws[j].writeConfig("icon", "lucix"); ws[j].reloadConfig(); n++; } } n;')
    if run("dbus-send", "--session", "--print-reply", "--dest=org.kde.plasmashell", "/PlasmaShell",
           "org.kde.PlasmaShell.evaluateScript", "string:" + js) != 0:
        return False


def screenshot():
    """Win+Shift+S: выделил область, и она сразу в буфере обмена (Ctrl+V вставляет)"""
    if not (shutil.which("spectacle") and shutil.which("kwriteconfig6")):
        return False
    try:
        p = subprocess.run(["spectacle", "--help"], capture_output=True, text=True, timeout=30)
        text = p.stdout + p.stderr
    except (OSError, subprocess.TimeoutExpired):
        text = ""
    flag = "--copy-image" if "--copy-image" in text else ("--clipboard" if "--clipboard" in text else "")
    cmd = "spectacle --background --region" + (" " + flag if flag else "")
    if not flag:
        log("spectacle без ключа копирования в буфер, область откроется в окне Spectacle")
        cmd = "spectacle --region"
    d = os.path.join(HOME, ".local", "share", "applications")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "lucix-screenshot.desktop"), "w", encoding="utf-8") as f:
        f.write("[Desktop Entry]\nType=Application\nName=Скриншот области\nExec=%s\nIcon=spectacle\nNoDisplay=true\n" % cmd)
    if shutil.which("kbuildsycoca6"):
        run("kbuildsycoca6")
    run("kwriteconfig6", "--file", "kglobalshortcutsrc", "--group", "services",
        "--group", "lucix-screenshot.desktop", "--key", "_launch", "Meta+Shift+S")
    run("systemctl", "--user", "restart", "plasma-kglobalaccel.service")


def keyboard():
    """русская и английская раскладки, переключение Alt+Shift, NumLock включён при входе"""
    if not shutil.which("kwriteconfig6"):
        return False
    for key, val in (("Use", "true"), ("LayoutList", "us,ru"), ("VariantList", ","), ("DisplayNames", ","),
                     ("Options", "grp:alt_shift_toggle"), ("ResetOldOptions", "true"), ("SwitchMode", "Global")):
        run("kwriteconfig6", "--file", "kxkbrc", "--group", "Layout", "--key", key, val)
    run("kwriteconfig6", "--file", "kcminputrc", "--group", "Keyboard", "--key", "NumLock", "0")
    if shutil.which("setxkbmap"):  # сразу, не дожидаясь перезахода
        run("setxkbmap", "-layout", "us,ru", "-option", "", "-option", "grp:alt_shift_toggle")


APP_DIRS = ("/usr/share/applications", "/var/lib/flatpak/exports/share/applications",
            os.path.join(HOME, ".local", "share", "applications"),
            os.path.join(HOME, ".local", "share", "flatpak", "exports", "share", "applications"))


def desktop_exists(name):
    return any(os.path.isfile(os.path.join(d, name)) for d in APP_DIRS)


MIMEAPPS = os.path.join(HOME, ".config", "mimeapps.list")


def set_defaults(pairs):
    """pairs: [(mime, desktop)]. Пишет ~/.config/mimeapps.list напрямую: xdg-mime в KDE требует qtpaths, которого нет"""
    try:
        with open(MIMEAPPS, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    head = "[Default Applications]"
    if head not in lines:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(head)
    start = lines.index(head)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    for mime, desktop in pairs:
        for i in range(start + 1, end):
            if lines[i].split("=", 1)[0] == mime:
                lines[i] = "%s=%s;" % (mime, desktop)
                break
        else:
            lines.insert(end, "%s=%s;" % (mime, desktop))
            end += 1
    os.makedirs(os.path.dirname(MIMEAPPS), exist_ok=True)
    with open(MIMEAPPS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def clean_mimeapps():
    """убирает из ассоциаций программы, которых больше нет (например, удалённые Cinnamon и Nemo)"""
    path = os.path.join(HOME, ".config", "mimeapps.list")
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return
    out, dropped = [], 0
    for line in lines:
        if "=" in line and not line.startswith(("#", "[")):
            mime, apps = line.split("=", 1)
            kept = [a for a in apps.split(";") if a and desktop_exists(a)]
            dropped += len([a for a in apps.split(";") if a]) - len(kept)
            if kept:
                out.append("%s=%s;" % (mime, ";".join(kept)))
            continue
        out.append(line)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    log("mimeapps: убрано несуществующих программ: %d" % dropped)


DEFAULT_APPS = (
    ("org.kde.kate.desktop", ("text/plain", "text/markdown", "text/x-log", "text/x-python", "text/x-shellscript",
                              "application/json", "application/xml", "text/csv", "text/x-readme")),
    ("org.kde.dolphin.desktop", ("inode/directory",)),
    ("org.kde.ark.desktop", ("application/zip", "application/x-tar", "application/x-compressed-tar",
                             "application/x-xz-compressed-tar", "application/gzip", "application/x-7z-compressed",
                             "application/vnd.rar")),
    ("pinta.desktop", ("image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp")),
    ("com.github.PintaProject.Pinta.desktop", ("image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp")),
    ("org.kde.okular.desktop", ("application/pdf",)),
)


def apps():
    """программы по умолчанию: текстовые документы, папки, архивы, картинки, PDF, браузер"""
    if not (desktop_exists("org.kde.kate.desktop") and desktop_exists("org.kde.dolphin.desktop")):
        log("Kate или Dolphin ещё не установлены, настрою позже")
        return False
    clean_mimeapps()
    pairs = []
    for desktop, mimes in DEFAULT_APPS:
        if desktop_exists(desktop):
            pairs += [(m, desktop) for m in mimes]
    if desktop_exists("org.mozilla.firefox.desktop"):
        pairs += [(m, "org.mozilla.firefox.desktop") for m in
                  ("x-scheme-handler/http", "x-scheme-handler/https", "text/html", "application/xhtml+xml")]
    set_defaults(pairs)
    log("программ по умолчанию записано: %d" % len(pairs))
    if shutil.which("kbuildsycoca6"):
        run("kbuildsycoca6")


PANEL_JS = (
    'var ps = panels(); var bad = [];'
    ' if (ps.length == 0) { "no panels"; } else {'
    ' var p = ps[0]; var launchers = ""; var ws = p.widgets();'
    ' for (var i = 0; i < ws.length; i++) {'
    '   if (ws[i].type == "org.kde.plasma.icontasks" || ws[i].type == "org.kde.plasma.taskmanager") {'
    '     ws[i].currentConfigGroup = ["General"]; launchers = ws[i].readConfig("launchers", ""); } }'
    ' for (var j = 0; j < ws.length; j++) { ws[j].remove(); }'
    ' try { p.hiding = "none"; } catch (e) { bad.push("hiding"); }'
    ' try { p.lengthMode = "fill"; } catch (e) { bad.push("lengthMode"); }'
    ' try { p.floating = false; } catch (e) { bad.push("floating"); }'
    ' try { p.opacity = "translucent"; } catch (e) { bad.push("opacity"); }'
    ' var lead = p.addWidget("org.kde.plasma.panelspacer"); lead.currentConfigGroup = ["General"];'
    ' lead.writeConfig("expanding", false); lead.writeConfig("length", 230);'
    ' p.addWidget("org.kde.plasma.panelspacer");'
    ' var k = p.addWidget("org.kde.plasma.kickoff"); k.currentConfigGroup = ["General"]; k.writeConfig("icon", "lucix");'
    ' var t = p.addWidget("org.kde.plasma.icontasks");'
    ' if (launchers) { t.currentConfigGroup = ["General"]; t.writeConfig("launchers", launchers); }'
    ' p.addWidget("org.kde.plasma.panelspacer");'
    ' var tray = p.addWidget("org.kde.plasma.systemtray"); tray.currentConfigGroup = ["General"];'
    ' tray.writeConfig("extraItems", ["org.kde.plasma.networkmanagement", "org.kde.plasma.volume", "org.kde.plasma.battery",'
    ' "org.kde.plasma.bluetooth", "org.kde.plasma.notifications", "org.kde.plasma.clipboard", "org.kde.plasma.devicenotifier",'
    ' "org.kde.plasma.keyboardlayout", "org.kde.plasma.keyboardindicator", "org.kde.plasma.brightness",'
    ' "org.kde.plasma.printmanager", "org.kde.kscreen", "org.kde.plasma.manage-inputmethod"]);'
    ' tray.writeConfig("hiddenItems", ["org.kde.plasma.mediacontroller"]);'
    ' p.addWidget("org.kde.plasma.digitalclock");'
    ' "ok widgets=" + p.widgets().length + " bad=" + bad.join(","); }'
)


def panel():
    """панель всегда видна и прозрачная: слева пусто, по центру меню и приложения, справа раскладка, трей и часы"""
    if not shutil.which("dbus-send"):
        return False
    if run("dbus-send", "--session", "--print-reply", "--dest=org.kde.plasmashell", "/PlasmaShell",
           "org.kde.PlasmaShell.evaluateScript", "string:" + PANEL_JS) != 0:
        return False


def kbdisplay():
    """в индикаторе раскладки только флаг, без букв"""
    if not shutil.which("kwriteconfig6"):
        return False
    for key, val in (("ShowFlag", "true"), ("ShowLabel", "false"), ("ShowLayoutIndicator", "true")):
        run("kwriteconfig6", "--file", "kxkbrc", "--group", "Layout", "--key", key, val)


def lockwall():
    """экран блокировки с нашими обоями (уроборос)"""
    if not shutil.which("kwriteconfig6"):
        return False
    img = "file:///usr/share/backgrounds/lucix/lucix.jpg"
    run("kwriteconfig6", "--file", "kscreenlockerrc", "--group", "Greeter", "--key", "WallpaperPlugin", "org.kde.image")
    run("kwriteconfig6", "--file", "kscreenlockerrc", "--group", "Greeter", "--group", "Wallpaper",
        "--group", "org.kde.image", "--group", "General", "--key", "Image", img)


def kwin():
    """без активных углов экрана (обзор окон при наведении), компоновка не отключается во весь экран (меньше подлагов при сворачивании)"""
    if not shutil.which("kwriteconfig6"):
        return False
    for grp, key, val in (("Effect-overview", "BorderActivate", ""), ("Effect-windowview", "BorderActivate", ""),
                          ("Effect-windowview", "BorderActivateAll", ""), ("Effect-windowview", "BorderActivateClass", ""),
                          ("Effect-desktopgrid", "BorderActivate", ""), ("Compositing", "WindowsBlockCompositing", "false")):
        run("kwriteconfig6", "--file", "kwinrc", "--group", grp, "--key", key, val)
    for edge in ("Top", "TopRight", "Right", "BottomRight", "Bottom", "BottomLeft", "Left", "TopLeft"):
        run("kwriteconfig6", "--file", "kwinrc", "--group", "ElectricBorders", "--key", edge, "None")
    run("dbus-send", "--session", "--dest=org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure")


def sounds():
    """убираем системные звуки Plasma (вход, уведомления, ошибки); звуки игр и программ не затрагиваются"""
    if not shutil.which("kwriteconfig6"):
        return False
    run("kwriteconfig6", "--file", "kdeglobals", "--group", "Sounds", "--key", "Enable", "false")
    run("kwriteconfig6", "--file", "kdeglobals", "--group", "Sounds", "--key", "Theme", "none")
    if shutil.which("xset"):
        run("xset", "b", "off")


def cursor():
    """курсор Lucix по умолчанию (если он есть в системе); сменить можно в настройках в любой момент"""
    if not os.path.isdir("/usr/share/icons/Lucix-Cursor"):
        return False  # курсора в системе пока нет, проверим при следующем входе
    if not shutil.which("plasma-apply-cursortheme"):
        return False
    if run("plasma-apply-cursortheme", "Lucix-Cursor") != 0:
        return False


def trash():
    """мгновенная очистка корзины (удалить файл = он сразу пропадает)"""
    if not os.path.isfile("/usr/lib/systemd/user/lucix-trash-clean.path"):
        return False
    run("systemctl", "--user", "daemon-reload")
    if run("systemctl", "--user", "enable", "--now", "lucix-trash-clean.path") != 0:
        return False


VIDEO_MIMES = ("video/mp4", "video/x-matroska", "video/webm", "video/x-msvideo", "video/quicktime",
               "video/mpeg", "video/x-flv", "video/ogg", "video/3gpp")


def videos():
    if not os.path.isfile("/usr/share/applications/vlc.desktop"):
        log("VLC ещё не установлен, видео по умолчанию настрою позже")
        return False
    set_defaults([(m, "vlc.desktop") for m in VIDEO_MIMES])
    log("видео по умолчанию: VLC")


def privacy():
    """на экране блокировки и в меню не показывается, что ты смотришь или слушаешь"""
    if not shutil.which("kwriteconfig6"):
        return False
    run("kwriteconfig6", "--file", "kscreenlockerrc", "--group", "Greeter", "--key", "ShowMediaControls", "false")


AUTOSTART_OFF = ("org.kde.kdeconnect.daemon.desktop", "kdeconnectd.desktop", "xwaylandvideobridge.desktop",
                 "org.kde.discover.notifier.desktop", "org.kde.kalendarac.desktop")


def memory():
    """меньше памяти: без индексации файлов (Baloo) и без лишних фоновых программ"""
    if shutil.which("kwriteconfig6"):
        run("kwriteconfig6", "--file", "baloofilerc", "--group", "Basic Settings", "--key", "Indexing-Enabled", "false")
    for tool in ("balooctl6", "balooctl"):
        if shutil.which(tool):
            run(tool, "disable")
            break
    d = os.path.join(HOME, ".config", "autostart")
    for name in AUTOSTART_OFF:
        if any(os.path.isfile(os.path.join(base, name)) for base in ("/etc/xdg/autostart", "/usr/share/autostart")):
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, name), "w", encoding="utf-8") as f:
                f.write("[Desktop Entry]\nHidden=true\n")


def cleanup():
    """убираем остатки: ярлык «Диагностика Lucix» на рабочем столе"""
    for rel in ("Desktop/lucix-diag.desktop", "Рабочий стол/lucix-diag.desktop"):
        p = os.path.join(HOME, rel)
        if os.path.isfile(p):
            os.remove(p)
            log("удалён %s" % p)


def terminal():
    """в терминале Konsole Ctrl+C копирует выделенное (без выделения прерывает программу), Ctrl+V вставляет"""
    if not shutil.which("kwriteconfig6"):
        return False
    for key, val in (("edit_copy", "Ctrl+C; Ctrl+Shift+C"), ("edit_paste", "Ctrl+V; Ctrl+Shift+V"),
                     ("edit-copy", "Ctrl+C; Ctrl+Shift+C"), ("edit-paste", "Ctrl+V; Ctrl+Shift+V")):
        run("kwriteconfig6", "--file", "konsolerc", "--group", "Shortcuts", "--key", key, val)


def power():
    """монитор сам не гаснет и компьютер сам не засыпает (на питании от сети)"""
    if not shutil.which("kwriteconfig6"):
        return False
    for prof in ("AC", "Battery", "LowBattery"):
        for key in ("DimDisplayWhenIdle", "TurnOffDisplayWhenIdle"):
            run("kwriteconfig6", "--file", "powerdevilrc", "--group", prof, "--group", "Display", "--key", key, "false")
    run("kwriteconfig6", "--file", "powerdevilrc", "--group", "AC", "--group", "SuspendAndShutdown",
        "--key", "AutoSuspendAction", "0")
    if shutil.which("xset"):  # сразу, не дожидаясь перезахода
        run("xset", "s", "off")
        run("xset", "s", "noblank")
        run("xset", "-dpms")
    run("systemctl", "--user", "restart", "plasma-powerdevil.service")


STEPS = (
    ("flatpak", 2, flatpak),
    ("focus", 1, focus),
    ("wallpaper", 1, wallpaper),
    ("colors", 1, colors),
    ("kickoff", 1, kickoff),
    ("screenshot", 1, screenshot),
    ("videos", 2, videos),
    ("keyboard", 1, keyboard),
    ("apps", 3, apps),
    ("panel", 3, panel),
    ("kbdisplay", 2, kbdisplay),
    ("lockwall", 1, lockwall),
    ("kwin", 1, kwin),
    ("sounds", 1, sounds),
    ("cursor", 1, cursor),
    ("trash", 1, trash),
    ("privacy", 1, privacy),
    ("memory", 1, memory),
    ("cleanup", 1, cleanup),
    ("terminal", 1, terminal),
    ("power", 1, power),
)


def main():
    try:
        with open(MARK, encoding="utf-8") as f:
            marks = dict(json.load(f))
    except (OSError, ValueError):
        marks = {}
    changed = False
    for name, version, fn in STEPS:
        if marks.get(name, 0) >= version:
            continue
        log("шаг %s версии %s" % (name, version))
        try:
            if fn() is False:
                continue
        except Exception as e:
            log("ошибка в %s: %r" % (name, e))
            continue
        marks[name] = version
        changed = True
    if changed:
        os.makedirs(os.path.dirname(MARK), exist_ok=True)
        with open(MARK, "w", encoding="utf-8") as f:
            json.dump(marks, f)


if __name__ == "__main__":
    main()
PLASMAPY
    cat > "$tmp/etc/xdg/autostart/lucix-apply-plasma.desktop" <<'PLASMAAUTOSTART'
[Desktop Entry]
Type=Application
Name=Lucix Plasma defaults
Exec=sh -c "sleep 8 && python3 /usr/share/lucix/apply-plasma.py"
OnlyShowIn=KDE;
NoDisplay=true
PLASMAAUTOSTART
    #переназначение клавиш (keyd): правый Alt как Esc по умолчанию, менять можно через окно «Переназначение клавиш»
    mkdir -p "$tmp/etc/keyd" "$tmp/usr/share/applications"
    cat > "$tmp/usr/share/lucix/keys-apply.py" <<'KEYSAPPLY'
#!/usr/bin/env python3
"""Lucix: запись переназначений клавиш для keyd. Запускается от root (pkexec) из «Переназначение клавиш».
Команды: show | set КЛАВИША ЧТО | remove КЛАВИША | reset | reload"""
import os
import re
import subprocess
import sys

CONF = os.environ.get("LUCIX_KEYD_CONF", "/etc/keyd/default.conf")
NAME = re.compile(r"^[a-z0-9_+]{1,40}$")
HEAD = ("# Lucix: переназначение клавиш (keyd).\n"
        "# Удобнее менять через «Переназначение клавиш» в меню. Вручную: sudo keyd reload после правки.\n"
        "[ids]\n*\n\n[main]\n")


def read_map():
    maps, in_main = {}, False
    try:
        with open(CONF, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return maps
    for line in lines:
        s = line.strip()
        if s.startswith("["):
            in_main = s == "[main]"
        elif in_main and "=" in s and not s.startswith("#"):
            a, b = s.split("=", 1)
            maps[a.strip()] = b.strip()
    return maps


def reload_keyd():
    for cmd in (["systemctl", "enable", "--now", "keyd"], ["keyd", "reload"]):
        try:
            subprocess.run(cmd, capture_output=True)
        except OSError:
            pass


def write_map(maps):
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "w", encoding="utf-8") as f:
        f.write(HEAD + "".join("%s = %s\n" % kv for kv in sorted(maps.items())))
    reload_keyd()


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "show":
        m = read_map()
        print("\n".join("%s -> %s" % kv for kv in sorted(m.items())))
        return 0
    if cmd == "reload":
        reload_keyd()
        return 0
    if cmd == "reset":
        write_map({})
        return 0
    if cmd == "set" and len(argv) == 4:
        if not (NAME.match(argv[2]) and NAME.match(argv[3])):
            print("недопустимое имя клавиши")
            return 2
        m = read_map()
        m[argv[2]] = argv[3]
        write_map(m)
        return 0
    if cmd == "remove" and len(argv) == 3:
        m = read_map()
        m.pop(argv[2], None)
        write_map(m)
        return 0
    print("usage: show | set КЛАВИША ЧТО | remove КЛАВИША | reset | reload")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
KEYSAPPLY
    cat > "$tmp/usr/share/lucix/keys-gui.py" <<'KEYSGUI'
#!/usr/bin/env python3
"""Lucix: окно «Переназначение клавиш» (например, чтобы правый Alt работал как Esc)."""
import os
import shutil
import subprocess
import sys

APPLY = "/usr/share/lucix/keys-apply.py"
CONF = "/etc/keyd/default.conf"
TITLE = "--title=Переназначение клавиш"


def zen(*args):
    return subprocess.run(["zenity", TITLE, "--width=520"] + list(args), capture_output=True, text=True)


def apply(*args):
    return subprocess.run(["pkexec", "python3", APPLY] + list(args)).returncode


def current():
    out = subprocess.run(["python3", APPLY, "show"], capture_output=True, text=True).stdout.strip()
    return out or "(пока ничего не переназначено)"


def ask(text):
    r = zen("--entry", "--text=" + text)
    return r.stdout.strip().lower() if r.returncode == 0 else ""


def main():
    if not shutil.which("zenity"):
        print("нужен zenity")
        return 1
    if not shutil.which("keyd"):
        zen("--error", "--text=Не установлен keyd. Он ставится вместе с обновлением Lucix.")
        return 1
    r = zen("--list", "--radiolist", "--height=400", "--text=Сейчас переназначено:\n" + current(),
            "--column=", "--column=Действие", "--column=id", "--hide-column=3", "--print-column=3",
            "TRUE", "Правый Alt работает как Esc", "rightalt-esc",
            "FALSE", "Caps Lock работает как Esc", "caps-esc",
            "FALSE", "Своё переназначение", "custom",
            "FALSE", "Убрать одно переназначение", "remove",
            "FALSE", "Сбросить все переназначения", "reset",
            "FALSE", "Открыть файл настроек вручную", "edit")
    if r.returncode != 0:
        return 0
    choice = r.stdout.strip()
    ok = True
    if choice == "rightalt-esc":
        ok = apply("set", "rightalt", "esc") == 0
    elif choice == "caps-esc":
        ok = apply("set", "capslock", "esc") == 0
    elif choice == "custom":
        src = ask("Какую клавишу переназначить? Например: rightalt, capslock, rightmeta, rightctrl")
        dst = ask("Чем она должна быть? Например: esc, leftctrl, enter, backspace") if src else ""
        if not (src and dst):
            return 0
        ok = apply("set", src, dst) == 0
    elif choice == "remove":
        src = ask("Какое переназначение убрать? Название клавиши, например: rightalt")
        if not src:
            return 0
        ok = apply("remove", src) == 0
    elif choice == "reset":
        ok = apply("reset") == 0
    elif choice == "edit":
        subprocess.run(["pkexec", "env", "DISPLAY=" + os.environ.get("DISPLAY", ":0"),
                        "XAUTHORITY=" + os.environ.get("XAUTHORITY", ""), "xed", CONF])
        ok = apply("reload") == 0
    zen("--info", "--text=" + ("Готово. Изменения уже действуют." if ok else "Не получилось применить (отмена или ошибка)."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
KEYSGUI
    cat > "$tmp/etc/keyd/default.conf" <<'KEYDCONF'
# Lucix: переназначение клавиш (keyd).
# Удобнее менять через «Переназначение клавиш» в меню. Вручную: sudo keyd reload после правки.
[ids]
*

[main]
rightalt = esc
KEYDCONF
    sed -i -e '$a\' "$tmp/DEBIAN/conffiles"
    echo "/etc/keyd/default.conf" >> "$tmp/DEBIAN/conffiles"
    cat > "$tmp/usr/share/applications/lucix-keys.desktop" <<'KEYSDESKTOP'
[Desktop Entry]
Type=Application
Name=Переназначение клавиш
Comment=Например, чтобы правый Alt работал как Esc
Exec=python3 /usr/share/lucix/keys-gui.py
Icon=input-keyboard
Categories=Settings;
Terminal=false
KEYSDESKTOP
    #обязательные пакеты: keyd (клавиши), vlc (видео), python3-pil (курсоры Windows), flatpak (магазин), база Plasma,
    #значок Wi-Fi и громкость, окна выбора файлов («Обзор») в Flatpak и GTK-приложениях
    sed -i 's/^Depends: .*/&, keyd, vlc, python3-pil, flatpak, kate, konsole, dolphin, ark, plasma-nm, plasma-pa, kscreen, kde-spectacle, xdg-desktop-portal-kde, xdg-desktop-portal-gtk/' "$tmp/DEBIAN/control"
    #желательные: если их нет в репозитории, обновление всё равно пройдёт
    sed -i 's/^Recommends: .*/&, ffmpegthumbnailer, gstreamer1.0-libav, alsa-utils, okular/' "$tmp/DEBIAN/control"
    grep -q '^Depends: .*keyd.*portal-gtk' "$tmp/DEBIAN/control" || { echo "не удалось дописать Depends"; exit 1; }
    grep -q '^Recommends: .*okular' "$tmp/DEBIAN/control" || { echo "не удалось дописать Recommends"; exit 1; }
    #все приложения одним окном, очистка снимков Timeshift, мгновенная корзина
    mkdir -p "$tmp/usr/bin" "$tmp/usr/lib/systemd/user" "$tmp/etc/systemd/user/default.target.wants"
    cat > "$tmp/usr/bin/lucix-apps" <<'LUCIXAPPS'
#!/usr/bin/env python3
"""Lucix: все приложения системы в одном окне.
Вкладки: «Приложения» (всё, что есть в меню), «Все пакеты» (каждый установленный пакет), «Flatpak» (включая среды)."""
import configparser
import glob
import os
import shutil
import subprocess
import sys

RU = (os.environ.get("LC_ALL") or os.environ.get("LANG") or "").startswith("ru")
HOME = os.path.expanduser("~")
FLATPAK_DIRS = ("/var/lib/flatpak/exports/share/applications",
                os.path.join(HOME, ".local/share/flatpak/exports/share/applications"))
SYSTEM_DIR = "/usr/share/applications"
USER_DIR = os.path.join(HOME, ".local/share/applications")


def run(cmd, timeout=90):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def parse_desktop(path):
    cp = configparser.RawConfigParser(strict=False)
    cp.optionxform = str
    try:
        cp.read(path, encoding="utf-8")
    except (configparser.Error, UnicodeDecodeError, OSError):
        return None
    if not cp.has_section("Desktop Entry"):
        return None
    e = cp["Desktop Entry"]
    if e.get("Type") != "Application" or e.get("NoDisplay", "false").lower() == "true" \
            or e.get("Hidden", "false").lower() == "true":
        return None
    name = (e.get("Name[ru]") if RU else None) or e.get("Name") or os.path.basename(path)
    comment = (e.get("Comment[ru]") if RU else None) or e.get("Comment") or ""
    return name, comment


def flatpak_info():
    """application id -> (название, версия, ветка, установка)"""
    if not shutil.which("flatpak"):
        return {}
    out = run(["flatpak", "list", "--columns=application,name,version,branch,installation"])
    info = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) >= 5:
            info[p[0]] = p[1:5]
    return info


def launchers():
    """список (название, описание, источник, пакет/ссылка, версия) для всех приложений из меню"""
    flat = flatpak_info()
    files = []
    for d, kind in [(SYSTEM_DIR, "apt")] + [(x, "flatpak") for x in FLATPAK_DIRS] + [(USER_DIR, "user")]:
        for f in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            files.append((f, kind))
    owners = {}
    sys_files = [f for f, k in files if k == "apt"]
    if sys_files and shutil.which("dpkg-query"):
        for i in range(0, len(sys_files), 200):
            for line in run(["dpkg-query", "-S"] + sys_files[i:i + 200]).splitlines():
                if ": /" in line:
                    pk, path = line.split(": /", 1)
                    owners["/" + path.strip()] = pk.split(",")[0].strip().split(":")[0]
    versions = {}
    pk_all = sorted(set(owners.values()))
    for i in range(0, len(pk_all), 200):
        for line in run(["dpkg-query", "-W", "-f=${Package}\t${Version}\n"] + pk_all[i:i + 200]).splitlines():
            p = line.split("\t")
            if len(p) == 2:
                versions[p[0]] = p[1]
    rows, seen = [], set()
    for path, kind in files:
        parsed = parse_desktop(path)
        if not parsed:
            continue
        name, comment = parsed
        base = os.path.basename(path)[:-len(".desktop")]
        if kind == "apt":
            pkg = owners.get(path, "")
            row = (name, comment, "Ubuntu (apt)" if RU else "Ubuntu (apt)", pkg, versions.get(pkg, ""))
        elif kind == "flatpak":
            i = flat.get(base, ["", "", "", ""])
            row = (name, comment, "Flatpak", base, i[1])
        else:
            row = (name, comment, "Свой ярлык" if RU else "Custom launcher", base, "")
        key = (name, row[2], row[3])
        if key not in seen:
            seen.add(key)
            rows.append(row)
    return sorted(rows, key=lambda r: r[0].lower())


def packages():
    """каждый установленный пакет: (имя, версия, размер КБ, описание)"""
    out = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${Package}\t${Version}\t${Installed-Size}\t${binary:Summary}\n"])
    rows = []
    for line in out.splitlines():
        p = line.split("\t", 4)
        if len(p) == 5 and p[0].startswith("ii"):
            try:
                size = int(p[3] or 0)
            except ValueError:
                size = 0
            rows.append((p[1], p[2], size, p[4]))
    return sorted(rows, key=lambda r: r[0])


def flatpaks():
    """все Flatpak, включая среды выполнения: (название, ссылка, версия, ветка, установка, размер)"""
    if not shutil.which("flatpak"):
        return []
    out = run(["flatpak", "list", "--columns=name,application,version,branch,installation,size"])
    rows = [tuple(l.split("\t")[:6]) for l in out.splitlines() if l.count("\t") >= 5]
    return sorted(rows, key=lambda r: r[0].lower())


def human(kb):
    return "%.1f МБ" % (kb / 1024) if kb >= 1024 else "%d КБ" % kb


def main():
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk

    win = Gtk.Window(title="Все приложения Lucix" if RU else "All Lucix apps")
    win.set_default_size(1000, 640)
    win.connect("destroy", Gtk.main_quit)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(8)
    win.add(box)
    entry = Gtk.SearchEntry()
    entry.set_placeholder_text("Поиск по названию, пакету, описанию" if RU else "Search")
    box.pack_start(entry, False, False, 0)
    notebook = Gtk.Notebook()
    box.pack_start(notebook, True, True, 0)
    status = Gtk.Label(xalign=0)
    box.pack_start(status, False, False, 0)
    views = []

    def add_tab(title, cols, rows, sort_hidden=None):
        n = len(cols)
        store = Gtk.ListStore(*([str] * n + ([int] if sort_hidden is not None else [])))
        for r in rows:
            vals = [str(x) for x in r[:n]]
            store.append(vals + ([int(r[sort_hidden])] if sort_hidden is not None else []))
        flt = store.filter_new()

        def visible(model, it, _data=None):
            q = entry.get_text().strip().lower()
            return not q or any(q in (model[it][i] or "").lower() for i in range(n))

        flt.set_visible_func(visible)
        tree = Gtk.TreeView(model=Gtk.TreeModelSort(model=flt))  # сортировка по клику на заголовок
        for i, c in enumerate(cols):
            col = Gtk.TreeViewColumn(c, Gtk.CellRendererText(), text=i)
            col.set_resizable(True)
            col.set_sort_column_id(n if (sort_hidden is not None and c == cols[sort_hidden_col.get(title, -1)]) else i)
            tree.append_column(col)
        scroll = Gtk.ScrolledWindow()
        scroll.add(tree)
        notebook.append_page(scroll, Gtk.Label(label="%s (%d)" % (title, len(rows))))
        views.append(flt)

    sort_hidden_col = {}
    add_tab("Приложения" if RU else "Apps", ["Название", "Описание", "Источник", "Пакет / ссылка", "Версия"], launchers())
    pk = packages()
    sort_hidden_col["Все пакеты" if RU else "All packages"] = 2
    add_tab("Все пакеты" if RU else "All packages", ["Пакет", "Версия", "Размер", "Описание"],
            [(p[0], p[1], human(p[2]), p[3], p[2]) for p in pk], sort_hidden=4)
    add_tab("Flatpak", ["Название", "Ссылка", "Версия", "Ветка", "Установка", "Размер"], flatpaks())

    def update_status(*_):
        cur = notebook.get_current_page()
        shown = len(views[cur]) if 0 <= cur < len(views) else 0
        status.set_text(("Показано: %d" if RU else "Shown: %d") % shown)

    def on_search(*_):
        for v in views:
            v.refilter()
        update_status()

    entry.connect("search-changed", on_search)
    notebook.connect("switch-page", lambda *_: update_status())
    win.show_all()
    update_status()
    Gtk.main()


if __name__ == "__main__":
    main()
LUCIXAPPS
    chmod 0755 "$tmp/usr/bin/lucix-apps"
    cat > "$tmp/usr/share/applications/lucix-apps.desktop" <<'APPSDESKTOP'
[Desktop Entry]
Type=Application
Name=Все приложения
Comment=Полный список приложений и пакетов в системе
Exec=lucix-apps
Icon=view-list-details
Categories=System;Settings;
Terminal=false
APPSDESKTOP
    cat > "$tmp/usr/share/lucix/snapshots-clear.py" <<'SNAPPY'
#!/usr/bin/env python3
"""Lucix: удалить все снимки системы (Timeshift) одной кнопкой."""
import shutil
import subprocess
import sys

TITLE = "--title=Снимки системы"


def zen(*args):
    return subprocess.run(["zenity", TITLE, "--width=460"] + list(args))


def main():
    if not shutil.which("timeshift"):
        zen("--error", "--text=Timeshift не установлен, снимков нет.")
        return 1
    r = zen("--question", "--ok-label=Удалить всё", "--cancel-label=Отмена",
            "--text=Удалить ВСЕ снимки системы (Timeshift)?\n\nМесто освободится, но откатиться к ним будет уже нельзя.")
    if r.returncode != 0:
        return 0
    p = subprocess.run(["pkexec", "timeshift", "--delete-all", "--scripted"], capture_output=True, text=True)
    if p.returncode == 0:
        zen("--info", "--text=Все снимки удалены.")
    else:
        zen("--error", "--text=Не получилось удалить:\n" + (p.stderr or p.stdout).strip()[-400:])
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
SNAPPY
    cat > "$tmp/usr/share/applications/lucix-snapshots-clear.desktop" <<'SNAPDESKTOP'
[Desktop Entry]
Type=Application
Name=Очистить снимки системы
Comment=Удалить все снимки Timeshift
Exec=python3 /usr/share/lucix/snapshots-clear.py
Icon=edit-clear-history
Categories=System;Settings;
Terminal=false
SNAPDESKTOP
    cat > "$tmp/usr/share/lucix/trash-clean.sh" <<'TRASHSH'
#!/bin/sh
# Lucix: мгновенная очистка корзины. Запускается сама, как только в корзину что-то попало.
T="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
[ -d "$T" ] || exit 0
rm -rf -- "$T/files/"* "$T/files/".[!.]* "$T/info/"* "$T/info/".[!.]* 2>/dev/null
rm -f -- "$T/directorysizes" 2>/dev/null
exit 0
TRASHSH
    chmod 0755 "$tmp/usr/share/lucix/trash-clean.sh"
    cat > "$tmp/usr/lib/systemd/user/lucix-trash-clean.path" <<'TRASHPATH'
[Unit]
Description=Lucix: мгновенная очистка корзины

[Path]
PathChanged=%h/.local/share/Trash/files
MakeDirectory=true

[Install]
WantedBy=default.target
TRASHPATH
    cat > "$tmp/usr/lib/systemd/user/lucix-trash-clean.service" <<'TRASHSERVICE'
[Unit]
Description=Lucix: очистка корзины

[Service]
Type=oneshot
ExecStart=/usr/share/lucix/trash-clean.sh
TRASHSERVICE
    ln -sf /usr/lib/systemd/user/lucix-trash-clean.path "$tmp/etc/systemd/user/default.target.wants/lucix-trash-clean.path"
    #«Диагностики Lucix» больше нет
    rm -f "$tmp/usr/bin/lucix-diag" "$tmp/usr/share/applications/lucix-diag.desktop" "$tmp/etc/skel/Desktop/lucix-diag.desktop"
    #курсор по умолчанию: если в проекте лежит branding/cursor.zip (набор курсоров Windows), конвертируем его при сборке
    if [[ -f "$ROOT_DIR/branding/cursor.zip" ]]; then
      python3 -c 'import PIL' 2>/dev/null || python3 -m pip install --quiet --user --break-system-packages pillow || echo "Pillow недоступен, курсор по умолчанию пропущен"
      python3 - "$ROOT_DIR/branding/cursor.zip" "$tmp/usr/share/icons/Lucix-Cursor" "$tmp/usr/share/lucix/install-cursor.py" <<'PYCURSOR'
import importlib.util, os, sys, tempfile, zipfile
zip_path, out_dir, script = sys.argv[1:4]
try:
    import PIL
except ImportError:
    print("Pillow недоступен, курсор по умолчанию пропущен")
    sys.exit(0)
spec = importlib.util.spec_from_file_location("ic", script)
ic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ic)
with tempfile.TemporaryDirectory() as t:
    zipfile.ZipFile(zip_path).extractall(t)
    d = ic.find_windows_dir(t)
    assert d, "в cursor.zip нет курсоров Windows"
    os.makedirs(out_dir, exist_ok=True)
    print("курсор Lucix-Cursor: %d шт" % ic.convert_windows(d, out_dir, "Lucix-Cursor"))
PYCURSOR
    fi
    #в проекте только Plasma: старые файлы Nemo из packaging в пакет не попадают
    rm -rf "$tmp/usr/share/nemo"
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

#пакет брендинга: название Lucix вместо Ubuntu, восстанавливается после обновления base-files
br="$(mktemp -d)"
mkdir -p "$br/DEBIAN" "$br/usr/share/lucix"
cat > "$br/DEBIAN/control" <<BRCONTROL
Package: lucix-branding
Version: $DEB_VERSION
Section: misc
Priority: optional
Architecture: all
Maintainer: Lucix <lucovisa@users.noreply.github.com>
Depends: lucix-base
Description: Lucix product names
 Replaces the visible Ubuntu names with Lucix (os-release, issue, lsb-release).
BRCONTROL
cat > "$br/usr/share/lucix/apply-branding.sh" <<'BRSH'
#!/bin/sh
# Lucix: фирменные названия вместо Ubuntu.
# Запускается при установке и каждый раз, когда обновление base-files переписывает файлы с названием системы.
ROOT="${LUCIX_ROOT:-}"
VER="${LUCIX_VER:-$(dpkg-query -W -f='${Version}' lucix-base 2>/dev/null || echo unknown)}"
REPO="https://github.com/lucovisa/lucix"

setkv() {
  if grep -q "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    echo "$2=$3" >> "$1"
  fi
}

#ID=ubuntu оставляем: от него зависят Steam, драйверы и сторонние установщики
osr="$ROOT/usr/lib/os-release"
if [ -f "$osr" ] && [ ! -L "$osr" ]; then
  setkv "$osr" NAME '"Lucix"'
  setkv "$osr" PRETTY_NAME "\"Lucix $VER\""
  setkv "$osr" VERSION "\"$VER\""
  setkv "$osr" HOME_URL "\"$REPO\""
  setkv "$osr" SUPPORT_URL "\"$REPO/issues\""
  setkv "$osr" BUG_REPORT_URL "\"$REPO/issues\""
  setkv "$osr" PRIVACY_POLICY_URL "\"$REPO\""
  setkv "$osr" LOGO lucix
fi

#надпись при входе в текстовую консоль
[ -d "$ROOT/etc" ] && printf 'Lucix %s \\n \\l\n\n' "$VER" > "$ROOT/etc/issue"
[ -d "$ROOT/etc" ] && printf 'Lucix %s\n' "$VER" > "$ROOT/etc/issue.net"

#описание в lsb_release, DISTRIB_ID не трогаем, на него опираются автообновления
if [ -f "$ROOT/etc/lsb-release" ]; then
  sed -i "s|^DISTRIB_DESCRIPTION=.*|DISTRIB_DESCRIPTION=\"Lucix $VER\"|" "$ROOT/etc/lsb-release"
fi
exit 0
BRSH
cat > "$br/DEBIAN/postinst" <<'BRPOST'
#!/bin/sh
set -e
case "$1" in
  configure|triggered) /usr/share/lucix/apply-branding.sh || true ;;
esac
exit 0
BRPOST
printf 'interest-noawait /usr/lib/os-release\n' > "$br/DEBIAN/triggers"
chmod 0755 "$br/DEBIAN" "$br/DEBIAN/postinst" "$br/usr/share/lucix/apply-branding.sh"
dpkg-deb --root-owner-group --build "$br" "$OUT/lucix-branding_${RAW_VERSION}_all.deb"
rm -rf "$br"

#пакет lucix-system: раскладка us+ru и переключение Alt+Shift для экрана входа и консоли (один раз, дальше настройки не трогаем)
sy="$(mktemp -d)"
mkdir -p "$sy/DEBIAN"
cat > "$sy/DEBIAN/control" <<SYCONTROL
Package: lucix-system
Version: $DEB_VERSION
Section: misc
Priority: optional
Architecture: all
Maintainer: Lucix <lucovisa@users.noreply.github.com>
Depends: lucix-base
Description: Lucix system defaults
 Sets us+ru keyboard layouts with Alt+Shift switching and turns off a few unneeded background services.
SYCONTROL
cat > "$sy/DEBIAN/postinst" <<'SYPOST'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -f /etc/default/keyboard ] && [ ! -e /var/lib/lucix/keyboard-set ]; then
  sed -i 's/^XKBLAYOUT=.*/XKBLAYOUT="us,ru"/' /etc/default/keyboard
  grep -q '^XKBLAYOUT=' /etc/default/keyboard || echo 'XKBLAYOUT="us,ru"' >> /etc/default/keyboard
  sed -i 's/^XKBOPTIONS=.*/XKBOPTIONS="grp:alt_shift_toggle"/' /etc/default/keyboard
  grep -q '^XKBOPTIONS=' /etc/default/keyboard || echo 'XKBOPTIONS="grp:alt_shift_toggle"' >> /etc/default/keyboard
  sed -i 's/^XKBVARIANT=.*/XKBVARIANT=""/' /etc/default/keyboard
  mkdir -p /var/lib/lucix
  touch /var/lib/lucix/keyboard-set
fi
if [ "$1" = configure ] && [ ! -e /var/lib/lucix/services-set ]; then
  for u in apport.service whoopsie.service motd-news.timer ua-timer.timer; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
      systemctl disable --now "$u" >/dev/null 2>&1 || true
    fi
  done
  mkdir -p /var/lib/lucix
  touch /var/lib/lucix/services-set
fi
exit 0
SYPOST
chmod 0755 "$sy/DEBIAN" "$sy/DEBIAN/postinst"
dpkg-deb --root-owner-group --build "$sy" "$OUT/lucix-system_${RAW_VERSION}_all.deb"
rm -rf "$sy"

( cd "$OUT" && sha256sum ./*.deb | sed 's| \./| |' > SHA256SUMS )
ls -lh "$OUT"
