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
    cat > "$tmp/usr/share/lucix/apply-defaults.py" <<'APPLYPY'
#!/usr/bin/env python3
"""Lucix: применяет настройки рабочего стола один раз на версию настроек.
Скриншоты как в Windows, панель по центру, доступ Flatpak к папкам."""
import ast
import os
import shutil
import subprocess
import time

SETTINGS_VERSION = "3"
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
        log("flameshot не установлен, скриншоты не настраиваю")
        return
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


def main():
    try:
        with open(MARK, encoding="utf-8") as f:
            if f.read().strip() == SETTINGS_VERSION:
                return
    except OSError:
        pass
    log("применяю настройки версии %s" % SETTINGS_VERSION)
    for step in (flatpak, screenshots, panel, theme):
        try:
            step()
        except Exception as e:
            log("ошибка в %s: %r" % (step.__name__, e))
    os.makedirs(os.path.dirname(MARK), exist_ok=True)
    with open(MARK, "w", encoding="utf-8") as f:
        f.write(SETTINGS_VERSION)
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "Lucix", "Настройки рабочего стола обновлены"])


if __name__ == "__main__":
    main()
APPLYPY
    mkdir -p "$tmp/usr/share/nemo/actions"
    cat > "$tmp/usr/share/lucix/install-cursor.py" <<'CURSORPY'
#!/usr/bin/env python3
"""Lucix: установка курсора мыши из архива (zip, tar.gz, tar.xz, tar.bz2).
Запускается из файлового менеджера: правый клик по архиву, «Установить как курсор мыши»."""
import os
import shutil
import subprocess
import sys
import tempfile

TITLE = "Курсор мыши"


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


def find_themes(root):
    found = set()
    for d, dirs, files in os.walk(root):
        if os.path.basename(d) == "cursors" and (files or dirs):
            found.add(os.path.dirname(d))
    return sorted(found)


def apply_theme(name):
    for schema in ("org.cinnamon.desktop.interface", "org.gnome.desktop.interface"):
        subprocess.run(["gsettings", "set", schema, "cursor-theme", "'%s'" % name.replace("'", "")])


def main():
    if len(sys.argv) < 2:
        say("Выбери архив с курсором (zip, tar.gz, tar.xz).")
        return 1
    archive = sys.argv[1]
    base = os.path.basename(archive)
    stem = base
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
                #zip не принимает filter, но сам не выпускает файлы за пределы папки
                shutil.unpack_archive(archive, tmp)
        except Exception as e:
            say("Не удалось распаковать архив:\n%s\n\nНужен курсор для Linux в архиве zip или tar. Курсоры Windows (.cur и .ani) сначала надо конвертировать." % e)
            return 1
        themes = find_themes(tmp)
        if not themes:
            say("В архиве нет курсора для Linux (нет папки cursors).\nКурсоры Windows (.cur и .ani) сначала надо конвертировать в формат Linux.")
            return 1
        os.makedirs(dest_root, exist_ok=True)
        names = []
        for t in themes:
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
    #скриншоты (flameshot) ставятся как рекомендованный пакет (если пакета нет, обновление не падает)
    sed -i 's/^Recommends: .*/&, flameshot/' "$tmp/DEBIAN/control"
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
