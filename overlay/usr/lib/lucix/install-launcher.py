#!/usr/bin/env python3
"""Запуск установщика Lucix: показывает план автоматической установки и просит подтверждение."""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lucixdisk

CAL = "/etc/calamares"
TITLE = "Установка Lucix"


def start(mode):
    try:
        shutil.copyfile("%s/settings.%s.conf" % (CAL, mode), CAL + "/settings.conf")
    except OSError as e:
        print("не удалось выбрать режим %s: %s" % (mode, e), file=sys.stderr)
        mode = "manual"
        try:
            shutil.copyfile(CAL + "/settings.manual.conf", CAL + "/settings.conf")
        except OSError:
            pass
    if mode != "auto":
        try:
            os.unlink(lucixdisk.PLAN_FILE)
        except OSError:
            pass
    os.execvp("calamares", ["calamares"])


def ask(text, ok, cancel, extra=None):
    cmd = ["zenity", "--question", "--width=560", "--title=" + TITLE, "--text=" + text,
           "--ok-label=" + ok, "--cancel-label=" + cancel]
    if extra:
        cmd.append("--extra-button=" + extra)
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode == 0:
        return "ok"
    if extra and extra in p.stdout:
        return "extra"
    return "cancel"


def gib(n):
    return "%d ГБ" % round(n / lucixdisk.GIB)


def main():
    try:
        os.unlink(lucixdisk.PLAN_FILE)
    except OSError:
        pass
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", "-E", sys.executable] + sys.argv)
    if not shutil.which("zenity"):
        start("manual")
    if not lucixdisk.is_efi():
        if ask("Компьютер загружен не в режиме UEFI, автоматическая установка недоступна.\n\nОткрыть установщик с ручной разметкой?",
               "Ручная разметка", "Отмена") == "ok":
            start("manual")
        return
    try:
        plans, reasons = lucixdisk.candidates()
    except Exception as e:
        plans, reasons = [], ["ошибка проверки дисков: %s" % e]
    if not plans:
        why = "\n".join(reasons) or "дисков не найдено"
        if ask("Автоматическая установка недоступна:\n%s\n\nОткрыть установщик с ручной разметкой?" % why,
               "Ручная разметка", "Отмена") == "ok":
            start("manual")
        return
    plan = plans[0]
    disk = "%s (%s, %s)" % (plan["model"] or "диск", plan["disk"], gib(plan["size_bytes"]))
    if plan["mode"] == "blank":
        text = ("Диск: %s\n\nДиск полностью пустой. Будет создана таблица GPT, EFI-раздел 512 МБ "
                "и раздел Lucix (ext4) на всё остальное место.\n\nРаздел подкачки не создаётся."
                % disk)
    else:
        text = ("Диск: %s\n\nБудет создан новый раздел Lucix (ext4) размером %s в свободном месте.\n"
                "Загрузчик встанет в существующий EFI-раздел %s.\n\n"
                "Существующие разделы (Windows и другие) не изменяются и не форматируются.\n"
                "Раздел подкачки не создаётся."
                % (disk, gib(plan["root_bytes"]), plan["esp"]))
    if len(plans) > 1:
        text += "\n\nПодходящих дисков найдено: %d, выбран с самым большим местом." % len(plans)
    r = ask(text, "Установить автоматически", "Отмена", "Ручная разметка")
    if r == "ok":
        lucixdisk.write_plan(plan)
        start("auto")
    elif r == "extra":
        start("manual")


if __name__ == "__main__":
    main()
