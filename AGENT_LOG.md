# Лог работы агента

Формат: `N.M` — атомарная запись. `Запрос` — что просил пользователь, `Сделано` — результат,
`Предложено` — варианты/рекомендации от агента.

---

## 1. Что было запрошено

1.1. `Запрос`: форкнуть репозиторий https://github.com/p0deje/Maccy в собственный GitHub-аккаунт.

## 2. Что сделано

2.1. Проверена авторизация `gh`: аккаунт `vernikr`, scopes `repo`, `gist`, `read:org`, `admin:public_key`.
2.2. Проверено отсутствие форка: `vernikr/Maccy` не существовал до операции.
2.3. Создан форк: `gh repo fork p0deje/Maccy --clone=false` → https://github.com/vernikr/Maccy
     (публичный, `isFork: true`, parent — `p0deje/Maccy`, default branch `master`).
2.4. Форк склонирован в рабочую директорию проекта (`/Users/vernikr/Downloads/projects/maccy`),
     история развёрнута до полной (`git fetch --unshallow`), подтянуты теги.
2.5. Настроены remote: `origin` → `vernikr/Maccy` (форк), `upstream` → `p0deje/Maccy` (первоисточник).

## 3. Что предложено

3.1. Приватный форк публичного репозитория на GitHub технически невозможен: форки наследуют
     видимость upstream. Альтернатива — «Leave fork network» + смена видимости на private
     (теряется связь с upstream) либо отдельный приватный репозиторий через import/mirror.
     Решение оставляю за пользователем (по умолчанию оставлен обычный публичный форк).
3.2. Варианты дальнейших шагов: рабочая ветка под изменения, синхронизация с `upstream/master`,
     настройка сборки проекта (Xcode/Swift), CI.

## 4. Журнал изменений

4.1. `AGENT_LOG.md` — создан файл лога (текущий).

---

## 5. Что было запрошено

5.1. `Запрос`: проанализировать, как оптимизировать производительность и где добавить профилирующее
     логгирование в трёх местах: (а) появление меню по клику на иконку в статус-баре;
     (б) hover-выделение пунктов (запаздывает за курсором); (в) плавность анимации панели превью.
     Код не менять.

## 6. Что сделано

6.1. Прочитан путь открытия попапа: `AppDelegate.performStatusItemClick` → `Popup` → `FloatingPanel.open`
     (`setContentSize`/`orderFrontRegardless`/`makeKey`), `PopupPosition.origin`.
6.2. Разобран рендер списка: `ContentView`, `HistoryListView`, `MultipleSelectionListView`, `HistoryItemView`,
     `ListItemView`, `ListItemTitleView`, `HoverSelectionModifier`, `MouseMovedViewModifier`.
6.3. Разобран hover-путь: `NavigationManager.selectWithoutScrolling`/`select(id:)`, `selection`/`leadHistoryItem`,
     `HistoryItemDecorator.application`/`accessibilityLabel`, `ColorImage.from`.
6.4. Разобрана анимация превью: `SlideoutController.togglePreview`, `SlideoutView` (layoutDirection/fixedSize/
     readWidth), `SlideoutContentView`, `PreviewItemView`, `AsyncView`, `LargeTextPreviewView`,
     `HistoryItemDecorator.generatePreviewImage`, `HistoryItem.image`, `NSImage.resized`.
6.5. Проверено существующее логгирование: swift-log `Logger` в `History`/`SlideoutController`; signpost/os_signpost
     не используется нигде.
6.6. Отчёт с гипотезами, точками для метрик и вариантами оптимизаций выдан в чат (код не менялся).

## 7. Что предложено

7.1. Меню: убрать двухфазный показ (`popup.height` → `setContentSize`, затем анимированный `verticallyResize`),
     прогреть `NSHostingView` до показа, растеризовать миниатюры заранее в фоне (CGImageSource с subsampling),
     кэшировать `pinnedItems`/`unpinnedItems` вместо 5 фильтров в `HistoryListView.body`.
7.2. Hover: кэшировать деривативы строки (`accessibilityLabel`, `colorSwatchImage`, `application`, `previewableText`),
     заменить линейный поиск по `items` на индекс id→item, отделить «наведение» от `Selection`, не писать
     в `isKeyboardNavigating` на каждое mouse-move, убрать `drawingGroup`/`help` с горячего пути.
7.3. Анимация превью: не флипать `layoutDirection` (явный порядок вставки), один драйвер анимации
     (окно или SwiftUI, не оба), не дёргать `readWidth` во время анимации, фон/офскрин-декодирование превью.
