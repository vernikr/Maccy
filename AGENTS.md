# AGENTS.md

Правила для агентов, работающих в этом репозитории (Swift/macOS, Xcode-проект). Цель — минимум
циклов сборки и ноль ложных диагнозов.

## Факты о проекте

- Xcode 26.2, `MACOSX_DEPLOYMENT_TARGET = 14.0`, Swift 5 mode, тесты — XCTest.
- Синхронизируемых групп в `project.pbxproj` нет → каждый новый файл регистрируется вручную.
- Сборка: `bash scripts/perf.sh build` — Debug в `.build/`, без подписи; перед сборкой сам запускает
  preflight (валидатор проекта + проверка заглушек). Перф-инструментация: `docs/performance-profiling.md`.
- Проверка ссылок в проекте: `python3 scripts/validate-pbxproj.py` (или `bash scripts/perf.sh validate`).
- Конфигурации: Debug = `-Onone` + условие `DEBUG`; Release = `-O` + `wholemodule`, условия `DEBUG` нет.
  Release-сборка: тот же `xcodebuild` с `-configuration Release`.
- Прогон на копии реальной истории (не трогая данные пользователя):
  `open -n -g -a …/Debug/Maccy.app --env MACCY_PERF=1 --env MACCY_STORAGE_PATH=/tmp/copy.sqlite
  --args enable-testing` (env из `xcodebuild` в тест-хост не пробрасывается, а `open --env` — пробрасывает).
  В Release `#if DEBUG` вырезан, поэтому этот способ там не работает. Живой сценарий и медианы —
  `docs/performance-baseline.md`.

## Грабли → правило

1. **Висячая ссылка в `project.pbxproj`** игнорируется молча. Симптом: тестовый класс не компилируется,
   `Executed 0 tests`, файла нет в сгенерированном `*.SwiftFileList`. Правило: ID в build phase обязан
   совпадать с ID в секции `PBXBuildFile`. Новый файл = четыре записи: `PBXFileReference`,
   `PBXBuildFile`, группа, Sources phase. Проверка — `bash scripts/perf.sh validate`; она находит
   висячие ID (с именем фазы и цели), дубли в фазе, мёртвые записи, ссылки на отсутствующие файлы
   и незакомпилированные `.swift`. `perf.sh build` вызывает её сам и не собирает при ошибке.
2. **`tail` по логу сборки теряет причины ошибок.** Правило: всегда
   `xcodebuild … > /tmp/build.log 2>&1`, диагноз — `grep -n "error:" /tmp/build.log`; `tail` только для статуса.
3. **Фоновые процессы в окружении не работают** (`&` внутри синхронного вызова убивается таймаутом,
   BACKGROUND не поддержан). Правило: сборки/тесты — синхронно, таймаут 600 с,
   `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`.
4. **Трейлинг-замыкание в условии `guard let`/`if let` не компилируется.** Правило:
   `let value = f { … }`, затем `guard let value else { … }`.
5. **Одинаковые `oldString`/`newString` (no-op замена) могут смёржить строки**, удалив перевод строки.
   Правило: никогда не делать no-op правок; после каждой правки перечитывать изменённый участок.
6. **Токены-заглушки в правках** (`…-placeholder`) потом нужно вычищать. Правило: большие вставки —
   перезаписью файла целиком; перед сборкой — `grep -rn "placeholder"` по изменённым файлам.
7. **Сюита тестов падает по средовым причинам**, а не из-за правок: `HistoryItemDecoratorTests` —
   `DateFormatter.date(from:)` возвращает `nil` при locale вида `en_US@rg=…`; `ClipboardTests
   .testIgnoreAllApplicationsExcept` требует Xcode в foreground. Правило: сначала baseline-прогон,
   и не расследовать эти два падения заново.
8. **Флаг проектировать тестируемым сразу** (рантайм-override + сеттер), если на него будут тесты.
9. **Пользовательский инстанс Maccy может быть запущен** и пишет в общее
   `~/Library/Application Support/Maccy/Storage.sqlite`. Правило: перед запуском/тестами —
   `pgrep -lx Maccy`; тесты и сборки запускать через схему, где test plan передаёт `enable-testing`
   (in-memory хранилище и отдельный defaults-suite).
10. **`defaults` по bundle id целится в контейнер установленного сэндбокс-приложения**: `defaults
    read/write/delete org.p0deje.Maccy` меняет **настоящие настройки пользователя**
    (`~/Library/Containers/org.p0deje.Maccy/Data/Library/Preferences/…`), а не домен
    несэндбоксной сборки из `.build`. Правило: для сборок работать по явному пути
    (`defaults write "$HOME/Library/Preferences/org.p0deje.Maccy" key …`), а перед любым `defaults`
    по bundle id — экспорт домена (`defaults export org.p0deje.Maccy /tmp/backup.plist`) и возврат
    через `defaults import`.
11. **Настройки меняют замер.** `popupPosition` (по умолчанию `.cursor`, а не `.statusItem`) сдвигает
    попап к курсору и делает замеры по зонам несравнимыми. Правило: перед сравнением прогонов
    сверять `position=` в `popup.open.firstFrame`, а различающиеся настройки приводить к одному
    значению (и возвращать назад после прогона).

## Порядок работы

1. Разведка до плана: версии (`xcodebuild -version`), цели (`-list`), настройки (deployment target,
   наличие sync-групп), занятые ресурсы (`pgrep -lx Maccy`).
2. Baseline: `xcodebuild test -project Maccy.xcodeproj -scheme Maccy -derivedDataPath .build \
   -destination 'platform=macOS' -only-testing:MaccyTests` — зафиксировать исходные падения.
3. Правки кода, затем правки `project.pbxproj`.
4. Проверка: `bash scripts/perf.sh validate` (0 error) → только потом сборка (`bash scripts/perf.sh build`).
5. Сборка с логом в файл → `grep error:` → тесты (сначала целевой класс, затем вся `MaccyTests`).
