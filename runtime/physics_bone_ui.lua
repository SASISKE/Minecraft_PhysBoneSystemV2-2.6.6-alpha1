local uiApi = {}
local configApi = require("physics_bone_config")
local worldApi = require("physics_bone_world")
local BUILD_VERSION = "2.6.6"
local COLLISION_GROUPS = { "body", "hair", "ears", "tail", "clothing", "accessories", "custom" }
local COLLISION_GROUP_LABELS = {
  body = "Тело", hair = "Волосы", ears = "Уши", tail = "Хвост",
  clothing = "Одежда", accessories = "Аксессуары", custom = "Своя",
}

local PARAMS = {
  { group = "Движение" },
  { path = "linkControlMode", componentOnly = true, label = "Настройки звеньев", help = "«По костям» применяет индивидуальные силы к выбранной кости. «Совместимость» сохраняет прежнюю привязку настроек сохранённых профилей. Переключение может изменить действие существующих переопределений.", choices = { "bone", "legacy" }, names = { bone = "По костям", legacy = "Совместимость" } },
  { path = "animationTargetMode", label = "Цель анимации", help = "«Анимация» следует текущим ключам; «Гибрид» смешивает их с сохранённой позой, а до калибровки — с нейтральной позой костей Blockbench; «Поза покоя» использует эту опорную позу.", choices = { "animation", "hybrid", "rest" }, names = { animation = "Анимация", hybrid = "Гибрид", rest = "Поза покоя" } },
  { path = "animationInfluence", label = "Влияние анимации", help = "Насколько физическая цель следует текущим ключам: 1 — полностью, ниже — меньше движения от анимации.", min = 0, max = 1, step = 0.05, decimals = 2 },
  { path = "poseFollow", label = "Следование за анимацией", help = "Сила удержания выбранной цели у начала цепи. Влияние ослабевает по длине; минимальный возврат задаётся настройкой «Возврат к форме».", min = 0, max = 1, step = 0.01, decimals = 2 },
  { path = "poseFollowFalloff", label = "Спад по длине цепи", help = "Насколько быстрее ослабевает следование от основания к кончику. 1 — линейно, выше — сильнее освобождает середину и конец.", min = 0, max = 4, step = 0.05, decimals = 2 },
  { path = "pull", label = "Сила следования", help = "Возврат к выбранной физической цели: анимации, гибридной позе или позе покоя. Силу по длине задают следование и возврат к форме.", min = 0, max = 500, step = 0.05, nudge = 1, decimals = 2, curve = 3 },
  { path = "spring", label = "Упругий возврат", help = "Сила упругости к сохранённой форме покоя, перенесённой вместе с основанием цепи. Возврат к форме задаёт минимальное влияние на кончик.", min = 0, max = 24, step = 0.25, decimals = 2 },
  { path = "restShapeReturn", label = "Возврат к форме", help = "Минимальная доля возврата по всей длине, включая кончик. Работает через силу следования и упругий возврат; при нуле кончик свободен.", min = 0, max = 1, step = 0.02, decimals = 2 },
  { path = "bendStiffness", label = "Жёсткость изгиба", help = "Сопротивление изменению естественной кривизны цепи. Это физическая сила изгиба, отдельная от возврата к анимации и от пружины к форме покоя.", min = 0, max = 24, step = 0.25, decimals = 2 },
  { path = "bendStiffnessFalloff", label = "Спад жёсткости к кончику", help = "Уменьшает жёсткость изгиба вдоль цепи. 0 — одинаковая по длине; 1 — плавно ослабевает к кончику; выше — кончик свободнее.", min = 0, max = 4, step = 0.05, decimals = 2 },
  { path = "restitution", label = "Отскок", help = "Сколько скорости сохраняется, когда звено пересекает цель анимации. Это отдельная настройка от пружины и затухания.", min = 0, max = 1, step = 0.02, decimals = 2 },
  { path = "damping", label = "Затухание", help = "Гасит остаточное движение и дрожание; слишком высокое значение делает реакцию вялой.", min = 0, max = 24, step = 0.25, decimals = 2 },
  { path = "mass", label = "Масса", help = "Инерция звена; выше — силам сложнее его разогнать.", min = 0.05, max = 20, step = 0.05, decimals = 2 },
  { path = "tipMass", label = "Масса кончика", help = "Постепенно увеличивает инерцию к концу цепи. Выше — кончик сильнее отстаёт при разгоне и смене направления.", min = 1, max = 6, step = 0.1, decimals = 1, suffix = "×" },
  { path = "rootMotionResponse", label = "Инерция перемещения", help = "Реакция на ускорение игрока при движении.", min = 0, max = 2, step = 0.02, decimals = 2 },
  { path = "motionDrag", label = "Сопротивление среды", help = "Сила сопротивления рассчитывается по движению самого аватара и звеньев через неподвижную среду: при ускорении цепь инерционно отстаёт и вытягивается. Отдельного внешнего воздействия нет. Сопротивление сильнее поперёк звена и слабее вдоль; 0 отключает.", min = 0, max = 2, step = 0.01, decimals = 2 },
  { path = "avatarMotionResponse", label = "Инерция поворота", help = "Реакция звена на ускорение поворота игрока.", min = 0, max = 2, step = 0.02, decimals = 2 },
  { path = "maxLinearSpeed", label = "Макс. скорость", help = "Ограничивает скорость расчётной точки звена.", min = 0, max = 60, step = 0.5, decimals = 1 },
  { group = "Гравитация" },
  { path = "gravitySpace", label = "Кадр гравитации", help = "Мир сохраняет направление вниз; Локально вращает вектор вместе с рамкой цепи.", choices = { "world", "local" }, names = { world = "Мир", ["local"] = "Локально" } },
  { path = "gravity.x", label = "Гравитация X", help = "Сила по X. В режиме «Мир» значения задаются в блоках/с².", min = -40, max = 40, step = 0.25, decimals = 2 },
  { path = "gravity.y", label = "Гравитация Y", help = "Сила по Y. В режиме «Мир» значения задаются в блоках/с².", min = -40, max = 40, step = 0.25, decimals = 2 },
  { path = "gravity.z", label = "Гравитация Z", help = "Сила по Z. В режиме «Мир» значения задаются в блоках/с².", min = -40, max = 40, step = 0.25, decimals = 2 },
  { path = "gravityTiltResponse", label = "Компенсация в покое", help = "В режиме «Мир» уравновешивает постоянную тяжесть в начальной позе, но сохраняет её изменение при наклоне родителя.", min = 0, max = 1, step = 0.02, decimals = 2 },
  { path = "gravityFalloff", label = "Спад гравитации", help = "Ослабляет гравитацию возле анимированной позы.", min = 0, max = 1, step = 0.02, decimals = 2 },
  { group = "Сустав" },
  { path = "joint.type", label = "Тип ограничения", help = "Свободно отключает предел; Конус ограничивает отклонение; Шарнир оставляет вращение вокруг оси.", choices = { "free", "cone", "hinge" }, names = { free = "Свободно", cone = "Конус", hinge = "Шарнир" } },
  { path = "joint.angle", label = "Максимальный угол", help = "Отклонение каждого звена от опорной формы покоя. На длинной цепи изгибы складываются, поэтому малый угол удерживает хвост от закручивания.", min = 0, max = 180, step = 1, decimals = 0 },
  { path = "joint.angularSpeed", label = "Скорость сустава", help = "Ограничивает скорость изменения выходного поворота.", min = 0, max = 720, step = 5, decimals = 0 },
  { path = "joint.axis.x", label = "Ось сустава X", help = "Компоненты оси шарнира; используются при типе «Шарнир».", min = -1, max = 1, step = 0.05, decimals = 2 },
  { path = "joint.axis.y", label = "Ось сустава Y", help = "Компоненты оси шарнира; используются при типе «Шарнир».", min = -1, max = 1, step = 0.05, decimals = 2 },
  { path = "joint.axis.z", label = "Ось сустава Z", help = "Компоненты оси шарнира; используются при типе «Шарнир».", min = -1, max = 1, step = 0.05, decimals = 2 },
  { group = "Столкновения" },
  { path = "collision.enabled", label = "Физические контакты", help = "Включает контакт физичных звеньев с выбранными коллайдерами, другими звеньями и блоками мира.", choices = { false, true }, names = { [false] = "Выкл", [true] = "Вкл" } },
  { path = "collision.avatar", label = "Коллайдеры аватара", help = "Учитывает сферы и капсулы, привязанные к частям модели.", choices = { false, true }, names = { [false] = "Выкл", [true] = "Вкл" } },
  { path = "collision.world", label = "Блоки мира", help = "Столкновение с collision-shape блоков; число проверок ограничено лимитом ниже.", choices = { false, true }, names = { [false] = "Выкл", [true] = "Вкл" } },
  { path = "collision.self", label = "Самостолкновение", help = "Не даёт несоседним звеньям одной цепи проходить друг через друга.", choices = { false, true }, names = { [false] = "Выкл", [true] = "Вкл" } },
  { path = "collision.selfNeighborDepth", label = "Исключить соседей", help = "Сколько рёбер графа исключать из self-collision от каждой точки. 1 исключает только прямо соединённые точки.", min = 0, max = 8, step = 1, decimals = 0 },
  { path = "collision.group", label = "Группа столкновений", help = "Категория этой цепочки для глобальной матрицы взаимодействий.", choices = { "body", "hair", "ears", "tail", "clothing", "accessories", "custom" }, names = { body = "Тело", hair = "Волосы", ears = "Уши", tail = "Хвост", clothing = "Одежда", accessories = "Аксессуары", custom = "Своя" } },
  { path = "collision.radius", label = "Радиус звена", help = "Толщина каждой симулируемой точки в единицах модели.", min = 0.05, max = 16, step = 0.1, decimals = 2 },
  { path = "collision.friction", label = "Трение контакта", help = "Насколько быстро гасит движение вдоль поверхности после удара.", min = 0, max = 1, step = 0.02, decimals = 2 },
  { path = "collision.restitution", label = "Упругость контакта", help = "Доля скорости, возвращаемая при отскоке от поверхности.", min = 0, max = 1, step = 0.02, decimals = 2 },
  { path = "collision.maxBlockQueries", label = "Лимит блоков/тик", help = "Максимум уникальных блоков, читаемых для одной цепи за игровой тик.", min = 0, max = 256, step = 4, decimals = 0 },
  { path = "collision.maxSelfPairs", label = "Лимит пар self", help = "Ограничивает число кандидатных пар при самостолкновении. Пространственная сетка не перебирает всю цепь попарно.", min = 0, max = 16384, step = 256, decimals = 0 },
  { path = "collision.iterations", label = "Итерации контакта", help = "Базовые проходы коллизий и ограничений; при глубоком пересечении возможны дополнительные, всего не более пяти.", min = 1, max = 4, step = 1, decimals = 0 },
  { group = "Конечная точка" },
  { path = "vector.x", label = "Конец X", help = "Смещение ручной конечной точки относительно pivot звена.", endpoint = true, axis = "x", min = -32, max = 32, step = 0.25, decimals = 2 },
  { path = "vector.y", label = "Конец Y", help = "Смещение ручной конечной точки относительно pivot звена.", endpoint = true, axis = "y", min = -32, max = 32, step = 0.25, decimals = 2 },
  { path = "vector.z", label = "Конец Z", help = "Смещение ручной конечной точки относительно pivot звена.", endpoint = true, axis = "z", min = -32, max = 32, step = 0.25, decimals = 2 },
}

local BASIC_PARAMS = {
  { path = "@vrPull", basicField = "vrPull", label = "Pull", help = "Возврат к выбранной позе: больше — сильнее. В нашей физике шкала приблизительная, числа не совпадают с VRChat. Точные силы и цель — в разделе «Подробнее».", min = 0, max = 1, step = 0.01, nudge = 0.05, decimals = 2 },
  { path = "@vrSpring", basicField = "vrSpring", label = "Spring", help = "Колебания: больше — медленнее затухают. Регулятор управляет затуханием нашей физики; его числа не равны VRChat Spring.", min = 0, max = 1, step = 0.01, nudge = 0.05, decimals = 2 },
  { path = "@vrGravity", basicField = "vrGravity", label = "Gravity", help = "Компонента Y тяжести: положительное значение тянет вниз, отрицательное — вверх в выбранном кадре. X и Z сохраняются. Шкала не равна VRChat.", min = -1, max = 1, step = 0.01, nudge = 0.05, decimals = 2 },
  { path = "gravitySpace", label = "Кадр тяжести", help = "«Мир» направляет гравитацию по мировым осям; «Локально» вращает их вместе с цепью. Для Gravity Falloff выбери «Мир».", choices = { "world", "local" }, names = { world = "Мир", ["local"] = "Локально" } },
  { path = "@vrFalloff", basicField = "vrFalloff", label = "Gravity Falloff", help = "1 сохраняет форму в позе при запуске, но позволяет тяжести отклонять цепочку при наклоне родителя. Используй мировую гравитацию и загружай аватар в обычной позе; численная модель отличается от VRChat.", min = 0, max = 1, step = 0.01, nudge = 0.05, decimals = 2 },
  { path = "@vrImmobile", basicField = "vrImmobile", label = "Immobile", help = "Насколько отключить реакцию на движение и поворот: 0 — реагирует сильнее, 1 — не получает этих воздействий. Одновременно меняет инерцию перемещения, поворота и сопротивление среды.", min = 0, max = 1, step = 0.01, nudge = 0.05, decimals = 2 },
  { path = "@restShapeReturn", basicField = "restShapeReturn", label = "Возврат к форме", help = "Больше — цепочка, включая кончик, сильнее возвращается к своей цели после движения. 0% оставляет кончик свободным; точная цель и силы доступны в разделе «Подробнее».", min = 0, max = 100, step = 1, nudge = 5, decimals = 0, suffix = "%" },
  { path = "@jointFreedom", basicField = "jointFreedom", label = "Свобода сгиба", help = "Больше — звено может дальше отклониться от опорной формы покоя. Изменение этого поля у свободного сустава включает ограничение «Конус».", min = 0, max = 100, step = 1, nudge = 5, decimals = 0, suffix = "%" },
}

