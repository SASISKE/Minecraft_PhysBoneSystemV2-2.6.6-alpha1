local configApi = {}
local presetsApi = require("physics_bone_presets")

local CONFIG_KEY = "physics_bone_v2"
local PRESET_MODULE = "physics_bone_preset"
local PRESET_ROOT = "PhysicsBoneV2/Characters"
local GROUPS = { "body", "hair", "ears", "tail", "clothing", "accessories", "custom" }
local activeConfigAvatarName
local activeConfigStorageName

local function defaultCollisionMatrix()
  local matrix = {}
  for _, first in ipairs(GROUPS) do
    matrix[first] = {}
    for _, second in ipairs(GROUPS) do matrix[first][second] = true end
  end
  return matrix
end

local DEFAULT_WORLD = {
  performance = "balanced",
  fixedStep = 1 / 60,
  maxSubsteps = 3,
  maxFrameDt = 0.10,
  maxPoints = 80,
  maxCandidatePairs = 512,
  contactIterations = 2,
  constraintPasses = 5,
  cellSize = 1,
  maxCellsPerProxy = 256,
  maxBlockQueries = 64,
  segmentMode = "point_segment",
  collisionMatrix = defaultCollisionMatrix(),
  collisionExclusions = {},
}

local DEFAULT_SETTINGS = {
  enabled = true,
  gravitySpace = "world",
  gravity = { x = 0, y = -9.81, z = 0 },
  gravityTiltResponse = 0.0,
  gravityFalloff = 0.0,
  restShapeReturn = 0.0,
  linkControlMode = "legacy",
  animationTargetMode = "hybrid",
  animationInfluence = 0.65,
  poseFollow = 0.30,
  poseFollowFalloff = 1.2,
  -- Balanced starter values: visible secondary motion without disabling pose follow.
  pull = 60.0,
  spring = 0.8,
  bendStiffness = 0.75,
  bendStiffnessFalloff = 1.2,
  restitution = 0.22,
  damping = 12.0,
  mass = 1.0,
  tipMass = 1.0,
  rootMotionResponse = 0.45,
  motionDrag = 0.25,
  avatarMotionResponse = 0.55,
  maxLinearSpeed = 24.0,
  joint = {
    type = "cone",
    axis = { x = 0, y = 1, z = 0 },
    angle = 20.0,
    angularSpeed = 180.0,
  },
  collision = {
    enabled = false,
    avatar = true,
    world = false,
    self = false,
    selfNeighborDepth = 1,
    group = "custom",
    mask = {},
    dynamic = true,
    radius = 0.5,
    friction = 0.25,
    restitution = 0.0,
    maxBlockQueries = 64,
    maxSelfPairs = 2048,
    iterations = 2,
  },
}

local RANGES = {
  gravity = { -40, 40 }, gravityTiltResponse = { 0, 1 }, gravityFalloff = { 0, 1 }, restShapeReturn = { 0, 1 }, pull = { 0, 500 },
  poseFollow = { 0, 1 }, poseFollowFalloff = { 0, 4 },
  tipMass = { 1, 6 },
  spring = { 0, 24 }, bendStiffness = { 0, 24 }, bendStiffnessFalloff = { 0, 4 },
  restitution = { 0, 1 }, damping = { 0, 24 }, mass = { 0.05, 20 },
  rootMotionResponse = { 0, 2 }, motionDrag = { 0, 2 }, avatarMotionResponse = { 0, 2 },
  maxLinearSpeed = { 0, 60 }, angle = { 0, 180 }, angularSpeed = { 0, 720 },
  collisionRadius = { 0.05, 16 }, collisionFriction = { 0, 1 }, collisionRestitution = { 0, 1 },
  collisionQueries = { 0, 256 }, collisionSelfPairs = { 0, 16384 }, collisionIterations = { 1, 4 },
  animationInfluence = { 0, 1 }, collisionSelfNeighborDepth = { 0, 8 },
}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function cleanRotationMatrix(raw)
  if type(raw) ~= "table" then return nil end
  local result = {}
  for row = 1, 3 do
    if type(raw[row]) ~= "table" then return nil end
    result[row] = {}
    for column = 1, 3 do
      local value = tonumber(raw[row][column])
      if not finite(value) or value < -1.001 or value > 1.001 then return nil end
      result[row][column] = math.max(-1, math.min(1, value))
    end
  end
  return result
end

