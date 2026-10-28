"""Lucix: подготовка диска для автоматической установки (только UEFI и GPT).

Правила безопасности:
- существующие разделы никогда не удаляются, не меняются и не форматируются;
- создаётся только новый раздел в свободном месте (или всё с нуля на полностью пустом диске);
- перед действием состояние диска перепроверяется и сверяется с планом, который подтвердил человек.
"""
import json
import os
import subprocess
import time

ESP_GUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
LINUX_GUID = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
MIB = 1024 * 1024
GIB = 1024 * MIB
MIN_ROOT_GIB = 20
ESP_MIB = 512
PLAN_FILE = "/run/lucix-install-plan.json"


class DiskError(Exception):
    pass


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def run_ok(cmd):
    rc, out, err = run(cmd)
    if rc != 0:
        raise DiskError("%s: %s" % (" ".join(cmd), (err or out).strip()))
    return out


def part_node(disk, n):
    return "%s%s%d" % (disk, "p" if disk[-1].isdigit() else "", n)


def blkid(node, tag):
    rc, out, _ = run(["blkid", "-o", "value", "-s", tag, node])
    return out.strip() if rc == 0 else ""


def is_efi():
    return os.path.isdir("/sys/firmware/efi")


def _flag(v):
    return str(v).lower() in ("1", "true")


def live_disks():
    """диски, на которых лежит сама загрузочная флешка"""
    res = set()
    for mp in ("/cdrom", "/run/live/medium", "/lib/live/mount/medium"):
        rc, src, _ = run(["findmnt", "-n", "-o", "SOURCE", mp])
        src = src.strip()
        if rc == 0 and src.startswith("/dev/"):
            res.add(src)
            rc2, pk, _ = run(["lsblk", "-no", "PKNAME", src])
            for name in pk.split():
                res.add("/dev/" + name)
    return res


def list_disks():
    rc, out, _ = run(["lsblk", "-J", "-b", "-d", "-p", "-o", "NAME,SIZE,TYPE,RM,RO,MODEL"])
    if rc != 0:
        return []
    skip = live_disks()
    res = []
    for d in json.loads(out).get("blockdevices", []):
        if d.get("type") != "disk" or _flag(d.get("ro")) or _flag(d.get("rm")):
            continue
        if d["name"] in skip:
            continue
        res.append({"name": d["name"], "size": int(d["size"]), "model": (d.get("model") or "").strip()})
    return res


def read_table(disk):
    rc, out, _ = run(["sfdisk", "-J", disk])
    if rc != 0 or not out.strip():
        return None
    try:
        return json.loads(out)["partitiontable"]
    except (ValueError, KeyError):
        return None


def is_blank(disk):
    rc, out, _ = run(["wipefs", "-n", disk])
    return rc == 0 and not out.strip()


def sector_size(disk, table):
    if table and table.get("sectorsize"):
        return int(table["sectorsize"])
    rc, out, _ = run(["blockdev", "--getss", disk])
    try:
        return int(out.strip())
    except ValueError:
        return 512