local COLLIDER_PARAMS = {
  { group = "Форма коллайдера" },
  { path = "enabled", label = "Коллайдер", help = "Включает выбранную сферу или капсулу.", choices = { false, true }, names = { [false] = "Выкл", [true] = "Вкл" }, collider = true },
  { path = "shape", label = "Форма", help = "Сфера или капсула; капсула направлена по заданной локальной оси.", choices = { "sphere", "capsule" }, names = { sphere = "Сфера", capsule = "Капсула" }, collider = true },
  { path = "group", label = "Группа", help = "Категория формы для матрицы столкновений.", choices = { "body", "hair", "ears", "tail", "clothing", "accessories", "custom" }, names = { body = "Тело", hair = "Волосы", ears = "Уши", tail = "Хвост", clothing = "Одежда", accessories = "Аксессуары", custom = "Своя" }, collider = true },
  { path = "radius", label = "Радиус", help = "Радиус формы в единицах модели.", min = 0.05, max = 16, step = 0.1, decimals = 2, collider = true },
  { path = "height", label = "Высота капсулы", help = "Длина средней части капсулы без сферических концов.", min = 0, max = 64, step = 0.25, decimals = 2, collider = true },
  { group = "Позиция и ось" },
  { path = "offset.x", label = "Смещение X", help = "Сдвиг центра относительно pivot выбранной части модели.", min = -32, max = 32, step = 0.25, decimals = 2, collider = true },
  { path = "offset.y", label = "Смещение Y", help = "Сдвиг центра относительно pivot выбранной части модели.", min = -32, max = 32, step = 0.25, decimals = 2, collider = true },
  { path = "offset.z", label = "Смещение Z", help = "Сдвиг центра относительно pivot выбранной части модели.", min = -32, max = 32, step = 0.25, decimals = 2, collider = true },
  { path = "axis.x", label = "Ось X", help = "Направление капсулы в локальных координатах выбранной части.", min = -1, max = 1, step = 0.05, decimals = 2, collider = true },
  { path = "axis.y", label = "Ось Y", help = "Направление капсулы в локальных координатах выбранной части.", min = -1, max = 1, step = 0.05, decimals = 2, collider = true },
  { path = "axis.z", label = "Ось Z", help = "Направление капсулы в локальных координатах выбранной части.", min = -1, max = 1, step = 0.05, decimals = 2, collider = true },
}

local WORLD_PARAMS = {
  { path = "fixedStep", label = "Шаг симуляции", help = "Фиксированный шаг общего решателя в секундах.", min = 0.0083, max = 0.05, step = 0.001, decimals = 4, world = true },
  { path = "maxSubsteps", label = "Шаги за тик", help = "Максимум подшагов симуляции за игровой тик.", min = 1, max = 5, step = 1, decimals = 0, world = true },
  { path = "maxFrameDt", label = "Ограничение кадра", help = "Максимальный dt, принимаемый после задержки кадра.", min = 0.0167, max = 0.25, step = 0.01, decimals = 3, world = true },
  { path = "maxPoints", label = "Бюджет точек", help = "Общий бюджет динамических точек: выше него весь PhysicsWorld синхронно снижает частоту; этот же лимит ограничивает контактные точки.", min = 1, max = 512, step = 1, decimals = 0, world = true },
  { path = "maxCandidatePairs", label = "Бюджет пар", help = "Общий лимит проверок пар за тик: контакты разных цепей и самостолкновения внутри цепей.", min = 0, max = 4096, step = 16, decimals = 0, world = true },
  { path = "contactIterations", label = "Проходы контакта", help = "Проходы разрешения динамических столкновений.", min = 1, max = 4, step = 1, decimals = 0, world = true },
  { path = "constraintPasses", label = "Проходы цепи", help = "Число проходов ограничений длины и суставов на каждом физическом подшаге. Профиль качества выбирает стартовое значение; здесь его можно настроить.", min = 1, max = 12, step = 1, decimals = 0, world = true },
  { path = "maxBlockQueries", label = "Блоков за тик", help = "Единый лимит запросов collision-shape блоков для всех компонентов.", min = 0, max = 256, step = 4, decimals = 0, world = true },
  { path = "segmentMode", label = "Контакт звеньев", help = "Текущий уровень контактов между сегментами разных цепей.", choices = { "point_segment", "segment_segment" }, names = { point_segment = "Точка-сегмент", segment_segment = "Сегмент-сегмент" }, world = true },
}

local PAGES = {
  { id = "overview", label = "Обзор" },
  { id = "components", label = "Компоненты" },
  { id = "colliders", label = "Коллайдеры" },
  { id = "groups", label = "Группы" },
  { id = "physics", label = "Физика" },
  { id = "performance", label = "Производительность" },
  { id = "diagnostics", label = "Диагностика" },
}

local function parameterHelp(path)
  for _, spec in ipairs(BASIC_PARAMS) do
    if spec.path == path then return spec.help end
  end
  for _, spec in ipairs(PARAMS) do
    if spec.path == path then return spec.help end
  end
  for _, spec in ipairs(COLLIDER_PARAMS) do
    if spec.path == path then return spec.help end
  end
  return nil
end

uiApi.parameterHelp = parameterHelp

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local args = { ... }
  local ok, result = pcall(fn, object, (table.unpack or unpack)(args))
  if ok then return result end
  return nil
end