7.4. Логгирование: `os_signpost` (subsystem `org.p0deje.Maccy`, категории `popup`/`hover`/`preview`) +
     Instruments (Points of Interest, Time Profiler, SwiftUI, Animation Hitches), включение по флагу;
     ключевые метрики — время до первого кадра, длительность `History.load`, число layout-проходов/переоценок
     body за кадр, счётчики дорогих вызовов (`NSWorkspace.urlForApplication`, `ColorImage.from`, `previewableText`).
7.5. Решение о переносе отчёта в `docs/` и о реализации метрик/оптимизаций оставлено за пользователем.

---

## 8. Что было запрошено

8.1. `Запрос`: добавить os_signpost-инструментацию по трём зонам (открытие меню, hover,
     анимация превью) с включением по флагу, а также все необходимые инструменты и обвязки,
     чтобы получить замеры до оптимизаций.

## 9. Что сделано

9.1. Ядро `Maccy/Performance/Perf.swift`: флаг (`MACCY_PERF` или preference `perfSignposts`,
     + `Perf.setEnabled(_:)` для тестов/отладчика), зоны `popup|hover|preview|frames`,
     API `begin/end/measure/event/count/record/counted`, часы hover-латентности (`NSEvent.timestamp`).
     Signposts идут в категорию `PointsOfInterest` (видны в Instruments), текстовые строки — в
     `Logger` по зонам.
9.2. `PerfCounters.swift`: потокобезопасная агрегация счётчиков/сумм/длительностей и `describe`.
9.3. `PerfFrameMonitor.swift`: CADisplayLink на контент-вью панели, раз в секунду —
     `fps/hitches/dropped/worst` + сброс счётчиков одним событием `frame.stats`; первый тик = маркер
     первого кадра для пробы.
9.4. `PopupOpenProbe.swift`: сессия открытия (источник, подшаги `setContentSize`/`setFrameOrigin`/
     `orderFrontRegardless`/`makeKey`/`becameKey`, заметки `size/items/wasVisible`) и итог
     `popup.open.firstFrame`; `cancel` при закрытии.
9.5. Хуки в коде: `AppDelegate` (клик/ready), `Popup` (шорткат), `FloatingPanel` (шаги, монитор кадров,
     ресайзы, close), `History` (load/search/pinned/unpinned), `HistoryItemDecorator` и `HistoryItem`
     (application, accessibilityLabel, previewText, hasImage, image/rtf/html, thumbnail/preview),
     `ApplicationImage`, `ColorImage`, `NavigationManager` (lead/didSet, `isKeyboardNavigating` write/no-op),
     `HoverSelectionModifier`, `MouseMovedViewModifier`, `SlideoutController` (toggle/autoOpen),
     `ContentView`/`HistoryListView`/`HistoryItemView`/`ListItemView`/`SlideoutView`/`PreviewItemView`
     (счётчики переоценок body), счётчики строк/иконок.
9.6. Обвязка: `docs/performance-profiling.md` (включение, таблицы метрик по зонам, команды log/xctrace,
     процедура сравнения до/после, оговорки), `scripts/perf.sh` (`on/off/status/stream/build/record`),
     `.gitignore` (+`.build/`), тесты `MaccyTests/PerfInstrumentationTests.swift` (8 тестов на флаг,
     счётчики, интервалы, hover-латентность, жизненный цикл пробы), регистрация файлов в `project.pbxproj`.

## 10. Проверки

10.1. `scripts/perf.sh build`: BUILD SUCCEEDED, новых предупреждений от файлов инструментации нет.
10.2. `xcodebuild test -only-testing:MaccyTests/PerfInstrumentationTests`: 8/8 passed.
10.3. Полная сюита `MaccyTests`: 63 теста, 0 падений среди запущенных; два сбоя в существующих
      тестах признаны средовыми и не связанными с изменениями: `HistoryItemDecoratorTests` падает на
      IUO `firstCopiedAt` из-за locale (`DateFormatter.date(from:)` возвращает nil, воспроизведено вне Maccy),
      `ClipboardTests.testIgnoreAllApplicationsExcept` требует Xcode в foreground.
10.4. Рантайм-проверка (лог тестового хоста): события доходят до лога, например
      `popup.open.firstFrame zone=popup source=unit-test ms=0.19 steps=[…] notes=[items=3]`.

## 11. Что предложено

11.1. Снять замеры по сценарию из `docs/performance-profiling.md` и только потом браться за
      оптимизации (пункты 7.1–7.3).
