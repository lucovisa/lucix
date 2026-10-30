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
import json, sys
root = sys.argv[1]
helper = root + "/usr/lib/lucix/lucix-helper"
apps = root + "/usr/share/lucix/apps.json"

REMOVE_FUNCS = '\nLIGHTDM_CONF = "/etc/lightdm/lightdm.conf.d/50-lucix.conf"\n\n\ndef post_remove_cinnamon():\n    """удаляет Cinnamon полностью, но только если Plasma (X11) уже установлена"""\n    if not shutil.which("startplasma-x11"):\n        say("Plasma (X11) не установлена, Cinnamon не трогаю")\n        return False\n    r = subprocess.run(["dpkg-query", "-W", "-f=${db:Status-Abbrev} ${Package}\\\\n", "cinnamon*", "muffin*", "nemo*"],\n                       capture_output=True, text=True)\n    pkgs = [l.split()[1] for l in r.stdout.splitlines() if l.startswith("ii ") and len(l.split()) == 2]\n    if not pkgs:\n        say("Cinnamon уже удалён")\n    else:\n        if run(["apt-get"] + APT_OPTS + ["purge"] + pkgs) != 0:\n            return False\n        if run(["apt-get"] + APT_OPTS + ["autoremove", "--purge"]) != 0:\n            return False\n    #сеанс по умолчанию теперь Plasma\n    try:\n        with open(LIGHTDM_CONF, encoding="utf-8") as f:\n            text = f.read()\n        if "user-session=" in text:\n            text = "\\n".join("user-session=plasmax11" if l.startswith("user-session=") else l\n                             for l in text.splitlines()) + "\\n"\n        else:\n            text = text.rstrip("\\n") + "\\nuser-session=plasmax11\\n"\n        with open(LIGHTDM_CONF, "w", encoding="utf-8") as f:\n            f.write(text)\n    except OSError as e:\n        say("не удалось сменить сеанс по умолчанию: %s" % e)\n    return True\n\n'

s = open(helper, encoding="utf-8").read()
if "post_keep_lightdm" not in s:
    anchor = "POST = {\n"
    assert s.count(anchor) == 1, "в хелпере не найден блок POST"
    funcs = '''#Plasma ставит SDDM, а экран входа оставляем прежний (LightDM)
def post_snapshot_plasma():
    try:
        snapshot("Lucix: before KDE Plasma")
    except Exception as e:
        say("snapshot skipped: %s" % e)
    return True


def post_preseed_lightdm():
    subprocess.run(["debconf-set-selections"], input="shared/default-x-display-manager select lightdm\\n",
                   text=True, env=ENV)
    return True


def post_keep_lightdm():
    if os.path.exists("/usr/sbin/lightdm"):
        with open("/etc/X11/default-display-manager", "w", encoding="utf-8") as f:
            f.write("/usr/sbin/lightdm\\n")
        run(["systemctl", "enable", "--force", "lightdm.service"])
    return True


'''
    s = s.replace(anchor, funcs + anchor + '    "snapshot-plasma": post_snapshot_plasma,\n    "preseed-lightdm": post_preseed_lightdm,\n    "keep-lightdm": post_keep_lightdm,\n')
    open(helper, "w", encoding="utf-8").write(s)

if "post_remove_cinnamon" not in open(helper, encoding="utf-8").read():
    s = open(helper, encoding="utf-8").read()
    anchor2 = '    "keep-lightdm": post_keep_lightdm,\n'
    assert s.count(anchor2) == 1, "в хелпере не найден keep-lightdm"
    s = s.replace("POST = {\n", REMOVE_FUNCS + "POST = {\n", 1)
    s = s.replace(anchor2, anchor2 + '    "remove-cinnamon": post_remove_cinnamon,\n')
    open(helper, "w", encoding="utf-8").write(s)

d = json.load(open(apps, encoding="utf-8"))
if not any(a.get("id") == "plasma" for a in d["apps"]):
    d["apps"].append({
        "id": "plasma",
        "name": ["KDE Plasma (experimental)", "KDE Plasma (экспериментально)"],
        "desc": ["Second desktop, about 1 GB. On the login screen pick Plasma (X11). Cinnamon stays",
                 "Второй рабочий стол, около 1 ГБ. На экране входа выбери сеанс Plasma (X11), Cinnamon остаётся"],
        "default": False,
        "steps": [
            {"method": "post", "name": "snapshot-plasma"},
            {"method": "post", "name": "preseed-lightdm"},
            {"method": "apt", "packages": ["kde-plasma-desktop", "plasma-session-x11", "kwin-x11", "spectacle"]},
            {"method": "post", "name": "keep-lightdm"},
        ],
    })
    pass

if not any(a.get("id") == "remove-cinnamon" for a in d["apps"]):
    d["apps"].append({
        "id": "remove-cinnamon",
        "name": ["Remove Cinnamon (Plasma only)", "Удалить Cinnamon (останется только Plasma)"],
        "desc": ["ONLY from a Plasma session and only after checking that Plasma works. Removes Cinnamon completely",
                 "ТОЛЬКО из сеанса Plasma и только когда убедился, что она работает. Cinnamon удаляется полностью"],
        "default": False,
        "steps": [
            {"method": "post", "name": "snapshot-plasma"},
            {"method": "post", "name": "remove-cinnamon"},
        ],
    })

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


def apply_theme(name):
    if shutil.which("plasma-apply-cursortheme"):
        subprocess.run(["plasma-apply-cursortheme", name])
    if shutil.which("gsettings"):  # для GTK-приложений
        subprocess.run(["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", "'%s'" % name.replace("'", "")])


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
    log("%s -> rc=%s %s" % (" ".join(cmd), p.returncode, p.stderr.strip()))
    return p.returncode


def flatpak():
    """браузеру и остальным Flatpak-приложениям: домашняя папка, диски и свои курсоры"""
    if not shutil.which("flatpak"):
        log("flatpak не найден, настрою позже")
        return False
    folders = ("home", "/media", "/run/media", "/mnt")
    run("flatpak", "override", "--user", *["--filesystem=%s" % f for f in folders])
    run("flatpak", "override", "--user", "--filesystem=xdg-data/icons:ro", "--filesystem=~/.icons:ro")
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


VIDEO_MIMES = ("video/mp4", "video/x-matroska", "video/webm", "video/x-msvideo", "video/quicktime",
               "video/mpeg", "video/x-flv", "video/ogg", "video/3gpp")


def videos():
    if not os.path.isfile("/usr/share/applications/vlc.desktop"):
        log("VLC ещё не установлен, видео по умолчанию настрою позже")
        return False
    run("xdg-mime", "default", "vlc.desktop", *VIDEO_MIMES)


STEPS = (
    ("flatpak", 1, flatpak),
    ("focus", 1, focus),
    ("wallpaper", 1, wallpaper),
    ("colors", 1, colors),
    ("kickoff", 1, kickoff),
    ("screenshot", 1, screenshot),
    ("videos", 1, videos),
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
    #рекомендованные пакеты: python3-pil (конвертер курсоров), vlc и кодеки (видео mp4), flatpak (приложения из магазина), keyd (клавиши)
    sed -i 's/^Recommends: .*/&, python3-pil, vlc, ffmpegthumbnailer, gstreamer1.0-libav, flatpak, keyd, alsa-utils/' "$tmp/DEBIAN/control"
    grep -q '^Recommends: .*keyd' "$tmp/DEBIAN/control" || { echo "не удалось дописать Recommends"; exit 1; }
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

( cd "$OUT" && sha256sum ./*.deb | sed 's| \./| |' > SHA256SUMS )
ls -lh "$OUT"