local function splitPath(path)
  local result = {}
  for part in tostring(path):gmatch("[^%.]+") do result[#result + 1] = part end
  return result
end

local function getPath(root, path)
  local value = root
  for _, key in ipairs(splitPath(path)) do
    if type(value) ~= "table" then return nil end
    value = value[key]
  end
  return value
end

local function overrideOwnsSetting(overrides, spec)
  if type(overrides) ~= "table" then return false end
  if spec.basicField == "gravityStrength" then return overrides.gravity ~= nil
  elseif spec.basicField == "gravityTiltResponse" then return overrides.gravityTiltResponse ~= nil
  elseif spec.basicField == "restShapeReturn" then return overrides.restShapeReturn ~= nil
  elseif spec.basicField == "vrPull" then return overrides.pull ~= nil
  elseif spec.basicField == "vrSpring" then return overrides.damping ~= nil
  elseif spec.basicField == "vrGravity" then return overrides.gravity ~= nil
  elseif spec.basicField == "vrFalloff" then return overrides.gravityTiltResponse ~= nil
  elseif spec.basicField == "vrImmobile" then
    return overrides.rootMotionResponse ~= nil or overrides.avatarMotionResponse ~= nil or overrides.motionDrag ~= nil
  elseif spec.basicField == "poseFollow" then
    return overrides.poseFollow ~= nil
  elseif spec.basicField == "motionResponse" then
    return overrides.rootMotionResponse ~= nil or overrides.avatarMotionResponse ~= nil
  elseif spec.basicField == "settling" then return overrides.damping ~= nil
  elseif spec.basicField == "jointFreedom" then
    return type(overrides.joint) == "table"
      and (overrides.joint.angle ~= nil or overrides.joint.type ~= nil)
  end
  return getPath(overrides, spec.path) ~= nil
end

local function setPath(root, path, value)
  local parts, current = splitPath(path), root
  for index = 1, #parts - 1 do
    if type(current[parts[index]]) ~= "table" then current[parts[index]] = {} end
    current = current[parts[index]]
  end
  current[parts[#parts]] = value
end

local function pathPrefix(prefix, path)
  if not prefix or not path or #prefix > #path then return false end
  for index, segment in ipairs(prefix) do
    local other = path[index]
    if not other or segment.name ~= other.name or segment.sameNameIndex ~= other.sameNameIndex then return false end
  end
  return true
end

local function pathKey(path)
  return require("physics_bone_registry").pathKey(path)
end

local function plain(value) return tostring(value or ""):gsub("§.", "") end

local function screenToGui(position, windowSize, scaledSize, fallbackScale)
  if not position then return 0, 0 end
  local x, y = tonumber(position.x) or 0, tonumber(position.y) or 0
  local pixelWidth, pixelHeight = windowSize and tonumber(windowSize.x), windowSize and tonumber(windowSize.y)
  local guiWidth, guiHeight = scaledSize and tonumber(scaledSize.x), scaledSize and tonumber(scaledSize.y)
  local scale = math.max(1, tonumber(fallbackScale) or 1)
  if pixelWidth and pixelWidth > 0 and guiWidth and guiWidth > 0 then x = x * guiWidth / pixelWidth
  else x = x / scale end
  if pixelHeight and pixelHeight > 0 and guiHeight and guiHeight > 0 then y = y * guiHeight / pixelHeight
  else y = y / scale end
  return x, y
end

local function mouseGui()
  local position = safeCall(client, "getMousePos")
  if not position then return 0, 0 end
  local windowSize = safeCall(client, "getWindowSize")
  local scaledSize = safeCall(client, "getScaledWindowSize")
  local scale = safeCall(client, "getGuiScale")
  return screenToGui(position, windowSize, scaledSize, scale)
end

local function textWidth(value)
  local result = safeCall(client, "getTextWidth", plain(value))
  return type(result) == "number" and result or (#plain(value) * 6)
end

local function textLineHeight()
  local single = safeCall(client, "getTextHeight", "A")
  local double = safeCall(client, "getTextHeight", "A\nA")
  if type(single) == "number" and type(double) == "number" and double > single then
    return double - single
  end
  -- Minecraft's default font advances 9 GUI pixels per line.
  return 9
end

local function paddingCount(value, width)
  local missing = math.max(0, (tonumber(width) or 0) - textWidth(value))
  if missing <= 0 then return 0 end
  local spaceWidth = textWidth(" ")
  if type(spaceWidth) ~= "number" or spaceWidth < 1 then spaceWidth = 4 end
  return math.min(256, math.ceil(missing / spaceWidth))
end

local function padRight(value, width)
  value = tostring(value or "")
  return value .. string.rep(" ", paddingCount(value, width))
end

local function padLeft(value, width)
  value = tostring(value or "")
  return string.rep(" ", paddingCount(value, width)) .. value
end

local function truncateToWidth(value, maximumWidth)
  value = plain(value)
  if textWidth(value) <= maximumWidth then return value end
  local result = {}
  for character in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local candidate = table.concat(result) .. character .. "…"
    if textWidth(candidate) > maximumWidth then break end
    result[#result + 1] = character
  end
  return table.concat(result) .. "…"
end

local function finiteNumber(value)
  value = tonumber(value)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function clampValue(spec, value)
  value = finiteNumber(value) or spec.min
  local steps = math.floor((value - spec.min) / spec.step + 0.5)
  local result = spec.min + steps * spec.step
  local scale = 10 ^ (spec.decimals or 0)
  return math.max(spec.min, math.min(spec.max, math.floor(result * scale + 0.5) / scale))
end

local function formatNumber(value, decimals)
  local scale = 10 ^ (decimals or 0)
  value = math.floor((tonumber(value) or 0) * scale + 0.5) / scale
  return string.format("%0." .. tostring(decimals or 0) .. "f", value)
end

local function formatInstructionUsage(stats)
  local used = type(stats) == "table" and finiteNumber(stats.used) or nil
  local limit = type(stats) == "table" and finiteNumber(stats.limit) or nil
  local ratio = type(stats) == "table" and finiteNumber(stats.ratio) or nil
  if not used or not limit or not ratio or limit <= 0 then return "§8API недоступен" end
  return "§f" .. formatNumber(used, 0) .. " / " .. formatNumber(limit, 0)
    .. " §7(" .. formatNumber(ratio * 100, 0) .. "%)"
end

local function appendQualityWarnings(lines, stats, maximumWidth, maximumCount)
  if type(stats) ~= "table" or stats.qualityReduced ~= true then return false end
  lines[#lines + 1] = "§eКачество физики снижено из-за бюджета:"
  local warnings = stats.degradationWarnings or {}
  maximumCount = math.max(1, math.floor(tonumber(maximumCount) or 2))
  local count = math.min(#warnings, maximumCount)
  if count == 0 then
    lines[#lines + 1] = "§eПроверь страницу «Диагностика»."
  else
    for index = 1, count do
      lines[#lines + 1] = "§e• " .. truncateToWidth(tostring(warnings[index]), maximumWidth or 240)
    end
    if #warnings > count then
      lines[#lines + 1] = "§8Ещё причин: " .. tostring(#warnings - count) .. " — см. «Диагностика»."
    end
  end
  return true
end

local function sliderRatio(spec, value)
  local range = math.max(0.000001, spec.max - spec.min)
  local normalized = math.max(0, math.min(1, ((tonumber(value) or spec.min) - spec.min) / range))
  local curve = math.max(1, tonumber(spec.curve) or 1)
  return normalized ^ (1 / curve)
end

local function sliderValue(spec, ratio)
  ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
  local curve = math.max(1, tonumber(spec.curve) or 1)
  return clampValue(spec, spec.min + (spec.max - spec.min) * ratio ^ curve)
end

uiApi.mapSliderRatio = sliderRatio
uiApi.mapSliderValue = sliderValue
uiApi.parameterNudge = function(spec) return tonumber(spec.nudge) or spec.step end

local function nodeMatches(registry, path)
  local key = path and pathKey(path)
  return key and registry and registry.byKey[key] or nil
end

local function currentEffective(component, linkKey)
  if not component then return nil end
  return configApi.effective(component, linkKey)
end

local function componentHasNode(graph, key)
  return graph and graph.linkByKey and graph.linkByKey[key] ~= nil
end

function uiApi.new(registry, draft, callbacks)
  return setmetatable({
    registry = registry, draft = configApi.clone(draft or configApi.defaults()), callbacks = callbacks or {}, open = false,
    revision = 0,
    page = "components",
    visible = false, selectedKey = registry and registry.flat[1] and registry.flat[1].key or nil,
    collapsed = {}, search = "", searchFocused = false, treeOffset = 0, detailsOffset = 0,
    advancedSettings = false,
    graphs = {}, status = "Выбери GROUP и создай компонент PhysBone.",
    diagnosticsData = {},
    hover = nil, dragging = nil, editing = nil, cursorWasUnlocked = nil,
    activeComponentId = nil, colliderMode = false, selectedColliderId = nil, colliderScope = "component",
    groupMode = "matrix", groupMaskTarget = "component",
    presetChoices = {},
    hud = nil, treeText = nil, detailsText = nil, messageText = nil,
    treeRows = {}, settingRows = {}, actionRows = {}, lineHeight = nil,
  }, { __index = uiApi })
end

function uiApi:setRegistry(registry)
  self.registry = registry
  if not (registry and registry.byKey[self.selectedKey]) then self.selectedKey = registry and registry.flat[1] and registry.flat[1].key or nil end
  self:refresh()
end

function uiApi:setDraft(draft, graphs)
  self.draft = configApi.clone(draft or configApi.defaults())
  if graphs then self.graphs = graphs end
  self:refresh()
end

function uiApi:setGraphs(graphs, draft)
  self.graphs = graphs or {}
  if draft then self.draft = configApi.clone(draft) end
  self:refresh()
end

function uiApi:setDiagnostics(data)
  self.diagnosticsData = data or {}
  self:refresh()
end

function uiApi:changed(message, resetComponentId)
  self.revision = (tonumber(self.revision) or 0) + 1
  if message then self.status = message end
  if self.callbacks.changed then self.callbacks.changed(self.draft, resetComponentId) end
  self:refresh()
end

function uiApi:selectedNode()
  return self.registry and self.registry.byKey[self.selectedKey] or nil
end

function uiApi:selection()
  local node = self:selectedNode()
  if node then
    -- Exact roots must win over ancestor graphs so nested PhysBones stay selectable.
    for index, component in ipairs(self.draft.components or {}) do
      local graph = self.graphs[index]
      if #((component.rootPath) or {}) == #(node.path or {}) and pathPrefix(component.rootPath, node.path) then
        return component, index, node.key, graph
      end
    end
    if self.activeComponentId then
      for index, component in ipairs(self.draft.components or {}) do
        if component.id == self.activeComponentId then
          local graph = self.graphs[index]
          if componentHasNode(graph, node.key) or pathPrefix(component.rootPath, node.path) then
            return component, index, node.key, graph
          end
        end
      end
    end
    for index, component in ipairs(self.draft.components or {}) do
      local graph = self.graphs[index]
      if componentHasNode(graph, node.key) then
        return component, index, node.key, graph
      end
      if pathPrefix(component.rootPath, node.path) then
        return component, index, node.key, graph
      end
    end
  end
  if self.activeComponentId then
    for index, component in ipairs(self.draft.components or {}) do
      if component.id == self.activeComponentId then
        return component, index, pathKey(component.rootPath), self.graphs[index]
      end
    end
  end
  return nil
end

function uiApi:selectedCollider()
  if self.colliderScope == "global" and self.selectedColliderId then
    for index, collider in ipairs(self.draft.colliders or {}) do
      if collider.id == self.selectedColliderId then return collider, index, self.draft, "global" end
    end
    return nil
  end
  local component = self:selection()
  if not component or not self.selectedColliderId then return nil end
  for index, collider in ipairs(component.colliders or {}) do
    if collider.id == self.selectedColliderId then return collider, index, component, "component" end
  end
  return nil
end

function uiApi:selectedExclusion()
  local node = self:selectedNode()
  if not node then return nil end
  for componentIndex, component in ipairs(self.draft.components or {}) do
    for excludedIndex, path in ipairs(component.excludedPaths or {}) do
      if #path == #node.path and pathPrefix(path, node.path) then
        return component, componentIndex, excludedIndex
      end
    end
  end
  return nil
end

function uiApi:createVisuals()
  if self.hud then return end
  local ok, root = pcall(function() return models:newPart("PhysBoneV2HUD", "HUD") end)
  if not ok or not root then self.status = "Не удалось создать окно Figura HUD"; return end
  self.hud = root
  self.treeText = safeCall(root, "newText", "PhysBoneV2Outliner")
  self.detailsText = safeCall(root, "newText", "PhysBoneV2Properties")
  self.messageText = safeCall(root, "newText", "PhysBoneV2Message")
  for _, task in ipairs({ self.treeText, self.detailsText, self.messageText }) do
    if task then
      safeCall(task, "setScale", 1)
      safeCall(task, "setOutline", false)
      safeCall(task, "setShadow", true)
      safeCall(task, "setBackground", true)
      safeCall(task, "setBackgroundColor", 0.035, 0.045, 0.06, 0.92)
      safeCall(task, "setOpacity", 0.95)
      safeCall(task, "setSeeThrough", false)
      safeCall(task, "setWrap", false)
    end
  end
end

function uiApi:toggle()
  self.open = not self.open
  if self.open then
    self.cursorWasUnlocked = safeCall(host, "isCursorUnlocked") == true
    safeCall(host, "setUnlockCursor", true)
    self:createVisuals()
    if self.hud then safeCall(self.hud, "setVisible", true) end
    self:refresh()
  else
    if self.hud then safeCall(self.hud, "setVisible", false) end
    safeCall(host, "setUnlockCursor", self.cursorWasUnlocked == true)
    self.cursorWasUnlocked, self.searchFocused, self.dragging, self.editing, self.hover = nil, false, nil, nil, nil
  end
end

function uiApi:visibleNodes()
  local result, needle = {}, string.lower(self.search or "")
  local matched = {}
  local function hasMatch(node)
    if needle == "" then return true end
    if string.find(string.lower(node.name or ""), needle, 1, true) then matched[node.key] = true; return true end
    local any = false
    for _, child in ipairs(node.children or {}) do if hasMatch(child) then any = true end end
    if any then matched[node.key] = true end
    return any
  end
  for _, node in ipairs(self.registry and self.registry.roots or {}) do hasMatch(node) end
  local function append(node)
    if needle ~= "" and not matched[node.key] then return end
    result[#result + 1] = node
    if self.collapsed[node.key] and needle == "" then return end
    for _, child in ipairs(node.children or {}) do append(child) end
  end
  for _, node in ipairs(self.registry and self.registry.roots or {}) do append(node) end
  return result
end

local function basicSettingValue(settings, field)
  settings = type(settings) == "table" and settings or {}
  if field == "gravityStrength" then
    local gravity = settings.gravity or {}
    local magnitude = math.sqrt((tonumber(gravity.x) or 0)^2 + (tonumber(gravity.y) or 0)^2 + (tonumber(gravity.z) or 0)^2)
    return magnitude / 9.81
  elseif field == "gravityTiltResponse" then
    return (tonumber(settings.gravityTiltResponse) or 0) * 100
  elseif field == "restShapeReturn" then
    return (tonumber(settings.restShapeReturn) or 0) * 100
  elseif field == "vrPull" then
    return math.min(1, math.sqrt(math.max(0, tonumber(settings.pull) or 0) / 500))
  elseif field == "vrSpring" then
    return 1 - math.max(0, math.min(24, tonumber(settings.damping) or 0)) / 24
  elseif field == "vrGravity" then
    return math.max(-1, math.min(1, -(tonumber(settings.gravity and settings.gravity.y) or 0) / 40))
  elseif field == "vrFalloff" then
    return math.max(0, math.min(1, tonumber(settings.gravityTiltResponse) or 0))
  elseif field == "vrImmobile" then
    local movement = math.max(0, math.min(2, tonumber(settings.rootMotionResponse) or 0))
    local turning = math.max(0, math.min(2, tonumber(settings.avatarMotionResponse) or 0))
    local drag = math.max(0, math.min(2, tonumber(settings.motionDrag) or 0))
    return 1 - (movement + turning + drag) / 6
  elseif field == "poseFollow" then
    return (tonumber(settings.poseFollow) or 0.30) * 100
  elseif field == "motionResponse" then
    local movement = tonumber(settings.rootMotionResponse) or 0
    local turning = tonumber(settings.avatarMotionResponse) or 0
    return ((movement + turning) * 0.5) * 50
  elseif field == "settling" then
    return (tonumber(settings.damping) or 0) / 24 * 100
  elseif field == "jointFreedom" then
    local joint = settings.joint or {}
    if joint.type == "free" then return 100 end
    return (tonumber(joint.angle) or 180) / 180 * 100
  end
  return nil
end

local function applyBasicSetting(settings, field, value, reference)
  if type(settings) ~= "table" then return false end
  value = tonumber(value)
  if not value then return false end
  reference = type(reference) == "table" and reference or settings
  if field == "gravityStrength" then
    local magnitude = math.max(0, value) * 9.81
    settings.gravity = { x = 0, y = -magnitude, z = 0 }
  elseif field == "gravityTiltResponse" then
    settings.gravityTiltResponse = math.max(0, math.min(100, value)) / 100
  elseif field == "restShapeReturn" then
    settings.restShapeReturn = math.max(0, math.min(100, value)) / 100
  elseif field == "vrPull" then
    local amount = math.max(0, math.min(1, value))
    settings.pull = 500 * amount * amount
  elseif field == "vrSpring" then
    settings.damping = 24 * (1 - math.max(0, math.min(1, value)))
  elseif field == "vrGravity" then
    local gravity = type(reference.gravity) == "table" and reference.gravity or {}
    settings.gravity = { x = tonumber(gravity.x) or 0, y = -40 * math.max(-1, math.min(1, value)), z = tonumber(gravity.z) or 0 }
  elseif field == "vrFalloff" then
    settings.gravityTiltResponse = math.max(0, math.min(1, value))
  elseif field == "vrImmobile" then
    local response = 2 * (1 - math.max(0, math.min(1, value)))
    settings.rootMotionResponse, settings.avatarMotionResponse = response, response
    settings.motionDrag = response
  elseif field == "poseFollow" then
    settings.poseFollow = math.max(0, math.min(100, value)) / 100
  elseif field == "motionResponse" then
    local response = math.max(0, value) * 0.02
    settings.rootMotionResponse, settings.avatarMotionResponse = response, response
  elseif field == "settling" then
    settings.damping = math.max(0, value) * 0.24
  elseif field == "jointFreedom" then
    settings.joint = settings.joint or {}
    local effectiveJoint = reference.joint or settings.joint
    if effectiveJoint.type == "free" and value < 100 then settings.joint.type = "cone" end
    settings.joint.angle = math.max(0, math.min(100, value)) * 1.8
  else
    return false
  end
  return true
end

local function setBasicGravityFrame(settings, frame, reference)
  if type(settings) ~= "table" or (frame ~= "world" and frame ~= "local") then return false end
  reference = type(reference) == "table" and reference or settings
  local strength = basicSettingValue(reference, "gravityStrength")
  settings.gravitySpace = frame
  return applyBasicSetting(settings, "gravityStrength", strength, reference)
end

uiApi.basicSettingValue = basicSettingValue
uiApi.applyBasicSetting = applyBasicSetting
uiApi.overrideOwnsSetting = overrideOwnsSetting
uiApi.setBasicGravityFrame = setBasicGravityFrame

local function settingValue(settings, spec)
  if spec.basicField then return clampValue(spec, basicSettingValue(settings, spec.basicField)) end
  if spec.endpoint then return type(settings) == "table" and settings[spec.axis] or nil end
  return getPath(settings, spec.path)
end

local function appendPageSettings(ui, lines, specs, settings, rightWidth)
  local maxLabelWidth, valueWidth = 0, 5
  for _, spec in ipairs(specs or {}) do
    if spec.group then maxLabelWidth = math.max(maxLabelWidth, textWidth(spec.group))
    else
      maxLabelWidth = math.max(maxLabelWidth, textWidth(spec.label))
      if not spec.choices then
        valueWidth = math.max(valueWidth, textWidth(formatNumber(settingValue(settings, spec) or spec.min, spec.decimals)))
      end
    end
  end
  local labelWidth = math.min(maxLabelWidth, math.max(8, math.floor(rightWidth * 0.34)))
  local controlStart = labelWidth + 2
  local segments = math.max(4, math.min(12, math.floor((rightWidth - controlStart - valueWidth - 11) / math.max(1, textWidth("■")))))
  for _, spec in ipairs(specs or {}) do
    if spec.group then
      lines[#lines + 1] = "§6" .. spec.group
    else
      local value = settingValue(settings, spec)
      if value == nil and not spec.choices then value = spec.min end
      local hoverKind = ui.hover and ui.hover.path == spec.path and ui.hover.kind or nil
      local controls, bounds = nil, nil
      if spec.choices then
        local label = spec.names[value] or tostring(value)
        controls = (hoverKind == "choice" and "§b" or "§8") .. "[‹] §f" .. label .. " §8[›]"
        bounds = { choiceStart = controlStart, choiceEnd = controlStart + textWidth(controls) }
      else
        local number = tonumber(value) or spec.min
        local ratio = sliderRatio(spec, number)
        local filled = math.max(0, math.min(segments, math.floor(ratio * segments + 0.5)))
        local minusStart = controlStart
        local valueStart = minusStart + textWidth("[−] ")
        local plusStart = valueStart + valueWidth + textWidth(" [+] ")
        local trackStart = plusStart + textWidth("[+] [")
        local trackEnd = trackStart + segments * textWidth("■")
        controls = (hoverKind == "minus" and "§b" or "§8") .. "[−] "
          .. (hoverKind == "value" and "§b" or "§f") .. padLeft(formatNumber(number, spec.decimals), valueWidth)
          .. " " .. (hoverKind == "plus" and "§b" or "§a") .. "[+] "
          .. (hoverKind == "slider" and "§a" or "§b") .. "[" .. string.rep("■", filled)
          .. string.rep("·", segments - filled) .. "]"
        bounds = { minusStart = minusStart - 1, minusEnd = valueStart - 1,
          valueStart = valueStart, valueEnd = valueStart + valueWidth,
          plusStart = valueStart + valueWidth + 1, plusEnd = trackStart - 1,
          sliderStart = trackStart, sliderEnd = trackEnd, sliderHitStart = trackStart - 1, sliderHitEnd = trackEnd + 1 }
      end
      local label = padRight(truncateToWidth(spec.label, labelWidth), labelWidth)
      lines[#lines + 1] = (ui.hover and ui.hover.path == spec.path and "§b" or "§f") .. label .. " §r" .. controls
      local row = { spec = spec, settings = settings, line = #lines,
        choiceStart = bounds.choiceStart or controlStart, choiceEnd = bounds.choiceEnd or controlStart,
        minusStart = bounds.minusStart or controlStart, minusEnd = bounds.minusEnd or controlStart,
        valueStart = bounds.valueStart or controlStart, valueEnd = bounds.valueEnd or controlStart,
        plusStart = bounds.plusStart or controlStart, plusEnd = bounds.plusEnd or controlStart,
        sliderStart = bounds.sliderStart or controlStart, sliderEnd = bounds.sliderEnd or controlStart,
        sliderHitStart = bounds.sliderHitStart or controlStart, sliderHitEnd = bounds.sliderHitEnd or controlStart }
      ui.settingRows[#ui.settingRows + 1] = row
    end
  end
end

function uiApi:writeSetting(spec, value)
  local component, _, linkKey = self:selection()
  if spec.world then
    self.draft.world = self.draft.world or {}
    if spec.path == "performance" then
      local profile = worldApi.performanceOptions(value)
      for key, profileValue in pairs(profile) do
        if key ~= "performance" then self.draft.world[key] = profileValue end
      end
      self.draft.world.performance = profile.performance
    else
      setPath(self.draft.world, spec.path, value)
    end
    self:changed("Настройка PhysicsWorld изменена; нажми «Сохранить».")
    return
  end
  if spec.collider then
    local collider = self:selectedCollider()
    if not collider then return end
    setPath(collider, spec.path, value)
    self:changed("Параметр коллайдера изменён; нажми «Сохранить».")
    return
  end
  if not component then return end
  if spec.endpoint then
    component.endpoint = component.endpoint or { mode = "manual", vector = { x = 0, y = -1, z = 0 } }
    component.endpoint.mode = "manual"
    component.endpoint.vector = component.endpoint.vector or { x = 0, y = -1, z = 0 }
    component.endpoint.vector[spec.axis] = value
    self:changed("Конечная точка обновлена.")
    return
  end
  local override = self.linkOverride == true and not spec.componentOnly
  local target
  if override then
    component.linkOverrides = component.linkOverrides or {}
    component.linkOverrides[linkKey] = component.linkOverrides[linkKey] or {}
    target = component.linkOverrides[linkKey]
    if spec.path:match("^joint%.axis%.") then
      local effective = configApi.effective(component, linkKey)
      target.joint = target.joint or {}
      target.joint.axis = configApi.clone(effective.joint.axis)
    end
  else
    component.settings = component.settings or configApi.defaultsForComponent(component.rootPath).settings
    target = component.settings
  end
  if spec.basicField then
    local effective = configApi.effective(component, linkKey)
    applyBasicSetting(target, spec.basicField, value, effective)
  else
    setPath(target, spec.path, value)
  end
  self:changed("Настройка изменена; нажми «Сохранить» для постоянного профиля.")
end

function uiApi:adjustParameter(row, value)
  local spec = row.spec
  if spec.choices then
    local current = settingValue(row.settings, spec)
    local selected = 1
    for index, choice in ipairs(spec.choices) do if choice == current then selected = index; break end end
    local nextIndex = ((selected - 1 + value) % #spec.choices) + 1
    self:writeSetting(spec, spec.choices[nextIndex])
  else
    local current = tonumber(settingValue(row.settings, spec)) or spec.min
    self:writeSetting(spec, clampValue(spec, current + value * (tonumber(spec.nudge) or spec.step)))
  end
end

function uiApi:toggleOverride()
  local component, _, linkKey = self:selection()
  if not component then return end
  component.linkOverrides = component.linkOverrides or {}
  if component.linkOverrides[linkKey] then
    component.linkOverrides[linkKey] = nil
    self.linkOverride = false
    self:changed("Звено снова наследует значения компонента.")
  else
    component.linkOverrides[linkKey] = {}
    self.linkOverride = true
    self:changed("Для выбранного звена включены отдельные переопределения.")
  end
end

function uiApi:createComponent()
  local node = self:selectedNode()
  if not node or not node.transformable then self.status = "Выбери трансформируемую GROUP ModelPart."; self:refresh(); return end
  for _, component in ipairs(self.draft.components or {}) do
    if pathPrefix(component.rootPath, node.path) or pathPrefix(node.path, component.rootPath) then
      self.status = "Компонент уже пересекается с выбранной частью модели."; self:refresh(); return
    end
  end
  local component = configApi.defaultsForComponent(node.path, node.name .. " PhysBone")
  self.draft.components[#self.draft.components + 1] = component
  self.activeComponentId = component.id
  self.selectedColliderId = nil
  self.colliderMode = false
  self.linkOverride = false
  self:changed("Создан компонент " .. node.name .. ". Проверь звенья справа и сохрани.")
end

function uiApi:selectedPresetChoice(component)
  if not component then return nil end
  local presets = configApi.presetsForKind(component.kind)
  local selected = self.presetChoices[component.id] or component.presetId
  for _, preset in ipairs(presets) do if preset.id == selected then return preset.id end end
  return presets[1] and presets[1].id or nil
end

function uiApi:cycleComponentKind(direction)
  local component = self:selection()
  if not component then return false end
  local kinds = configApi.componentKinds()
  local index = 1
  for candidate, kind in ipairs(kinds) do if kind.id == component.kind then index = candidate; break end end
  index = ((index - 1 + (tonumber(direction) or 1)) % #kinds) + 1
  component.kind = kinds[index].id
  component.settings = component.settings or {}
  component.settings.collision = component.settings.collision or {}
  component.settings.collision.group = component.kind
  local presets = configApi.presetsForKind(component.kind)
  self.presetChoices[component.id] = presets[1] and presets[1].id or nil
  self:changed("Тип компонента: " .. kinds[index].label .. ". Выбери стартовый профиль и примени его при необходимости.")
  return true
end

function uiApi:cycleComponentPreset(direction)
  local component = self:selection()
  if not component then return false end
  local presets = configApi.presetsForKind(component.kind)
  if #presets == 0 then
    self.status = "Для этого типа нет стартовых профилей; настрой параметры вручную."
    self:refresh()
    return false
  end
  local selected = self:selectedPresetChoice(component)
  local index = 1
  for candidate, preset in ipairs(presets) do if preset.id == selected then index = candidate; break end end
  index = ((index - 1 + (tonumber(direction) or 1)) % #presets) + 1
  self.presetChoices[component.id] = presets[index].id
  self.status = "Выбран профиль «" .. presets[index].label .. ". Нажми «Применить профиль», чтобы заменить базовые параметры компонента."
  self:refresh()
  return true
end

function uiApi:applyComponentPreset()
  local component = self:selection()
  local presetId = self:selectedPresetChoice(component)
  if not component or not presetId then
    self.status = "Для выбранного типа нет стартового профиля."
    self:refresh()
    return false
  end
  local ok, label = configApi.applyPreset(component, presetId)
  if not ok then self.status = label; self:refresh(); return false end
  self:changed("Применён стартовый профиль «" .. label .. ". Параметры можно менять отдельно.")
  return true
end

function uiApi:removeComponent()
  local component, index = self:selection()
  if not index then self.status = "Выбери корень назначенного компонента."; self:refresh(); return end
  table.remove(self.draft.components, index)
  if component and component.id == self.activeComponentId then
    self.activeComponentId, self.selectedColliderId, self.colliderMode = nil, nil, false
  end
  self:changed("Компонент удалён из черновика. Нажми «Сохранить» для подтверждения.")
end

function uiApi:createCollider()
  local node = self:selectedNode()
  local component = self:selection()
  if not node or not node.transformable then self.status = "Коллайдер можно привязать только к трансформируемой GROUP."; self:refresh(); return end
  local id = pathKey(node.path)
  local useGlobal = self.page == "colliders"
  if not useGlobal and not component then
    self.status = "На странице «Коллайдеры» форма станет общей для всех компонентов."
    self.page = "colliders"
    self:refresh()
    return
  end
  local owner = useGlobal and self.draft or component
  owner.colliders = owner.colliders or {}
  for _, collider in ipairs(owner.colliders) do
    if collider.id == id then
      self.selectedColliderId, self.colliderMode = collider.id, true
      self.colliderScope = useGlobal and "global" or "component"
      self.status = "Коллайдер этой части уже есть; выбрана его настройка."
      self:refresh()
      return
    end
  end
  owner.colliders[#owner.colliders + 1] = {
    id = id, path = configApi.clone(node.path), enabled = true, shape = "sphere",
    group = "body", mask = {},
    offset = { x = 0, y = 0, z = 0 }, axis = { x = 0, y = 1, z = 0 },
    radius = 1.5, height = 4,
  }
  if component then self.activeComponentId = component.id end
  self.colliderScope = useGlobal and "global" or "component"
  self.selectedColliderId, self.colliderMode = id, true
  self:changed("Добавлена сфера-коллайдер на " .. node.name .. ". Настрой её справа и сохрани.")
end

function uiApi:removeCollider()
  local collider, index, owner = self:selectedCollider()
  if not collider or not index or not owner then return end
  table.remove(owner.colliders, index)
  self.selectedColliderId = nil
  self.colliderMode = false
  self:changed("Коллайдер удалён из черновика; нажми «Сохранить».")
end

function uiApi:toggleComponent()
  local component = self:selection()
  if not component then return end
  component.enabled = component.enabled == false
  self:changed(component.enabled and "Компонент включён." or "Компонент выключен; смещения сбросятся.")
end

function uiApi:toggleBranches()
  local component = self:selection()
  if not component then return end
  component.branchMode = component.branchMode == "all" and "selected" or "all"
  component.branchChoices = {}
  self:changed("Обработка ветвей: " .. (component.branchMode == "all" and "все ветви" or "одна выбранная ветвь") .. ".")
end

function uiApi:resetComponent()
  local component = self:selection()
  if not component then return end
  component.settings = configApi.defaultsForComponent(component.rootPath).settings
  component.linkOverrides = {}
  self:changed("Стартовые настройки применены; отдельные настройки звеньев удалены.", component.id)
end

function uiApi:resetLink()
  local component, _, linkKey = self:selection()
  if not component or not linkKey then return end
  if not component.linkOverrides or not component.linkOverrides[linkKey] then
    self.status = "У этого звена нет отдельных настроек для сброса."
    self:refresh()
    return
  end
  component.linkOverrides[linkKey] = nil
  self.linkOverride = false
  self:changed("Настройки звена сброшены; оно наследует значения компонента.")
end

function uiApi:settingsForSelected()
  local component, _, linkKey = self:selection()
  if not component then return nil, nil, nil, false end
  local override = component.linkOverrides and component.linkOverrides[linkKey]
  local settings = currentEffective(component, linkKey)
  return settings, component, linkKey, override ~= nil
end

function uiApi:refresh()
  if not self.open then return end
  self:createVisuals()
  if not self.hud then return end
  local size = safeCall(client, "getScaledWindowSize")
  local width = size and tonumber(size.x) or 427
  local height = size and tonumber(size.y) or 240
  self.lineHeight = math.max(1, tonumber(textLineHeight()) or 9)
  local line = self.lineHeight
  local panelWidth = math.max(250, math.min(620, width - 16))
  local panelHeight = math.max(160, height - 14)
  local leftWidth = math.max(104, math.min(190, math.floor(panelWidth * 0.36)))
  local rightWidth = panelWidth - leftWidth - 8
  self.layout = { x = 8, y = 7, width = panelWidth, height = panelHeight, leftWidth = leftWidth, rightWidth = rightWidth }
  safeCall(self.treeText, "setPos", -self.layout.x, -self.layout.y, 0)
  safeCall(self.detailsText, "setPos", -(self.layout.x + leftWidth + 8), -self.layout.y, -0.1)
  safeCall(self.treeText, "setWidth", leftWidth)
  safeCall(self.detailsText, "setWidth", rightWidth)

  local visible = self:visibleNodes()
  local maxTreeRows = math.max(1, math.floor((panelHeight / line) - 9))
  self.treeOffset = math.max(0, math.min(self.treeOffset, math.max(0, #visible - maxTreeRows)))
  local treeLines = { "§6PhysBone v" .. BUILD_VERSION .. " — Outliner", (self.hover and self.hover.kind == "search" and "§b" or "§7") .. "Поиск: §f" .. (self.searchFocused and "▏" or "") .. self.search }
  self.treeRows = {}
  for index = self.treeOffset + 1, math.min(#visible, self.treeOffset + maxTreeRows) do
    local node = visible[index]
    local isSelected = node.key == self.selectedKey
    local component = false
    for _, graph in ipairs(self.graphs or {}) do if componentHasNode(graph, node.key) then component = true; break end end
    local hasChildren = #(node.children or {}) > 0
    local hovered = self.hover and self.hover.kind == "tree" and self.hover.key == node.key
    local arrow = hasChildren and (self.collapsed[node.key] and "▸" or "▾") or "·"
    local color = hovered and "§b" or (isSelected and "§e" or "§7")
    local indent = string.rep(" ", math.min(18, node.depth * 2))
    treeLines[#treeLines + 1] = color .. indent .. arrow .. " " .. node.name .. (component and " §a●" or "") .. "§r"
    self.treeRows[#self.treeRows + 1] = { node = node, hasChildren = hasChildren, line = #treeLines }
    local row = self.treeRows[#self.treeRows]
    row.disclosureStart = math.max(0, textWidth(indent) - 1)
    row.disclosureEnd = row.disclosureStart + textWidth(arrow) + 2
  end
  while #treeLines < math.floor(panelHeight / line) - 4 do treeLines[#treeLines + 1] = "" end
  treeLines[#treeLines + 1] = "§8────────────────"
  local assignLabel = "§aСоздать компонент"
  local component, componentIndex, linkKey, graph = self:selection()
  local isGroup = self:selectedNode() and self:selectedNode().transformable
  treeLines[#treeLines + 1] = (isGroup and "§a" or "§8") .. "Создать PhysBone"
  treeLines[#treeLines + 1] = (component and "§c" or "§8") .. "Удалить компонент"
  treeLines[#treeLines + 1] = (isGroup and (component or self.page == "colliders") and "§b" or "§8") .. "Добавить коллайдер"
  treeLines[#treeLines + 1] = "§7F8 — закрыть"
  if self.treeText then safeCall(self.treeText, "setText", table.concat(treeLines, "\n")) end
  self.actionRows = { create = #treeLines - 3, remove = #treeLines - 2, collider = #treeLines - 1, close = #treeLines }

  local briefStatus = tostring((self.hover and self.hover.path and parameterHelp(self.hover.path)) or self.status or "")
  briefStatus = truncateToWidth(briefStatus, math.max(96, rightWidth / 0.45))
  local detailLines = { "§6Physics Bone System v" .. BUILD_VERSION, "§7Выбранный узел: §f" .. (self:selectedNode() and self:selectedNode().name or "—"),
    "§8" .. briefStatus }
  self.settingRows = {}
  self.colliderRows = {}
  self.branchRows = {}
  self.groupRows = {}
  self.filterRows = {}
  self.pairRows = {}
  self.detailActions = {}
  local pageIndex = 1
  for index, page in ipairs(PAGES) do if page.id == self.page then pageIndex = index; break end end
  local currentPage = PAGES[pageIndex]
  detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "page-nav" and "§b" or "§e")
    .. "[‹] §f" .. currentPage.label .. " §e[›]"
  self.detailActions.pageNav = #detailLines
  if self.page == "components" and component then
    local selectedNode = self:selectedNode()
    local partPath = selectedNode and table.concat((function()
      local parts = {}; for _, segment in ipairs(selectedNode.path or {}) do parts[#parts + 1] = segment.name end; return parts
    end)(), "/") or "—"
    detailLines[#detailLines + 1] = "§8" .. partPath
    local hoveredEnable = self.hover and self.hover.kind == "component-enabled"
    detailLines[#detailLines + 1] = (hoveredEnable and "§b" or "§e") .. "Компонент: " .. (component.enabled == false and "ВЫКЛ" or "ВКЛ") .. " [клик]"
    self.detailActions.enabled = #detailLines
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "component-kind" and "§b" or "§e")
      .. "Тип: " .. configApi.componentKindLabel(component.kind) .. " [сменить]"
    self.detailActions.componentKind = #detailLines
    local componentPresets = configApi.presetsForKind(component.kind)
    local selectedPresetId = self:selectedPresetChoice(component)
    local selectedPresetLabel = "нет профиля"
    for _, preset in ipairs(componentPresets) do
      if preset.id == selectedPresetId then selectedPresetLabel = preset.label; break end
    end
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "component-preset" and "§b" or (#componentPresets > 0 and "§e" or "§8"))
      .. "Стартовый профиль: " .. selectedPresetLabel .. (#componentPresets > 0 and " [выбрать]" or "")
    self.detailActions.componentPreset = #componentPresets > 0 and #detailLines or nil
    if #componentPresets > 0 then
      detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "apply-component-preset" and "§b" or "§a")
        .. "Применить профиль к компоненту"
      self.detailActions.applyComponentPreset = #detailLines
    else self.detailActions.applyComponentPreset = nil end
    detailLines[#detailLines + 1] = "§7Звеньев: " .. tostring(graph and #graph.links or 0)
      .. " | ветви: " .. (component.branchMode == "all" and "все" or "выбранные") .. " [перекл.]"
    self.detailActions.branches = #detailLines
    if graph and graph.errors and graph.errors[1] then detailLines[#detailLines + 1] = "§c" .. graph.errors[1]
    elseif graph and graph.branches and graph.branches[1] then detailLines[#detailLines + 1] = "§eЕсть развилки: выбери режим «все ветви»"
    elseif graph then detailLines[#detailLines + 1] = "§aГраф цепи разрешён" end
    if component.branchMode ~= "all" and graph and graph.branches and graph.branches[1] then
      local branch = graph.branches[1]
      detailLines[#detailLines + 1] = "§6Выбери продолжение ветви:"
      for candidateIndex, candidate in ipairs(branch.candidates or {}) do
        if candidateIndex > 8 then break end
        local selected = component.branchChoices and component.branchChoices[branch.parentKey] == candidate.key
        detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "branch-choice" and self.hover.key == candidate.key and "§b"
          or (selected and "§a" or "§f")) .. "  → " .. candidate.name .. " [выбрать]"
        self.branchRows[#self.branchRows + 1] = { line = #detailLines, parentKey = branch.parentKey, key = candidate.key }
      end
      if #branch.candidates > 8 then detailLines[#detailLines + 1] = "§8Ещё варианты: переключи режим на все ветви." end
    end
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "endpoint-mode" and "§b" or "§e")
      .. "Конечная точка: " .. ((component.endpoint and component.endpoint.mode == "manual") and "ручная" or "дочерний pivot") .. " [перекл.]"
    self.detailActions.endpointMode = #detailLines
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "capture-rest-pose" and "§b" or "§e")
      .. (component.restPose and "Перекалибровать позу покоя" or "Сохранить позу покоя")
      .. " [в нейтральной позе]"
    self.detailActions.captureRestPose = #detailLines
    detailLines[#detailLines + 1] = "§8Без сохранения временная опора берётся при запуске аватара."
    local settings, _, _, hasOverride = self:settingsForSelected()
    local defaultSettings = configApi.defaultsForComponent(component.rootPath).settings
    self.linkOverride = hasOverride
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "override" and "§b" or "§e")
      .. "Переопределения звена: " .. (hasOverride and "ВКЛ" or "наследование") .. " [перекл.]"
    self.detailActions.override = #detailLines
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "exclude-link" and "§b" or "§e")
      .. (pathKey(component.rootPath) == linkKey and "Корень нельзя исключить из компонента" or "Исключить выбранное звено из физики")
    self.detailActions.exclude = pathKey(component.rootPath) ~= linkKey and #detailLines or nil
    local selectedCollider = self:selectedCollider()
    local colliderCount = #(component.colliders or {})
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "collider-mode" and "§b" or "§e")
      .. "Коллайдеры: " .. tostring(colliderCount) .. (self.colliderMode and " [к настройкам физики]" or " [редактировать]")
    self.detailActions.colliderMode = #detailLines
    if colliderCount == 0 then
      detailLines[#detailLines + 1] = "§8Слева выбери GROUP и нажми «Добавить коллайдер»."
    else
      for _, collider in ipairs(component.colliders) do
        local node = nodeMatches(self.registry, collider.path)
        local label = node and node.name or "путь не найден"
        local selected = self.selectedColliderId == collider.id and self.colliderMode
        detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "collider-row" and self.hover.id == collider.id and "§b"
          or (selected and "§a" or "§f")) .. "  " .. label .. " · " .. (collider.shape == "capsule" and "капсула" or "сфера")
          .. (collider.enabled == false and " §8ВЫКЛ" or " §aВКЛ")
        self.colliderRows[#self.colliderRows + 1] = { line = #detailLines, id = collider.id, scope = "component" }
      end
    end
    if self.colliderMode and selectedCollider then
      detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "remove-collider" and "§b" or "§c") .. "Удалить выбранный коллайдер"
      self.detailActions.removeCollider = #detailLines
    end
    if self.draft.diagnostics then
      detailLines[#detailLines + 1] = "§6Диагностика"
      local componentData = self.diagnosticsData[component.id]
      local selectedLink = graph and graph.linkByKey and graph.linkByKey[linkKey]
      local linkDiagnostic = componentData and selectedLink and componentData.links and componentData.links[selectedLink.index]
      if linkDiagnostic then
        detailLines[#detailLines + 1] = string.format("§7Отклонение %.1f° | скорость %.1f°/с",
          tonumber(linkDiagnostic.angleDegrees) or 0, tonumber(linkDiagnostic.speedDegrees) or 0)
        local gravity = linkDiagnostic.gravityInParent
        if type(gravity) == "table" then
          detailLines[#detailLines + 1] = "§7Гравитация в кадре цепи: "
            .. formatNumber(gravity.x or 0, 1) .. ", "
            .. formatNumber(gravity.y or 0, 1) .. ", "
            .. formatNumber(gravity.z or 0, 1)
        end
      else
        detailLines[#detailLines + 1] = "§8Нет данных для выбранного звена."
      end
      detailLines[#detailLines + 1] = "§7Мировой кадр: " .. ((componentData and componentData.gravityFrameAvailable) and "§aдоступен" or "§cнет")
    end
    local editingCollider = self.colliderMode and selectedCollider
    detailLines[#detailLines + 1] = editingCollider and "§6Форма коллайдера" or "§6Настройки физики"
    if not editingCollider then
      local modeHovered = self.hover and self.hover.kind == "settings-mode"
      detailLines[#detailLines + 1] = (modeHovered and "§b" or "§e")
        .. (self.advancedSettings and "Точные настройки [Основные]" or "Основные настройки [Подробнее]")
      self.detailActions.settingsMode = #detailLines
      if not self.advancedSettings then
        detailLines[#detailLines + 1] = "§8Настрой форму в покое и реакцию на движение выбранной цепочки."
      end
    end
    local paramRows = {}
    local section = ""
    local parameterList = editingCollider and COLLIDER_PARAMS
      or (self.advancedSettings and PARAMS or BASIC_PARAMS)
    local parameterSettings = editingCollider and selectedCollider or settings
    for _, spec in ipairs(parameterList) do
      if spec.group then
        section = spec.group
      else
        paramRows[#paramRows + 1] = { spec = spec, settings = parameterSettings, section = section }
      end
    end
    local maxParamRows = #paramRows
    local labelNaturalWidth, valueColumnWidth = 0, 30
    local markerWidth = math.max(textWidth("●"), textWidth("○"))
    local columnGap, controlGap = textWidth(" "), textWidth(" ")
    local minusWidth, plusWidth = textWidth("[−]"), textWidth("[+]")
    local bracketWidth, cellWidth = textWidth("["), math.max(3, textWidth("■"))
    for _, row in ipairs(paramRows) do
      local spec = row.spec
      if not (spec.endpoint and component.endpoint and component.endpoint.mode ~= "manual") then
        labelNaturalWidth = math.max(labelNaturalWidth, textWidth(spec.label))
        if not spec.choices then
          local minimum = formatNumber(spec.min, spec.decimals) .. (spec.suffix or "")
          local maximum = formatNumber(spec.max, spec.decimals) .. (spec.suffix or "")
          local current = settingValue(parameterSettings, spec)
          local currentText = formatNumber(current or spec.min, spec.decimals) .. (spec.suffix or "")
          valueColumnWidth = math.max(valueColumnWidth, textWidth(minimum), textWidth(maximum), textWidth(currentText))
        end
      end
    end
    local rightPadding = 7
    local minimumTrackSegments = 6
    local controlFixedWidth = minusWidth + controlGap + valueColumnWidth + controlGap + plusWidth
      + controlGap + bracketWidth * 2 + cellWidth * minimumTrackSegments
    local labelBudget = math.max(0, rightWidth - rightPadding - markerWidth - columnGap * 2 - controlFixedWidth)
    local labelColumnWidth = math.min(labelNaturalWidth, labelBudget)
    local controlStart = labelColumnWidth + columnGap + markerWidth + columnGap
    local sliderStart = controlStart + minusWidth + controlGap + valueColumnWidth + controlGap
      + plusWidth + controlGap + bracketWidth
    local sliderSegments = math.max(minimumTrackSegments, math.min(18,
      math.floor((rightWidth - rightPadding - sliderStart - bracketWidth) / cellWidth)))
    local sliderWidth = sliderSegments * cellWidth
    for index = 1, math.min(#paramRows, maxParamRows) do
      local row = paramRows[index]
      local spec = row.spec
      if row.section ~= section then section = row.section; detailLines[#detailLines + 1] = "§6" .. section end
        if spec.endpoint and (component.endpoint and component.endpoint.mode ~= "manual") then
          -- Endpoint vector controls are hidden while the terminal follows a child pivot.
        else
        local valueSource = spec.collider and selectedCollider
          or (spec.endpoint and (component.endpoint and component.endpoint.vector or {}) or settings)
        local value = settingValue(valueSource, spec)
      local numericValue = finiteNumber(value)
      if not spec.choices and not numericValue then
        local fallback = spec.endpoint and ({ x = 0, y = -1, z = 0 })[spec.axis] or settingValue(defaultSettings, spec)
        numericValue = finiteNumber(fallback) or spec.min
        value = numericValue
        self.status = "Настройка «" .. spec.label .. "» отсутствует; показано значение по умолчанию."
      end
      local editingThis = self.editing and self.editing.row.spec.path == spec.path
      local valueLabel = editingThis and (self.editing.text .. "▏")
        or (formatNumber(value, spec.decimals) .. (spec.suffix or ""))
      local isOwned = not spec.endpoint and not spec.collider and component.linkOverrides and component.linkOverrides[linkKey]
        and overrideOwnsSetting(component.linkOverrides[linkKey], spec)
      local marker = hasOverride and isOwned and "§a●" or "§8○"
      local prefix = truncateToWidth(spec.label, labelColumnWidth)
      local labelCell = padRight(prefix, labelColumnWidth)
      local controls, hitboxes = nil, nil
      if spec.choices then
        local label = spec.names[value] or tostring(value)
        local choiceColor = self.hover and self.hover.kind == "choice" and self.hover.path == spec.path and "§b" or "§8"
        controls = choiceColor .. "[‹] §f" .. label .. " " .. choiceColor .. "[›]"
        local choiceStart = controlStart
        local choiceEnd = choiceStart + textWidth(controls)
        hitboxes = { choiceStart = choiceStart - 1, choiceEnd = choiceEnd + 1 }
      else
        local ratio = sliderRatio(spec, numericValue)
        local filled = math.max(0, math.min(sliderSegments, math.floor(ratio * sliderSegments + 0.5)))
        local minusStart = controlStart
        local minusEnd = minusStart + minusWidth
        local valueStart = minusEnd + controlGap
        local valueEnd = valueStart + valueColumnWidth
        local plusStart = valueEnd + controlGap
        local plusEnd = plusStart + plusWidth
        local trackStart = plusEnd + controlGap + bracketWidth
        local trackEnd = trackStart + sliderWidth
        local hovering = self.hover and self.hover.path == spec.path and self.hover.kind
        local minusColor = hovering == "minus" and "§b" or "§8"
        local valueColor = hovering == "value" and "§b" or "§f"
        local plusColor = hovering == "plus" and "§b" or "§a"
        local sliderColor = hovering == "slider" and "§a" or "§b"
        controls = minusColor .. "[−] " .. valueColor .. padLeft(valueLabel, valueColumnWidth)
          .. " " .. plusColor .. "[+] " .. sliderColor .. "["
          .. string.rep("■", filled) .. string.rep("·", sliderSegments - filled) .. "]"
        hitboxes = { minusStart = minusStart - 1, minusEnd = minusEnd + 1,
          valueStart = valueStart - 1, valueEnd = valueEnd + 1,
          plusStart = plusStart - 1, plusEnd = plusEnd + 1,
          sliderStart = trackStart, sliderEnd = trackEnd,
          sliderHitStart = trackStart - 1, sliderHitEnd = trackEnd + 1 }
      end
      local lineText = (self.hover and self.hover.path == spec.path and "§b" or "§f")
        .. labelCell .. " " .. marker .. "§r " .. controls
      detailLines[#detailLines + 1] = lineText
      local lineIndex = #detailLines
      self.settingRows[#self.settingRows + 1] = { spec = spec, settings = valueSource, line = lineIndex, sourceIndex = index,
        labelStart = 0, labelEnd = labelColumnWidth,
        minusStart = hitboxes and hitboxes.minusStart or controlStart,
        minusEnd = hitboxes and hitboxes.minusEnd or controlStart,
        valueStart = hitboxes and hitboxes.valueStart or controlStart,
        valueEnd = hitboxes and hitboxes.valueEnd or controlStart,
        plusStart = hitboxes and hitboxes.plusStart or controlStart,
        plusEnd = hitboxes and hitboxes.plusEnd or controlStart,
        sliderStart = hitboxes and hitboxes.sliderStart or controlStart,
        sliderEnd = hitboxes and hitboxes.sliderEnd or controlStart,
        sliderHitStart = hitboxes and hitboxes.sliderHitStart or controlStart,
        sliderHitEnd = hitboxes and hitboxes.sliderHitEnd or controlStart,
        choiceStart = hitboxes and hitboxes.choiceStart or controlStart,
        choiceEnd = hitboxes and hitboxes.choiceEnd or controlStart,
        isOwned = isOwned == true, overrideActive = hasOverride,
      }
        end
    end
    detailLines[#detailLines + 1] = self.advancedSettings and "§8Подсказка: наведи курсор на параметр." or "§8Наведи курсор на настройку, чтобы увидеть подсказку."
    detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "reset-link" and "§b" or "§e") .. "Сбросить настройки звена"
    self.detailActions.resetLink = #detailLines
    detailLines[#detailLines + 1] = "§eСброс компонента"
    self.detailActions.reset = #detailLines
  elseif self.page == "overview" then
    local enabled, points, links = 0, 0, 0
    for index, item in ipairs(self.draft.components or {}) do
      if item.enabled ~= false then enabled = enabled + 1 end
      local itemGraph = self.graphs[index]
      links = links + (itemGraph and #(itemGraph.links or {}) or 0)
      points = points + (itemGraph and tonumber(itemGraph.pointCount) or 0)
    end
    local stats = self.diagnosticsData.__world or {}
    detailLines[#detailLines + 1] = "§6Система"
    detailLines[#detailLines + 1] = "§7Компоненты: §f" .. tostring(#(self.draft.components or {})) .. " §7(вкл. §f" .. tostring(enabled) .. "§7)"
    detailLines[#detailLines + 1] = "§7Звенья: §f" .. tostring(links) .. " §7| точки графа: §f" .. tostring(points)
    detailLines[#detailLines + 1] = "§7Профиль мира: §f" .. tostring(self.draft.world.performance or "balanced")
    detailLines[#detailLines + 1] = "§7Общие коллайдеры: §f" .. tostring(#(self.draft.colliders or {}))
    detailLines[#detailLines + 1] = "§6Последний шаг физики"
    detailLines[#detailLines + 1] = "§7Подшаги: §f" .. tostring(stats.substeps or 0) .. " §7| точки: §f" .. tostring(stats.activePoints or 0)
    detailLines[#detailLines + 1] = "§7Контакты: §f" .. tostring(stats.resolvedContacts or 0) .. " §7| время: §f" .. formatNumber(stats.frameTimeMs or 0, 3) .. " ms"
    appendQualityWarnings(detailLines, stats, rightWidth - 12, 1)
    detailLines[#detailLines + 1] = "§7Выбери страницу стрелками сверху. Профиль сохраняется вместе с аватаром."
  elseif self.page == "colliders" then
    detailLines[#detailLines + 1] = "§6Общие формы тела — доступны всем компонентам"
    detailLines[#detailLines + 1] = "§7Выбери GROUP в Outliner и нажми «Добавить коллайдер»."
    local selectedCollider, selectedIndex = self:selectedCollider()
    for index, collider in ipairs(self.draft.colliders or {}) do
      local node = nodeMatches(self.registry, collider.path)
      local label = node and node.name or "путь не найден"
      local selected = self.colliderScope == "global" and self.selectedColliderId == collider.id
      detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "collider-row" and self.hover.id == collider.id and "§b"
        or (selected and "§a" or "§f")) .. label .. " · " .. (collider.shape == "capsule" and "капсула" or "сфера")
        .. (collider.enabled == false and " §8ВЫКЛ" or " §aВКЛ")
      self.colliderRows[#self.colliderRows + 1] = { line = #detailLines, id = collider.id, scope = "global" }
    end
    if #self.draft.colliders == 0 then detailLines[#detailLines + 1] = "§8Общих коллайдеров пока нет." end
    if selectedCollider and self.colliderScope == "global" then
      detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "remove-collider" and "§b" or "§c") .. "Удалить выбранную общую форму"
      self.detailActions.removeCollider = #detailLines
      appendPageSettings(self, detailLines, COLLIDER_PARAMS, selectedCollider, self.layout.rightWidth)
    elseif not selectedCollider and #self.draft.colliders > 0 then
      detailLines[#detailLines + 1] = "§8Нажми на строку формы, чтобы редактировать её."
    end
    if selectedIndex then self.colliderMode = true end
  elseif self.page == "groups" then
    local hoveredMode = self.hover and self.hover.kind == "group-mode"
    local groupModeLabels = {
      matrix = "матрица групп", masks = "маски объектов", pairs = "исключения пар цепочек",
    }
    detailLines[#detailLines + 1] = (hoveredMode and "§b" or "§e")
      .. "Режим: " .. (groupModeLabels[self.groupMode] or groupModeLabels.matrix) .. " [перекл.]"
    self.detailActions.groupMode = #detailLines
    if self.groupMode == "pairs" then
      local source = self:selection()
      if not source then
        detailLines[#detailLines + 1] = "§8Выбери исходную цепочку слева."
      else
        detailLines[#detailLines + 1] = "§7Цепочка: §f" .. tostring(source.name or source.id)
        detailLines[#detailLines + 1] = "§8Клик по другой цепочке переключает контакт только этой пары."
        local world = self.draft.world or {}
        world.collisionExclusions = type(world.collisionExclusions) == "table" and world.collisionExclusions or {}
        local exclusionsById = {}
        for _, pair in ipairs(world.collisionExclusions) do
          if type(pair) == "table" and type(pair.first) == "string" and type(pair.second) == "string" then
            local first, second = pair.first, pair.second
            if second < first then first, second = second, first end
            local row = exclusionsById[first]
            if not row then row = {}; exclusionsById[first] = row end
            row[second] = true
          end
        end
        for _, target in ipairs(self.draft.components or {}) do
          if target.id ~= source.id then
            local first, second = source.id, target.id
            if second < first then first, second = second, first end
            local row = exclusionsById[first]
            local excluded = row and row[second] == true or false
            local hovered = self.hover and self.hover.kind == "component-pair"
              and self.hover.sourceId == source.id and self.hover.targetId == target.id
            local targetName = tostring(target.name or target.kind or "цепочка")
            local state = excluded and "контакт выкл." or "контакт вкл."
            local lineText = (hovered and "§b" or (excluded and "§c" or "§a"))
              .. targetName .. " · " .. tostring(target.id) .. ": " .. state .. " [клик]"
            detailLines[#detailLines + 1] = truncateToWidth(lineText, math.max(72, self.layout.rightWidth - 4))
            self.pairRows[#self.pairRows + 1] = {
              line = #detailLines, sourceId = source.id, targetId = target.id,
            }
          end
        end
      end
    elseif self.groupMode == "masks" then
      local component = self:selection()
      local collider, _, _, colliderScope = self:selectedCollider()
      local hasComponent, hasCollider = component ~= nil, collider ~= nil
      if self.groupMaskTarget == "component" and not hasComponent and hasCollider then self.groupMaskTarget = "collider" end
      if self.groupMaskTarget == "collider" and not hasCollider and hasComponent then self.groupMaskTarget = "component" end
      if hasComponent and hasCollider then
        local targetHovered = self.hover and self.hover.kind == "group-mask-target"
        local targetLabel = self.groupMaskTarget == "collider" and "коллайдер" or "цепочка"
        detailLines[#detailLines + 1] = (targetHovered and "§b" or "§e")
          .. "Настраивается: " .. targetLabel .. " [сменить]"
        self.detailActions.groupMaskTarget = #detailLines
      elseif hasComponent then
        detailLines[#detailLines + 1] = "§7Настраивается маска выбранной цепочки."
      elseif hasCollider then
        detailLines[#detailLines + 1] = "§7Настраивается маска выбранного коллайдера."
      else
        detailLines[#detailLines + 1] = "§8Выбери цепочку или коллайдер для настройки маски."
      end

      local mask, owner, id, scope, objectName
      if self.groupMaskTarget == "collider" and collider then
        mask, owner, id, scope = collider.mask, "collider", collider.id, colliderScope
        local node = nodeMatches(self.registry, collider.path)
        objectName = node and node.name or tostring(collider.id)
      elseif component then
        component.settings = component.settings or configApi.defaultsForComponent(component.rootPath).settings
        component.settings.collision = component.settings.collision or {}
        component.settings.collision.mask = component.settings.collision.mask or {}
        mask, owner, id = component.settings.collision.mask, "component", component.id
        objectName = tostring(component.kind or "custom")
      end
      if type(mask) == "table" then
        detailLines[#detailLines + 1] = "§6Фильтр: " .. tostring(objectName)
        detailLines[#detailLines + 1] = "§8Маска только запрещает пары, разрешённые общей матрицей."
        for _, group in ipairs(COLLISION_GROUPS) do
          local enabled = mask[group] ~= false
          local rowKey = tostring(owner) .. ":" .. tostring(id) .. ":" .. group
          local hovered = self.hover and self.hover.kind == "mask-filter" and self.hover.key == rowKey
          detailLines[#detailLines + 1] = (hovered and "§b" or (enabled and "§a" or "§8"))
            .. "  " .. COLLISION_GROUP_LABELS[group] .. ": " .. (enabled and "разрешено" or "запрещено") .. " [клик]"
          self.filterRows[#self.filterRows + 1] = {
            line = #detailLines, owner = owner, id = id, scope = scope, group = group, key = rowKey,
          }
        end
      end
    else
      detailLines[#detailLines + 1] = "§8Клик по ячейке включает/выключает пару групп."
      local matrix = self.draft.world.collisionMatrix or {}
      for _, first in ipairs(COLLISION_GROUPS) do
        local start = textWidth(COLLISION_GROUP_LABELS[first] .. "  ")
        local rowText = "§f" .. COLLISION_GROUP_LABELS[first] .. "  "
        for _, second in ipairs(COLLISION_GROUPS) do
          local enabled = not (matrix[first] and matrix[first][second] == false)
          local hovered = self.hover and self.hover.kind == "group-cell" and self.hover.first == first and self.hover.second == second
          local symbol = enabled and "●" or "○"
          rowText = rowText .. (hovered and "§b" or (enabled and "§a" or "§8")) .. symbol
          self.groupRows[#self.groupRows + 1] = { line = #detailLines + 1, first = first, second = second,
            start = start, finish = start + textWidth(symbol) + 1 }
          start = start + textWidth(symbol .. " ")
          rowText = rowText .. " "
        end
        detailLines[#detailLines + 1] = rowText
      end
      detailLines[#detailLines + 1] = "§8Порядок групп: Тело, Волосы, Уши, Хвост, Одежда, Аксессуары, Своя."
    end
  elseif self.page == "physics" then
    detailLines[#detailLines + 1] = "§6Параметры общего решателя"
    appendPageSettings(self, detailLines, WORLD_PARAMS, self.draft.world, self.layout.rightWidth)
    detailLines[#detailLines + 1] = "§8Это глобальные лимиты и шаг мира, не силы отдельного PhysBone."
  elseif self.page == "performance" then
    detailLines[#detailLines + 1] = "§6Профиль качества"
    local performanceSpec = { path = "performance", label = "Режим", help = "Готовая конфигурация общих лимитов.",
      choices = { "performance", "balanced", "quality" }, names = { performance = "Производительность", balanced = "Сбалансированный", quality = "Качество" }, world = true }
    appendPageSettings(self, detailLines, { performanceSpec }, self.draft.world, self.layout.rightWidth)
    detailLines[#detailLines + 1] = "§7Профиль меняет лимиты ниже; их можно настроить вручную на странице «Физика»."
    local stats = self.diagnosticsData.__world or {}
    detailLines[#detailLines + 1] = "§6Активная нагрузка"
    detailLines[#detailLines + 1] = "§7Физ. точки: §f" .. tostring(stats.activeSimulationPoints or 0) .. " / " .. tostring(stats.simulationPointBudget or self.draft.world.maxPoints or 0)
      .. " §7| частота: §f" .. formatNumber(stats.simulationHz or 0, 1) .. " / " .. formatNumber(stats.configuredSimulationHz or 0, 1) .. " Гц"
    detailLines[#detailLines + 1] = "§7Контактные точки: §f" .. tostring(stats.activePoints or 0) .. " / " .. tostring(stats.maxPoints or self.draft.world.maxPoints or 0)
    detailLines[#detailLines + 1] = "§7Пары: §f" .. tostring(stats.pairChecks or 0) .. " / " .. tostring(stats.maxCandidatePairs or self.draft.world.maxCandidatePairs or 0)
      .. " §8(межцеп. " .. tostring(stats.candidatePairs or 0) .. ", self " .. tostring(stats.selfPairs or 0) .. ")"
    detailLines[#detailLines + 1] = "§7Блок-запросы: §f" .. tostring(stats.worldQueries or 0) .. " / " .. tostring(stats.worldQueryBudget or self.draft.world.maxBlockQueries or 0)
    appendQualityWarnings(detailLines, stats, rightWidth - 12, 2)
  elseif self.page == "diagnostics" then
    local stats = self.diagnosticsData.__world or {}
    local instructions = self.diagnosticsData.__instructions or {}
    detailLines[#detailLines + 1] = "§6Общий PhysicsWorld"
    detailLines[#detailLines + 1] = "§7Профиль: §f" .. tostring(stats.performance or self.draft.world.performance or "—")
    detailLines[#detailLines + 1] = "§7Компоненты/физ. точки: §f" .. tostring(stats.activeComponents or 0) .. " / " .. tostring(stats.activeSimulationPoints or 0)
    detailLines[#detailLines + 1] = "§7Частота физики: §f" .. formatNumber(stats.simulationHz or 0, 1) .. " / " .. formatNumber(stats.configuredSimulationHz or 0, 1) .. " Гц"
    detailLines[#detailLines + 1] = "§7Контактных точек: §f" .. tostring(stats.activePoints or 0) .. " / " .. tostring(stats.maxPoints or 0)
    detailLines[#detailLines + 1] = "§7Сегменты: §f" .. tostring(stats.activeSegments or 0) .. " §7| шаги: §f" .. tostring(stats.substeps or 0)
    detailLines[#detailLines + 1] = "§7Коллайдеры тела: §fобщие " .. tostring(stats.sharedBodyColliders or 0)
      .. " §7| локальные " .. tostring(stats.componentBodyColliders or 0)
      .. " §7| всего " .. tostring(stats.activeBodyColliders or 0)
    detailLines[#detailLines + 1] = "§7Проверка body-кандидатов/тик: §f" .. tostring(stats.avatarShapeCandidates or 0)
    detailLines[#detailLines + 1] = "§7Кандидаты/контакты: §f" .. tostring(stats.candidatePairs or 0) .. " / " .. tostring(stats.resolvedContacts or 0)
    detailLines[#detailLines + 1] = "§7Локальные контакты/self пары: §f" .. tostring(stats.localContacts or 0) .. " / " .. tostring(stats.selfPairs or 0)
    detailLines[#detailLines + 1] = "§7Общий бюджет пар: §f" .. tostring(stats.pairChecks or 0) .. " / " .. tostring(stats.maxCandidatePairs or 0)
    detailLines[#detailLines + 1] = "§7Запросы блоков: §f" .. tostring(stats.worldQueries or 0) .. " / " .. tostring(stats.worldQueryBudget or 0)
    detailLines[#detailLines + 1] = "§7Время шага: §f" .. formatNumber(stats.frameTimeMs or 0, 3) .. " ms"
    detailLines[#detailLines + 1] = "§7Вся физика/тик: §f" .. formatNumber(stats.totalPhysicsMs or 0, 3) .. " ms"
    detailLines[#detailLines + 1] = "§7Figura TICK (пред. тик): " .. formatInstructionUsage(instructions.tick)
    detailLines[#detailLines + 1] = "§7Figura RENDER (пред. кадр): " .. formatInstructionUsage(instructions.render)
    detailLines[#detailLines + 1] = "§7Автоснижение нагрузки: §f"
      .. ((stats.instructionPressure or (stats.timePressure or 0) > 0)
        and (tostring(math.floor((stats.loadShedScale or 1) * 100)) .. "% бюджета") or "не активно")
    detailLines[#detailLines + 1] = "§8Счётчики относятся ко всему аватару, не только к физике."
    local qualityReduced = appendQualityWarnings(detailLines, stats, rightWidth - 12, 4)
    local warnings = {}
    if stats.budgetExceeded then warnings[#warnings + 1] = "динамический бюджет исчерпан" end
    if stats.pointBudgetExceeded then warnings[#warnings + 1] = "превышен лимит точек" end
    if stats.simulationBudgetExceeded then warnings[#warnings + 1] = "точки превышают бюджет и на минимальных 20 Гц" end
    if stats.blockBudgetExceeded then warnings[#warnings + 1] = "лимит блоков исчерпан" end
    if stats.selfBudgetExceeded then warnings[#warnings + 1] = "лимит self-контактов исчерпан" end
    if stats.worldUnavailable then warnings[#warnings + 1] = "API блоков недоступен" end
    if stats.instructionPressure then
      warnings[#warnings + 1] = "нагрузка TICK снизила необязательные контакты/запросы"
    elseif instructions.tick and instructions.tick.warning then
      warnings[#warnings + 1] = "TICK выше 70% лимита Figura"
    end
    if (stats.timePressure or 0) > 0 then
      warnings[#warnings + 1] = "долгий шаг физики снизил необязательные контакты/запросы"
    end
    if instructions.render and instructions.render.warning then warnings[#warnings + 1] = "RENDER выше 70% лимита Figura" end
    detailLines[#detailLines + 1] = #warnings > 0 and ("§cПредупреждения: " .. table.concat(warnings, ", "))
      or (qualityReduced and "§8Других ошибок бюджета нет." or "§aБюджеты соблюдены; ошибок контактов нет.")
    local selectedData = component and self.diagnosticsData[component.id]
    if selectedData then detailLines[#detailLines + 1] = "§7Выбранный компонент: мировой кадр " .. (selectedData.gravityFrameAvailable and "§aдоступен" or "§cнедоступен") end
  else
    local excludedComponent, _, excludedIndex = self:selectedExclusion()
    if excludedComponent then
      detailLines[#detailLines + 1] = "§7Выбранная группа исключена из физики: §f" .. (self:selectedNode() and self:selectedNode().name or "—")
      detailLines[#detailLines + 1] = "§8Она следует за анимацией родителя и не получает отдельную симуляцию."
      detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "restore-exclusion" and "§b" or "§e") .. "Вернуть звено в компонент"
      self.detailActions.restoreExclusion = #detailLines
    else
      detailLines[#detailLines + 1] = "§7Выбери трансформируемую GROUP ModelPart слева."
      detailLines[#detailLines + 1] = "§7Создай компонент, затем настрой силы и суставы."
      detailLines[#detailLines + 1] = "§8Физика действует на ModelPart, не деформирует единый меш."
    end
  end
  detailLines[#detailLines + 1] = "§aСохранить §7| §cОтмена §7| §eДиагностика " .. ((self.draft.diagnostics and "ВКЛ") or "ВЫКЛ")
  detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "export" and "§b" or "§3") .. "Экспортировать профиль v2"
  detailLines[#detailLines + 1] = (self.hover and self.hover.kind == "import" and "§b" or "§3") .. "Загрузить physics_bone_preset.lua"
  local detailScale = math.min(1, math.max(0.7, panelHeight / math.max(1, #detailLines * line)))
  self.layout.detailScale = detailScale
  -- Keep navigation and save/export actions visible while the middle of a
  -- long page scrolls. Row handlers still use logical (unscrolled) line IDs.
  local visibleCapacity = math.max(7, math.floor(panelHeight / (line * detailScale)))
  local headerCount, footerCount = 4, 3
  local middleCount = math.max(0, #detailLines - headerCount - footerCount)
  local middleCapacity = math.max(0, visibleCapacity - headerCount - footerCount)
  self.detailScrollMax = math.max(0, middleCount - middleCapacity)
  if self.detailScrollMax > 0 then
    detailLines[self.detailActions.pageNav] = detailLines[self.detailActions.pageNav] .. " §8[колесо ↑↓]"
  end
  self.detailsOffset = math.max(0, math.min(self.detailsOffset or 0, self.detailScrollMax))
  local displayed, visibleToLogical = {}, {}
  local function displayLine(index)
    displayed[#displayed + 1] = detailLines[index]
    visibleToLogical[#visibleToLogical + 1] = index
  end
  for index = 1, headerCount do displayLine(index) end
  local firstMiddle = headerCount + 1 + self.detailsOffset
  local lastMiddle = math.min(#detailLines - footerCount, firstMiddle + middleCapacity - 1)
  for index = firstMiddle, lastMiddle do displayLine(index) end
  for index = #detailLines - footerCount + 1, #detailLines do displayLine(index) end
  self.detailVisibleToLogical = visibleToLogical
  safeCall(self.detailsText, "setScale", detailScale, detailScale, detailScale)
  safeCall(self.detailsText, "setWidth", math.floor(rightWidth / detailScale))
  if self.detailsText then safeCall(self.detailsText, "setText", table.concat(displayed, "\n")) end
  self.detailActions.footer = #detailLines - 2
  self.detailActions.export = #detailLines - 1
  self.detailActions.import = #detailLines
  if self.messageText then
    local messageX = self.layout.x + panelWidth + 8
    local messageWidth = math.max(0, width - messageX - 8)
    safeCall(self.messageText, "setPos", -messageX, -self.layout.y, -0.2)
    safeCall(self.messageText, "setWidth", messageWidth)
    safeCall(self.messageText, "setWrap", true)
    safeCall(self.messageText, "setText", messageWidth >= 100 and (self.status or "") or "")
  end
end

function uiApi:targetAt(x, y)
  if not self.layout then return nil end
  local detailScale = self.layout.detailScale or 1
  local line = math.floor(y / ((x < self.layout.leftWidth and 1 or detailScale) * self.lineHeight)) + 1
  if x >= self.layout.leftWidth then
    line = self.detailVisibleToLogical and self.detailVisibleToLogical[line]
    if not line then return nil end
  end
  if x < self.layout.leftWidth then
    if line == 2 then return { kind = "search" } end
    for _, row in ipairs(self.treeRows) do
      if row.line == line then return { kind = "tree", key = row.node.key, hasChildren = row.hasChildren, row = row } end
    end
    if line == self.actionRows.create then return { kind = "create" } end
    if line == self.actionRows.remove then return { kind = "remove" } end
    if line == self.actionRows.collider then return { kind = "create-collider" } end
    if line == self.actionRows.close then return { kind = "close" } end
  else
    if line == self.detailActions.pageNav then return { kind = "page-nav" } end
    if line == self.detailActions.groupMode then return { kind = "group-mode", key = "group-mode" } end
    if line == self.detailActions.groupMaskTarget then return { kind = "group-mask-target", key = "group-mask-target" } end
    if line == self.detailActions.settingsMode then return { kind = "settings-mode" } end
    if line == self.detailActions.enabled then return { kind = "component-enabled" } end
    if line == self.detailActions.componentKind then return { kind = "component-kind" } end
    if line == self.detailActions.componentPreset then return { kind = "component-preset" } end
    if line == self.detailActions.applyComponentPreset then return { kind = "apply-component-preset" } end
    if line == self.detailActions.branches then return { kind = "branches" } end
    if line == self.detailActions.override then return { kind = "override" } end
    if line == self.detailActions.endpointMode then return { kind = "endpoint-mode" } end
    if line == self.detailActions.captureRestPose then return { kind = "capture-rest-pose" } end
    if line == self.detailActions.exclude then return { kind = "exclude-link" } end
    if line == self.detailActions.restoreExclusion then return { kind = "restore-exclusion" } end
    if line == self.detailActions.resetLink then return { kind = "reset-link" } end
    if line == self.detailActions.reset then return { kind = "reset" } end
    if line == self.detailActions.colliderMode then return { kind = "collider-mode" } end
    if line == self.detailActions.removeCollider then return { kind = "remove-collider" } end
    if line == self.detailActions.footer then return { kind = "footer" } end
    if line == self.detailActions.export then return { kind = "export" } end
    if line == self.detailActions.import then return { kind = "import" } end
    for _, row in ipairs(self.branchRows or {}) do
      if row.line == line then return { kind = "branch-choice", key = row.key, parentKey = row.parentKey } end
    end
    for _, row in ipairs(self.colliderRows or {}) do
      if row.line == line then return { kind = "collider-row", id = row.id, scope = row.scope } end
    end
    for _, row in ipairs(self.groupRows or {}) do
      if row.line == line then
        local column = (x - self.layout.leftWidth - 8) / detailScale
        if column >= row.start and column <= row.finish then
          return { kind = "group-cell", first = row.first, second = row.second }
        end
      end
    end
    for _, row in ipairs(self.filterRows or {}) do
      if row.line == line then
        return { kind = "mask-filter", owner = row.owner, id = row.id, scope = row.scope,
          group = row.group, key = row.key }
      end
    end
    for _, row in ipairs(self.pairRows or {}) do
      if row.line == line then
        return { kind = "component-pair", sourceId = row.sourceId, targetId = row.targetId }
      end
    end
    for _, row in ipairs(self.settingRows) do
      if row.line == line then
        local column = (x - self.layout.leftWidth - 8) / detailScale
        if row.spec.choices then
          if column >= row.choiceStart and column <= row.choiceEnd then
            return { kind = "choice", row = row, path = row.spec.path }
          end
          return { kind = "parameter", path = row.spec.path }
        end
        if column >= row.minusStart and column <= row.minusEnd then return { kind = "minus", row = row, path = row.spec.path } end
        if column >= row.valueStart and column <= row.valueEnd then return { kind = "value", row = row, path = row.spec.path } end
        if column >= row.plusStart and column <= row.plusEnd then return { kind = "plus", row = row, path = row.spec.path } end
        if column >= row.sliderHitStart and column <= row.sliderHitEnd then return { kind = "slider", row = row, path = row.spec.path } end
        return { kind = "parameter", path = row.spec.path }
      end
    end
  end
  return nil
end

local HOVER_ID_FIELDS = { "key", "path", "id", "group", "first", "second", "sourceId", "targetId", "owner", "scope", "index" }

local function hoverIdentity(target)
  if type(target) ~= "table" then return "" end
  local parts = { tostring(target.kind or "") }
  for _, field in ipairs(HOVER_ID_FIELDS) do
    local value = target[field]
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      parts[#parts + 1] = field .. "=" .. tostring(value)
    end
  end
  return table.concat(parts, "\31")
end

function uiApi:setHover(target)
  local old = hoverIdentity(self.hover)
  local new = hoverIdentity(target)
  if old == new then return end
  self.hover = target
  self:refresh()
end

function uiApi:sliderSet(row, mouseX)
  local column = (mouseX - self.layout.x - self.layout.leftWidth - 8) / (self.layout.detailScale or 1)
  local ratio = math.max(0, math.min(1, (column - row.sliderStart) / math.max(1, row.sliderEnd - row.sliderStart)))
  self:writeSetting(row.spec, sliderValue(row.spec, ratio))
end

function uiApi:beginNumberEdit(row)
  if row.spec.choices then return end
  self.editing = { row = row, text = "", original = formatNumber(settingValue(row.settings, row.spec), row.spec.decimals), replaceOnType = true }
  self.status = "Введи число и нажми Enter; Esc отменит ввод."
  self:refresh()
end

function uiApi:commitNumberEdit()
  local edit = self.editing
  if not edit then return end
  local value = tonumber(edit.text)
  if value then self:writeSetting(edit.row.spec, clampValue(edit.row.spec, value))
  else self.status = "Число не распознано; значение оставлено прежним." end
  self.editing = nil
  self:refresh()
end

function uiApi:onMousePress(button, action)
  if not self.open then return false end
  if action == 0 then self.dragging = nil; return self:mouseInside() end
  if action ~= 1 or button ~= 0 then return self:mouseInside() end
  local mouseX, mouseY = mouseGui()
  local inside = self:mouseInside(mouseX, mouseY)
  if not inside then
    if self.editing then self:commitNumberEdit() end
    return false
  end
  local target = self:targetAt(mouseX - self.layout.x, mouseY - self.layout.y)
  self:setHover(target)
  if not target then return true end
  if target.kind == "page-nav" then
    local currentIndex = 1
    for index, page in ipairs(PAGES) do if page.id == self.page then currentIndex = index; break end end
    local rightX = (mouseX - (self.layout.x + self.layout.leftWidth + 8)) / (self.layout.detailScale or 1)
    local delta = rightX < self.layout.rightWidth * 0.5 and -1 or 1
    currentIndex = ((currentIndex - 1 + delta) % #PAGES) + 1
    self.page = PAGES[currentIndex].id
    self.detailsOffset = 0
    self.colliderMode = false
    if (self.page == "diagnostics" or self.page == "performance") and not self.draft.diagnostics then
      self.draft.diagnostics = true
      self:changed("Диагностика включена для показа счётчиков нагрузки.")
    else self:refresh() end
  elseif target.kind == "search" then self.searchFocused = true; self:refresh()
  elseif target.kind == "tree" then
    -- Use the rendered indentation and arrow widths with a small forgiving edge.
    local column = mouseX - self.layout.x
    local row = target.row
    local onDisclosure = row and column >= row.disclosureStart and column <= row.disclosureEnd
    if target.hasChildren and onDisclosure then
      self.collapsed[target.key] = not self.collapsed[target.key]; self:refresh()
    else
      self.selectedKey = target.key
      self.detailsOffset = 0
      local selectedComponent = self:selection()
      if selectedComponent then self.activeComponentId = selectedComponent.id end
      self.linkOverride = false
      self:refresh()
    end
  elseif target.kind == "create" then self:createComponent()
  elseif target.kind == "remove" then self:removeComponent()
  elseif target.kind == "create-collider" then self:createCollider()
  elseif target.kind == "close" then self:toggle()
  elseif target.kind == "settings-mode" then
    self.advancedSettings = not self.advancedSettings
    self.detailsOffset = 0
    self.status = self.advancedSettings and "Показаны все технические настройки." or "Показаны основные настройки."
    self:refresh()
  elseif target.kind == "component-enabled" then
    local component = self:selection(); if component then component.enabled = component.enabled == false; self:changed(component.enabled and "Компонент включён." or "Компонент выключен.") end
  elseif target.kind == "component-kind" then self:cycleComponentKind(1)
  elseif target.kind == "component-preset" then self:cycleComponentPreset(1)
  elseif target.kind == "apply-component-preset" then self:applyComponentPreset()
  elseif target.kind == "branches" then self:toggleBranches()
  elseif target.kind == "branch-choice" then
    local selectedComponent = self:selection()
    if selectedComponent then
      selectedComponent.branchChoices = selectedComponent.branchChoices or {}
      selectedComponent.branchChoices[target.parentKey] = target.key
      self:changed("Продолжение ветви выбрано.")
    end
  elseif target.kind == "override" then self:toggleOverride()
  elseif target.kind == "exclude-link" then
    local component, _, linkKey = self:selection()
    local node = self:selectedNode()
    if component and node and pathKey(component.rootPath) ~= linkKey then
      component.excludedPaths = component.excludedPaths or {}
      component.excludedPaths[#component.excludedPaths + 1] = configApi.clone(node.path)
      self:changed("Звено исключено; оно останется прикреплено к анимированному родителю.")
    end
  elseif target.kind == "restore-exclusion" then
    local component, _, excludedIndex = self:selectedExclusion()
    if component and excludedIndex then
      table.remove(component.excludedPaths, excludedIndex)
      self:changed("Звено возвращено в физическую цепь.")
    end
  elseif target.kind == "endpoint-mode" then
    local selectedComponent = self:selection()
    if selectedComponent then
      if selectedComponent.endpoint and selectedComponent.endpoint.mode == "manual" then selectedComponent.endpoint = { mode = "child" }
      else selectedComponent.endpoint = { mode = "manual", vector = { x = 0, y = -1, z = 0 } } end
      self:changed("Режим конечной точки изменён.")
    end
  elseif target.kind == "capture-rest-pose" then
    local component = self:selection()
    if component and self.callbacks.captureRestPose then self.callbacks.captureRestPose(component.id) end
  elseif target.kind == "reset-link" then self:resetLink()
  elseif target.kind == "reset" then self:resetComponent()
  elseif target.kind == "collider-mode" then
    local collider = self:selectedCollider()
    if collider then self.colliderMode = not self.colliderMode
    elseif #(self:selection() and self:selection().colliders or {}) > 0 then
      local component = self:selection()
      self.selectedColliderId = component.colliders[1].id
      self.colliderMode = true
    else self.colliderMode = false end
    self:refresh()
  elseif target.kind == "collider-row" then
    self.colliderScope = target.scope or "component"
    if self.selectedColliderId == target.id and self.colliderMode then
      self.colliderMode = false
    else
      self.selectedColliderId, self.colliderMode = target.id, true
    end
    self:refresh()
  elseif target.kind == "group-mode" then
    self.groupMode = ({ matrix = "masks", masks = "pairs", pairs = "matrix" })[self.groupMode] or "masks"
    self:refresh()
  elseif target.kind == "group-mask-target" then
    self.groupMaskTarget = self.groupMaskTarget == "collider" and "component" or "collider"
    self:refresh()
  elseif target.kind == "mask-filter" then
    local mask
    if target.owner == "component" then
      local component = self:selection()
      if component and component.id == target.id then
        component.settings = component.settings or configApi.defaultsForComponent(component.rootPath).settings
        component.settings.collision = component.settings.collision or {}
        component.settings.collision.mask = component.settings.collision.mask or {}
        mask = component.settings.collision.mask
      end
    elseif target.owner == "collider" then
      local collider, _, _, scope = self:selectedCollider()
      if collider and collider.id == target.id and scope == target.scope then
        collider.mask = collider.mask or {}
        mask = collider.mask
      end
    end
    if mask then
      local enabled = mask[target.group] ~= false
      mask[target.group] = not enabled
      local label = COLLISION_GROUP_LABELS[target.group] or tostring(target.group)
      self:changed((not enabled and "Контакт разрешён с группой «" or "Контакт запрещён с группой «")
        .. label .. ". Нажми «Сохранить».")
    end
  elseif target.kind == "group-cell" then
    self.draft.world.collisionMatrix = self.draft.world.collisionMatrix or {}
    local matrix = self.draft.world.collisionMatrix
    matrix[target.first] = matrix[target.first] or {}
    matrix[target.second] = matrix[target.second] or {}
    local enabled = matrix[target.first][target.second] == false
    matrix[target.first][target.second] = enabled
    matrix[target.second][target.first] = enabled
    self:changed("Матрица столкновений обновлена; нажми «Сохранить».")
  elseif target.kind == "component-pair" then
    local source, other
    for _, component in ipairs(self.draft.components or {}) do
      if component.id == target.sourceId then source = component end
      if component.id == target.targetId then other = component end
    end
    if source and other and source.id ~= other.id then
      local first, second = source.id, other.id
      if second < first then first, second = second, first end
      self.draft.world = self.draft.world or {}
      local exclusions = self.draft.world.collisionExclusions
      if type(exclusions) ~= "table" then exclusions = {}; self.draft.world.collisionExclusions = exclusions end
      local found
      for index, pair in ipairs(exclusions) do
        if type(pair) == "table" and pair.first == first and pair.second == second then
          found = index
          break
        end
      end
      if found then
        table.remove(exclusions, found)
        self:changed("Контакт между цепочками снова разрешён. Нажми «Сохранить».")
      elseif #exclusions < 2016 then
        exclusions[#exclusions + 1] = { first = first, second = second }
        self:changed("Контакт этой пары цепочек исключён. Нажми «Сохранить».")
      else
        self.status = "Достигнут лимит 2016 исключённых пар."
        self:refresh()
      end
    end
  elseif target.kind == "remove-collider" then self:removeCollider()
  elseif target.kind == "export" then
    if self.callbacks.export then
      local ok, message = self.callbacks.export(self.draft)
      self.status = tostring(message or (ok and "Профиль экспортирован." or "Экспорт не выполнен."))
      self:refresh()
    end
  elseif target.kind == "import" then
    if self.callbacks.import then self.callbacks.import() end
  elseif target.kind == "footer" then
    local rightX = (mouseX - (self.layout.x + self.layout.leftWidth + 8)) / (self.layout.detailScale or 1)
    if rightX < self.layout.rightWidth * 0.32 then
      if self.callbacks.save then self.callbacks.save() end
    elseif rightX < self.layout.rightWidth * 0.64 then
      if self.callbacks.cancel then self.callbacks.cancel() end
    else
      self.draft.diagnostics = not self.draft.diagnostics
      self:changed("Диагностика " .. (self.draft.diagnostics and "включена" or "выключена") .. ".")
    end
  elseif target.kind == "choice" then self:adjustParameter(target.row, 1)
  elseif target.kind == "minus" then self:adjustParameter(target.row, -1)
  elseif target.kind == "plus" then self:adjustParameter(target.row, 1)
  elseif target.kind == "slider" then self.dragging = target.row; self:sliderSet(target.row, mouseX)
  elseif target.kind == "value" then self:beginNumberEdit(target.row)
  else self.searchFocused = false end
  return true
end

function uiApi:mouseInside(x, y)
  x, y = x or select(1, mouseGui()), y or select(2, mouseGui())
  return self.layout and x >= self.layout.x and x <= self.layout.x + self.layout.width
    and y >= self.layout.y and y <= self.layout.y + self.layout.height or false
end

function uiApi:onMouseMove()
  if not self.open then return false end
  local mouseX, mouseY = mouseGui()
  if self.dragging then self:sliderSet(self.dragging, mouseX); return true end
  local target = self:mouseInside(mouseX, mouseY)
    and self:targetAt(mouseX - self.layout.x, mouseY - self.layout.y) or nil
  self:setHover(target)
  return self:mouseInside(mouseX, mouseY)
end

function uiApi:onMouseScroll(delta)
  if not self.open or not self:mouseInside() then return false end
  local x = select(1, mouseGui()) - self.layout.x
  if x < self.layout.leftWidth then
    self.treeOffset = math.max(0, math.min(#self:visibleNodes(), self.treeOffset + (delta > 0 and -3 or 3)))
  else
    self.detailsOffset = math.max(0, math.min(self.detailScrollMax or 0,
      self.detailsOffset + (delta > 0 and -3 or 3)))
  end
  self:refresh()
  return true
end

function uiApi:onCharTyped(character)
  if not self.open or type(character) ~= "string" then return false end
  if self.editing then
    if character:match("^[%d%.%-]$") and #self.editing.text < 16 then
      if self.editing.replaceOnType then self.editing.text = ""; self.editing.replaceOnType = false end
      self.editing.text = self.editing.text .. character
    end
    self:refresh()
    return true
  end
  if self.searchFocused and #self.search < 40 then self.search = self.search .. character; self.treeOffset = 0; self:refresh(); return true end
  return false
end

function uiApi:onKeyPress(key, action)
  if not self.open or action ~= 1 then return false end
  if self.editing then
    if key == 256 then self.editing = nil; self:refresh()
    elseif key == 259 then self.editing.text = self.editing.text:sub(1, math.max(0, #self.editing.text - 1)); self.editing.replaceOnType = false; self:refresh()
    elseif key == 257 or key == 335 then self:commitNumberEdit() end
    return true
  end
  if key == 259 and self.searchFocused then self.search = self.search:sub(1, math.max(0, #self.search - 1)); self:refresh(); return true end
  if key == 256 then self:toggle(); return true end
  return false
end

function uiApi:tick()
  if self.open and self.editing then self:refresh() end
end

return uiApi