11.2. По желанию: добавить UI-триггер для флага (сейчас только env/`defaults`), автоматический
      сбор отчёта (`xcrun xctrace export`) и регрессионный прогон по метрикам в CI.

---

## 12. Что было запрошено

12.1. `Запрос`: разобрать историю собственной работы — что помогло, что предотвратило бы ошибки и
      лишние круги, как сократить число шагов. Код не менять.

## 13. Что сделано

13.1. Разбор выдан в чат: три группы полезных подсказок (конвенции репозитория, карта из
      предыдущего анализа, дешёвые разведки среды) и три области нехватки (контракт инструментов,
      правила правок на границах файлов/уникальных ID, базовое состояние тестов и занятых ресурсов).
13.2. Посчитана цена ошибок: 7 вызовов `xcodebuild`, из них ~3 чистых потери (~8–10 минут):
      оборванная фоновая сборка, сборка без видимых ошибок из-за `tail`, два прогона «0 tests»
      из-за висячей ссылки в `project.pbxproj`.

## 14. Что предложено

14.1. Валидатор `project.pbxproj` на висячие ссылки ID (предотвращает немой «0 tests»).
14.2. Локальный `AGENTS.md`/чеклист с правилами: полный лог сборки в файл + `grep error:`;
      никаких no-op замен и токенов-заглушек; трейлинг-замыкание недопустимо в условии
      `guard let`/`if let`; сборки только синхронно; baseline-прогон тестов до правок.
14.3. Зафиксировать в документации известные средовые падения существующих тестов
      (locale-зависимый `DateFormatter`, требование Xcode в foreground для `ClipboardTests`).

---

## 15. Что было запрошено

15.1. `Запрос`: кратко перенести выводы («где потеряны круги», «что бы их предотвратило»,
      «как сократить число шагов») в создаваемый `AGENTS.md`.

## 16. Что сделано

16.1. Создан корневой `AGENTS.md`: факты о проекте, 9 правил «грабли → правило» и порядок работы
      (разведка → baseline тестов → правки → проверка ID в pbxproj → сборка с логом в файл → тесты).
16.2. В `AGENT_LOG.md` добавлены разделы 12–16 по этой переписке.

---

## 17. Что было запрошено

17.1. `Запрос`: написать скрипт-валидатор ссылок в `Maccy.xcodeproj` и вставить его вызов
      в preflight-проверку перед сборкой.

## 18. Что сделано

18.1. `scripts/validate-pbxproj.py`: разбор проекта через `plutil -convert json`, проверки — висячие
      ссылки (с именем фазы и цели), дубли и не-`PBXBuildFile` в фазах, мёртвые `PBXBuildFile`,
      ссылки на отсутствующие файлы на диске (обход дерева групп), `.swift` на диске, который
      не компилируется целью. Коды: 0 — чисто/только warning, 1 — ошибки, 2 — проект не читается.
18.2. `scripts/perf.sh`: добавлены `validate` и `preflight` (валидатор + grep по токенам-заглушкам),
      `build` теперь запускает preflight и не собирает при ошибке; `usage` печатает дословно шапку.
18.3. Документация: `AGENTS.md` (факты, правило 1, шаг 4 порядка работы) и `docs/performance-profiling.md`
      (список подкоманд `perf.sh`).

## 19. Проверки

19.1. На текущем проекте: 0 ошибок, 1 warning — найден реально мёртвый файл upstream
      `Maccy/GlobalHotKey.swift` (нигде не зарегистрирован и никем не используется).
19.2. Негативные сценарии на копии репозитория в `/tmp`: висячий ID в Sources phase → error+exit 1
      с указанием цели; новый незарегистрированный файл → warning; удалённый файл → error.
19.3. Сквозная проверка через `bash scripts/perf.sh build`: битая ссылка в phase блокирует сборку
      (`preflight failed, not building`), токен-заглушка блокирует сборку, чистое состояние →
      BUILD SUCCEEDED. Проект после тестов восстановлен, `git status` чист.
19.4. Первая версия валидатора содержала два бага (обход начинался с объекта проекта вместо
      `mainGroup`; `PBXBuildFile` с `productRef` считался ошибкой) — исправлено до коммита.

## 20. Что предложено

20.1. Опционально: разобраться с мёртвым `Maccy/GlobalHotKey.swift` (удалить или зарегистрировать),
      чтобы preflight был полностью зелёным.
20.2. Опционально: вызывать `validate`/`preflight` из CI или git-hook перед сборкой.