function configApi.clone(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return nil end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do result[key] = configApi.clone(item, seen) end
  seen[value] = nil
  return result
end

function configApi.defaults()
  return { schema = 6, world = configApi.clone(DEFAULT_WORLD), components = {}, colliders = {}, diagnostics = false }
end

local function clamp(value, range, fallback, label, warnings)
  value = tonumber(value)
  if not finite(value) then
    warnings[#warnings + 1] = label .. ": заменено значением по умолчанию"
    return fallback
  end
  local clean = math.max(range[1], math.min(range[2], value))
  if clean ~= value then warnings[#warnings + 1] = label .. ": ограничено допустимым диапазоном" end
  return clean
end

local function cleanPath(path)
  if type(path) ~= "table" or #path == 0 or #path > 128 then return nil end
  local result = {}
  for index, segment in ipairs(path) do
    if type(segment) ~= "table" or type(segment.name) ~= "string"
      or #segment.name > 128 or not finite(segment.sameNameIndex) or segment.sameNameIndex < 1 then return nil end
    result[index] = { name = segment.name, sameNameIndex = math.floor(segment.sameNameIndex) }
  end
  return result
end

local function cleanColliders(rawList, warnings, label, limit)
  local result, seen = {}, {}
  for index, source in ipairs(type(rawList) == "table" and rawList or {}) do
    if index > (limit or 128) then
      warnings[#warnings + 1] = label .. ": превышен лимит коллайдеров"
      break
    end
    if type(source) == "table" then
      local path = cleanPath(source.path)
      local id = type(source.id) == "string" and source.id:sub(1, 512)
        or (path and require("physics_bone_registry").pathKey(path))
      if path and id and not seen[id] then
        seen[id] = true
        local offsetSource = type(source.offset) == "table" and source.offset or {}
        local axisSource = type(source.axis) == "table" and source.axis or {}
        local axis = { x = tonumber(axisSource.x), y = tonumber(axisSource.y), z = tonumber(axisSource.z) }
        local axisLength = math.sqrt((axis.x or 0)^2 + (axis.y or 0)^2 + (axis.z or 0)^2)
        if not finite(axis.x) or not finite(axis.y) or not finite(axis.z) or not finite(axisLength) or axisLength < 0.001 then
          axis = { x = 0, y = 1, z = 0 }
        else
          axis = { x = axis.x / axisLength, y = axis.y / axisLength, z = axis.z / axisLength }
        end
        local offset = {}
        for _, coordinate in ipairs({ "x", "y", "z" }) do
          offset[coordinate] = clamp(offsetSource[coordinate], { -64, 64 }, 0,
            label .. " collider " .. id .. " offset." .. coordinate, warnings)
        end
        local mask = {}
        for _, group in ipairs(GROUPS) do
          if type(source.mask) == "table" and source.mask[group] ~= nil then mask[group] = source.mask[group] == true end
        end
        local validGroups = { body = true, hair = true, ears = true, tail = true, clothing = true, accessories = true, custom = true }
        local group = type(source.group) == "string" and validGroups[source.group] and source.group or "body"
        result[#result + 1] = {
          id = id, path = path, enabled = source.enabled ~= false,
          shape = source.shape == "capsule" and "capsule" or "sphere",
          group = group, mask = mask, offset = offset, axis = axis,
          radius = clamp(source.radius, RANGES.collisionRadius, DEFAULT_SETTINGS.collision.radius,
            label .. " collider " .. id .. " radius", warnings),
          height = clamp(source.height, { 0, 64 }, 4, label .. " collider " .. id .. " height", warnings),
        }
      elseif path then
        warnings[#warnings + 1] = label .. ": повторяется коллайдер " .. id
      else
        warnings[#warnings + 1] = label .. ": коллайдер " .. index .. " пропущен — неверный путь"
      end
    end
  end
  return result
end

local function cleanSettings(raw, warnings, label, schemaVersion)
  raw = type(raw) == "table" and raw or {}
  if schemaVersion == 4 then
    raw = configApi.clone(raw)
    raw.bendStiffness = raw.spring or raw.bendStiffness or DEFAULT_SETTINGS.bendStiffness
    raw.spring = DEFAULT_SETTINGS.spring
  elseif schemaVersion < 5 then
    raw = configApi.clone(raw)
    if raw.restitution == nil then raw.restitution = raw.spring end
    raw.bendStiffness = raw.bendStiffness or DEFAULT_SETTINGS.bendStiffness
    raw.spring = DEFAULT_SETTINGS.spring
  end
  local result = configApi.clone(DEFAULT_SETTINGS)
  result.enabled = raw.enabled ~= false
  result.gravitySpace = raw.gravitySpace == "local" and "local" or "world"
  result.linkControlMode = raw.linkControlMode == "bone" and "bone" or "legacy"
  result.animationTargetMode = (raw.animationTargetMode == "animation" or raw.animationTargetMode == "rest")
    and raw.animationTargetMode or "hybrid"
  local sourceGravity = type(raw.gravity) == "table" and raw.gravity or {}
  for _, axis in ipairs({ "x", "y", "z" }) do
    result.gravity[axis] = clamp(sourceGravity[axis], RANGES.gravity, DEFAULT_SETTINGS.gravity[axis], label .. " gravity." .. axis, warnings)
  end
  for _, field in ipairs({ "gravityTiltResponse", "gravityFalloff", "restShapeReturn", "animationInfluence", "poseFollow", "poseFollowFalloff", "pull", "spring", "bendStiffness", "bendStiffnessFalloff", "restitution", "damping", "mass", "tipMass", "rootMotionResponse", "motionDrag", "avatarMotionResponse", "maxLinearSpeed" }) do
    result[field] = clamp(raw[field], RANGES[field], DEFAULT_SETTINGS[field], label .. " " .. field, warnings)
  end
  local joint = type(raw.joint) == "table" and raw.joint or {}
  result.joint.type = (joint.type == "free" or joint.type == "cone" or joint.type == "hinge") and joint.type or "cone"
  local axis = type(joint.axis) == "table" and joint.axis or {}
  local axisLength = math.sqrt((tonumber(axis.x) or 0)^2 + (tonumber(axis.y) or 0)^2 + (tonumber(axis.z) or 0)^2)
  if not finite(axis.x) or not finite(axis.y) or not finite(axis.z) or not finite(axisLength) or axisLength < 0.001 then
    result.joint.axis = { x = 0, y = 1, z = 0 }
    warnings[#warnings + 1] = label .. " joint.axis: сброшена на локальную Y"
  else
    result.joint.axis = { x = axis.x / axisLength, y = axis.y / axisLength, z = axis.z / axisLength }
  end
  result.joint.angle = clamp(joint.angle, RANGES.angle, DEFAULT_SETTINGS.joint.angle, label .. " joint.angle", warnings)
  result.joint.angularSpeed = clamp(joint.angularSpeed, RANGES.angularSpeed, DEFAULT_SETTINGS.joint.angularSpeed, label .. " joint.angularSpeed", warnings)
  local collision = type(raw.collision) == "table" and raw.collision or {}
  result.collision.enabled = collision.enabled == true
  result.collision.avatar = collision.avatar ~= false
  result.collision.world = collision.world == true
  result.collision.self = collision.self == true
  result.collision.dynamic = collision.dynamic ~= false
  result.collision.group = type(collision.group) == "string" and ({ body = true, hair = true, ears = true,
    tail = true, clothing = true, accessories = true, custom = true })[collision.group] and collision.group or "custom"
  result.collision.mask = {}
  for _, group in ipairs(GROUPS) do
    if type(collision.mask) == "table" and collision.mask[group] ~= nil then
      result.collision.mask[group] = collision.mask[group] == true
    end
  end
  result.collision.radius = clamp(collision.radius, RANGES.collisionRadius, DEFAULT_SETTINGS.collision.radius, label .. " collision.radius", warnings)
  result.collision.friction = clamp(collision.friction, RANGES.collisionFriction, DEFAULT_SETTINGS.collision.friction, label .. " collision.friction", warnings)
  result.collision.restitution = clamp(collision.restitution, RANGES.collisionRestitution, DEFAULT_SETTINGS.collision.restitution, label .. " collision.restitution", warnings)
  result.collision.maxBlockQueries = math.floor(clamp(collision.maxBlockQueries, RANGES.collisionQueries,
    DEFAULT_SETTINGS.collision.maxBlockQueries, label .. " collision.maxBlockQueries", warnings))
  result.collision.maxSelfPairs = math.floor(clamp(collision.maxSelfPairs, RANGES.collisionSelfPairs,
    DEFAULT_SETTINGS.collision.maxSelfPairs, label .. " collision.maxSelfPairs", warnings))
  result.collision.selfNeighborDepth = math.floor(clamp(collision.selfNeighborDepth,
    RANGES.collisionSelfNeighborDepth, DEFAULT_SETTINGS.collision.selfNeighborDepth,
    label .. " collision.selfNeighborDepth", warnings))
  result.collision.iterations = math.floor(clamp(collision.iterations, RANGES.collisionIterations,
    DEFAULT_SETTINGS.collision.iterations, label .. " collision.iterations", warnings))
  return result
end

local function cleanOverride(raw, warnings, label, schemaVersion)
  local result = {}
  if type(raw) ~= "table" then return result end
  if schemaVersion == 4 then
    raw = configApi.clone(raw)
    raw.bendStiffness = raw.spring or raw.bendStiffness
    raw.spring = nil
  elseif schemaVersion < 5 then
    raw = configApi.clone(raw)
    if raw.restitution == nil then result.restitution = raw.spring end
    raw.spring = nil
  end
  for _, field in ipairs({ "enabled", "gravitySpace" }) do
    if raw[field] ~= nil then
      if field == "enabled" then result.enabled = raw.enabled == true
      else result.gravitySpace = raw.gravitySpace == "local" and "local" or "world" end
    end
  end
  for _, field in ipairs({ "gravityTiltResponse", "gravityFalloff", "restShapeReturn", "animationInfluence", "poseFollow", "poseFollowFalloff", "pull", "spring", "bendStiffness", "bendStiffnessFalloff", "restitution", "damping", "mass", "tipMass", "rootMotionResponse", "motionDrag", "avatarMotionResponse", "maxLinearSpeed" }) do
    if raw[field] ~= nil then
      result[field] = clamp(raw[field], RANGES[field], DEFAULT_SETTINGS[field], label .. " " .. field, warnings)
    end
  end
  if raw.animationTargetMode ~= nil then
    result.animationTargetMode = (raw.animationTargetMode == "animation" or raw.animationTargetMode == "rest")
      and raw.animationTargetMode or "hybrid"
  end
  if type(raw.gravity) == "table" then
    result.gravity = {}
    for _, axis in ipairs({ "x", "y", "z" }) do
      if raw.gravity[axis] ~= nil then result.gravity[axis] = clamp(raw.gravity[axis], RANGES.gravity, DEFAULT_SETTINGS.gravity[axis], label .. " gravity." .. axis, warnings) end
    end
  end
  if type(raw.joint) == "table" then
    result.joint = {}
    local joint = raw.joint
    if joint.type ~= nil then result.joint.type = (joint.type == "free" or joint.type == "cone" or joint.type == "hinge") and joint.type or "cone" end
    for _, field in ipairs({ "angle", "angularSpeed" }) do
      if joint[field] ~= nil then result.joint[field] = clamp(joint[field], RANGES[field], DEFAULT_SETTINGS.joint[field], label .. " joint." .. field, warnings) end
    end
    if type(joint.axis) == "table" then
      local axis = joint.axis
      local x, y, z = tonumber(axis.x), tonumber(axis.y), tonumber(axis.z)
      local size = math.sqrt((x or 0)^2 + (y or 0)^2 + (z or 0)^2)
      if finite(x) and finite(y) and finite(z) and finite(size) and size >= 0.001 then
        result.joint.axis = { x = x / size, y = y / size, z = z / size }
      end
    end
  end
  if type(raw.collision) == "table" then
    local collision = raw.collision
    result.collision = {}
    for _, field in ipairs({ "enabled", "avatar", "world", "self", "dynamic" }) do
      if collision[field] ~= nil then result.collision[field] = collision[field] == true end
    end
    if collision.group ~= nil then
      result.collision.group = type(collision.group) == "string"
        and ({ body = true, hair = true, ears = true, tail = true, clothing = true, accessories = true, custom = true })[collision.group]
        and collision.group or "custom"
    end
    if type(collision.mask) == "table" then
      result.collision.mask = {}
      for _, group in ipairs(GROUPS) do
        if collision.mask[group] ~= nil then result.collision.mask[group] = collision.mask[group] == true end
      end
    end
    for _, field in ipairs({ "radius", "friction", "restitution", "maxBlockQueries", "maxSelfPairs", "selfNeighborDepth", "iterations" }) do
      if collision[field] ~= nil then
        local rangeKey = ({ radius = "collisionRadius", friction = "collisionFriction",
          restitution = "collisionRestitution", maxBlockQueries = "collisionQueries",
          maxSelfPairs = "collisionSelfPairs", iterations = "collisionIterations" })[field]
        if field == "selfNeighborDepth" then rangeKey = "collisionSelfNeighborDepth" end
        result.collision[field] = clamp(collision[field], RANGES[rangeKey], DEFAULT_SETTINGS.collision[field],
          label .. " collision." .. field, warnings)
        if field == "maxBlockQueries" or field == "maxSelfPairs" or field == "selfNeighborDepth" or field == "iterations" then
          result.collision[field] = math.floor(result.collision[field])
        end
      end
    end
  end
  return result
end

function configApi.validate(raw)
  local clean, warnings = configApi.defaults(), {}
  if type(raw) ~= "table" then
    warnings[#warnings + 1] = "настройки v2 повреждены; загружены значения по умолчанию"
    return clean, warnings
  end
  if raw.schema ~= 1 and raw.schema ~= 2 and raw.schema ~= 3 and raw.schema ~= 4 and raw.schema ~= 5 and raw.schema ~= 6 then warnings[#warnings + 1] = "неизвестная версия схемы; применены безопасные значения" end
  local schemaVersion = raw.schema
  if schemaVersion ~= 1 and schemaVersion ~= 2 and schemaVersion ~= 3 and schemaVersion ~= 4 and schemaVersion ~= 5 and schemaVersion ~= 6 then
    schemaVersion = 0
  end
  local world = type(raw.world) == "table" and raw.world or {}
  clean.world.performance = (world.performance == "performance" or world.performance == "quality")
    and world.performance or "balanced"
  clean.world.fixedStep = clamp(world.fixedStep, { 1 / 120, 1 / 20 }, DEFAULT_WORLD.fixedStep, "world.fixedStep", warnings)
  clean.world.maxSubsteps = math.floor(clamp(world.maxSubsteps, { 1, 5 }, DEFAULT_WORLD.maxSubsteps, "world.maxSubsteps", warnings))
  clean.world.maxFrameDt = clamp(world.maxFrameDt, { 1 / 60, 0.25 }, DEFAULT_WORLD.maxFrameDt, "world.maxFrameDt", warnings)
  clean.world.maxPoints = math.floor(clamp(world.maxPoints, { 1, 512 }, DEFAULT_WORLD.maxPoints, "world.maxPoints", warnings))
  clean.world.maxCandidatePairs = math.floor(clamp(world.maxCandidatePairs, { 0, 4096 }, DEFAULT_WORLD.maxCandidatePairs, "world.maxCandidatePairs", warnings))
  clean.world.contactIterations = math.floor(clamp(world.contactIterations, { 1, 4 }, DEFAULT_WORLD.contactIterations, "world.contactIterations", warnings))
  clean.world.constraintPasses = math.floor(clamp(world.constraintPasses, { 1, 12 }, DEFAULT_WORLD.constraintPasses, "world.constraintPasses", warnings))
  clean.world.cellSize = clamp(world.cellSize, { 0.25, 8 }, DEFAULT_WORLD.cellSize, "world.cellSize", warnings)
  clean.world.maxCellsPerProxy = math.floor(clamp(world.maxCellsPerProxy, { 8, 1024 }, DEFAULT_WORLD.maxCellsPerProxy, "world.maxCellsPerProxy", warnings))
  clean.world.maxBlockQueries = math.floor(clamp(world.maxBlockQueries, { 0, 256 }, DEFAULT_WORLD.maxBlockQueries, "world.maxBlockQueries", warnings))
  clean.world.segmentMode = world.segmentMode == "segment_segment" and "segment_segment" or "point_segment"
  clean.colliders = cleanColliders(raw.colliders, warnings, "общие коллайдеры аватара", 128)
  if type(world.collisionMatrix) == "table" then
    for _, first in ipairs(GROUPS) do
      local sourceRow = world.collisionMatrix[first]
      if type(sourceRow) == "table" then
        for _, second in ipairs(GROUPS) do
          if sourceRow[second] ~= nil then clean.world.collisionMatrix[first][second] = sourceRow[second] == true end
        end
      end
    end
  end
  if type(world.collisionExclusions) == "table" then
    local seen = {}
    for index, pair in ipairs(world.collisionExclusions) do
      if index > 2016 then
        warnings[#warnings + 1] = "исключения пар столкновений ограничены 2016 записями"
        break
      end
      local first = type(pair) == "table" and pair.first or nil
      local second = type(pair) == "table" and pair.second or nil
      if type(first) == "string" and type(second) == "string"
        and #first > 0 and #first <= 80 and #second > 0 and #second <= 80 and first ~= second then
        if second < first then first, second = second, first end
        local row = seen[first]
        if not row then row = {}; seen[first] = row end
        if not row[second] then
          row[second] = true
          clean.world.collisionExclusions[#clean.world.collisionExclusions + 1] = { first = first, second = second }
        end
      else
        warnings[#warnings + 1] = "некорректное исключение пары столкновений пропущено"
      end
    end
    table.sort(clean.world.collisionExclusions, function(first, second)
      if first.first == second.first then return first.second < second.second end
      return first.first < second.first
    end)
  end
  clean.diagnostics = raw.diagnostics == true
  local roots = {}
  local componentIds = {}
  for index, source in ipairs(type(raw.components) == "table" and raw.components or {}) do
    if index > 64 then warnings[#warnings + 1] = "превышен лимит 64 компонентов"; break end
    if type(source) ~= "table" then
      warnings[#warnings + 1] = "компонент " .. index .. " пропущен: неверный формат"
    else
      local rootPath = cleanPath(source.rootPath)
      local identity = rootPath and require("physics_bone_registry").pathKey(rootPath) or nil
      if not rootPath or roots[identity] then
        warnings[#warnings + 1] = "компонент " .. index .. " пропущен: отсутствует путь или повторяется корень"
      else
        roots[identity] = true
        local componentId = type(source.id) == "string" and source.id:sub(1, 80) or ("component_" .. index)
        if componentIds[componentId] then
          warnings[#warnings + 1] = "компонент " .. index .. ": повторяющийся ID заменён на уникальный"
          local baseId = configApi.defaultsForComponent(rootPath).id
          componentId = baseId
          local suffix = 2
          while componentIds[componentId] do
            local suffixText = "_" .. tostring(suffix)
            componentId = baseId:sub(1, 80 - #suffixText) .. suffixText
            suffix = suffix + 1
          end
        end
        componentIds[componentId] = true
        local component = {
          id = componentId,
          name = type(source.name) == "string" and source.name:sub(1, 80) or "PhysBone",
          enabled = source.enabled ~= false,
          kind = ({ body = true, hair = true, ears = true, tail = true, clothing = true, accessories = true, custom = true })[source.kind]
            and source.kind or "custom",
          rootPath = rootPath,
          branchMode = source.branchMode == "all" and "all" or "selected",
          branchChoices = {}, excludedPaths = {},
          endpoint = { mode = "child" },
          colliders = {},
          settings = cleanSettings(source.settings, warnings, "компонент " .. index, schemaVersion),
          linkOverrides = {},
        }
        local preset = type(source.presetId) == "string" and presetsApi.get(source.presetId) or nil
        if preset and preset.kind == component.kind then component.presetId = preset.id end
        if type(source.restPose) == "table" then
          component.restPose = {}
          for pointIndex, point in ipairs(source.restPose) do
            if pointIndex > 512 then warnings[#warnings + 1] = "компонент " .. index .. ": поза покоя ограничена 512 точками"; break end
            if type(point) == "table" and finite(tonumber(point.x)) and finite(tonumber(point.y)) and finite(tonumber(point.z)) then
              component.restPose[pointIndex] = { x = clamp(point.x, { -64, 64 }, 0, "restPose.x", warnings),
                y = clamp(point.y, { -64, 64 }, 0, "restPose.y", warnings),
                z = clamp(point.z, { -64, 64 }, 0, "restPose.z", warnings) }
            else
              warnings[#warnings + 1] = "компонент " .. index .. ": неверная точка позы покоя пропущена"
            end
          end
          component.restPoseRootFrame = cleanRotationMatrix(source.restPoseRootFrame)
        end
        for parentKey, childKey in pairs(type(source.branchChoices) == "table" and source.branchChoices or {}) do
          if type(parentKey) == "string" and type(childKey) == "string" then component.branchChoices[parentKey:sub(1, 512)] = childKey:sub(1, 512) end
        end
        for _, path in ipairs(type(source.excludedPaths) == "table" and source.excludedPaths or {}) do
          local cleanExcluded = cleanPath(path)
          if cleanExcluded and #component.excludedPaths < 256 then component.excludedPaths[#component.excludedPaths + 1] = cleanExcluded end
        end
        local endpoint = type(source.endpoint) == "table" and source.endpoint or {}
        if endpoint.mode == "child" then
          component.endpoint = { mode = "child" }
        elseif type(endpoint.vector) == "table" then
          local vector = { x = tonumber(endpoint.vector.x), y = tonumber(endpoint.vector.y), z = tonumber(endpoint.vector.z) }
          local len = math.sqrt((vector.x or 0)^2 + (vector.y or 0)^2 + (vector.z or 0)^2)
          if finite(vector.x) and finite(vector.y) and finite(vector.z) and finite(len) and len >= 0.001 and len <= 64 then
            component.endpoint = { mode = "manual", vector = vector }
          else
            warnings[#warnings + 1] = "компонент " .. index .. ": ручная конечная точка некорректна"
          end
        end
        for key, override in pairs(type(source.linkOverrides) == "table" and source.linkOverrides or {}) do
          if type(key) == "string" and type(override) == "table" then
            component.linkOverrides[key:sub(1, 512)] = cleanOverride(override, warnings, "звено " .. key, schemaVersion)
          end
        end
        component.colliders = cleanColliders(source.colliders, warnings, "компонент " .. index, 128)
        clean.components[#clean.components + 1] = component
      end
    end
  end
  return clean, warnings
end

function configApi.effective(component, linkKey)
  local result = configApi.clone(component.settings or DEFAULT_SETTINGS)
  local override = component.linkOverrides and component.linkOverrides[linkKey]
  if type(override) == "table" then
    for key, value in pairs(override) do
      if type(value) == "table" and type(result[key]) == "table" then
        for subKey, subValue in pairs(value) do result[key][subKey] = subValue end
      else
        result[key] = value
      end
    end
  end
  return result
end

local function avatarConfigName()
  local name = "avatar"
  if avatar and type(avatar.getName) == "function" then
    local ok, value = pcall(function() return avatar:getName() end)
    if ok and value ~= nil then name = tostring(value) end
  end
  return name
end

local function safeConfigName(name)
  name = tostring(name or "avatar")
  local slug = name:lower():gsub("[^%w_-]+", "-"):gsub("^[-_]+", ""):gsub("[-_]+$", "")
  if slug == "" then slug = "avatar" end
  local hash = 0
  for index = 1, #name do hash = (hash * 31 + name:byte(index)) % 2147483647 end
  return slug:sub(1, 48) .. "-" .. string.format("%08x", hash)
end

local function isConfigFilenameError(value)
  return tostring(value):find("Failed to parse file name", 1, true) ~= nil
end

local function selectConfigName(name)
  if not config or type(config.setName) ~= "function" then return true end
  return pcall(function() config:setName(name) end)
end

-- Config's selected filename is shared by all scripts on this avatar. Keep a
-- temporary selection scoped to one synchronous load/save operation.
local function withPreservedConfigName(action)
  if not config or type(config.setName) ~= "function" then return pcall(action) end
  if type(config.getName) ~= "function" then
    return false, "Figura Config не сообщает текущее имя хранилища; профиль не изменён.", "name_unavailable"
  end
  local gotName, previousName = pcall(function() return config:getName() end)
  if not gotName or type(previousName) ~= "string" then
    return false, "Не удалось прочитать текущее имя Figura Config; профиль не изменён.", "name_unavailable"
  end
  local ok, a, b, c, d = pcall(action)
  local restored, restoreError = selectConfigName(previousName)
  if not restored then
    return false, "Не удалось восстановить прежнее имя Figura Config: " .. tostring(restoreError), "restore_failed"
  end
  return ok, a, b, c, d
end

function configApi.load()
  local warnings = {}
  local raw
  if config then
    local avatarName = avatarConfigName()
    local scopeOk, loaded, value, storageName, selectionError = withPreservedConfigName(function()
      local selected = avatarName
      local selectionFailure
      if type(config.setName) == "function" then
        local named, nameError = selectConfigName(selected)
        if not named then
          if isConfigFilenameError(nameError) then
            local safeName = safeConfigName(avatarName)
            local safeNamed, safeError = selectConfigName(safeName)
            if safeNamed then
              selected = safeName
              warnings[#warnings + 1] = "Имя аватара нормализовано для профиля PhysBone."
            else
              selectionFailure = safeError
              selected = nil
            end
          else
            selectionFailure = nameError
            selected = nil
          end
        end
      end
      local readOk, readValue
      if selected then readOk, readValue = pcall(function() return config:load(CONFIG_KEY) end)
      else readOk, readValue = false, selectionFailure end
      if not readOk and selected and isConfigFilenameError(readValue) then
        local safeName = safeConfigName(avatarName)
        if safeName ~= selected then
          local named, nameError = selectConfigName(safeName)
          if named then
            local safeLoaded, safeValue = pcall(function() return config:load(CONFIG_KEY) end)
            readOk, readValue = safeLoaded, safeValue
            if safeLoaded then
              selected = safeName
              warnings[#warnings + 1] = "Имя аватара нормализовано для профиля PhysBone."
            end
          else readValue = nameError end
        end
      end
      return readOk, readValue, selected, selectionFailure
    end)
    if not scopeOk then
      warnings[#warnings + 1] = "Не удалось безопасно прочитать локальный профиль PhysBone: " .. tostring(loaded)
      if value ~= "name_unavailable" then return configApi.defaults(), warnings end
      -- Non-host viewers and restricted Config APIs can still use the avatar's
      -- bundled profile without touching the shared local Config selection.
    else
      if not loaded and selectionError then
        warnings[#warnings + 1] = "Не удалось выбрать хранилище профиля аватара: " .. tostring(selectionError)
      end
      if not loaded then
        warnings[#warnings + 1] = "Не удалось прочитать локальный профиль PhysBone: " .. tostring(value)
          .. ". Исходные данные не изменены; используется встроенный профиль, если он доступен."
      else
        activeConfigAvatarName, activeConfigStorageName = avatarName, storageName
        raw = value
      end
    end
  end

  if raw ~= nil then
    if type(raw) ~= "table" then
      warnings[#warnings + 1] = "Повреждённый локальный профиль PhysBone (неверный формат). "
        .. "Исходные данные не изменены; запущены безопасные значения по умолчанию. "
        .. "Импорт physics_bone_preset.lua остаётся доступен в F8."
      return configApi.defaults(), warnings
    end
    local clean, validationWarnings = configApi.validate(raw)
    if #validationWarnings > 0 then
      validationWarnings[#validationWarnings + 1] =
        "Локальный профиль PhysBone содержит некорректные или неподдерживаемые данные. "
          .. "Исходные данные не изменены; в памяти загружена безопасная копия."
    end
    for _, warning in ipairs(warnings) do validationWarnings[#validationWarnings + 1] = warning end
    return clean, validationWarnings
  end

  local ok, bundled = pcall(require, PRESET_MODULE)
  if ok and type(bundled) == "table" then
    local clean, presetWarnings = configApi.validate(bundled)
    for _, warning in ipairs(presetWarnings) do warnings[#warnings + 1] = warning end
    return clean, warnings
  end
  return configApi.defaults(), warnings
end

local function portablePaths(name)
  name = tostring(name or "avatar")
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then slug = "avatar" end
  slug = slug:sub(1, 40)
  local hash = 0
  for index = 1, #name do hash = (hash * 31 + name:byte(index)) % 2147483647 end
  local folder = PRESET_ROOT .. "/" .. slug .. "-" .. string.format("%08x", hash)
  return folder, folder .. "/physics_bone_preset.json", folder .. "/physics_bone_preset.lua"
end

function configApi.exportPreset(raw)
  local clean = configApi.validate(raw)
  if not file then return false, "File API Figura недоступен" end
  local allowedOk, allowed = pcall(function() return file:allowed() end)
  if not allowedOk or allowed ~= true then return false, "сначала разреши File API для этого аватара" end
  local avatarName = "avatar"
  pcall(function() if avatar and type(avatar.getName) == "function" then avatarName = avatar:getName() end end)
  local folder, jsonPath, luaPath = portablePaths(avatarName)
  if type(file.isPathAllowed) == "function" then
    local pathOk, pathAllowed = pcall(function() return file:isPathAllowed(folder) end)
    if not pathOk or pathAllowed ~= true then return false, "Figura запретила запись в figura/data для пресета" end
  end
  local mkdirOk = pcall(function() file:mkdirs(folder) end)
  local dirOk, isDirectory = pcall(function() return file:isDirectory(folder) end)
  if not mkdirOk or not dirOk or isDirectory ~= true then return false, "не удалось создать папку в figura/data" end
  if type(toJson) ~= "function" then return false, "Figura JSON API недоступен" end
  local jsonOk, jsonText = pcall(function() return toJson(clean) end)
  if not jsonOk or type(jsonText) ~= "string" then return false, "не удалось сформировать JSON профиля" end
  local luaText = "return parseJson(" .. string.format("%q", jsonText) .. ")\n"
  local writeJson = pcall(function() file:writeString(jsonPath, jsonText) end)
  local writeLua = pcall(function() file:writeString(luaPath, luaText) end)
  local jsonExistsOk, jsonExists = pcall(function() return file:exists(jsonPath) end)
  local luaExistsOk, luaExists = pcall(function() return file:exists(luaPath) end)
  if not writeJson or not writeLua or not jsonExistsOk or not jsonExists or not luaExistsOk or not luaExists then
    return false, "Figura не подтвердила запись обоих файлов профиля"
  end
  return true, folder
end

function configApi.importBundledPreset()
  local ok, raw = pcall(require, PRESET_MODULE)
  if not ok or type(raw) ~= "table" then return nil, "рядом со скриптами нет physics_bone_preset.lua" end
  local clean, warnings = configApi.validate(raw)
  return clean, warnings
end

function configApi.save(raw)
  local clean, warnings = configApi.validate(raw)
  if not config then return false, "Figura Config недоступен", clean, warnings end
  local avatarName = avatarConfigName()
  local storageName = activeConfigAvatarName == avatarName and activeConfigStorageName or avatarName
  local function writeProfile(name)
    local named, nameError = selectConfigName(name)
    if not named then return false, nameError end
    return pcall(function() return config:save(CONFIG_KEY, clean) end)
  end
  local scopeOk, ok, result, usedName = withPreservedConfigName(function()
    local selected = storageName
    local writeOk, writeResult = writeProfile(selected)
    if not writeOk and isConfigFilenameError(writeResult) then
      local safeName = safeConfigName(avatarName)
      if safeName ~= selected then
        writeOk, writeResult = writeProfile(safeName)
        if writeOk and writeResult ~= false then selected = safeName end
      end
    end
    return writeOk, writeResult, selected
  end)
  if not scopeOk then
    return false, "не удалось безопасно сохранить настройки v2: " .. tostring(ok), clean, warnings
  end
  if not ok or result == false then return false, "не удалось сохранить настройки v2: " .. tostring(result), clean, warnings end
  storageName = usedName
  activeConfigAvatarName, activeConfigStorageName = avatarName, storageName
  local message = storageName == avatarName
      and "настройки v2 сохранены отдельно для этого аватара"
      or "настройки v2 сохранены отдельно под безопасным именем этого аватара"
  return true, message, clean, warnings
end

function configApi.defaultsForComponent(rootPath, name)
  local rootKey = require("physics_bone_registry").pathKey(rootPath or {})
  local hash = 0
  for index = 1, #rootKey do hash = (hash * 31 + rootKey:byte(index)) % 2147483647 end
  local settings = configApi.clone(DEFAULT_SETTINGS)
  settings.gravityTiltResponse = 1
  settings.restShapeReturn = 0.5
  settings.linkControlMode = "bone"
  return {
    id = "physbone_" .. string.format("%08x", hash),
    name = name or "PhysBone",
    kind = "custom",
    enabled = true,
    rootPath = configApi.clone(rootPath), branchMode = "selected",
    branchChoices = {}, excludedPaths = {},
    colliders = {},
    endpoint = { mode = "child" },
    settings = settings, linkOverrides = {},
  }
end

function configApi.componentKinds()
  return presetsApi.componentKinds()
end

function configApi.componentKindLabel(kind)
  return presetsApi.kindLabel(kind)
end

function configApi.presetsForKind(kind)
  return presetsApi.presetsForKind(kind)
end

function configApi.applyPreset(component, presetId)
  if type(component) ~= "table" then return false, "не выбран компонент" end
  local preset = presetsApi.get(presetId)
  if not preset then return false, "стартовый профиль не найден" end
  local settings = configApi.clone(DEFAULT_SETTINGS)
  local function merge(target, source)
    for key, value in pairs(source or {}) do
      if type(value) == "table" and type(target[key]) == "table" then merge(target[key], value)
      else target[key] = configApi.clone(value) end
    end
  end
  merge(settings, preset.settings)
  settings.linkControlMode = "bone"
  settings.collision.group = preset.kind
  component.kind = preset.kind
  component.presetId = preset.id
  component.settings = settings
  return true, preset.label
end

return configApi
