# Lucix: автоматическая подготовка диска вместо экрана разметки Calamares
import json
import os
import sys
import time

sys.path.insert(0, "/usr/lib/lucix")
import libcalamares


def _say(msg):
    libcalamares.utils.debug("lucixpart: " + str(msg))


def run():
    try:
        import lucixdisk
    except Exception as e:
        return ("Lucix: ошибка модуля", "Не удалось загрузить lucixdisk: %s" % e)
    try:
        with open(lucixdisk.PLAN_FILE) as f:
            plan = json.load(f)
    except Exception:
        return ("Нет плана автоматической установки",
                "Запусти установку ярлыком «Установить Lucix» и подтверди план в окне.")
    if not plan.get("confirmed") or time.time() - float(plan.get("created", 0)) > 6 * 3600:
        return ("План установки не подтверждён", "Запусти установку заново ярлыком «Установить Lucix».")
    libcalamares.job.setprogress(0.1)
    try:
        parts = lucixdisk.apply_plan(plan, _say)
    except lucixdisk.DiskError as e:
        _say("ОШИБКА: %s" % e)
        return ("Автоматическая подготовка диска остановлена",
                "%s\n\nУстановка остановлена. Подробности в журнале установщика." % e)
    except Exception as e:
        _say("НЕОЖИДАННАЯ ОШИБКА: %r" % e)
        return ("Ошибка подготовки диска", "%r\n\nУстановка остановлена. Подробности в журнале." % e)
    try:
        os.unlink(lucixdisk.PLAN_FILE)
    except OSError:
        pass
    gs = libcalamares.globalstorage
    gs.insert("partitions", parts)
    gs.insert("efiSystemPartition", "/boot/efi")
    if gs.value("firmwareType") is None:
        gs.insert("firmwareType", "efi")
    gs.insert("bootLoader", {"installPath": plan["disk"]})
    _say("готово: %s" % ", ".join("%s -> %s" % (p["device"], p["mountPoint"]) for p in parts))
    libcalamares.job.setprogress(1.0)
    return None
