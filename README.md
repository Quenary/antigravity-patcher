# antigravity-patcher

Патчер [Google Antigravity](https://antigravity.google/download) для **macOS**, **Linux** и **Windows**. Снимает клиентскую проверку региона у Desktop, standalone IDE, CLI `agy` и VS Code-расширения.

Осознанно не трогает систему: ни DNS, ни hosts, ни прокси. Это не анлокер «под ключ», а патчер файлов клиента.

## Зависимости

- macOS и Linux: `bash` и `perl`, оба штатные в macOS и Ubuntu
- Windows: ничего ставить не нужно, достаточно PowerShell 5.1

## Запуск

macOS и Linux:

```bash
bash ag_patcher.sh
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ag_patcher.ps1
```

## Поддерживаемые команды

Одинаковые у `ag_patcher.sh` и `ag_patcher.ps1`. Имя дописывается к команде запуска.

| Команда | Что делает |
|---|---|
| *(без аргументов)* | меню |
| `patch` | пропатчить найденное |
| `unpatch` | откатить |
| `status` | показать состояние |
| `watch` | тихий цикл в этом терминале |
| `install-watch` | автозапуск при входе |
| `uninstall-watch` | убрать автозапуск |
| `help` | справка (`-h`, `--help`) |

Лишние пути после команды обрабатываются вместо поиска. `AG_ROOT` — дополнительный каталог установки, если поиск его не увидел.

## Сторож

`watch` крутится, пока открыт терминал. `install-watch` включает автозапуск при входе, `uninstall-watch` убирает его.

- Linux — `systemd --user`
- macOS — LaunchAgent
- Windows — задача планировщика текущего пользователя (`ONLOGON`, без прав администратора)

После обновления Antigravity патч затирается. Сторож накатывает его сам, когда файлы меняются. Если файл занят, закрывает только процесс, который его держит, и окно Antigravity или IDE, патчит и снова открывает desktop или IDE. CLI `agy` после патча сам не запускает. VS Code и Cursor не закрывает.

## Что патчится

- нативные бинари `language_server*` / `agy` — `ineligible` → `inexigible` (10 байт, размер файла не меняется)
- Antigravity IDE — JS в `out/main.js` и `extension.js`, если они лежат распакованными

Не являются целями: `Antigravity.exe` (в нём `ineligible` — это строки Chromium) и `app.asar` desktop 2.x (сигнатуры JS там нет).

macOS: после правки бинарь переподписывается ad-hoc (`codesign`), иначе приложение «повреждено». Linux и Windows: достаточно записи в файл.

## Откуда методы

Самостоятельная реализация на bash/perl и PowerShell. Идеи и сигнатуры — из этих проектов:

- [confeden/Antigravity](https://github.com/confeden/Antigravity) — оригинальный анлокер (Windows / Linux, Rust)
- [Asalio123/antigravity-unlocker](https://github.com/Asalio123/antigravity-unlocker) — порт на macOS, Linux и Windows (с DNS-пином, которого здесь нет)

## Disclaimer

Для личного доступа к бесплатному инструменту из региона блокировки. Нарушает условия Google — используйте на свой риск. Это не кряк платных подписок.
