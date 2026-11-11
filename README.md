# PhysBone System V2 — alpha 2.6.6-alpha.1

An experimental secondary-bone system for Figura avatars. The editor is currently in Russian. It is inspired by VRChat PhysBones but does not implement the same formulas or value ranges. Expect bugs and potentially substantial FPS loss; test on a copy of your avatar first.

## Install

1. Install Minecraft and Figura and confirm your avatar already loads. The live test used Minecraft 1.21.11 with NoFigura 0.1.6.9; compatibility with standard Figura or other versions has not been independently verified.
   Give different avatars and test copies distinct `name` values in `avatar.json`: matching names can share and overwrite the same local PhysBone profile.
2. Copy **all Lua files inside `runtime`** to the root of your avatar folder, next to `avatar.json` and the existing scripts. Do not nest the `runtime` folder. Back up any files with the same names before replacing them.
3. Check `avatar.json` **before changing it**. If `autoScripts` exists, add `physics_bone_loader` to that array without removing or reordering existing entries, for example:

   ```json
   "autoScripts": ["script", "physics_bone_loader"]
   ```

   If `autoScripts` is absent, Figura automatically runs every original Lua script. Before installing, record all existing `.lua` paths and include **all of them** in a new `autoScripts` array followed by `physics_bone_loader`. Remove `.lua` and replace folder separators with dots: `libs/animation.lua` becomes `libs.animation`. If the avatar had no scripts, `["physics_bone_loader"]` is enough. Do not add the other PhysBone `runtime` files to the array; the loader imports them. The previous automatic execution order was undefined, so test scripts that depend on ordering. See [Figura's metadata documentation](https://docs.figuramc.org/tutorials/Avatar-Metadata#autoscripts--string).
4. Select/reload the avatar in Figura and open the editor with **F8**. Check Figura's errors and key bindings if it does not open.

## First chain

The model must have separately transformable groups with distinct pivots. A single mesh cannot be turned into a physical chain by this script.

1. In the left Outliner select the first group of a tail or ear and choose **Создать PhysBone** (create PhysBone).
2. Resolve branch choices and, if needed, set **Конечная точка** to the manual endpoint and specify its vector.
3. Choose **Тип** (type) and a **Стартовый профиль** (starter preset), then click **Применить профиль к компоненту** (apply). This replaces the component's settings. Tune the controls gradually; **Подробнее** opens advanced controls and the right panel scrolls.
4. Load the avatar in its usual pose, test motion and your animations, then click **Сохранить** (save). Each ear can use its own component. **Shift + `** toggles bone gizmos.

On the **Производительность** (performance) page, the performance mode reduces simulation quality/work but does not guarantee a high frame rate. Start with one short chain; contacts add cost.

## Collisions and sharing

Contacts are disabled by default. Add and position a sphere or capsule on **Коллайдеры** (colliders), then enable **Физические контакты** and the desired avatar/world/self-contact options for the chain. Body and block tests use chain points, so the middle of a long bone can cross thin obstacles; fast motion and exhausted budgets can miss contacts too.

To bundle your setup with your avatar, choose **Экспортировать профиль v2** in F8, grant Figura File API access if needed, and copy the generated `physics_bone_preset.lua` from `figura/data/PhysicsBoneV2/Characters/…` to the avatar root. Share your avatar with its model, `avatar.json`, PhysBone Lua files and preset. Existing local Figura Config takes precedence; to replace it, choose **Загрузить physics_bone_preset.lua**, review and save. The profile contains paths for that particular model.

To disable the system, remove `physics_bone_loader` from `autoScripts` and reload the avatar. Saved Figura data is not deleted by this action.

This alpha scans one model hierarchy; groups in another top-level model or outside the selected `root` may not appear in the Outliner. The alpha has not been accepted across different rigs, all animations, first-person views, collision cases or profile-transfer workflows. NoFigura reported **456.99 KiB** for the test avatar with this alpha; standard Figura documentation mentions a **100 KB** limit. A locally working avatar may therefore fail to upload to a standard Figura server. Check the final size and upload on your own setup; delivery to other viewers has not been verified. See [Figura's file format documentation](https://docs.figuramc.org/start_here/Avatar%20File%20Format). The simulation is client-side and may differ between viewers. Item/hand attachments, armor and animation authoring are outside this package.

RU--------------------------------------------------------------------------------------------------------------
# PhysBone System V2 — альфа 2.6.6-alpha.1

Физика цепочек для аватаров Figura: хвосты, уши, волосы и другие отдельные группы модели. Это ранняя версия для проб и обратной связи. Она не является копией VRChat PhysBones: похожие ползунки используют другие формулы и числа.

## Что нужно

- Minecraft с работающим модом Figura и аватаром, который уже загружается в Figura. Проверяемая среда разработчика — Minecraft 1.21.11 с NoFigura 0.1.6.9; совместимость с обычной Figura и другими версиями отдельно не проверена.
- Модель с отдельными вращаемыми группами и правильно расположенными pivot для каждого звена. Одна цельная mesh-группа не станет цепью костей.
- Резервная копия аватара: сначала пробуйте систему на копии, а не на единственном оригинале.
- Разным аватарам и их тестовым копиям задавайте разные `name` в `avatar.json`: одинаковые имена могут разделять одно локальное хранилище профиля PhysBone и перезаписать настройки друг друга.

## Установка на свой аватар

1. Распакуйте архив. Скопируйте **все Lua-файлы из папки `runtime`** в корень папки копии аватара, рядом с его `avatar.json` и скриптами. Не копируйте саму папку `runtime` внутрь аватара. Если одноимённые файлы уже существуют, сначала сделайте их резервную копию.
2. Проверьте `avatar.json` **до изменения**:

   - Если `autoScripts` уже есть, добавьте в него `physics_bone_loader`, не меняя остальные записи и их порядок. Например, если уже подключён `script`:

   ```json
   "autoScripts": ["script", "physics_bone_loader"]
   ```

   - Если `autoScripts` **нет**, Figura запускает все имевшиеся Lua-файлы автоматически. Перед установкой запишите пути **всех исходных** `.lua`-файлов аватара; при создании массива перечислите их все, затем `physics_bone_loader`. Имена указываются без `.lua`, вложенные папки отделяются точкой: например, `libs/animation.lua` становится `libs.animation`. Если исходных скриптов не было, достаточно `["physics_bone_loader"]`. Не добавляйте остальные файлы PhysBone из `runtime` в массив: их подключит загрузчик.

   Ранее порядок автоматического запуска не был определён; если старые скрипты зависят от порядка, проверьте их работу после установки. Не создавайте второй `autoScripts`, сохраняйте корректный JSON и остальные поля файла. [Документация Figura об autoScripts](https://docs.figuramc.org/tutorials/Avatar-Metadata#autoscripts--string).
3. Выберите копию в Figura или выполните `/figura reload`. Откройте редактор **F8**. Если F8 не открывается, проверьте список скриптов и ошибки Figura; клавиша может конфликтовать с другими привязками.

## Добавить физику

1. Слева в Outliner выберите группу у основания хвоста или одного уха и нажмите **Создать PhysBone**. Два уха обычно настраиваются отдельными компонентами.
2. При развилке выберите продолжение или режим всех ветвей. Для последнего звена при необходимости переключите **Конечная точка** на ручную и задайте направление и длину.
3. Справа выберите **Тип**, стартовый профиль и нажмите **Применить профиль к компоненту**. Профиль заменяет настройки этого компонента. Меняйте Pull, Spring, Gravity, Gravity Falloff, Immobile, возврат к форме и свободу сгиба постепенно; **Подробнее** открывает остальные параметры. Правая панель прокручивается.
4. Проверяйте обычную позу, ходьбу, повороты и свои анимации. Загрузите аватар в его обычной позе: Gravity Falloff использует начальную ориентацию. Если нужно, сохраните собственную позу покоя через редактор.
5. Нажмите **Сохранить**. Настройки сохраняются локально через Figura Config; они не становятся автоматически частью папки аватара.

**Shift + `** переключает отладочные обозначения звеньев. На странице **Производительность** можно выбрать режим «Производительность»: он снижает качество/частоту некоторых расчётов, но не гарантирует высокий FPS. Начните с одной короткой цепи и добавляйте остальные по одной.

## Столкновения

Физические контакты у новых компонентов выключены. Для столкновений с телом создайте и настройте сферы или капсулы на странице **Коллайдеры**, затем у цепи включите **Физические контакты** и **Коллайдеры аватара**. Блоки мира и самостолкновения включаются отдельно. Проверьте группы и маски. Коллайдер не создаётся автоматически под вашу модель; сложные контакты дополнительно нагружают игру.

Контакты с телом и блоками проверяются в точках цепи: середина длинного звена может проходить через тонкое препятствие. Быстрое движение и ограниченные бюджеты также могут пропускать контакт. Это ограничение альфы.

## Передача настроенного аватара

1. В F8 нажмите **Экспортировать профиль v2** и разрешите Figura File API, если потребуется.
2. Найдите созданный `physics_bone_preset.lua` в `figura/data/PhysicsBoneV2/Characters/…` именно той игровой сборки и положите его в корень папки настроенного аватара рядом со скриптами. Экспорт содержит пути групп конкретной модели и не является универсальной настройкой для других моделей.
3. Передавайте папку аватара с его моделью, `avatar.json`, Lua-модулями PhysBone и этим профилем. Пользователь без локальных настроек получит встроенный профиль. Если у него уже есть локальные настройки для аватара, в F8 нажмите **Загрузить physics_bone_preset.lua**, проверьте и нажмите **Сохранить**.

Чтобы отключить систему, уберите `physics_bone_loader` из `autoScripts` и перезагрузите аватар. Сохранённые данные Figura сами при этом не удаляются.

## Что ещё не готово

- **Производительность — известная проблема.** На тестовом аватаре наблюдалось заметное падение FPS; стоимость зависит от модели, числа звеньев и контактов. На некоторых системах играть может быть некомфортно.
- Поведение на других моделях, всех анимациях, при виде от первого лица и у других зрителей не проверено. Анимированное основание в части режимов может отслеживаться неточно.
- Outliner сейчас сканирует одну иерархию модели. Группы в другой корневой модели или вне выбранной группы `root` могут не появиться; для такой модели может понадобиться перенести нужные группы в одну иерархию и проверить их pivot.
- Коллизии, полный цикл настройки F8 и перенос профилей требуют дополнительных игровых проверок. Физика клиентская; одинаковый результат у всех зрителей не гарантируется.
- Скрипты значительно увеличивают размер аватара. В тесте NoFigura показывала **456,99 KiB** для модели с альфой; документация обычной Figura упоминает ограничение **100 KB**. Поэтому загрузка на стандартный сервер Figura может не пройти, даже если аватар работает локально. Проверьте размер и загрузку в своей сборке: передача другим зрителям пока не подтверждена. [Официальная документация Figura](https://docs.figuramc.org/start_here/Avatar%20File%20Format).
- Текущий выпуск не добавляет крепления предметов к руке и не настраивает броню или анимации.
