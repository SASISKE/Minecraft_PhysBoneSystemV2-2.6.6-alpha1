local registryApi = require("physics_bone_registry")
local chainApi = require("physics_bone_chain")
local configApi = require("physics_bone_config")
local inputApi = require("physics_bone_input")
local core = require("physics_bone_core")
local collisionsApi = require("physics_bone_collisions")
local gizmosApi = require("physics_bone_gizmos")
local uiApi = require("physics_bone_ui")
local worldApi = require("physics_bone_world")
local diagnosticsApi = require("physics_bone_diagnostics")

local studio = {
  initialized = false, rootPart = nil, registry = nil,
  savedConfig = nil, draftConfig = nil, runtimes = {}, graphs = {},
  input = inputApi.new(), ui = nil, gizmos = gizmosApi.new(),
  physicsWorld = worldApi.new(), worldDiagnostics = {}, worldQueryBudget = { cache = {} },
  sharedAvatarShapes = {}, sharedAvatarShapeCount = 0, componentAvatarShapeCount = 0,
  sharedComponentAvatarShapes = {}, componentColliderSources = {},
  avatarColliderGrid = collisionsApi.newShapeGrid(), activeBodyColliderCount = 0,
  instructionDiagnostics = diagnosticsApi.new(),
  lastInput = nil, alive = true, playerWasLoaded = nil, lastError = nil,
}

local TICK_DT = 1 / 20
local EVENT_NAME = "figura.physics_bone_v2"
local GLFW_KEY_GRAVE_ACCENT = 96
local GLFW_MOD_SHIFT = 0x0001
local updateGizmoState

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local args = { ... }
  local ok, result = pcall(fn, object, (table.unpack or unpack)(args))
  if ok then return result end
  return nil
end

local function emitLog(message)
  if type(_G.log) == "function" then pcall(_G.log, "[PhysBone v2] " .. tostring(message)) end
end

local function solverClockMs()
  local clockApi = type(os) == "table" and os.clock or nil
  if type(clockApi) == "function" then
    local ok, value = pcall(clockApi)
    if ok and type(value) == "number" and value == value and value ~= math.huge then return value * 1000 end
  end
  local value = safeCall(client, "getSystemTime")
  if type(value) == "number" and value == value and value ~= math.huge then return value end
  return nil
end

local function diagnosticsVisible()
  return studio.testCapture == true or (studio.ui and studio.ui.open == true
    and studio.draftConfig and studio.draftConfig.diagnostics == true)
end

local function sampleInstructionDiagnostics(kind)
  local diagnostics = studio.instructionDiagnostics
  local enabled = diagnosticsVisible()
  diagnostics:setEnabled(enabled)
  -- Figura reports the previous completed TICK; this lightweight sample lets the
  -- scheduler reduce optional work before starting the next physics step.
  if kind == "tick" then diagnostics:sampleTick(avatar, true)
  elseif enabled and kind == "render" then diagnostics:sampleRender(avatar) end
end

local function vec3(x, y, z)
  return { x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0 }
end

local function vectorFrom(value)
  if not value then return vec3(0, 0, 0) end
  local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
  if not x or not y or not z or x ~= x or y ~= y or z ~= z
    or x == math.huge or y == math.huge or z == math.huge then return vec3(0, 0, 0) end
  return vec3(x, y, z)
end

local function identity()
  return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
end

local function copyMatrix(matrix)
  local result = identity()
  if type(matrix) == "table" then
    for row = 1, 3 do for col = 1, 3 do result[row][col] = matrix[row][col] end end
  end
  return result
end

local function multiply(a, b)
  local result = identity()
  for row = 1, 3 do
    for col = 1, 3 do
      result[row][col] = 0
      for index = 1, 3 do result[row][col] = result[row][col] + a[row][index] * b[index][col] end
    end
  end
  return result
end

local function transpose(matrix)
  local result = identity()
  for row = 1, 3 do
    for col = 1, 3 do result[row][col] = matrix[col][row] end
  end
  return result
end

local function dot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