def free_regions(first, last, parts, align):
    """свободные участки (начало, конец включительно) в секторах, выровненные по 1 МиБ"""
    used = sorted((int(p["start"]), int(p["start"]) + int(p["size"]) - 1) for p in parts)
    gaps, cur = [], first
    for s, e in used:
        if s > cur:
            gaps.append((cur, s - 1))
        cur = max(cur, e + 1)
    if cur <= last:
        gaps.append((cur, last))
    res = []
    for g0, g1 in gaps:
        a = -(-g0 // align) * align
        b = ((g1 + 1) // align) * align - 1
        if b > a:
            res.append((a, b))
    return res


def make_plan(disk, size=0, model=""):
    table = read_table(disk)
    if table is None:
        if not is_blank(disk):
            raise DiskError("на диске есть неизвестная разметка или файловая система")
        ss = sector_size(disk, None)
        if size and size < (ESP_MIB + MIN_ROOT_GIB * 1024) * MIB:
            raise DiskError("пустой диск слишком мал (нужно от %d ГБ)" % (MIN_ROOT_GIB + 1))
        return {"mode": "blank", "disk": disk, "model": model, "size_bytes": size,
                "sector_size": ss, "esp": None, "start": None, "end": None,
                "root_bytes": max(0, size - ESP_MIB * MIB)}
    if table.get("label") != "gpt":
        raise DiskError("таблица разделов не GPT")
    parts = table.get("partitions", [])
    if len(parts) >= 128:
        raise DiskError("слишком много разделов")
    ss = sector_size(disk, table)
    esp = None
    for p in parts:
        if str(p.get("type", "")).upper() == ESP_GUID and blkid(p["node"], "TYPE") == "vfat":
            esp = p["node"]
            break
    if not esp:
        raise DiskError("на диске нет EFI-раздела (FAT32)")
    first = int(table.get("firstlba", 34))
    last = int(table.get("lastlba", (size // ss) - 35 if size else 0))
    regions = free_regions(first, last, parts, max(1, MIB // ss))
    if not regions:
        raise DiskError("на диске нет свободного места")
    a, b = max(regions, key=lambda r: r[1] - r[0])
    root_bytes = (b - a + 1) * ss
    if root_bytes < MIN_ROOT_GIB * GIB:
        raise DiskError("самый большой свободный участок %d ГБ, нужно от %d ГБ" % (root_bytes // GIB, MIN_ROOT_GIB))
    return {"mode": "free", "disk": disk, "model": model, "size_bytes": size,
            "sector_size": ss, "esp": esp, "start": a, "end": b, "root_bytes": root_bytes}


def candidates():
    """подходящие планы и причины отказа по остальным дискам"""
    plans, reasons = [], []
    for d in list_disks():
        try:
            plans.append(make_plan(d["name"], d["size"], d["model"]))
        except DiskError as e:
            reasons.append("%s: %s" % (d["name"], e))
    plans.sort(key=lambda p: p["root_bytes"], reverse=True)
    return plans, reasons


def _wait_node(node):
    run(["udevadm", "settle"])
    for _ in range(40):
        if os.path.exists(node):
            return
        time.sleep(0.5)
    raise DiskError("устройство %s не появилось" % node)


def _entry(node, mount, fs, label, ptype):
    return {"device": node, "mountPoint": mount, "fs": fs, "fsName": fs,
            "uuid": blkid(node, "UUID"), "partuuid": blkid(node, "PARTUUID"),
            "label": label, "partlabel": label, "parttype": ptype, "partattrs": "0",
            "claimed": True, "features": {}}


def apply_plan(plan, say):
    disk = plan["disk"]
    if disk in live_disks():
        raise DiskError("это диск загрузочной флешки")
    fresh = make_plan(disk, plan.get("size_bytes", 0), plan.get("model", ""))
    for k in ("mode", "start", "end", "esp"):
        if fresh.get(k) != plan.get(k):
            raise DiskError("состояние диска изменилось после подтверждения (%s)" % k)
    if plan["mode"] == "blank":
        return _apply_blank(disk, say)
    return _apply_free(plan, say)


def _apply_blank(disk, say):
    say("пустой диск %s: создаю GPT, EFI %d МБ и раздел Lucix" % (disk, ESP_MIB))
    run_ok(["sgdisk", "-o", disk])
    run_ok(["sgdisk", "-n", "1:0:+%dM" % ESP_MIB, "-t", "1:EF00", "-c", "1:EFI",
            "-n", "2:0:0", "-t", "2:8300", "-c", "2:Lucix", disk])
    run(["partprobe", disk])
    esp, root = part_node(disk, 1), part_node(disk, 2)
    _wait_node(esp)
    _wait_node(root)
    run_ok(["mkfs.vfat", "-F", "32", "-n", "EFI", esp])
    run_ok(["mkfs.ext4", "-F", "-q", "-L", "Lucix", root])
    return [_entry(root, "/", "ext4", "Lucix", LINUX_GUID),
            _entry(esp, "/boot/efi", "fat32", "EFI", ESP_GUID)]


def _apply_free(plan, say):
    disk, start, end = plan["disk"], plan["start"], plan["end"]
    before = read_table(disk)["partitions"]
    say("таблица разделов до изменений (для восстановления через sfdisk):")
    say(run_ok(["sfdisk", "-d", disk]))
    run(["sgdisk", "--backup=/tmp/lucix-gpt-backup.bin", disk])
    old = {p["node"]: (int(p["start"]), int(p["size"]), str(p.get("type", "")).upper()) for p in before}
    run_ok(["sgdisk", "-n", "0:%d:%d" % (start, end), "-t", "0:8300", "-c", "0:Lucix", disk])
    run(["partprobe", disk])
    run(["udevadm", "settle"])
    after = read_table(disk)["partitions"]
    new = [p for p in after if p["node"] not in old]
    ours = [p for p in new if int(p["start"]) == start and int(p["start"]) + int(p["size"]) - 1 == end]
    if len(new) != 1 or len(ours) != 1:
        raise DiskError("после создания раздела таблица выглядит не так, как ожидалось")
    now = {p["node"]: (int(p["start"]), int(p["size"]), str(p.get("type", "")).upper()) for p in after}
    for node, val in old.items():
        if now.get(node) != val:
            raise DiskError("существующий раздел %s изменился, остановка" % node)
    root = ours[0]["node"]
    _wait_node(root)
    rc, mounted, _ = run(["findmnt", "-rn", "-S", root])
    if rc == 0 and mounted.strip():
        raise DiskError("%s уже смонтирован" % root)
    say("создан раздел %s, форматирую ext4" % root)
    run_ok(["mkfs.ext4", "-F", "-q", "-L", "Lucix", root])
    return [_entry(root, "/", "ext4", "Lucix", LINUX_GUID),
            _entry(plan["esp"], "/boot/efi", "fat32", "EFI", ESP_GUID)]


def write_plan(plan):
    plan = dict(plan, confirmed=True, created=time.time())
    fd = os.open(PLAN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(plan, f)
