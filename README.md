# antigravity-patcher

Патчер [Google Antigravity](https://antigravity.google/download) для **macOS** и **Linux**. Снимает клиентскую проверку региона у Desktop, standalone IDE, CLI `agy` и VS Code-расширения.

Осознанно не трогает систему: ни DNS, ни `/etc/hosts`, ни прокси. Это не анлокер «под ключ», а патчер файлов клиента.

## Что патчится

- нативные бинари `language_server*` / `agy` — `ineligible` → `inexigible` (10 байт, размер файла не меняется)
- Antigravity IDE — JS в `out/main.js` и `extension.js` (гейт «Sorry, this account is ineligible»)

После обновления Antigravity патч затирается — скрипт нужно прогнать снова.

## Запуск

Нужны только `bash` и `perl` (штатные в macOS и Ubuntu).

```bash
bash ag_patcher.sh              # меню
bash ag_patcher.sh patch        # пропатчить всё найденное
bash ag_patcher.sh unpatch      # откатить
bash ag_patcher.sh status       # ничего не менять
```

macOS: после правки бинарь переподписывается ad-hoc (`codesign`), иначе приложение «повреждено». Linux: достаточно записи в файл.

## Откуда методы

Самостоятельная реализация на bash/perl. Идеи и сигнатуры — из этих проектов:

- [confeden/Antigravity](https://github.com/confeden/Antigravity) — оригинальный анлокер (Windows / Linux, Rust)
- [Asalio123/antigravity-unlocker](https://github.com/Asalio123/antigravity-unlocker) — bash-порт на macOS и Linux (с DNS-пином, которого здесь нет)

## Disclaimer

Для личного доступа к бесплатному инструменту из региона блокировки. Нарушает условия Google — используйте на свой риск. Это не кряк платных подписок.