local function subtract(a, b)
  return vec3(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function scale(value, amount)
  return vec3(value.x * amount, value.y * amount, value.z * amount)
end

local function cross(a, b)
  return vec3(a.y * b.z - a.z * b.y,
    a.z * b.x - a.x * b.z,
    a.x * b.y - a.y * b.x)
end

local function normalize(value)
  local magnitude = math.sqrt(dot(value, value))
  if not magnitude or magnitude < 0.000001 or magnitude ~= magnitude or magnitude == math.huge then return nil end
  return scale(value, 1 / magnitude)
end

-- The world-to-parent matrix also contains model-pixel scale. Keep that scale
-- for gravity, but remove it before extracting frame rotation for inertia.
local function rotationOnly(frame)
  if type(frame) ~= "table" then return nil end
  local x = normalize(vec3(frame[1][1], frame[2][1], frame[3][1]))
  local rawY = vec3(frame[1][2], frame[2][2], frame[3][2])
  if not x then return nil end
  local y = normalize(subtract(rawY, scale(x, dot(x, rawY))))
  if not y then return nil end
  local z = normalize(cross(x, y))
  if not z then return nil end
  return {
    { x.x, y.x, z.x },
    { x.y, y.y, z.y },
    { x.z, y.z, z.z },
  }
end

local function rotationVector(matrix)
  local cosine = math.max(-1, math.min(1,
    (matrix[1][1] + matrix[2][2] + matrix[3][3] - 1) * 0.5))
  local angle = math.acos(cosine)
  if angle < 0.000001 then
    return vec3((matrix[3][2] - matrix[2][3]) * 0.5,
      (matrix[1][3] - matrix[3][1]) * 0.5,
      (matrix[2][1] - matrix[1][2]) * 0.5)
  end
  local sine = math.sin(angle)
  if math.abs(sine) < 0.000001 then return nil end
  local axis = vec3((matrix[3][2] - matrix[2][3]) / (2 * sine),
    (matrix[1][3] - matrix[3][1]) / (2 * sine),
    (matrix[2][1] - matrix[1][2]) / (2 * sine))
  return scale(axis, angle)
end

local function capVector(value, maximum)
  local magnitude = math.sqrt(dot(value, value))
  if magnitude <= maximum or magnitude < 0.000001 then return value end
  return scale(value, maximum / magnitude)
end

local function validMatrix(matrix)
  if type(matrix) ~= "table" then return false end
  for row = 1, 3 do
    if type(matrix[row]) ~= "table" then return false end
    for column = 1, 3 do
      local entry = matrix[row][column]
      if type(entry) ~= "number" or entry ~= entry or entry == math.huge or entry == -math.huge then return false end
    end
  end
  return true
end

local function transform(matrix, value)
  if not validMatrix(matrix) then return vec3(value.x, value.y, value.z) end
  return vec3(
    matrix[1][1] * value.x + matrix[1][2] * value.y + matrix[1][3] * value.z,
    matrix[2][1] * value.x + matrix[2][2] * value.y + matrix[2][3] * value.z,
    matrix[3][1] * value.x + matrix[3][2] * value.y + matrix[3][3] * value.z)
end

local worldToParentFrame

local function matrixBasis(matrix)
  if not matrix or type(vec) ~= "function" then return nil end
  local function axis(x, y, z)
    local result = safeCall(matrix, "applyDir", vec(x, y, z))
    return result and vectorFrom(result) or nil
  end
  local xAxis, yAxis, zAxis = axis(1, 0, 0), axis(0, 1, 0), axis(0, 0, 1)
  if not xAxis or not yAxis or not zAxis then return nil end
  return {
    { xAxis.x, yAxis.x, zAxis.x },
    { xAxis.y, yAxis.y, zAxis.y },
    { xAxis.z, yAxis.z, zAxis.z },
  }, { xAxis, yAxis, zAxis }
end

local function vectorLength(value)
  return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

local function worldBlockGetter()
  local ok, getter = pcall(function() return world and world.getBlockState end)
  if ok and type(getter) == "function" then return getter end
  return nil
end

local function blockAabbsAt(blockX, blockY, blockZ, getter)
  if type(getter) ~= "function" then return nil, false end
  local ok, state = pcall(getter, blockX, blockY, blockZ)
  if not ok or not state then return nil, false end
  local hasCollision = safeCall(state, "hasCollision")
  if hasCollision == false then return {}, true end
  local shapes = safeCall(state, "getCollisionShape")
  if type(shapes) ~= "table" then return {}, true end
  local result = {}
  for _, shape in ipairs(shapes) do
    local low, high = shape[1], shape[2]
    if low and high then
      local a, b = vectorFrom(low), vectorFrom(high)
      result[#result + 1] = {
        min = { x = blockX + math.min(a.x, b.x), y = blockY + math.min(a.y, b.y), z = blockZ + math.min(a.z, b.z) },
        max = { x = blockX + math.max(a.x, b.x), y = blockY + math.max(a.y, b.y), z = blockZ + math.max(a.z, b.z) },
        kind = "block", blockX = blockX, blockY = blockY, blockZ = blockZ,
      }
    end
  end
  return result, true
end

local function newCollisionContext(runtime)
  local context = {
    enabled = false, avatarShapes = {}, componentAvatarShapes = {}, sharedAvatarShapes = nil,
    avatarShapeGrid = nil, avatarShapeCandidates = {}, avatarShapeSeen = {}, contactShapeScratch = {},
    componentAvatarShapeCount = 0, rootOriginWorld = vec3(0, 0, 0),
    worldScale = 1, frameAvailable = false, worldQueries = 0, budgetExceeded = false, worldUnavailable = false,
    sharedQueryBudget = nil,
  }
  context.toWorldPoint = function(point, out)
    if context.frameAvailable ~= true or not validMatrix(context.parentToWorld) then return nil end
    local matrix, origin = context.parentToWorld, context.rootOriginWorld
    out = type(out) == "table" and out or {}
    out.x = origin.x + matrix[1][1] * point.x + matrix[1][2] * point.y + matrix[1][3] * point.z
    out.y = origin.y + matrix[2][1] * point.x + matrix[2][2] * point.y + matrix[2][3] * point.z
    out.z = origin.z + matrix[3][1] * point.x + matrix[3][2] * point.y + matrix[3][3] * point.z
    return out
  end
  context.toParentVector = function(direction)
    if context.frameAvailable ~= true or not validMatrix(context.worldToParent) then return nil end
    return transform(context.worldToParent, direction)
  end
  context.queryWorld = function(position, radius)
    if context.worldAvailable ~= true then return {}, 0, false, false end
    local minX, maxX = math.floor(position.x - radius), math.floor(position.x + radius)
    local minY, maxY = math.floor(position.y - radius), math.floor(position.y + radius)
    local minZ, maxZ = math.floor(position.z - radius), math.floor(position.z + radius)
    local result, before, exhausted = {}, context.worldQueries, false
    for blockX = minX, maxX do
      for blockY = minY, maxY do
        for blockZ = minZ, maxZ do
          local key = blockX .. ":" .. blockY .. ":" .. blockZ
          local cached = context.blockCache[key]
          if cached == nil then
            local sharedBudget = context.sharedQueryBudget
            if context.worldQueries >= context.maxBlockQueries
              or (sharedBudget and (tonumber(sharedBudget.remaining) or 0) <= 0) then
              exhausted = true
              context.budgetExceeded = true
              if sharedBudget then sharedBudget.exhausted = true end
              break
            end
            local shapes, available = blockAabbsAt(blockX, blockY, blockZ, context.getBlockState)
            context.worldQueries = context.worldQueries + 1
            if sharedBudget then
              sharedBudget.remaining = math.max(0, (tonumber(sharedBudget.remaining) or 0) - 1)
              sharedBudget.total = (tonumber(sharedBudget.total) or 0) + 1
            end
            context.worldAvailable = context.worldAvailable and available == true
            cached = shapes or {}
            context.blockCache[key] = cached
          end
          for _, shape in ipairs(cached) do result[#result + 1] = shape end
        end
        if exhausted then break end
      end
      if exhausted then break end
    end
    return result, context.worldQueries - before, exhausted, context.worldAvailable
  end
  context.beginTick = function(settings, sharedQueryBudget)
    local collision = settings or {}
    context.sharedQueryBudget = sharedQueryBudget
    context.blockCache = sharedQueryBudget and sharedQueryBudget.cache or {}
    context.worldQueries = 0
    context.budgetExceeded = false
    context.worldUnavailable = false
    context.maxBlockQueries = math.max(0, math.floor(tonumber(collision.maxBlockQueries) or 64))
    context.maxSelfPairs = math.max(0, math.floor(tonumber(collision.maxSelfPairs) or 2048))
    context.getBlockState = worldBlockGetter()
    context.worldAvailable = context.getBlockState ~= nil
    context.enabled = collision.enabled == true
    context.friction = tonumber(collision.friction) or 0.25
    context.restitution = tonumber(collision.restitution) or 0
  end
  return context
end

local function colliderWorldShape(collider, shape)
  if type(collider) ~= "table" then return nil end
  local key = registryApi.pathKey(collider.path)
  local node = studio.registry and studio.registry.byKey[key]
  local partMatrix = node and safeCall(node.part, "partToWorldMatrix")
  if not partMatrix then return nil end
  local offset = collider.offset or { x = 0, y = 0, z = 0 }
  local center = safeCall(partMatrix, "apply", vec(offset.x or 0, offset.y or 0, offset.z or 0))
  local basis, axes = matrixBasis(partMatrix)
  if not center or not basis then return nil end
  local radiusScale = math.max(vectorLength(axes[1]), vectorLength(axes[2]), vectorLength(axes[3]))
  local radius = math.max(0.001, (tonumber(collider.radius) or 0.5) * radiusScale)
  shape = type(shape) == "table" and shape or {}
  shape.id, shape.group, shape.mask, shape.radius = collider.id, collider.group or "body", collider.mask, radius
  if collider.shape == "capsule" then
    local axis = collider.axis or { x = 0, y = 1, z = 0 }
    local halfHeight = (tonumber(collider.height) or 0) * 0.5
    local first = safeCall(partMatrix, "apply", vec(
      (offset.x or 0) - (axis.x or 0) * halfHeight,
      (offset.y or 0) - (axis.y or 1) * halfHeight,
      (offset.z or 0) - (axis.z or 0) * halfHeight))
    local second = safeCall(partMatrix, "apply", vec(
      (offset.x or 0) + (axis.x or 0) * halfHeight,
      (offset.y or 0) + (axis.y or 1) * halfHeight,
      (offset.z or 0) + (axis.z or 0) * halfHeight))
    if not first or not second then return nil end
    shape.kind, shape.a, shape.b = "capsule", vectorFrom(first), vectorFrom(second)
    shape.center, shape.min, shape.max = nil, nil, nil
  else
    shape.kind, shape.center = "sphere", vectorFrom(center)
    shape.a, shape.b, shape.min, shape.max = nil, nil, nil, nil
  end
  return shape
end

local function updateCollisionFrame(runtime, sharedAvatarShapes, avatarShapeGrid, parentMatrix, worldToParent, rootMatrix)
  local settings = studio.testCapture and runtime.testCollisionSettings
    or (runtime.settings and runtime.settings.collision or {})
  local context = runtime.collisionContext
  context.frameAvailable = false
  context.enabled = settings.enabled == true or runtime.collisionOverrideEnabled == true
  context.sharedAvatarShapes = sharedAvatarShapes or {}
  context.avatarShapeGrid = avatarShapeGrid
  context.componentAvatarShapes = studio.sharedComponentAvatarShapes or {}
  context.componentAvatarShapeCount = studio.componentAvatarShapeCount or 0
  context.avatarShapes = context.componentAvatarShapes
  if not context.enabled then return end
  if not rootMatrix then
    local root = runtime.linkNodes[1] and runtime.linkNodes[1].part
    rootMatrix = safeCall(root, "partToWorldMatrix")
  end
  local parentToWorld, worldAxes = matrixBasis(parentMatrix)
  local rootOrigin = rootMatrix and safeCall(rootMatrix, "apply", vec(0, 0, 0))
  if not parentToWorld or not worldToParent or not rootOrigin then
    context.enabled = false
    context.worldUnavailable = true
    return
  end
  context.parentToWorld, context.worldToParent = parentToWorld, worldToParent
  context.frameAvailable = true
  context.rootOriginWorld = vectorFrom(rootOrigin)
  context.worldScale = math.max(vectorLength(worldAxes[1]), vectorLength(worldAxes[2]), vectorLength(worldAxes[3]), 0.000001)
  context.collisionMatrix = studio.draftConfig and studio.draftConfig.world
    and studio.draftConfig.world.collisionMatrix or nil
  if studio.testCapture and runtime.testUseSyntheticCollisionShape then
    context.componentAvatarShapes = runtime.testCollisionShapes or {}
    context.componentAvatarShapeCount = #context.componentAvatarShapes
    context.avatarShapes = context.componentAvatarShapes
    return
  end
end

local function sampleFrameMotion(runtime, currentFrame, dt, tick)
  local frameVersion = runtime.rotationFrameVersion or 0
  if runtime.sampledRotationFrameVersion == frameVersion then
    return runtime.frameMotion or { available = false, angularVelocity = vec3(0, 0, 0), angularAcceleration = vec3(0, 0, 0) }
  end
  runtime.sampledRotationFrameVersion = frameVersion
  local current = currentFrame and copyMatrix(currentFrame) or nil
  local zero = vec3(0, 0, 0)
  local currentTick = tonumber(tick) or studio.tickCount or 0
  local elapsedTicks = currentTick - (runtime.previousRotationSampleTick or currentTick)
  runtime.previousRotationSampleTick = currentTick
  if elapsedTicks > 0 then dt = elapsedTicks * TICK_DT end
  if not current then
    runtime.previousRotationFrame = nil
    runtime.previousFrameAngularVelocity = zero
    return { available = false, angularVelocity = zero, angularAcceleration = zero }
  end

  local previous = runtime.previousRotationFrame
  local previousVelocity = runtime.previousFrameAngularVelocity or zero
  runtime.previousRotationFrame = current
  if not previous then
    runtime.previousFrameAngularVelocity = zero
    return { available = true, angularVelocity = zero, angularAcceleration = zero }
  end

  dt = tonumber(dt)
  if not dt or dt <= 0 or dt ~= dt or dt == math.huge then dt = TICK_DT end
  local previousToCurrent = multiply(previous, transpose(current))
  local rotationStep = rotationVector(previousToCurrent)
  if not rotationStep then
    runtime.previousFrameAngularVelocity = zero
    return { available = false, angularVelocity = zero, angularAcceleration = zero }
  end
  local angle = math.sqrt(dot(rotationStep, rotationStep))
  -- Treat an abrupt frame discontinuity as a reset instead of a violent impulse.
  if angle > math.rad(90) then
    runtime.previousFrameAngularVelocity = zero
    return { available = false, angularVelocity = zero, angularAcceleration = zero }
  end

  local maxAngularSpeed = math.rad(720)
  local maxAngularAcceleration = math.rad(900)
  local angularVelocityPrevious = capVector(scale(rotationStep, 1 / dt), maxAngularSpeed)
  local currentFromPrevious = transpose(previousToCurrent)
  local angularVelocity = transform(currentFromPrevious, angularVelocityPrevious)
  local previousVelocityCurrent = transform(currentFromPrevious, previousVelocity)
  local angularAcceleration = capVector(
    scale(subtract(angularVelocity, previousVelocityCurrent), 1 / dt), maxAngularAcceleration)
  runtime.previousFrameAngularVelocity = angularVelocity
  return {
    available = true,
    angularVelocity = angularVelocity,
    angularAcceleration = angularAcceleration,
  }
end

-- Prefer the actual animated root pivot for bone-mode translation. The player
-- position alone misses motion from body animations (lying down, rolling,
-- bending), while adding the two would count locomotion twice.
function studio.captureAnimatedRootPosition(runtime, position, frameTime)
  local ok, x, y, z = pcall(function() return tonumber(position.x), tonumber(position.y), tonumber(position.z) end)
  local function finiteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end
  if not ok or not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z) or not finiteNumber(frameTime) then
    runtime.rootWorldFrameAvailable = false
    return false
  end
  runtime.rootWorldPosition, runtime.rootWorldFrameTime = vec3(x, y, z), frameTime
  runtime.rootWorldFrameVersion = (runtime.rootWorldFrameVersion or 0) + 1
  runtime.rootWorldFrameAvailable = true
  return true
end

function studio.canSampleAnimatedRoot(part, renderContext)
  if renderContext ~= nil and renderContext ~= "RENDER" then return false end
  local seen = {}
  while part do
    if seen[part] or safeCall(part, "getVisible") == false then return false end
    seen[part] = true
    part = safeCall(part, "getParent")
  end
  return true
end

function studio.sampleAnimatedRootMotion(runtime, playerMotion, tick)
  playerMotion = playerMotion or {}
  if not runtime or not runtime.settings or runtime.settings.linkControlMode ~= "bone"
    or (studio.testCapture and type(studio.testInputProvider) == "function") then
    return playerMotion
  end
  local tracker = runtime.animatedRootTracker
  if not tracker then tracker = inputApi.newPositionTracker(); runtime.animatedRootTracker = tracker end
  local function clearSample()
    tracker:reset()
    runtime.animatedRootSampleVersion, runtime.animatedRootSampleTime = nil, nil
    runtime.animatedRootMotion, runtime.animatedRootEmittedVelocity = nil, nil
    runtime.animatedRootScheduledAcceleration, runtime.animatedRootScheduledTicks = nil, 0
    runtime.animatedRootLastDispatchTick = nil
  end
  if runtime.rootWorldFrameAvailable ~= true or not runtime.rootWorldPosition then
    clearSample()
    return playerMotion
  end
  local currentTick = tonumber(tick) or 0
  local function dispatch()
    if not runtime.animatedRootMotion then return playerMotion end
    if runtime.animatedRootLastDispatchTick == currentTick then return runtime.animatedRootMotion end
    local acceleration = vec3(0,0,0)
    if (runtime.animatedRootScheduledTicks or 0) > 0 then
      acceleration = runtime.animatedRootScheduledAcceleration
      runtime.animatedRootScheduledTicks = runtime.animatedRootScheduledTicks - 1
      local previous = runtime.animatedRootEmittedVelocity
      runtime.animatedRootEmittedVelocity = vec3(previous.x + acceleration.x * TICK_DT,
        previous.y + acceleration.y * TICK_DT, previous.z + acceleration.z * TICK_DT)
    end
    runtime.animatedRootMotion = { rootVelocity = runtime.animatedRootMotion.rootVelocity, rootAcceleration = acceleration }
    runtime.animatedRootLastDispatchTick = currentTick
    return runtime.animatedRootMotion
  end
  local version = runtime.rootWorldFrameVersion or 0
  if runtime.animatedRootSampleVersion == version then
    if currentTick - (runtime.animatedRootSampleTick or currentTick) > 2 then
      clearSample()
      runtime.rootWorldFrameAvailable = false
      return playerMotion
    end
    return dispatch()
  end
  local sampleTime = tonumber(runtime.rootWorldFrameTime)
  local previousTime = runtime.animatedRootSampleTime
  runtime.animatedRootSampleVersion, runtime.animatedRootSampleTick = version, currentTick
  if not sampleTime or sampleTime ~= sampleTime or sampleTime == math.huge or sampleTime == -math.huge
    or (previousTime and (sampleTime <= previousTime or sampleTime - previousTime > 5)) then
    clearSample()
    return playerMotion
  end
  local elapsed = previousTime and (sampleTime - previousTime) * TICK_DT or TICK_DT
  -- Merge measurements straddling a tick boundary when they are too close to
  -- differentiate reliably; keep the old timestamp and position for the next.
  if previousTime and elapsed < 1 / 240 then return dispatch() end
  runtime.animatedRootSampleTime = sampleTime
  local sampled = tracker:sample(runtime.rootWorldPosition, elapsed)
  if not sampled.available then
    runtime.animatedRootMotion, runtime.animatedRootEmittedVelocity = nil, nil
    runtime.animatedRootScheduledTicks = 0
    return playerMotion
  end
  local emitted = runtime.animatedRootEmittedVelocity
  if not emitted then
    runtime.animatedRootEmittedVelocity = sampled.velocity
    runtime.animatedRootScheduledTicks = 0
  else
    local steps = math.max(1, math.min(5, math.floor(elapsed / TICK_DT + 0.5)))
    runtime.animatedRootScheduledAcceleration = capVector(scale(subtract(sampled.velocity, emitted),
      1 / (steps * TICK_DT)), 48)
    runtime.animatedRootScheduledTicks = steps
  end
  runtime.animatedRootMotion = { rootVelocity = sampled.velocity, rootAcceleration = vec3(0,0,0) }
  return dispatch()
end

local function resetFrameMotion(runtime)
  runtime.previousRotationFrame = runtime.rotationFrameAvailable and copyMatrix(runtime.rotationFrame) or nil
  runtime.previousFrameAngularVelocity = vec3(0, 0, 0)
  runtime.sampledRotationFrameVersion = runtime.rotationFrameVersion or 0
  runtime.previousRotationSampleTick = studio.tickCount or 0
  if runtime.animatedRootTracker then runtime.animatedRootTracker:reset() end
  runtime.animatedRootSampleVersion, runtime.animatedRootSampleTick, runtime.animatedRootSampleTime, runtime.animatedRootMotion = nil, nil, nil, nil
  runtime.animatedRootEmittedVelocity, runtime.animatedRootScheduledAcceleration = nil, nil
  runtime.animatedRootScheduledTicks, runtime.animatedRootLastDispatchTick = 0, nil
  runtime.rootWorldFrameAvailable, runtime.rootWorldPosition, runtime.rootWorldFrameTime = false, nil, nil
  runtime.frameMotion = {
    available = runtime.rotationFrameAvailable == true,
    angularVelocity = vec3(0, 0, 0),
    angularAcceleration = vec3(0, 0, 0),
  }
end
studio.resetFrameMotion = resetFrameMotion

local function rotationMatrix(rotation)
  local x, y, z = math.rad(rotation.x), math.rad(rotation.y), math.rad(rotation.z)
  local sx, cx, sy, cy, sz, cz = math.sin(x), math.cos(x), math.sin(y), math.cos(y), math.sin(z), math.cos(z)
  return {
    { cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx },
    { sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx },
    { -sy, cy * sx, cy * cx },
  }
end

local function rotationVectorToEuler(rx, ry, rz)
  local angle = math.sqrt(rx * rx + ry * ry + rz * rz)
  if angle < 0.000001 then return 0, 0, 0 end
  local ax, ay, az = rx / angle, ry / angle, rz / angle
  local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
  local r11 = t * ax * ax + c
  local r21 = t * ax * ay + s * az
  local r31 = t * ax * az - s * ay
  local r32 = t * ay * az + s * ax
  local r33 = t * az * az + c
  local pitch = math.asin(math.max(-1, math.min(1, -r31)))
  local function atan2(yValue, xValue)
    if math.atan2 then return math.atan2(yValue, xValue) end
    if xValue > 0 then return math.atan(yValue / xValue) end
    if xValue < 0 and yValue >= 0 then return math.atan(yValue / xValue) + math.pi end
    if xValue < 0 and yValue < 0 then return math.atan(yValue / xValue) - math.pi end
    if xValue == 0 and yValue > 0 then return math.pi / 2 end
    if xValue == 0 and yValue < 0 then return -math.pi / 2 end
    return 0
  end
  local roll = atan2(r32, r33)
  local yaw = atan2(r21, r11)
  return math.deg(roll), math.deg(pitch), math.deg(yaw)
end

local function partName(part)
  return tostring(safeCall(part, "getName") or "")
end

local function modelRoot()
  local ok, modelCollection = pcall(function() return models end)
  if not ok or not modelCollection then return nil end
  local raw = safeCall(modelCollection, "getChildren")
  if type(raw) ~= "table" then return nil end
  local parts = {}
  for _, part in pairs(raw) do if part then parts[#parts + 1] = part end end
  table.sort(parts, function(a, b) return partName(a) < partName(b) end)
  local candidates = {}
  for _, part in ipairs(parts) do
    local name = partName(part)
    if name ~= "PhysBoneV2HUD" and name ~= "PhysicsStudioHUD" and name ~= "PhysicsStudioGizmos" then
      local children = safeCall(part, "getChildren")
      if type(children) == "table" then
        for _, child in pairs(children) do
          if partName(child) == "root" and safeCall(child, "getType") == "GROUP" then return child end
        end
      end
      if safeCall(part, "getType") == "GROUP" then candidates[#candidates + 1] = part end
    end
  end
  return candidates[1]
end

worldToParentFrame = function(runtime, frameCache)
  local root = runtime and runtime.linkNodes and runtime.linkNodes[1] and runtime.linkNodes[1].part
  local parent = safeCall(root, "getParent")
  local cached = parent and frameCache and frameCache[parent]
  if cached then return cached.frame, cached.matrix end
  local worldMatrix = safeCall(parent, "partToWorldMatrix")
  local inverse = safeCall(worldMatrix, "inverted")
  if not inverse or type(vec) ~= "function" then return nil end
  local function axis(x, y, z)
    local ok, result = pcall(function() return inverse:applyDir(vec(x, y, z)) end)
    return ok and vectorFrom(result) or nil
  end
  local xAxis, yAxis, zAxis = axis(1, 0, 0), axis(0, 1, 0), axis(0, 0, 1)
  if not xAxis or not yAxis or not zAxis then return nil end
  local frame = {
    { xAxis.x, yAxis.x, zAxis.x },
    { xAxis.y, yAxis.y, zAxis.y },
    { xAxis.z, yAxis.z, zAxis.z },
  }
  if parent and frameCache then frameCache[parent] = { frame = frame, matrix = worldMatrix } end
  return frame, worldMatrix
end

local function buildAnimatedTargets(runtime)
  local graph = runtime.graph
  local points, linkFrames, afterFrames = {}, {}, {}
  for index = 1, graph.pointCount do points[index] = vec3(0, 0, 0) end
  if #graph.links == 0 then return points, linkFrames end
  points[1] = vec3(0, 0, 0)
  for linkIndex, link in ipairs(graph.links) do
    local parentFrame = link.parentIndex and afterFrames[link.parentIndex] or identity()
    linkFrames[linkIndex] = copyMatrix(parentFrame)
    local node = runtime.linkNodes[linkIndex]
    local currentRotation = vectorFrom(safeCall(node and node.part, "getTrueRot"))
    local applied = runtime.appliedEuler[linkIndex] or vec3(0, 0, 0)
    local animatedRotation = vec3(currentRotation.x - applied.x, currentRotation.y - applied.y, currentRotation.z - applied.z)
    runtime.animatedRotations[linkIndex] = animatedRotation
    local after = multiply(parentFrame, rotationMatrix(animatedRotation))
    afterFrames[linkIndex] = after
    for _, edge in ipairs((graph.edgesByLink and graph.edgesByLink[linkIndex]) or {}) do
        local rest = edge.restVector or vec3(0, -1, 0)
        if not edge.terminal then
          local child = runtime.linkNodes[edge.to]
          local animatedPos = vectorFrom(safeCall(child and child.part, "getTruePos"))
          rest = vec3(rest.x + animatedPos.x, rest.y + animatedPos.y, rest.z + animatedPos.z)
        end
        local delta = transform(after, rest)
        points[edge.to] = vec3(points[edge.from].x + delta.x, points[edge.from].y + delta.y, points[edge.from].z + delta.z)
    end
  end
  runtime.linkFrames = linkFrames
  return points, linkFrames, afterFrames
end

-- Build the chain's neutral reference from the Blockbench pose, not from the
-- currently playing animation. Figura's getTrue* accessors include animation
-- and offsets, which may already be curled when this component is created.
local function buildBindPoseTargets(runtime)
  local graph = runtime.graph
  local points, linkFrames, afterFrames = {}, {}, {}
  for index = 1, graph.pointCount do points[index] = vec3(0, 0, 0) end
  if #graph.links == 0 then return points, linkFrames, afterFrames end
  points[1] = vec3(0, 0, 0)
  for linkIndex, link in ipairs(graph.links) do
    local parentFrame = link.parentIndex and afterFrames[link.parentIndex] or identity()
    linkFrames[linkIndex] = copyMatrix(parentFrame)
    local node = runtime.linkNodes[linkIndex]
    local bindRotation = vectorFrom(safeCall(node and node.part, "getRot"))
    local after = multiply(parentFrame, rotationMatrix(bindRotation))
    afterFrames[linkIndex] = after
    for _, edge in ipairs((graph.edgesByLink and graph.edgesByLink[linkIndex]) or {}) do
      local rest = edge.restVector or vec3(0, -1, 0)
      if not edge.terminal then
        local child = runtime.linkNodes[edge.to]
        local bindPosition = vectorFrom(safeCall(child and child.part, "getPos"))
        rest = vec3(rest.x + bindPosition.x, rest.y + bindPosition.y, rest.z + bindPosition.z)
      end
      local delta = transform(after, rest)
      points[edge.to] = vec3(points[edge.from].x + delta.x,
        points[edge.from].y + delta.y, points[edge.from].z + delta.z)
    end
  end
  return points, linkFrames, afterFrames
end

studio.buildBindPoseTargets = buildBindPoseTargets

local function newRuntimeState(runtime, animatedTargets)
  if type(runtime.bindPosePoints) ~= "table" or #runtime.bindPosePoints ~= runtime.graph.pointCount then
    local bindTargets, _, bindFrames = buildBindPoseTargets(runtime)
    runtime.bindPosePoints = bindTargets
    runtime.bindPoseRootFrame = bindFrames and bindFrames[1]
  end
  local calibrated = runtime.config and runtime.config.restPose
  local hasCalibration = type(calibrated) == "table" and #calibrated == runtime.graph.pointCount
  runtime.restReferenceKind = hasCalibration and "calibrated" or "blockbench_bind_pose"
  local restPose = hasCalibration and calibrated or runtime.bindPosePoints
  local restPoseRootFrame = hasCalibration and runtime.config.restPoseRootFrame
    or runtime.bindPoseRootFrame
  return core.newComponentState(runtime.graph, animatedTargets, restPose, restPoseRootFrame)
end

function studio.gravityFrameForStep(runtime)
  if runtime and runtime.gravityFrameAvailable == true then return runtime.gravityFrame end
  return nil
end

local function clearOffsets()
  for _, runtime in ipairs(studio.runtimes or {}) do
    for index, node in ipairs(runtime.linkNodes or {}) do
      local part = node and node.part
      if part then safeCall(part, "setOffsetRot", 0, 0, 0) end
      runtime.appliedEuler[index] = vec3(0, 0, 0)
    end
  end
  gizmosApi.clear(studio.gizmos)
end

local function graphSignature(graph)
  local keys = {}
  for _, link in ipairs(graph.links or {}) do keys[#keys + 1] = link.key end
  return table.concat(keys, "|")
end

local function makeRuntime(component, graph)
  local runtime = {
    key = graph.rootKey, componentId = component.id, graph = graph, config = component,
    settings = component.settings, linkOverrides = component.linkOverrides,
    enabled = component.enabled ~= false and graph.complete == true,
    linkNodes = {}, linkKeys = {}, appliedEuler = {}, animatedRotations = {}, linkFrames = {},
    gravityFrame = nil, gravityFrameAvailable = false,
    rotationFrame = identity(), rotationFrameAvailable = false,
    previousRotationFrame = nil, previousFrameAngularVelocity = vec3(0, 0, 0),
    frameMotion = { available = false, angularVelocity = vec3(0, 0, 0), angularAcceleration = vec3(0, 0, 0) },
    state = nil, offsets = {},
    renderOffsets = {}, diagnostics = {},
    collisionContext = newCollisionContext(), collisionDiagnostics = {},
    collisionOverrideEnabled = false,
  }
  for index, link in ipairs(graph.links or {}) do
    local node = studio.registry.byKey[link.key]
    runtime.linkNodes[index], runtime.linkKeys[index] = node, link.key
    runtime.appliedEuler[index] = vec3(0, 0, 0)
  end
  for _, override in pairs(runtime.linkOverrides or {}) do
    if type(override) == "table" and type(override.collision) == "table"
      and override.collision.enabled == true then
      runtime.collisionOverrideEnabled = true
      break
    end
  end
  local signature = graphSignature(graph)
  local targets = buildAnimatedTargets(runtime)
  if not runtime.state then runtime.state = newRuntimeState(runtime, targets) end
  runtime.offsets = runtime.state.offsets
  runtime.renderOffsets = runtime.state.offsets
  runtime.signature = signature
  runtime.terminalVector = vec3(0, -1, 0)
  runtime.terminalDirection = vec3(0, -1, 0)
  runtime.restLengths = {}
  for _, edge in ipairs(graph.edges or {}) do
    if edge.terminal then
      runtime.terminalVector = edge.restVector
      runtime.restLengths[edge.from] = edge.restLength
      local length = math.max(0.001, tonumber(edge.restLength) or 1)
      runtime.terminalDirection = vec3(edge.restVector.x / length, edge.restVector.y / length, edge.restVector.z / length)
    end
  end
  return runtime
end

local function samePath(first, second)
  if first == second then return true end
  if type(first) ~= "table" or type(second) ~= "table" or #first ~= #second then return false end
  return registryApi.pathKey(first) == registryApi.pathKey(second)
end

local function sameStringMap(first, second)
  first, second = type(first) == "table" and first or {}, type(second) == "table" and second or {}
  for key, value in pairs(first) do if second[key] ~= value then return false end end
  for key, value in pairs(second) do if first[key] ~= value then return false end end
  return true
end

local function samePathList(first, second)
  first, second = type(first) == "table" and first or {}, type(second) == "table" and second or {}
  if #first ~= #second then return false end
  local found = {}
  for _, path in ipairs(first) do found[registryApi.pathKey(path)] = (found[registryApi.pathKey(path)] or 0) + 1 end
  for _, path in ipairs(second) do
    local key = registryApi.pathKey(path)
    if not found[key] then return false end
    found[key] = found[key] - 1
    if found[key] <= 0 then found[key] = nil end
  end
  return next(found) == nil
end

local function sameEndpoint(first, second)
  first, second = type(first) == "table" and first or {}, type(second) == "table" and second or {}
  if (first.mode or "child") ~= (second.mode or "child") then return false end
  local a, b = first.vector or {}, second.vector or {}
  return (tonumber(a.x) or 0) == (tonumber(b.x) or 0)
    and (tonumber(a.y) or 0) == (tonumber(b.y) or 0)
    and (tonumber(a.z) or 0) == (tonumber(b.z) or 0)
end

local function sameTopology(first, second)
  local a = type(first) == "table" and first.components or {}
  local b = type(second) == "table" and second.components or {}
  if #a ~= #b then return false end
  for index, component in ipairs(a) do
    local other = b[index]
    if not other or component.id ~= other.id or not samePath(component.rootPath, other.rootPath)
      or (component.branchMode or "selected") ~= (other.branchMode or "selected")
      or not sameStringMap(component.branchChoices, other.branchChoices)
      or not samePathList(component.excludedPaths, other.excludedPaths)
      or not sameEndpoint(component.endpoint, other.endpoint) then return false end
  end
  return true
end

local function rebuildRuntime()
  clearOffsets()
  studio.runtimes, studio.graphs = {}, {}
  local accepted = {}
  for index, component in ipairs(studio.draftConfig and studio.draftConfig.components or {}) do
    local graph, err = chainApi.build(studio.registry, component)
    if not graph then graph = { rootKey = "", links = {}, linkByKey = {}, errors = { tostring(err) }, branches = {}, complete = false } end
    local overlapPath, overlapReason = chainApi.findOverlap(accepted, graph)
    if overlapPath then
      graph.complete = false
      graph.errors[#graph.errors + 1] = overlapReason
    end
    studio.graphs[index] = graph
    if graph.complete then
      local runtime = makeRuntime(component, graph)
      studio.runtimes[#studio.runtimes + 1] = runtime
      accepted[#accepted + 1] = graph
    end
  end
  if studio.ui then studio.ui:setGraphs(studio.graphs, studio.draftConfig) end
  if studio.gizmos.visible and updateGizmoState then updateGizmoState(true) end
end

local function resetRuntimeState(runtime)
  for index, node in ipairs(runtime.linkNodes or {}) do
    safeCall(node and node.part, "setOffsetRot", 0, 0, 0)
    runtime.appliedEuler[index] = vec3(0, 0, 0)
  end
  local targets = buildAnimatedTargets(runtime)
  runtime.state = newRuntimeState(runtime, targets)
  runtime.offsets, runtime.renderOffsets = runtime.state.offsets, runtime.state.offsets
  runtime.diagnostics, runtime.collisionDiagnostics = {}, {}
  runtime.testTargets = nil
  resetFrameMotion(runtime)
  if runtime.collisionContext and type(runtime.collisionContext.beginTick) == "function" then
    runtime.collisionContext.beginTick(runtime.settings and runtime.settings.collision or {})
  end
end

local function updateRuntimeConfig(raw, resetComponentId)
  local byId = {}
  for _, component in ipairs(raw.components or {}) do byId[component.id] = component end
  for _, runtime in ipairs(studio.runtimes or {}) do
    local component = byId[runtime.componentId]
    if component then
      local wasEnabled = runtime.enabled
      runtime.config, runtime.settings, runtime.linkOverrides = component, component.settings, component.linkOverrides
      runtime.enabled = component.enabled ~= false and runtime.graph.complete == true
      runtime.collisionOverrideEnabled = false
      for _, override in pairs(runtime.linkOverrides or {}) do
        if type(override) == "table" and type(override.collision) == "table"
          and override.collision.enabled == true then
          runtime.collisionOverrideEnabled = true
          break
        end
      end
      if component.id == resetComponentId or wasEnabled ~= runtime.enabled then resetRuntimeState(runtime) end
    end
  end
end

local function applyDraft(raw, resetComponentId)
  local clean, warnings = configApi.validate(raw)
  local topologyChanged = not sameTopology(studio.draftConfig, clean)
  studio.draftConfig = clean
  if studio.physicsWorld and type(studio.physicsWorld.configure) == "function" then
    studio.physicsWorld:configure(clean.world)
  end
  if topologyChanged then rebuildRuntime() else updateRuntimeConfig(clean, resetComponentId) end
  if studio.ui then studio.ui:setDraft(clean, studio.graphs) end
  if #warnings > 0 and studio.ui then studio.ui.status = warnings[1]; studio.ui:refresh() end
end

local function saveDraft()
  local ok, message, clean, warnings = configApi.save(studio.draftConfig)
  if ok then
    studio.savedConfig = configApi.clone(clean)
    applyDraft(clean)
    if studio.ui then studio.ui:setDraft(clean, studio.graphs); studio.ui.status = message; studio.ui:refresh() end
  else
    if studio.ui then studio.ui.status = message; studio.ui:refresh() end
  end
  if #((warnings) or {}) > 0 and studio.ui then studio.ui.status = warnings[1]; studio.ui:refresh() end
end

local function captureRestPose(componentId)
  local runtime
  for _, candidate in ipairs(studio.runtimes or {}) do
    if candidate.componentId == componentId then runtime = candidate; break end
  end
  if not runtime or not runtime.enabled or studio.alive == false or studio.playerWasLoaded == false then
    return false, "Нельзя сохранить позу: компонент или игрок сейчас не готовы."
  end
  local targets, _, jointFrames = buildAnimatedTargets(runtime)
  for _, component in ipairs(studio.draftConfig.components or {}) do
    if component.id == componentId then
      component.restPose = configApi.clone(targets)
      component.restPoseRootFrame = configApi.clone(jointFrames and jointFrames[1])
      applyDraft(studio.draftConfig, componentId)
      return true, "Снимок взят из текущей позы. Если она не нейтральная, пересними в нейтральном положении; затем нажми «Сохранить»."
    end
  end
  return false, "Компонент для калибровки не найден."
end

local function initialize()
  studio.rootPart = modelRoot()
  if not studio.rootPart then return false end
  local registry, err = registryApi.scan(studio.rootPart)
  if not registry then
    if studio.lastError ~= err then emitLog(err); studio.lastError = err end
    return false
  end
  studio.registry = registry
  local loaded, warnings = configApi.load()
  studio.savedConfig = configApi.clone(loaded)
  studio.draftConfig = configApi.clone(loaded)
  if studio.physicsWorld and type(studio.physicsWorld.configure) == "function" then
    studio.physicsWorld:configure(loaded.world)
  end
  studio.initialized = true
  studio.ui = uiApi.new(registry, studio.draftConfig, {
    changed = function(raw, resetComponentId) applyDraft(raw, resetComponentId) end,
    save = saveDraft,
    cancel = function()
      applyDraft(configApi.clone(studio.savedConfig or configApi.defaults()))
      if studio.ui then studio.ui.status = "Черновик отменён."; studio.ui:refresh() end
    end,
    export = function(raw) return configApi.exportPreset(raw) end,
    import = function()
      local imported, importWarnings = configApi.importBundledPreset()
      if imported then
        applyDraft(imported)
        if studio.ui then studio.ui.status = "Загружен профиль из physics_bone_preset.lua; сохрани, чтобы применить локально."; studio.ui:refresh() end
      elseif studio.ui then studio.ui.status = importWarnings; studio.ui:refresh() end
    end,
    captureRestPose = function(componentId)
      local ok, message = captureRestPose(componentId)
      if studio.ui then studio.ui.status = message; studio.ui:refresh() end
      return ok
    end,
  })
  rebuildRuntime()
  studio.ui:setDraft(studio.draftConfig, studio.graphs)
  if #warnings > 0 then studio.ui.status = warnings[1] end
  return true
end

-- Test-only reset for reproducible live A/B runs. It is inert in regular avatars.
function studio.testResetSimulation()
  if studio.testCapture ~= true then return false end
  for _, runtime in ipairs(studio.runtimes or {}) do
    local targets = buildAnimatedTargets(runtime)
    runtime.state = newRuntimeState(runtime, targets)
    runtime.offsets, runtime.renderOffsets = runtime.state.offsets, runtime.state.offsets
    runtime.diagnostics = {}
    runtime.testTargets = targets
    runtime.testCollisionShapes = nil
    resetFrameMotion(runtime)
  end
  return true
end

-- Test-only integration probe: runs the same bounded Figura block-shape query
-- used by the solver and returns its geometry without changing model state.
function studio.testProbeWorld(position, radius)
  if studio.testCapture ~= true or type(position) ~= "table" then return nil end
  local runtime = studio.runtimes and studio.runtimes[1]
  local context = runtime and runtime.collisionContext
  if not context or type(context.beginTick) ~= "function" or type(context.queryWorld) ~= "function" then return nil end
  context.beginTick({ maxBlockQueries = 256 })
  local shapes, queries, exhausted, available = context.queryWorld(position, radius or 2.5)
  return {
    available = available == true, queries = tonumber(queries) or 0,
    budgetExceeded = exhausted == true, shapes = shapes or {},
  }
end

function studio.tick()
  if not studio.initialized and not initialize() then return end
  if studio.ui then studio.ui:tick() end
  sampleInstructionDiagnostics("tick")
  studio.tickCount = (studio.tickCount or 0) + 1
  if studio.testCapture and type(studio.testPreTick) == "function" then
    local okTest, reason = pcall(studio.testPreTick)
    if not okTest then
      emitLog("[PhysBone v2 test] pre-tick failed: " .. tostring(reason))
      studio.testCapture = false
    end
  end
  local loaded = safeCall(player, "isLoaded")
  if loaded == false then
    studio.input:reset()
    if studio.playerWasLoaded ~= false then
      clearOffsets()
      for _, runtime in ipairs(studio.runtimes) do
        runtime.state = newRuntimeState(runtime, buildAnimatedTargets(runtime))
        runtime.offsets, runtime.renderOffsets = runtime.state.offsets, runtime.state.offsets
        resetFrameMotion(runtime)
      end
    end
    studio.playerWasLoaded = false
    return
  end
  if studio.playerWasLoaded == false then
    studio.input:reset()
    for _, runtime in ipairs(studio.runtimes) do
      runtime.state = newRuntimeState(runtime, buildAnimatedTargets(runtime))
      runtime.offsets, runtime.renderOffsets = runtime.state.offsets, runtime.state.offsets
      resetFrameMotion(runtime)
    end
  end
  studio.playerWasLoaded = true
  local alive = safeCall(player, "isAlive")
  local wasAlive = studio.alive
  studio.alive = alive ~= false
  if not studio.alive then
    if wasAlive then
      studio.input:reset()
      for _, runtime in ipairs(studio.runtimes) do
        local targets = buildAnimatedTargets(runtime)
        runtime.state = newRuntimeState(runtime, targets)
        resetFrameMotion(runtime)
      end
    end
    return
  end
  if not wasAlive then
    studio.input:reset()
    for _, runtime in ipairs(studio.runtimes) do
      local targets = buildAnimatedTargets(runtime)
      runtime.state = newRuntimeState(runtime, targets)
      resetFrameMotion(runtime)
    end
  end
  -- Include input, target preparation, the world solver, and finalization in
  -- the always-on time budget; World:step alone omits substantial physics work.
  local physicsTickStarted = solverClockMs()
  local queryBudget = studio.worldQueryBudget
  queryBudget.cache = queryBudget.cache or {}
  for key in pairs(queryBudget.cache) do queryBudget.cache[key] = nil end
  queryBudget.configured = math.max(0, math.floor(tonumber(studio.draftConfig
    and studio.draftConfig.world and studio.draftConfig.world.maxBlockQueries) or studio.physicsWorld.maxBlockQueries or 64))
  queryBudget.remaining = studio.instructionDiagnostics:budgetLimit(queryBudget.configured)
  queryBudget.total = 0
  queryBudget.exhausted = false
  local bodyYaw = safeCall(player, "getBodyYaw")
  local motion = studio.input:sample(player, bodyYaw, TICK_DT)
  if studio.testCapture and type(studio.testInputProvider) == "function" then
    local okOverride, override = pcall(studio.testInputProvider, studio.tickCount)
    if okOverride and type(override) == "table" then
      if type(override.rootVelocity) == "table" then
        motion.rootVelocity = vectorFrom(override.rootVelocity)
      end
      if type(override.rootAcceleration) == "table" then
        motion.rootAcceleration = vectorFrom(override.rootAcceleration)
      end
    end
  end
  studio.lastInput = motion
  for _, runtime in ipairs(studio.runtimes) do
    if runtime.enabled then
      local targets, frames, jointFrames = buildAnimatedTargets(runtime)
      if studio.testCapture then runtime.testJointFrames = jointFrames end
      local frame = runtime.gravityFrameAvailable and runtime.gravityFrame or identity()
      local rotation = runtime.rotationFrameAvailable and runtime.rotationFrame or identity()
    local frameMotion = sampleFrameMotion(runtime,
        runtime.rotationFrameAvailable and runtime.rotationFrame or nil, TICK_DT, studio.tickCount)
      runtime.frameMotion = frameMotion
      local rootMotion = studio.sampleAnimatedRootMotion(runtime, motion, studio.tickCount)
      local localAcceleration = transform(frame, rootMotion.rootAcceleration or vec3(0, 0, 0))
      local localVelocity = transform(frame, rootMotion.rootVelocity or vec3(0, 0, 0))
      local localMotion = {
        rootVelocity = localVelocity,
        rootAcceleration = localAcceleration,
        rootAngularVelocity = frameMotion.available and frameMotion.angularVelocity
          or transform(rotation, motion.rootAngularVelocity or vec3(0, 0, 0)),
        rootAngularAcceleration = frameMotion.available and frameMotion.angularAcceleration
          or transform(rotation, vec3(0, motion.rootYawAcceleration or 0, 0)),
      }
      runtime.localMotion = localMotion
      if studio.testCapture then runtime.testInput = localMotion end
      local settingsForStep = runtime.settings
      local testAvatarResponse = tonumber(runtime.testAvatarMotionResponse)
      local testRootResponse = tonumber(runtime.testRootMotionResponse)
      local testPhysicsSettings = studio.testCapture and type(runtime.testPhysicsSettings) == "table"
        and runtime.testPhysicsSettings or nil
      if studio.testCapture and (testAvatarResponse ~= nil or testRootResponse ~= nil or testPhysicsSettings ~= nil) then
        settingsForStep = {}
        for key, value in pairs(runtime.settings or {}) do settingsForStep[key] = value end
        if testAvatarResponse ~= nil then settingsForStep.avatarMotionResponse = testAvatarResponse end
        if testRootResponse ~= nil then settingsForStep.rootMotionResponse = testRootResponse end
        for _, key in ipairs({ "pull", "spring", "bendStiffness", "bendStiffnessFalloff", "restitution", "damping", "mass", "tipMass", "poseFollow", "poseFollowFalloff", "gravityTiltResponse", "gravityFalloff", "gravitySpace", "maxLinearSpeed", "motionDrag", "joint" }) do
          if testPhysicsSettings and testPhysicsSettings[key] ~= nil then settingsForStep[key] = testPhysicsSettings[key] end
        end
      end
      if studio.testCapture and runtime.testCollisionSettings then
        if settingsForStep == runtime.settings then
          settingsForStep = {}
          for key, value in pairs(runtime.settings or {}) do settingsForStep[key] = value end
        end
        settingsForStep.collision = configApi.clone(runtime.testCollisionSettings)
      end
      local baseCollision = settingsForStep.collision or {}
      local needsCollisionContext = baseCollision.enabled == true or runtime.collisionOverrideEnabled
        or (studio.testCapture and runtime.testCollisionSettings ~= nil)
      if needsCollisionContext then
        local tickCollision = {}
        for key, value in pairs(baseCollision) do tickCollision[key] = value end
        local rootOverride = runtime.linkOverrides and runtime.linkOverrides[runtime.graph.links[1].key]
        if type(rootOverride) == "table" and type(rootOverride.collision) == "table"
          and not (studio.testCapture and runtime.testCollisionSettings) then
          for key, value in pairs(rootOverride.collision) do tickCollision[key] = value end
        end
        runtime.collisionContext.beginTick(tickCollision, queryBudget)
      else
        runtime.collisionContext.enabled = false
      end
      if studio.testCapture and runtime.testCollisionSettings then
        local context = runtime.collisionContext
        if runtime.testUseSyntheticCollisionShape and not runtime.testCollisionShapes
          and context.parentToWorld and context.rootOriginWorld then
          local probe = targets[2] or targets[1] or vec3(0, 0, 0)
          local center = context.toWorldPoint(probe)
          local radius = math.max(0.001, tonumber(runtime.testCollisionRadiusModel) or 2) * context.worldScale
          runtime.testCollisionShapes = { {
            id = "test-static-sphere", kind = "sphere", center = center, radius = radius,
          } }
        end
        context.enabled = true
        if runtime.testUseSyntheticCollisionShape then
          -- The fixture deliberately injects a collider at a known world point.
          -- Do not let the production broadphase cache shadow that isolated shape.
          context.avatarShapeGrid = nil
          context.sharedAvatarShapes = nil
          context.componentAvatarShapes = {}
          context.avatarShapes = runtime.testCollisionShapes or {}
          context.worldAvailable = false
        end
      end
      if studio.testCapture and runtime.testWorldSeedCenter and not runtime.testWorldSeedApplied
        and runtime.collisionContext and runtime.collisionContext.frameAvailable == true then
        local shift = runtime.collisionContext.toParentVector(
          subtract(runtime.testWorldSeedCenter, runtime.collisionContext.rootOriginWorld))
        for pointIndex, point in ipairs(targets) do
          targets[pointIndex] = vec3(point.x + shift.x, point.y + shift.y, point.z + shift.z)
          if runtime.state.points[pointIndex] then
            runtime.state.points[pointIndex] = vec3(runtime.state.points[pointIndex].x + shift.x,
              runtime.state.points[pointIndex].y + shift.y, runtime.state.points[pointIndex].z + shift.z)
            runtime.state.previousPoints[pointIndex] = vec3(runtime.state.previousPoints[pointIndex].x + shift.x,
              runtime.state.previousPoints[pointIndex].y + shift.y, runtime.state.previousPoints[pointIndex].z + shift.z)
          end
        end
        runtime.testWorldSeedApplied = true
      end
      if studio.testCapture then
        if settingsForStep == runtime.settings then
          settingsForStep = {}
          for key, value in pairs(runtime.settings or {}) do settingsForStep[key] = value end
        end
        settingsForStep.captureForceDiagnostics = true
      end
      if studio.testCapture then runtime.testTargets = targets end
      runtime.state, runtime.worldStepContext = core.prepareWorldStep(
        runtime.state, runtime.graph, targets, localMotion, settingsForStep, TICK_DT,
        studio.gravityFrameForStep(runtime), frames, runtime.linkOverrides, jointFrames, runtime.collisionContext,
        runtime.config and runtime.config.restPose, runtime.config and runtime.config.restPoseRootFrame,
        studio.physicsWorld.constraintPasses)
      if needsCollisionContext then
        runtime.worldPointInfo = core.worldPointInfo(runtime.worldStepContext)
      else
        runtime.worldPointInfo = nil
      end
    else
      runtime.worldStepContext = nil
      runtime.worldPointInfo = nil
      resetFrameMotion(runtime)
      runtime.localMotion = {
        rootVelocity = vec3(0, 0, 0),
        rootAcceleration = vec3(0, 0, 0),
        rootAngularVelocity = vec3(0, 0, 0),
        rootAngularAcceleration = vec3(0, 0, 0),
      }
    end
  end
  local worldComponents = {}
  for _, runtime in ipairs(studio.runtimes) do
    if runtime.enabled and runtime.worldStepContext then
      worldComponents[#worldComponents + 1] = {
        id = runtime.componentId, enabled = true, runtime = runtime,
        state = runtime.state, graph = runtime.graph, pointInfo = runtime.worldPointInfo,
        frame = runtime.collisionContext,
        boneOwnedCollisions = runtime.settings and runtime.settings.linkControlMode == "bone",
        kind = runtime.config and runtime.config.kind,
        group = runtime.settings and runtime.settings.collision and runtime.settings.collision.group or "custom",
        mask = runtime.settings and runtime.settings.collision and runtime.settings.collision.mask,
      }
    end
  end
  local showDiagnostics = diagnosticsVisible()
  local measureWorld = studio.testCapture == true or showDiagnostics == true
  local worldSolverStarted = measureWorld and solverClockMs() or nil
  local instructionPressure = studio.instructionDiagnostics.instructionPressure == true
  local instructionRatio = studio.instructionDiagnostics.tick.ratio
  local worldStats = studio.physicsWorld:step(TICK_DT, worldComponents, {
    instructionPressure = instructionPressure,
    instructionRatio = instructionRatio,
    timePressure = studio.instructionDiagnostics.timePressure,
    integrate = function(component, dt)
      local runtime = component.runtime
      core.advanceWorldSubstep(runtime.worldStepContext, dt)
      component.state = runtime.state
    end,
    resolveLocal = function(component, dt, contactPoints, _, pairBudgetRemaining, extraPassBudget)
      local runtime = component.runtime
      return core.resolveWorldContacts(runtime.worldStepContext, dt, contactPoints, pairBudgetRemaining, extraPassBudget)
    end,
  })
  local worldSolverFinished = worldSolverStarted and solverClockMs() or nil
  if worldSolverStarted and worldSolverFinished then
    worldStats.frameTimeMs = math.max(0, worldSolverFinished - worldSolverStarted)
  end
  worldStats.worldQueries = math.max(worldStats.worldQueries or 0, queryBudget.total or 0)
  worldStats.worldQueryBudget = queryBudget.remaining + (queryBudget.total or 0)
  worldStats.configuredWorldQueryBudget = queryBudget.configured or worldStats.configuredWorldQueryBudget
  worldStats.blockBudgetExceeded = worldStats.blockBudgetExceeded or queryBudget.exhausted == true
  worldStats.sharedBodyColliders = studio.sharedAvatarShapeCount or 0
  worldStats.componentBodyColliders = studio.componentAvatarShapeCount or 0
  worldStats.activeBodyColliders = studio.activeBodyColliderCount or 0
  studio.worldDiagnostics = worldStats
  for _, component in ipairs(worldComponents) do
    local runtime = component.runtime
    runtime.state, runtime.offsets, runtime.diagnostics = core.finishWorldFrame(
      runtime.worldStepContext, TICK_DT, showDiagnostics)
    runtime.renderOffsets = runtime.offsets
    runtime.collisionDiagnostics = runtime.state.collisionDiagnostics or {}
  end
  local physicsTickFinished = physicsTickStarted and solverClockMs() or nil
  if physicsTickStarted and physicsTickFinished then
    worldStats.totalPhysicsMs = math.max(0, physicsTickFinished - physicsTickStarted)
    studio.instructionDiagnostics:sampleSolverTime(worldStats.totalPhysicsMs)
  end
  local avatarShapeCandidates = 0
  for _, runtime in ipairs(studio.runtimes) do
    avatarShapeCandidates = avatarShapeCandidates
      + (tonumber(runtime.collisionDiagnostics and runtime.collisionDiagnostics.avatarShapeCandidates) or 0)
  end
  worldStats.avatarShapeCandidates = avatarShapeCandidates
  if studio.testCapture then
    local elapsed = worldSolverStarted and worldSolverFinished and math.max(0, worldSolverFinished - worldSolverStarted) or nil
    local share = elapsed and tonumber(worldStats.activeComponents) and worldStats.activeComponents > 0
      and elapsed / worldStats.activeComponents or nil
    for _, runtime in ipairs(studio.runtimes) do
      if runtime.enabled then runtime.testSolverTimeMs = share end
    end
  end
  if studio.ui and studio.ui.open and studio.tickCount % 5 == 0 then
    local data = {}
    for _, runtime in ipairs(studio.runtimes) do
      data[runtime.componentId] = { links = runtime.diagnostics, gravityFrameAvailable = runtime.gravityFrameAvailable == true }
    end
    data.__world = studio.worldDiagnostics
    data.__instructions = studio.instructionDiagnostics:snapshot()
    studio.ui:setDiagnostics(data)
  end
  if studio.testCapture and type(studio.testPostTick) == "function" then
    local okTest, reason = pcall(studio.testPostTick)
    if not okTest then
      emitLog("[PhysBone v2 test] post-tick failed: " .. tostring(reason))
      studio.testCapture = false
    end
  end
end

function studio.postRender(delta, renderContext)
  if not studio.initialized then return end
  local needAvatarColliders = false
  for _, runtime in ipairs(studio.runtimes) do
    local collision = runtime.settings and runtime.settings.collision or {}
    if runtime.enabled and (collision.enabled == true or runtime.collisionOverrideEnabled == true
        or (studio.testCapture and runtime.testCollisionSettings ~= nil))
      and (collision.avatar ~= false or runtime.collisionOverrideEnabled == true
        or (studio.testCapture and runtime.testCollisionSettings ~= nil)) then
      needAvatarColliders = true
      break
    end
  end
  local globalColliders = needAvatarColliders and studio.draftConfig and studio.draftConfig.colliders or {}
  studio.sharedAvatarShapes, studio.sharedAvatarShapeCount = collisionsApi.refreshShapeCache(
    studio.sharedAvatarShapes, globalColliders, colliderWorldShape)
  local componentSources = studio.componentColliderSources or {}
  local componentSourceCount = 0
  if needAvatarColliders then
    for _, runtime in ipairs(studio.runtimes) do
      for _, collider in ipairs(runtime.config and runtime.config.colliders or {}) do
        if type(collider) == "table" and collider.enabled ~= false then
          componentSourceCount = componentSourceCount + 1
          componentSources[componentSourceCount] = collider
        end
      end
    end
  end
  for index = #componentSources, componentSourceCount + 1, -1 do componentSources[index] = nil end
  studio.componentColliderSources = componentSources
  studio.sharedComponentAvatarShapes, studio.componentAvatarShapeCount = collisionsApi.refreshShapeCache(
    studio.sharedComponentAvatarShapes, componentSources, colliderWorldShape)
  studio.avatarColliderGrid = collisionsApi.refreshShapeGrid(studio.avatarColliderGrid,
    studio.sharedAvatarShapes, studio.sharedComponentAvatarShapes)
  local parentFrameCache = {}
  for _, runtime in ipairs(studio.runtimes) do
    local frame, parentMatrix = worldToParentFrame(runtime, parentFrameCache)
    if frame then
      runtime.gravityFrame, runtime.gravityFrameAvailable = frame, true
      local rootMatrixForRender
      if runtime.settings and runtime.settings.linkControlMode == "bone" and runtime.enabled then
        local root = runtime.linkNodes[1] and runtime.linkNodes[1].part
        if renderContext == "FIRST_PERSON" then
          runtime.rootWorldFrameAvailable = false
        elseif renderContext == nil or renderContext == "RENDER" then
          if root and studio.canSampleAnimatedRoot(root, renderContext) then
            rootMatrixForRender = safeCall(root, "partToWorldMatrix")
            local worldPosition = rootMatrixForRender and type(vec) == "function"
              and safeCall(rootMatrixForRender, "apply", vec(0,0,0)) or nil
            local partialTick = tonumber(delta) or tonumber(safeCall(client, "getFrameTime"))
            local frameTime = partialTick and partialTick >= 0 and partialTick <= 1
              and (studio.tickCount or 0) + partialTick or nil
            studio.captureAnimatedRootPosition(runtime, worldPosition, frameTime)
          else
            runtime.rootWorldFrameAvailable = false
          end
        end
      else
        runtime.rootWorldFrameAvailable = false
      end
      local rotation = rotationOnly(frame)
      if rotation then
        runtime.rotationFrame, runtime.rotationFrameAvailable = rotation, true
        runtime.rotationFrameVersion = (runtime.rotationFrameVersion or 0) + 1
      end
      if runtime.settings and runtime.settings.collision and runtime.settings.collision.enabled == true
        or runtime.collisionOverrideEnabled == true
        or (studio.testCapture and runtime.testCollisionSettings) then
        updateCollisionFrame(runtime, studio.sharedAvatarShapes, studio.avatarColliderGrid, parentMatrix, frame, rootMatrixForRender)
      else
        runtime.collisionContext.enabled = false
        runtime.collisionContext.sharedAvatarShapes = studio.sharedAvatarShapes
        runtime.collisionContext.avatarShapeGrid = studio.avatarColliderGrid
        runtime.collisionContext.componentAvatarShapes = studio.sharedComponentAvatarShapes
        runtime.collisionContext.componentAvatarShapeCount = studio.componentAvatarShapeCount
        runtime.collisionContext.avatarShapes = runtime.collisionContext.componentAvatarShapes
      end
    else
      runtime.gravityFrameAvailable = false
      runtime.rootWorldFrameAvailable = false
      runtime.rotationFrameAvailable = false
      runtime.collisionContext.frameAvailable = false
      runtime.collisionContext.enabled = false
      runtime.collisionContext.worldUnavailable = true
      runtime.collisionContext.sharedAvatarShapes = studio.sharedAvatarShapes
      runtime.collisionContext.avatarShapeGrid = studio.avatarColliderGrid
      runtime.collisionContext.componentAvatarShapes = studio.sharedComponentAvatarShapes
      runtime.collisionContext.componentAvatarShapeCount = studio.componentAvatarShapeCount
      runtime.collisionContext.avatarShapes = runtime.collisionContext.componentAvatarShapes
    end
  end
  studio.activeBodyColliderCount = studio.sharedAvatarShapeCount + studio.componentAvatarShapeCount
  if type(studio.worldDiagnostics) == "table" then
    studio.worldDiagnostics.sharedBodyColliders = studio.sharedAvatarShapeCount
    studio.worldDiagnostics.componentBodyColliders = studio.componentAvatarShapeCount
    studio.worldDiagnostics.activeBodyColliders = studio.activeBodyColliderCount
  end
end

function studio.render(delta)
  if not studio.initialized then return end
  sampleInstructionDiagnostics("render")
  delta = math.max(0, math.min(1, tonumber(delta) or 0))
  for _, runtime in ipairs(studio.runtimes) do
    if runtime.enabled and studio.alive and studio.playerWasLoaded ~= false then
      local offsets = core.interpolate(runtime.state, delta)
      for index, node in ipairs(runtime.linkNodes) do
        local offset = offsets[index] or vec3(0, 0, 0)
        local x, y, z = rotationVectorToEuler(offset.x, offset.y, offset.z)
        local applied = runtime.appliedEuler[index]
        if not applied or applied.x ~= x or applied.y ~= y or applied.z ~= z then
          safeCall(node and node.part, "setOffsetRot", x, y, z)
          runtime.appliedEuler[index] = vec3(x, y, z)
        end
      end
    else
      for index, node in ipairs(runtime.linkNodes) do
        local applied = runtime.appliedEuler[index]
        if not applied or applied.x ~= 0 or applied.y ~= 0 or applied.z ~= 0 then
          safeCall(node and node.part, "setOffsetRot", 0, 0, 0)
          runtime.appliedEuler[index] = vec3(0, 0, 0)
        end
      end
    end
  end
  if studio.gizmos.visible and updateGizmoState then updateGizmoState(false) end
end

updateGizmoState = function(force, visibleOverride)
  local manager = studio.gizmos
  local visible = visibleOverride
  if visible == nil then visible = manager.visible end
  local state = gizmosApi.editorState(studio.ui, studio.registry, registryApi)
  local colliderKey = state.showCollider and state.selectedColliderKey or nil
  local colliderNode = state.showCollider and state.selectedColliderNode or nil
  local colliderObject = state.showCollider and state.selectedCollider or nil
  local changed = force == true or manager.chainsRef ~= studio.runtimes
    or manager.selectedRootKey ~= state.selectedRootKey
    or manager.settingsRef ~= state.settingsRef or manager.uiRevision ~= state.uiRevision
    or manager.page ~= state.page or manager.colliderMode ~= state.colliderMode
    or manager.selectedColliderId ~= state.selectedColliderId or manager.colliderScope ~= state.colliderScope
    or manager.colliderVisible ~= (visible == true and state.showCollider == true)
    or (visible == true and state.showCollider == true and (manager.colliderKey ~= colliderKey
      or manager.colliderNode ~= colliderNode or manager.colliderObject ~= colliderObject
      or manager.colliderRevision ~= state.uiRevision))
  if not changed then return end
  gizmosApi.setVisible(manager, studio.runtimes, visible, state.selectedRootKey,
    state.selectedCollider, state.selectedColliderNode, state.selectedColliderKey,
    state.settingsRef, state.uiRevision, state.page, state.colliderMode,
    state.selectedColliderId, state.colliderScope, state.showCollider)
end

local editorKey = keybinds:newKeybind("PhysBone v2 — редактор", "key.keyboard.f8", false)
editorKey.press = function()
  if not studio.initialized then initialize() end
  if studio.ui then studio.ui:toggle() end
end

local function register(eventName, callback)
  local event = events and events[eventName]
  if event and type(event.register) == "function" then
    event:register(callback, EVENT_NAME .. "." .. string.lower(eventName))
  else emitLog("Figura event is not available: " .. eventName) end
end

register("ENTITY_INIT", initialize)
register("TICK", studio.tick)
register("RENDER", studio.render)
register("POST_RENDER", studio.postRender)
register("MOUSE_PRESS", function(button, action)
  return studio.ui and studio.ui:onMousePress(button, action) or false
end)
register("MOUSE_MOVE", function(dx, dy)
  return studio.ui and studio.ui:onMouseMove(dx, dy) or false
end)
register("MOUSE_SCROLL", function(delta)
  return studio.ui and studio.ui:onMouseScroll(delta) or false
end)
register("CHAR_TYPED", function(character)
  return studio.ui and studio.ui:onCharTyped(character) or false
end)
register("KEY_PRESS", function(key, action, modifier)
  if tonumber(key) == GLFW_KEY_GRAVE_ACCENT and tonumber(action) == 1
    and tonumber(modifier) and tonumber(modifier) % (GLFW_MOD_SHIFT * 2) == GLFW_MOD_SHIFT then
    if not studio.initialized then initialize() end
    if studio.initialized then
      updateGizmoState(true, not studio.gizmos.visible)
    end
    return true
  end
  return studio.ui and studio.ui:onKeyPress(key, action) or false
end)

return studio
