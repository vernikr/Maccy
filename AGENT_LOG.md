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
