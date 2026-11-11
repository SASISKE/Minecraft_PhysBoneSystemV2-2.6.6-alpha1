-- Shared scheduler and cross-component particle contacts for PhysBone v2.
-- Components keep their own chain state. This module coordinates the fixed step
-- and resolves contacts in a common world frame.
local worldApi = {}
local broadphase = require("physics_bone_broadphase")

local DEFAULTS = {
  fixedStep = 1 / 60,
  maxSubsteps = 3,
  maxFrameDt = 0.10,
  maxPoints = 80,
  maxCandidatePairs = 512,
  contactIterations = 2,
  constraintPasses = 5,
  cellSize = 1,
  maxCellsPerProxy = 256,
}

local PERFORMANCE = {
  performance = { fixedStep = 1 / 30, maxSubsteps = 2, maxFrameDt = 0.10, maxPoints = 64,
    maxCandidatePairs = 192, contactIterations = 1, constraintPasses = 3, cellSize = 1, maxCellsPerProxy = 128,
    maxBlockQueries = 32, segmentMode = "point_segment" },
  balanced = { fixedStep = 1 / 60, maxSubsteps = 3, maxFrameDt = 0.10, maxPoints = 80,
    maxCandidatePairs = 512, contactIterations = 2, constraintPasses = 5, cellSize = 1, maxCellsPerProxy = 256,
    maxBlockQueries = 64, segmentMode = "point_segment" },
  quality = { fixedStep = 1 / 60, maxSubsteps = 3, maxFrameDt = 0.10, maxPoints = 128,
    maxCandidatePairs = 1024, contactIterations = 4, constraintPasses = 8, cellSize = 0.75, maxCellsPerProxy = 512,
    maxBlockQueries = 96, segmentMode = "segment_segment" },
}

local COLLISION_PRIORITY = {
  body = 100, tail = 90, ears = 90, hair = 80,
  custom = 60, clothing = 40, accessories = 30,
}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, minimum, maximum, fallback)
  value = tonumber(value)
  if not finite(value) then value = fallback end
  return math.max(minimum, math.min(maximum, value))
end

local function performanceOptions(mode)
  local source = PERFORMANCE[mode] or PERFORMANCE.balanced
  local result = {}
  for key, value in pairs(source) do result[key] = value end
  result.performance = PERFORMANCE[mode] and mode or "balanced"
  return result
end

local function vec(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function add(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, amount) return vec(a.x * amount, a.y * amount, a.z * amount) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function length(a) return math.sqrt(math.max(0, dot(a, a))) end
local function normalize(a, fallback)
  local size = length(a)
  if size > 0.000001 then return mul(a, 1 / size) end
  return fallback or vec(1, 0, 0)
end

local function sweptPointAabb(proxy, radius, cellSize, bounds)
  local start, finish = proxy.previousWorld, proxy.world
  bounds = bounds or {}
  bounds.minX = math.floor((math.min(start.x, finish.x) - radius) / cellSize)
  bounds.minY = math.floor((math.min(start.y, finish.y) - radius) / cellSize)
  bounds.minZ = math.floor((math.min(start.z, finish.z) - radius) / cellSize)
  bounds.maxX = math.floor((math.max(start.x, finish.x) + radius) / cellSize)
  bounds.maxY = math.floor((math.max(start.y, finish.y) + radius) / cellSize)
  bounds.maxZ = math.floor((math.max(start.z, finish.z) + radius) / cellSize)
  return bounds
end

local function sweptSegmentAabb(segment, radius, cellSize, bounds)
  local a0, a1 = segment.first.previousWorld, segment.first.world
  local b0, b1 = segment.second.previousWorld, segment.second.world
  bounds = bounds or {}
  bounds.minX = math.floor((math.min(a0.x, a1.x, b0.x, b1.x) - radius) / cellSize)
  bounds.minY = math.floor((math.min(a0.y, a1.y, b0.y, b1.y) - radius) / cellSize)
  bounds.minZ = math.floor((math.min(a0.z, a1.z, b0.z, b1.z) - radius) / cellSize)
  bounds.maxX = math.floor((math.max(a0.x, a1.x, b0.x, b1.x) + radius) / cellSize)
  bounds.maxY = math.floor((math.max(a0.y, a1.y, b0.y, b1.y) + radius) / cellSize)
  bounds.maxZ = math.floor((math.max(a0.z, a1.z, b0.z, b1.z) + radius) / cellSize)
  return bounds
end

local function boundsOverlap(a, b)
  return a.minX <= b.maxX and a.maxX >= b.minX
    and a.minY <= b.maxY and a.maxY >= b.minY
    and a.minZ <= b.maxZ and a.maxZ >= b.minZ
end

local function sweptPointBounds(proxy, radius, bounds)
  local start, finish = proxy.previousWorld, proxy.world
  bounds = bounds or {}
  bounds.minX, bounds.minY, bounds.minZ = math.min(start.x, finish.x) - radius,
    math.min(start.y, finish.y) - radius, math.min(start.z, finish.z) - radius
  bounds.maxX, bounds.maxY, bounds.maxZ = math.max(start.x, finish.x) + radius,
    math.max(start.y, finish.y) + radius, math.max(start.z, finish.z) + radius
  return bounds
end

local function sweptSegmentBounds(segment, radius, bounds)
  local a0, a1 = segment.first.previousWorld, segment.first.world
  local b0, b1 = segment.second.previousWorld, segment.second.world
  bounds = bounds or {}
  bounds.minX, bounds.minY, bounds.minZ = math.min(a0.x, a1.x, b0.x, b1.x) - radius,
    math.min(a0.y, a1.y, b0.y, b1.y) - radius,
    math.min(a0.z, a1.z, b0.z, b1.z) - radius
  bounds.maxX, bounds.maxY, bounds.maxZ = math.max(a0.x, a1.x, b0.x, b1.x) + radius,
    math.max(a0.y, a1.y, b0.y, b1.y) + radius,
    math.max(a0.z, a1.z, b0.z, b1.z) + radius
  return bounds
end

local function visitGridCells(bounds, limit, callback)
  local count = (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) * (bounds.maxZ - bounds.minZ + 1)
  if count > limit then return false end
  local keepGoing = true
  for x = bounds.minX, bounds.maxX do
    if not keepGoing then break end
    for y = bounds.minY, bounds.maxY do
      if not keepGoing then break end
      for z = bounds.minZ, bounds.maxZ do
        if not callback(x, y, z) then keepGoing = false; break end
      end
    end
  end
  return true, keepGoing
end

local function pointSegmentDelta(px, py, pz, ax, ay, az, bx, by, bz)
  local x, y, z = bx - ax, by - ay, bz - az
  local sizeSquared = x * x + y * y + z * z
  local t = sizeSquared > 0.000001 and math.max(0, math.min(1,
    ((px - ax) * x + (py - ay) * y + (pz - az) * z) / sizeSquared)) or 0
  return px - (ax + x * t), py - (ay + y * t), pz - (az + z * t), t
end

local function closestSegments(a0, a1, b0, b1)
  local firstAxis, secondAxis = sub(a1, a0), sub(b1, b0)
  local between = sub(a0, b0)
  local firstLength, secondLength = dot(firstAxis, firstAxis), dot(secondAxis, secondAxis)
  local firstDot, secondDot = dot(firstAxis, between), dot(secondAxis, between)
  local s, t
  if firstLength <= 0.000001 and secondLength <= 0.000001 then
    s, t = 0, 0
  elseif firstLength <= 0.000001 then
    s, t = 0, math.max(0, math.min(1, secondDot / secondLength))
  elseif secondLength <= 0.000001 then
    t, s = 0, math.max(0, math.min(1, -firstDot / firstLength))
  else
    local crossDot = dot(firstAxis, secondAxis)
    local denominator = firstLength * secondLength - crossDot * crossDot
    s = denominator > 0.000001 and math.max(0, math.min(1,
      (crossDot * secondDot - firstDot * secondLength) / denominator)) or 0
    t = (crossDot * s + secondDot) / secondLength
    if t < 0 then
      t = 0
      s = math.max(0, math.min(1, -firstDot / firstLength))
    elseif t > 1 then
      t = 1
      s = math.max(0, math.min(1, (crossDot - firstDot) / firstLength))
    end
  end
  return add(a0, mul(firstAxis, s)), add(b0, mul(secondAxis, t)), s, t
end

local function lerp(a, b, amount)
  return add(a, mul(sub(b, a), amount))
end

local function stableNormal(firstId, secondId)
  local total
  if type(firstId) == "number" and type(secondId) == "number" then
    total = (math.floor(firstId) * 73856093 + math.floor(secondId) * 19349663) % 3
  else
    total = 0
    local text = tostring(firstId) .. "|" .. tostring(secondId)
    for index = 1, #text do total = (total * 31 + text:byte(index)) % 3 end
  end
  if total == 0 then return vec(1, 0, 0) end
  if total == 1 then return vec(0, 1, 0) end
  return vec(0, 0, 1)
end

local function markDegradation(stats, level, code, message)
  if type(stats) ~= "table" then return end
  stats.qualityReduced = true
  stats.degradationLevel = math.max(tonumber(stats.degradationLevel) or 0, tonumber(level) or 0)
  stats.degradationCodes = stats.degradationCodes or {}
  stats.degradationWarnings = stats.degradationWarnings or {}
  if stats.degradationCodes[code] then return end
  stats.degradationCodes[code] = true
  stats.degradationWarnings[#stats.degradationWarnings + 1] = message
end

local function mergeDegradation(target, source)
  if type(source) ~= "table" then return end
  for index, message in ipairs(source.degradationWarnings or {}) do
    markDegradation(target, source.degradationLevel or 1,
      "merged:" .. tostring(message), message)
  end
  if source.qualityReduced then
    target.qualityReduced = true
    target.degradationLevel = math.max(tonumber(target.degradationLevel) or 0,
      tonumber(source.degradationLevel) or 1)
  end
end

local function maskAllows(mask, group)
  if type(mask) ~= "table" then return true end
  return mask[group] ~= false
end

local function groupsAllow(world, first, second)
  local exclusions = world.collisionExclusionMap
  if exclusions then
    local firstId = first.component and first.component.id
    local secondId = second.component and second.component.id
    if type(firstId) == "string" and type(secondId) == "string" and firstId ~= secondId then
      if secondId < firstId then firstId, secondId = secondId, firstId end
      local exclusionRow = exclusions[firstId]
      if exclusionRow and exclusionRow[secondId] then return false end
    end
  end
  local firstGroup, secondGroup = first.group or "custom", second.group or "custom"
  local matrix = world.collisionMatrix
  local firstRow = type(matrix[firstGroup]) == "table" and matrix[firstGroup] or nil
  local secondRow = type(matrix[secondGroup]) == "table" and matrix[secondGroup] or nil
  if (firstRow and firstRow[secondGroup] == false) or (secondRow and secondRow[firstGroup] == false) then return false end
  return maskAllows(first.mask, secondGroup) and maskAllows(second.mask, firstGroup)
end

local function toWorld(frame, value, out)
  if frame and frame.frameAvailable == false then return nil end
  if frame and type(frame.toWorldPoint) == "function" then
    local result = frame.toWorldPoint(value, out)
    if result == nil and out then result = out end
    if type(result) ~= "table" or not finite(result.x) or not finite(result.y) or not finite(result.z) then return nil end
    if out then
      out.x, out.y, out.z = result.x, result.y, result.z
      return out
    end
    return result
  end
  if out then
    out.x, out.y, out.z = value.x, value.y, value.z
    return out
  end
  return vec(value.x, value.y, value.z)
end

local function toParent(frame, value)
  if frame and type(frame.toParentVector) == "function" then return frame.toParentVector(value) end
  return vec(value.x, value.y, value.z)
end

local function clearArray(values)
  for index = #values, 1, -1 do values[index] = nil end
end

local function writePoint(proxy, worldPoint, worldPrevious)
  proxy.world, proxy.previousWorld = worldPoint, worldPrevious
  proxy.dirty = true
end

local function setVelocity(proxy, velocity, dt)
  proxy.previousWorld = sub(proxy.world, mul(velocity, dt))
  proxy.dirty = true
end

local function flushContactPoint(proxy)
  if not proxy.dirty then return end
  local state, frame = proxy.component.state, proxy.component.frame
  local current = toParent(frame, proxy.world)
  local previous = toParent(frame, proxy.previousWorld)
  local root = frame and frame.rootOriginWorld
  if root then
    local parentRoot = toParent(frame, root)
    current, previous = sub(current, parentRoot), sub(previous, parentRoot)
  end
  state.points[proxy.index], state.previousPoints[proxy.index] = current, previous
  proxy.dirty = false
end

local function pointVelocity(proxy, dt)
  if dt <= 0 then return vec(0, 0, 0) end
  return mul(sub(proxy.world, proxy.previousWorld), 1 / dt)
end

local function applyPointPoint(pair, dt)
  local a, b = pair.first, pair.second
  -- Normal points from b toward a so normal impulses separate the pair.
  local dx, dy, dz = a.world.x - b.world.x, a.world.y - b.world.y, a.world.z - b.world.z
  local distanceSquared = dx * dx + dy * dy + dz * dz
  local combined = a.radius + b.radius
  if distanceSquared >= combined * combined then return false end
  local delta, distance = vec(dx, dy, dz), math.sqrt(math.max(0, distanceSquared))
  local normal = distance > 0.000001 and mul(delta, 1 / distance)
    or stableNormal(a.sortKey or a.id, b.sortKey or b.id)
  local totalWeight = a.inverseMass + b.inverseMass
  if totalWeight <= 0 then return false end
  local penetration = combined - distance
  local movedA = add(a.world, mul(normal, penetration * a.inverseMass / totalWeight))
  local movedB = sub(b.world, mul(normal, penetration * b.inverseMass / totalWeight))
  writePoint(a, movedA, a.previousWorld)
  writePoint(b, movedB, b.previousWorld)

  local velocityA, velocityB = pointVelocity(a, dt), pointVelocity(b, dt)
  local relative = sub(velocityA, velocityB)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (a.restitution + b.restitution) * 0.5))
  local normalImpulse = 0
  if normalSpeed < 0 then
    normalImpulse = -(1 + restitution) * normalSpeed / totalWeight
    velocityA = add(velocityA, mul(normal, normalImpulse * a.inverseMass))
    velocityB = sub(velocityB, mul(normal, normalImpulse * b.inverseMass))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 then
    local friction = math.max(0, math.min(1, (a.friction + b.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityA = sub(velocityA, mul(tangentDirection, impulse * a.inverseMass))
    velocityB = add(velocityB, mul(tangentDirection, impulse * b.inverseMass))
  end
  setVelocity(a, velocityA, dt)
  setVelocity(b, velocityB, dt)
  return true
end

local function applySweptPointPoint(pair, dt)
  local a, b = pair.first, pair.second
  local combined = a.radius + b.radius
  local startDelta = sub(a.previousWorld, b.previousWorld)
  local startDistance = length(startDelta)
  if startDistance <= combined then return false end
  local relativeTravel = sub(sub(a.world, a.previousWorld), sub(b.world, b.previousWorld))
  local travelSquared = dot(relativeTravel, relativeTravel)
  if travelSquared <= 0.00000001 then return false end
  local closestTime = math.max(0, math.min(1, -dot(startDelta, relativeTravel) / travelSquared))
  if closestTime <= 0 then return false end
  local closestDelta = add(startDelta, mul(relativeTravel, closestTime))
  if dot(closestDelta, closestDelta) >= combined * combined then return false end

  local low, high = 0, closestTime
  for _ = 1, 12 do
    local middle = (low + high) * 0.5
    local delta = add(startDelta, mul(relativeTravel, middle))
    if dot(delta, delta) <= combined * combined then high = middle else low = middle end
  end
  local hitTime = high
  local impactA = lerp(a.previousWorld, a.world, hitTime)
  local impactB = lerp(b.previousWorld, b.world, hitTime)
  local normal = normalize(sub(impactA, impactB), stableNormal(a.sortKey or a.id, b.sortKey or b.id))
  local totalWeight = a.inverseMass + b.inverseMass
  if totalWeight <= 0 then return false end

  local velocityA, velocityB = pointVelocity(a, dt), pointVelocity(b, dt)
  local relative = sub(velocityA, velocityB)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (a.restitution + b.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / totalWeight or 0
  if normalImpulse > 0 then
    velocityA = add(velocityA, mul(normal, normalImpulse * a.inverseMass))
    velocityB = sub(velocityB, mul(normal, normalImpulse * b.inverseMass))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 and normalImpulse > 0 then
    local friction = math.max(0, math.min(1, (a.friction + b.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityA = sub(velocityA, mul(tangentDirection, impulse * a.inverseMass))
    velocityB = add(velocityB, mul(tangentDirection, impulse * b.inverseMass))
  end

  local remaining = dt * (1 - hitTime)
  writePoint(a, add(impactA, mul(velocityA, remaining)), a.previousWorld)
  writePoint(b, add(impactB, mul(velocityB, remaining)), b.previousWorld)
  setVelocity(a, velocityA, dt)
  setVelocity(b, velocityB, dt)
  return true
end

local function applyPointSegment(pair, dt)
  local pointProxy, segment = pair.point, pair.segment
  local p, a, b = pointProxy.world, segment.first.world, segment.second.world
  local dx, dy, dz, t = pointSegmentDelta(p.x, p.y, p.z, a.x, a.y, a.z, b.x, b.y, b.z)
  local distanceSquared = dx * dx + dy * dy + dz * dz
  local combined = pointProxy.radius + segment.radius
  if distanceSquared >= combined * combined then return false end
  local delta, distance = vec(dx, dy, dz), math.sqrt(math.max(0, distanceSquared))
  local firstWeight = segment.first.inverseMass * (1 - t)
  local secondWeight = segment.second.inverseMass * t
  local totalWeight = pointProxy.inverseMass + firstWeight + secondWeight
  if totalWeight <= 0 then return false end
  local normal = distance > 0.000001 and mul(delta, 1 / distance)
    or normalize({ x = -(segment.second.world.z - segment.first.world.z), y = 0,
    z = segment.second.world.x - segment.first.world.x },
    stableNormal(pointProxy.sortKey or pointProxy.id, segment.sortKey or segment.id))
  local penetration = combined - distance
  writePoint(pointProxy, add(pointProxy.world, mul(normal, penetration * pointProxy.inverseMass / totalWeight)), pointProxy.previousWorld)
  writePoint(segment.first, sub(segment.first.world, mul(normal, penetration * firstWeight / totalWeight)), segment.first.previousWorld)
  writePoint(segment.second, sub(segment.second.world, mul(normal, penetration * secondWeight / totalWeight)), segment.second.previousWorld)

  local velocityPoint = pointVelocity(pointProxy, dt)
  local velocityFirst = pointVelocity(segment.first, dt)
  local velocitySecond = pointVelocity(segment.second, dt)
  local velocitySegment = add(mul(velocityFirst, 1 - t), mul(velocitySecond, t))
  local relative = sub(velocityPoint, velocitySegment)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (pointProxy.restitution + segment.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / totalWeight or 0
  if normalImpulse > 0 then
    velocityPoint = add(velocityPoint, mul(normal, normalImpulse * pointProxy.inverseMass))
    velocityFirst = sub(velocityFirst, mul(normal, normalImpulse * segment.first.inverseMass * (1 - t)))
    velocitySecond = sub(velocitySecond, mul(normal, normalImpulse * segment.second.inverseMass * t))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 then
    local friction = math.max(0, math.min(1, (pointProxy.friction + segment.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityPoint = sub(velocityPoint, mul(tangentDirection, impulse * pointProxy.inverseMass))
    velocityFirst = add(velocityFirst, mul(tangentDirection, impulse * segment.first.inverseMass * (1 - t)))
    velocitySecond = add(velocitySecond, mul(tangentDirection, impulse * segment.second.inverseMass * t))
  end
  setVelocity(pointProxy, velocityPoint, dt)
  setVelocity(segment.first, velocityFirst, dt)
  setVelocity(segment.second, velocitySecond, dt)
  return true
end

local function applySweptPointSegment(pair, dt)
  local pointProxy, segment = pair.point, pair.segment
  local combined = pointProxy.radius + segment.radius
  local pointStart, pointEnd = pointProxy.previousWorld, pointProxy.world
  local firstStart, firstEnd = segment.first.previousWorld, segment.first.world
  local secondStart, secondEnd = segment.second.previousWorld, segment.second.world
  local pointTravel = length(sub(pointEnd, pointStart))
  local firstTravel = length(sub(firstEnd, firstStart))
  local secondTravel = length(sub(secondEnd, secondStart))
  local speedBound = pointTravel + math.max(firstTravel, secondTravel)
  if speedBound <= 0.000001 then return false end

  local function sample(time)
    local px = pointStart.x + (pointEnd.x - pointStart.x) * time
    local py = pointStart.y + (pointEnd.y - pointStart.y) * time
    local pz = pointStart.z + (pointEnd.z - pointStart.z) * time
    local ax = firstStart.x + (firstEnd.x - firstStart.x) * time
    local ay = firstStart.y + (firstEnd.y - firstStart.y) * time
    local az = firstStart.z + (firstEnd.z - firstStart.z) * time
    local bx = secondStart.x + (secondEnd.x - secondStart.x) * time
    local by = secondStart.y + (secondEnd.y - secondStart.y) * time
    local bz = secondStart.z + (secondEnd.z - secondStart.z) * time
    local x, y, z, segmentT = pointSegmentDelta(px, py, pz, ax, ay, az, bx, by, bz)
    return math.sqrt(math.max(0, x * x + y * y + z * z)), segmentT
  end

  local startDistance = sample(0)
  if startDistance <= combined then return false end
  local time, safeTime, hitTime, hitSegmentT = 0, 0, nil, nil
  for _ = 1, 24 do
    local distance = sample(time)
    local gap = distance - combined
    if gap <= 0.00005 then hitTime = time; break end
    safeTime = time
    local advance = gap / speedBound * 0.8
    if advance <= 0.000001 or time + advance >= 1 then break end
    time = time + advance
  end
  if not hitTime then return false end

  local low, high = safeTime, hitTime
  for _ = 1, 10 do
    local middle = (low + high) * 0.5
    local distance = sample(middle)
    if distance <= combined then high = middle else low = middle end
  end
  hitTime = high
  local distance
  distance, hitSegmentT = sample(hitTime)
  local impactPoint = lerp(pointStart, pointEnd, hitTime)
  local impactFirst = lerp(firstStart, firstEnd, hitTime)
  local impactSecond = lerp(secondStart, secondEnd, hitTime)
  local closest = lerp(impactFirst, impactSecond, hitSegmentT)
  local normal = normalize(sub(impactPoint, closest),
    stableNormal(pointProxy.sortKey or pointProxy.id, segment.sortKey or segment.id))
  local firstWeight = segment.first.inverseMass * (1 - hitSegmentT)
  local secondWeight = segment.second.inverseMass * hitSegmentT
  local totalWeight = pointProxy.inverseMass + firstWeight + secondWeight
  if totalWeight <= 0 then return false end

  local penetration = math.max(0, combined - distance)
  if penetration > 0 then
    impactPoint = add(impactPoint, mul(normal, penetration * pointProxy.inverseMass / totalWeight))
    impactFirst = sub(impactFirst, mul(normal, penetration * firstWeight / totalWeight))
    impactSecond = sub(impactSecond, mul(normal, penetration * secondWeight / totalWeight))
  end

  local velocityPoint = pointVelocity(pointProxy, dt)
  local velocityFirst = pointVelocity(segment.first, dt)
  local velocitySecond = pointVelocity(segment.second, dt)
  local velocitySegment = add(mul(velocityFirst, 1 - hitSegmentT), mul(velocitySecond, hitSegmentT))
  local relative = sub(velocityPoint, velocitySegment)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (pointProxy.restitution + segment.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / totalWeight or 0
  if normalImpulse > 0 then
    velocityPoint = add(velocityPoint, mul(normal, normalImpulse * pointProxy.inverseMass))
    velocityFirst = sub(velocityFirst, mul(normal, normalImpulse * segment.first.inverseMass * (1 - hitSegmentT)))
    velocitySecond = sub(velocitySecond, mul(normal, normalImpulse * segment.second.inverseMass * hitSegmentT))
  end
  local tangent = sub(relative, mul(normal, normalSpeed))
  local tangentLength = length(tangent)
  if tangentLength > 0.000001 and normalImpulse > 0 then
    local friction = math.max(0, math.min(1, (pointProxy.friction + segment.friction) * 0.5))
    local impulse = math.min(tangentLength / totalWeight, friction * normalImpulse)
    local tangentDirection = mul(tangent, 1 / tangentLength)
    velocityPoint = sub(velocityPoint, mul(tangentDirection, impulse * pointProxy.inverseMass))
    velocityFirst = add(velocityFirst, mul(tangentDirection, impulse * segment.first.inverseMass * (1 - hitSegmentT)))
    velocitySecond = add(velocitySecond, mul(tangentDirection, impulse * segment.second.inverseMass * hitSegmentT))
  end

  local remaining = dt * (1 - hitTime)
  writePoint(pointProxy, add(impactPoint, mul(velocityPoint, remaining)), pointProxy.previousWorld)
  writePoint(segment.first, add(impactFirst, mul(velocityFirst, remaining)), segment.first.previousWorld)
  writePoint(segment.second, add(impactSecond, mul(velocitySecond, remaining)), segment.second.previousWorld)
  setVelocity(pointProxy, velocityPoint, dt)
  setVelocity(segment.first, velocityFirst, dt)
  setVelocity(segment.second, velocitySecond, dt)
  return true
end

local function applySegmentSegment(pair, dt)
  local first, second = pair.first, pair.second
  local a, b, s, t = closestSegments(first.first.world, first.second.world, second.first.world, second.second.world)
  local delta = sub(a, b)
  local distance = length(delta)
  local combined = first.radius + second.radius
  if distance >= combined then return false end
  local firstAWeight, firstAFraction = first.first.inverseMass * (1 - s), 1 - s
  local firstBWeight, firstBFraction = first.second.inverseMass * s, s
  local secondAWeight, secondAFraction = second.first.inverseMass * (1 - t), 1 - t
  local secondBWeight, secondBFraction = second.second.inverseMass * t, t
  local totalWeight = firstAWeight + firstBWeight + secondAWeight + secondBWeight
  local effectiveWeight = first.first.inverseMass * firstAFraction * firstAFraction
    + first.second.inverseMass * firstBFraction * firstBFraction
    + second.first.inverseMass * secondAFraction * secondAFraction
    + second.second.inverseMass * secondBFraction * secondBFraction
  if totalWeight <= 0 or effectiveWeight <= 0 then return false end
  local normal = distance > 0.000001 and mul(delta, 1 / distance)
    or stableNormal(first.sortKey or first.id, second.sortKey or second.id)
  local penetration = combined - distance
  writePoint(first.first, add(first.first.world, mul(normal, penetration * firstAWeight / totalWeight)), first.first.previousWorld)
  writePoint(first.second, add(first.second.world, mul(normal, penetration * firstBWeight / totalWeight)), first.second.previousWorld)
  writePoint(second.first, sub(second.first.world, mul(normal, penetration * secondAWeight / totalWeight)), second.first.previousWorld)
  writePoint(second.second, sub(second.second.world, mul(normal, penetration * secondBWeight / totalWeight)), second.second.previousWorld)

  local velocityFirstA, velocityFirstB = pointVelocity(first.first, dt), pointVelocity(first.second, dt)
  local velocitySecondA, velocitySecondB = pointVelocity(second.first, dt), pointVelocity(second.second, dt)
  local velocityA = add(mul(velocityFirstA, 1 - s), mul(velocityFirstB, s))
  local velocityB = add(mul(velocitySecondA, 1 - t), mul(velocitySecondB, t))
  local relative = sub(velocityA, velocityB)
  local normalSpeed = dot(relative, normal)
  local restitution = math.max(0, math.min(1, (first.restitution + second.restitution) * 0.5))
  local normalImpulse = normalSpeed < 0 and -(1 + restitution) * normalSpeed / effectiveWeight or 0
  if normalImpulse > 0 then
    velocityFirstA = add(velocityFirstA, mul(normal, normalImpulse * firstAWeight))
    velocityFirstB = add(velocityFirstB, mul(normal, normalImpulse * firstBWeight))
    velocitySecondA = sub(velocitySecondA, mul(normal, normalImpulse * secondAWeight))
    velocitySecondB = sub(velocitySecondB, mul(normal, normalImpulse * secondBWeight))
  end
  velocityA = add(mul(velocityFirstA, 1 - s), mul(velocityFirstB, s))
  velocityB = add(mul(velocitySecondA, 1 - t), mul(velocitySecondB, t))
  relative = sub(velocityA, velocityB)
  local tangent = sub(relative, mul(normal, dot(relative, normal)))
  local tangentLength = length(tangent)
  local frictionImpulse = 0
  if tangentLength > 0.000001 and normalImpulse > 0 then
    frictionImpulse = math.min(tangentLength / effectiveWeight,
      math.max(0, math.min(1, (first.friction + second.friction) * 0.5)) * normalImpulse)
  end
  local tangentDirection = tangentLength > 0.000001 and mul(tangent, 1 / tangentLength) or vec(0, 0, 0)
  velocityFirstA = sub(velocityFirstA, mul(tangentDirection, frictionImpulse * firstAWeight))
  velocityFirstB = sub(velocityFirstB, mul(tangentDirection, frictionImpulse * firstBWeight))
  velocitySecondA = add(velocitySecondA, mul(tangentDirection, frictionImpulse * secondAWeight))
  velocitySecondB = add(velocitySecondB, mul(tangentDirection, frictionImpulse * secondBWeight))
  setVelocity(first.first, velocityFirstA, dt)
  setVelocity(first.second, velocityFirstB, dt)
  setVelocity(second.first, velocitySecondA, dt)
  setVelocity(second.second, velocitySecondB, dt)
  return true
end

local function applySweptSegmentSegment(pair, dt)
  local first, second = pair.first, pair.second
  local firstStartA, firstStartB = first.first.previousWorld, first.second.previousWorld
  local secondStartA, secondStartB = second.first.previousWorld, second.second.previousWorld
  local firstEndA, firstEndB = first.first.world, first.second.world
  local secondEndA, secondEndB = second.first.world, second.second.world
  local combined = first.radius + second.radius
  local speedBound = math.max(length(sub(firstEndA, firstStartA)), length(sub(firstEndB, firstStartB)))
    + math.max(length(sub(secondEndA, secondStartA)), length(sub(secondEndB, secondStartB)))
  if speedBound <= 0.000001 then return false end
  local function sample(time)
    local a0, a1 = lerp(firstStartA, firstEndA, time), lerp(firstStartB, firstEndB, time)
    local b0, b1 = lerp(secondStartA, secondEndA, time), lerp(secondStartB, secondEndB, time)
    local closestA, closestB = closestSegments(a0, a1, b0, b1)
    return length(sub(closestA, closestB))
  end
  if sample(0) <= combined then return false end
  local time, safeTime, hitTime = 0, 0, nil
  for _ = 1, 32 do
    local gap = sample(time) - combined
    if gap <= 0.00005 then hitTime = time; break end
    safeTime = time
    local advance = gap / speedBound * 0.8
    if advance <= 0.000001 or time + advance >= 1 then break end
    time = time + advance
  end
  if not hitTime then return false end
  local low, high = safeTime, hitTime
  for _ = 1, 12 do
    local middle = (low + high) * 0.5
    if sample(middle) <= combined then high = middle else low = middle end
  end
  hitTime = math.min(1, high + 0.0005)
  first.first.world, first.second.world = lerp(firstStartA, firstEndA, hitTime), lerp(firstStartB, firstEndB, hitTime)
  second.first.world, second.second.world = lerp(secondStartA, secondEndA, hitTime), lerp(secondStartB, secondEndB, hitTime)
  if not applySegmentSegment(pair, dt) then
    first.first.world, first.second.world = firstEndA, firstEndB
    second.first.world, second.second.world = secondEndA, secondEndB
    return false
  end
  local remaining = dt * (1 - hitTime)
  local function finish(proxy)
    local velocity = pointVelocity(proxy, dt)
    local final = add(proxy.world, mul(velocity, remaining))
    writePoint(proxy, final, proxy.previousWorld)
    setVelocity(proxy, velocity, dt)
  end
  finish(first.first); finish(first.second); finish(second.first); finish(second.second)
  return true
end

local World = {}
World.__index = World

function worldApi.new(options)
  options = type(options) == "table" and options or {}
  local world = setmetatable({
    components = {},
    accumulator = 0,
    diagnostics = {},
    pointProxies = {},
    segmentProxies = {}, edgeOnlyProxies = {},
    pointProxyPool = {},
    segmentProxyPool = {},
    localProxyMap = {},
    candidatePairScratch = {},
    candidatePairPool = {},
    seenPairs = {},
    pointGrid = broadphase.new(),
    segmentGrid = broadphase.new(),
    largePoints = {},
    largeSegments = {},
  }, World)
  world:configure(options)
  return world
end

function World:configure(options)
  options = type(options) == "table" and options or {}
  local previousStep = tonumber(self.fixedStep) or tonumber(self.configuredFixedStep) or DEFAULTS.fixedStep
  local previousAccumulator = tonumber(self.accumulator) or 0
  local profile = performanceOptions(options.performance)
  self.performance = profile.performance
  self.configuredFixedStep = clamp(options.fixedStep, 1 / 120, 1 / 20, profile.fixedStep or DEFAULTS.fixedStep)
  self.fixedStep = self.configuredFixedStep
  self.maxSubsteps = math.floor(clamp(options.maxSubsteps, 1, 5, profile.maxSubsteps or DEFAULTS.maxSubsteps))
  self.maxFrameDt = clamp(options.maxFrameDt, 1 / 60, 0.25, profile.maxFrameDt or DEFAULTS.maxFrameDt)
  self.maxPoints = math.floor(clamp(options.maxPoints, 1, 512, profile.maxPoints or DEFAULTS.maxPoints))
  self.maxCandidatePairs = math.floor(clamp(options.maxCandidatePairs, 0, 4096,
    profile.maxCandidatePairs or DEFAULTS.maxCandidatePairs))
  self.contactIterations = math.floor(clamp(options.contactIterations, 1, 4,
    profile.contactIterations or DEFAULTS.contactIterations))
  self.constraintPasses = math.floor(clamp(options.constraintPasses, 1, 12,
    profile.constraintPasses or DEFAULTS.constraintPasses))
  self.cellSize = clamp(options.cellSize, 0.25, 8, profile.cellSize or DEFAULTS.cellSize)
  self.maxCellsPerProxy = math.floor(clamp(options.maxCellsPerProxy, 8, 1024,
    profile.maxCellsPerProxy or DEFAULTS.maxCellsPerProxy))
  self.maxBlockQueries = math.floor(clamp(options.maxBlockQueries, 0, 256,
    profile.maxBlockQueries or 64))
  if options.segmentMode == "segment_segment" then self.segmentMode = "segment_segment"
  elseif options.segmentMode == "point_segment" then self.segmentMode = "point_segment"
  else self.segmentMode = profile.segmentMode or "point_segment" end
  self.collisionMatrix = type(options.collisionMatrix) == "table" and options.collisionMatrix or {}
  local exclusionMap
  for _, pair in ipairs(type(options.collisionExclusions) == "table" and options.collisionExclusions or {}) do
    if type(pair) == "table" and type(pair.first) == "string" and type(pair.second) == "string"
      and pair.first ~= pair.second and #pair.first > 0 and #pair.second > 0 then
      local first, second = pair.first, pair.second
      if second < first then first, second = second, first end
      if not exclusionMap then exclusionMap = {} end
      local row = exclusionMap[first]
      if not row then row = {}; exclusionMap[first] = row end
      row[second] = true
    end
  end
  self.collisionExclusionMap = exclusionMap
  -- The accumulator represents elapsed seconds, not a fraction of the step.
  local carryLimit = self.fixedStep * self.maxSubsteps + math.max(previousStep, self.fixedStep)
  self.accumulator = math.max(0, math.min(previousAccumulator, carryLimit))
  return self
end

worldApi.performanceOptions = performanceOptions

local function componentPriority(component)
  local explicit = tonumber(component and component.collisionPriority)
  if finite(explicit) then return explicit end
  return COLLISION_PRIORITY[component and component.kind] or 50
end

local function sortComponents(components)
  table.sort(components, function(first, second)
    local firstPriority, secondPriority = componentPriority(first), componentPriority(second)
    if firstPriority == secondPriority then return first.id < second.id end
    return firstPriority > secondPriority
  end)
end

function World:setComponents(components)
  self.components = {}
  local seen = {}
  for _, component in ipairs(components or {}) do
    if type(component) == "table" and component.id ~= nil then
      local id = tostring(component.id)
      if not seen[id] then
        seen[id] = true
        component.id = id
        self.components[#self.components + 1] = component
      end
    end
  end
  sortComponents(self.components)
  return #self.components
end

function World:addComponent(component)
  if type(component) ~= "table" or component.id == nil then return false end
  local id = tostring(component.id)
  for index, existing in ipairs(self.components) do
    if existing.id == id then self.components[index] = component; return true end
  end
  component.id = id
  self.components[#self.components + 1] = component
  sortComponents(self.components)
  return true
end

function World:removeComponent(id)
  id = tostring(id)
  for index = #self.components, 1, -1 do
    if self.components[index].id == id then table.remove(self.components, index); return true end
  end
  return false
end

local function neighborDistanceMap(component, maximumDepth)
  local graph = component and component.graph
  local points = component and component.state and component.state.points
  if type(graph) ~= "table" or type(points) ~= "table" then return nil end
  maximumDepth = math.max(0, math.min(8, math.floor(tonumber(maximumDepth) or 1)))
  local cached = graph._worldNeighborDistances
  if type(cached) == "table" and cached.graph == graph and cached.pointCount == #points
    and cached.maximumDepth == maximumDepth then
    return cached.distances
  end

  local adjacency = {}
  for index = 1, #points do adjacency[index] = {} end
  for _, edge in ipairs(graph.edges or {}) do
    local from, to = tonumber(edge.from), tonumber(edge.to)
    if from and to and adjacency[from] and adjacency[to] then
      adjacency[from][#adjacency[from] + 1] = to
      adjacency[to][#adjacency[to] + 1] = from
    end
  end

  local distances = {}
  if maximumDepth > 0 then
    for origin = 1, #points do
      local distanceByPoint = { [origin] = 0 }
      local queue, head = { origin }, 1
      while head <= #queue do
        local current = queue[head]
        head = head + 1
        local distance = distanceByPoint[current]
        if distance < maximumDepth then
          for _, neighbor in ipairs(adjacency[current] or {}) do
            if distanceByPoint[neighbor] == nil then
              distanceByPoint[neighbor] = distance + 1
              queue[#queue + 1] = neighbor
            end
          end
        end
      end
      distances[origin] = distanceByPoint
    end
  end
  graph._worldNeighborDistances = {
    graph = graph, pointCount = #points, maximumDepth = maximumDepth, distances = distances,
  }
  return distances
end

local function sameComponentPairAllowed(kind, first, second)
  if first.component ~= second.component then return true end
  -- Point/point self-contact remains in the local collision solver. The shared
  -- world adds the missing capsule contacts between distinct branches.
  if kind == "pp" or first.selfCollision ~= true or second.selfCollision ~= true then return false end
  local distanceMap = first.neighborDistances or second.neighborDistances
  if type(distanceMap) ~= "table" then return false end
  local depth = math.max(1, math.floor(math.max(
    tonumber(first.selfNeighborDepth) or 1, tonumber(second.selfNeighborDepth) or 1)))
  local function near(a, b)
    local row = distanceMap[a]
    local distance = row and row[b]
    return distance ~= nil and distance <= depth
  end
  if kind == "ps" then
    local point, segment = first, second
    if first.index == nil then point, segment = second, first end
    return not (near(point.index, segment.first.index) or near(point.index, segment.second.index))
  end
  return not (near(first.first.index, second.first.index)
    or near(first.first.index, second.second.index)
    or near(first.second.index, second.first.index)
    or near(first.second.index, second.second.index))
end

local function collectProxies(world, components)
  local points, segments = world.pointProxies, world.segmentProxies
  local edgeOnlyProxies = world.edgeOnlyProxies
  clearArray(points)
  clearArray(segments)
  clearArray(edgeOnlyProxies)
  local pointPool, segmentPool, localProxies = world.pointProxyPool, world.segmentProxyPool, world.localProxyMap
  local pointPoolIndex, segmentPoolIndex, count, truncated, frameUnavailable = 0, 0, 0, false, 0
  for _, component in ipairs(components or {}) do
    if component.enabled ~= false and type(component.state) == "table"
      and type(component.state.points) == "table" and type(component.state.previousPoints) == "table" then
      local pointInfo = component.pointInfo or {}
      for index in pairs(localProxies) do localProxies[index] = nil end
      local maximumNeighborDepth = 0
      for _, info in pairs(pointInfo) do
        if info.selfCollision == true then
          maximumNeighborDepth = math.max(maximumNeighborDepth,
            1, tonumber(info.selfNeighborDepth) or 1)
        end
      end
      local neighborDistances = nil
      local missingFrame = false
      for index, current in ipairs(component.state.points) do
        local info = pointInfo[index] or {}
        local radius = math.max(0, tonumber(info.radius) or 0)
        if info.dynamic ~= false and radius > 0 then
          if component.frame and component.frame.frameAvailable == false then
            missingFrame = true
          elseif count >= world.maxPoints then
            truncated = true
            break
          else
            pointPoolIndex = pointPoolIndex + 1
            local proxy = pointPool[pointPoolIndex]
            if not proxy then
              proxy = { world = vec(0, 0, 0), previousWorld = vec(0, 0, 0) }
              pointPool[pointPoolIndex] = proxy
            end
            local worldPoint = toWorld(component.frame, current, proxy.world)
            local previousWorld = toWorld(component.frame, component.state.previousPoints[index], proxy.previousWorld)
            if not worldPoint or not previousWorld then
              missingFrame = true
              pointPoolIndex = pointPoolIndex - 1
            else
              count = count + 1
              if maximumNeighborDepth > 0 and not neighborDistances then
                neighborDistances = neighborDistanceMap(component, maximumNeighborDepth)
              end
              if proxy.idComponent ~= component.id or proxy.idIndex ~= index then
                proxy.id = component.id .. ":" .. tostring(index)
                proxy.idComponent, proxy.idIndex = component.id, index
              end
              proxy.component, proxy.index, proxy.radius, proxy.dirty = component, index, radius, false
              proxy.edgeOnly = false
              proxy.inverseMass = math.max(0, tonumber(info.inverseMass) or 0)
              proxy.selfCollision = info.selfCollision == true
              proxy.selfNeighborDepth = math.max(0, math.floor(tonumber(info.selfNeighborDepth) or 1))
              proxy.neighborDistances = neighborDistances
              proxy.group, proxy.mask = info.group or component.group or "custom", info.mask or component.mask
              proxy.friction = clamp(info.friction, 0, 1, 0.25)
              proxy.restitution = clamp(info.restitution, 0, 1, 0)
              localProxies[index] = proxy
              points[#points + 1] = proxy
            end
          end
        end
      end
      for _, edge in ipairs(component.graph and component.graph.edges or {}) do
        local first, second = localProxies[edge.from], localProxies[edge.to]
        if component.boneOwnedCollisions == true and second and second.edgeOnly then second = nil end
        if component.boneOwnedCollisions == true and not first and second then
          -- A bone owns its outgoing segment even if the preceding bone has
          -- no point collider. Create a shared endpoint solely for segments;
          -- it must not enter the point-contact broadphase.
          if count >= world.maxPoints then
            truncated = true
          else
            local source, previous = component.state.points[edge.from], component.state.previousPoints[edge.from]
            if source and previous then
              pointPoolIndex = pointPoolIndex + 1
              local proxy = pointPool[pointPoolIndex]
              if not proxy then
                proxy = { world = vec(0, 0, 0), previousWorld = vec(0, 0, 0) }
                pointPool[pointPoolIndex] = proxy
              end
              local worldPoint = toWorld(component.frame, source, proxy.world)
              local previousWorld = toWorld(component.frame, previous, proxy.previousWorld)
              if worldPoint and previousWorld then
                local info = pointInfo[edge.from] or {}
                count = count + 1
                proxy.id = component.id .. ":" .. tostring(edge.from)
                proxy.idComponent, proxy.idIndex = component.id, edge.from
                proxy.component, proxy.index, proxy.radius, proxy.dirty = component, edge.from, second.radius, false
                proxy.edgeOnly = true
                proxy.inverseMass = math.max(0, tonumber(info.inverseMass) or 0)
                proxy.selfCollision = second.selfCollision
                proxy.selfNeighborDepth, proxy.neighborDistances = second.selfNeighborDepth, neighborDistances
                proxy.group, proxy.mask = second.group, second.mask
                proxy.friction, proxy.restitution = second.friction, second.restitution
                localProxies[edge.from] = proxy
                edgeOnlyProxies[#edgeOnlyProxies + 1] = proxy
                first = proxy
              else
                missingFrame = true
                pointPoolIndex = pointPoolIndex - 1
              end
            end
          end
        end
        if first and second then
          local radius = math.max(0, tonumber(edge.radius) or (component.boneOwnedCollisions == true
            and second.radius or (first.radius + second.radius) * 0.5))
          if radius > 0 then
            segmentPoolIndex = segmentPoolIndex + 1
            local segment = segmentPool[segmentPoolIndex]
            if not segment then segment = {}; segmentPool[segmentPoolIndex] = segment end
            if segment.idComponent ~= component.id or segment.idFrom ~= edge.from or segment.idTo ~= edge.to then
              segment.id = component.id .. ":e:" .. tostring(edge.from) .. ":" .. tostring(edge.to)
              segment.idComponent, segment.idFrom, segment.idTo = component.id, edge.from, edge.to
            end
            segment.component, segment.first, segment.second, segment.radius = component, first, second, radius
            segment.selfCollision = component.boneOwnedCollisions == true and second.selfCollision == true
              or (component.boneOwnedCollisions ~= true and first.selfCollision == true and second.selfCollision == true)
            segment.selfNeighborDepth = component.boneOwnedCollisions == true and (second.selfNeighborDepth or 1)
              or math.max(first.selfNeighborDepth or 1, second.selfNeighborDepth or 1)
            segment.neighborDistances = neighborDistances
            local material = component.boneOwnedCollisions == true and second or first
            segment.group, segment.mask = edge.group or material.group, edge.mask or material.mask
            segment.friction = component.boneOwnedCollisions == true and second.friction
              or (first.friction + second.friction) * 0.5
            segment.restitution = component.boneOwnedCollisions == true and second.restitution
              or (first.restitution + second.restitution) * 0.5
            segments[#segments + 1] = segment
          end
        end
      end
      if missingFrame then frameUnavailable = frameUnavailable + 1 end
    end
  end
  return points, segments, count, truncated, frameUnavailable
end

local function countSimulationPoints(components)
  local count = 0
  for _, component in ipairs(components or {}) do
    local points = component.enabled ~= false and component.state and component.state.points or nil
    if type(points) == "table" then
      local pointInfo = component.pointInfo or {}
      for index in ipairs(points) do
        local info = pointInfo[index]
        if info then
          local inverseMass = tonumber(info.inverseMass)
          -- `dynamic` describes whether this point has a collision proxy, not
          -- whether the solver advances it. Disabled collision must not hide
          -- simulated points from the shared performance budget.
          if (inverseMass == nil and index > 1) or (inverseMass ~= nil and inverseMass > 0) then
            count = count + 1
          end
        elseif index > 1 then
          -- Collision-free components may omit per-point collision metadata.
          -- Their first point remains the fixed chain root for budget purposes.
          count = count + 1
        end
      end
    end
  end
  return count
end

local function addProxyToGrid(grid, large, proxy, bounds, maxCells)
  -- Bounds are already in grid coordinates; enumerate directly to avoid a second transform.
  local cellCount = (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) * (bounds.maxZ - bounds.minZ + 1)
  if cellCount > maxCells then large[#large + 1] = proxy; return end
  for x = bounds.minX, bounds.maxX do
    for y = bounds.minY, bounds.maxY do
      for z = bounds.minZ, bounds.maxZ do
        local bucket = broadphase.cell(grid, x, y, z, true)
        bucket[#bucket + 1] = proxy
      end
    end
  end
end

local function hasPotentialDynamicContacts(components)
  local componentsWithProxies, hasSelfColliderPair = 0, false
  for _, component in ipairs(components or {}) do
    if component.enabled ~= false then
      local proxyCount, selfColliderCount = 0, 0
      for _, info in pairs(component.pointInfo or {}) do
        if info.dynamic ~= false and (tonumber(info.radius) or 0) > 0 then
          proxyCount = proxyCount + 1
          if info.selfCollision == true then selfColliderCount = selfColliderCount + 1 end
        end
      end
      if proxyCount > 0 then
        componentsWithProxies = componentsWithProxies + 1
        if componentsWithProxies > 1 then return true end
      end
      if selfColliderCount > 1 then hasSelfColliderPair = true end
    end
  end
  return hasSelfColliderPair
end

function World:resolveDynamicContacts(components, dt, budgetLimit, iterationLimit, skipIfNoPairs, segmentModeOverride)
  components = components or self.components
  dt = clamp(dt, 0.0001, 0.25, self.fixedStep)
  local stats = { activeComponents = 0, activePoints = 0, activeSegments = 0,
    candidatePairs = 0, resolvedContacts = 0, iterations = 0,
    segmentSegmentPairs = 0, budgetExceeded = false, pointBudgetExceeded = false,
    frameUnavailableComponents = 0, contactPoints = {}, qualityReduced = false,
    degradationLevel = 0, degradationWarnings = {}, degradationCodes = {},
    segmentPairsSkipped = false }
  for _, component in ipairs(components) do if component.enabled ~= false then stats.activeComponents = stats.activeComponents + 1 end end
  if skipIfNoPairs == true and not hasPotentialDynamicContacts(components) then
    self.diagnostics = stats
    return stats
  end
  local points, segments, count, truncated, frameUnavailable = collectProxies(self, components)
  stats.activePoints, stats.activeSegments, stats.pointBudgetExceeded = count, #segments, truncated
  if truncated then
    markDegradation(stats, 4, "point-budget",
      "Часть физических точек пропущена: превышен общий лимит точек.")
  end
  stats.frameUnavailableComponents = frameUnavailable
  if #points < 1 then self.diagnostics = stats; return stats end
  local maxCandidatePairs = math.max(0, math.floor(tonumber(budgetLimit) or self.maxCandidatePairs))
  local function collidePass()
    local pointGrid, segmentGrid = self.pointGrid, self.segmentGrid
    broadphase.clear(pointGrid)
    broadphase.clear(segmentGrid)
    local largePoints, largeSegments = self.largePoints, self.largeSegments
    clearArray(largePoints)
    clearArray(largeSegments)
    for proxyOrder, proxy in ipairs(points) do
      proxy.order, proxy.sortKey = proxyOrder, proxyOrder
    end
    for segmentOrder, segment in ipairs(segments) do
      segment.order, segment.sortKey = #points + segmentOrder, #points + segmentOrder
    end
    for _, proxy in ipairs(points) do
      proxy.gridBounds = sweptPointAabb(proxy, proxy.radius, self.cellSize, proxy.gridBounds)
      proxy.sweepBounds = sweptPointBounds(proxy, proxy.radius, proxy.sweepBounds)
      addProxyToGrid(pointGrid, largePoints, proxy, proxy.gridBounds, self.maxCellsPerProxy)
    end
    for _, segment in ipairs(segments) do
      segment.gridBounds = sweptSegmentAabb(segment, segment.radius, self.cellSize, segment.gridBounds)
      segment.sweepBounds = sweptSegmentBounds(segment, segment.radius, segment.sweepBounds)
      addProxyToGrid(segmentGrid, largeSegments, segment, segment.gridBounds, self.maxCellsPerProxy)
    end
    local seen, pairsToCheck = self.seenPairs, self.candidatePairScratch
    clearArray(pairsToCheck)
    for _, kindSeen in pairs(seen) do
      for _, firstSeen in pairs(kindSeen) do
        for secondOrder in pairs(firstSeen) do firstSeen[secondOrder] = nil end
      end
    end
    local function addPair(kind, first, second)
      if not groupsAllow(self, first, second) or not sameComponentPairAllowed(kind, first, second) then return true end
      local firstOrder, secondOrder = first.order, second.order
      if firstOrder > secondOrder then firstOrder, secondOrder = secondOrder, firstOrder end
      local kindSeen = seen[kind]
      if not kindSeen then kindSeen = {}; seen[kind] = kindSeen end
      local firstSeen = kindSeen[firstOrder]
      if firstSeen and firstSeen[secondOrder] then return true end
      if stats.candidatePairs >= maxCandidatePairs then
        if kind == "ss" then
          stats.segmentPairsSkipped = true
          markDegradation(stats, 1, "segment-segment-budget",
            "Сегмент-сегмент пропущен: лимит пар.")
        else
          stats.budgetExceeded = true
          markDegradation(stats, 3, "dynamic-pair-budget",
            "Часть контактов пропущена: лимит пар.")
        end
        return false
      end
      if not firstSeen then firstSeen = {}; kindSeen[firstOrder] = firstSeen end
      firstSeen[secondOrder] = true
      stats.candidatePairs = stats.candidatePairs + 1
      if kind == "ss" then stats.segmentSegmentPairs = stats.segmentSegmentPairs + 1 end
      local pairIndex = #pairsToCheck + 1
      local pair = self.candidatePairPool[pairIndex]
      if not pair then pair = {}; self.candidatePairPool[pairIndex] = pair end
      pair.kind = kind
      if kind == "pp" or kind == "ss" then
        pair.first, pair.second, pair.point, pair.segment = first, second, nil, nil
      else
        pair.first, pair.second, pair.point, pair.segment = nil, nil, first, second
      end
      pairsToCheck[pairIndex] = pair
      return true
    end
    local function gatherPoint(pointProxy, bucket)
      if not bucket then return true end
      for _, other in ipairs(bucket) do
        if pointProxy.order < other.order and boundsOverlap(pointProxy.sweepBounds, other.sweepBounds) then
          if not addPair("pp", pointProxy, other) then return false end
        end
      end
      return true
    end
    local function gatherSegment(pointProxy, bucket)
      if not bucket then return true end
      for _, segment in ipairs(bucket) do
        if boundsOverlap(pointProxy.sweepBounds, segment.sweepBounds) then
          if not addPair("ps", pointProxy, segment) then return false end
        end
      end
      return true
    end
    local function gatherSegmentSegment(segment, bucket)
      if not bucket then return true end
      for _, other in ipairs(bucket) do
        if segment.order < other.order and boundsOverlap(segment.sweepBounds, other.sweepBounds) then
          if not addPair("ss", segment, other) then return false end
        end
      end
      return true
    end
    for _, proxy in ipairs(points) do
      local bounds = sweptPointAabb(proxy, proxy.radius, self.cellSize)
      local cellsFit = visitGridCells(bounds, self.maxCellsPerProxy, function(x, y, z)
        if not gatherPoint(proxy, broadphase.cell(pointGrid, x, y, z, false)) then return false end
        return gatherSegment(proxy, broadphase.cell(segmentGrid, x, y, z, false))
      end)
      if not cellsFit then
        for _, other in ipairs(points) do
          if proxy.order < other.order and boundsOverlap(proxy.sweepBounds, other.sweepBounds) then
            if not addPair("pp", proxy, other) then break end
          end
        end
        for _, segment in ipairs(segments) do
          if boundsOverlap(proxy.sweepBounds, segment.sweepBounds) then
            if not addPair("ps", proxy, segment) then break end
          end
        end
      end
      for _, other in ipairs(largePoints) do
        if proxy.order < other.order and boundsOverlap(proxy.sweepBounds, other.sweepBounds) then
          if not addPair("pp", proxy, other) then break end
        end
      end
      for _, segment in ipairs(largeSegments) do
        if boundsOverlap(proxy.sweepBounds, segment.sweepBounds) then
          if not addPair("ps", proxy, segment) then break end
        end
      end
      if stats.budgetExceeded then break end
    end
    local segmentMode = segmentModeOverride or self.segmentMode
    if segmentMode == "segment_segment" and not stats.budgetExceeded and not stats.segmentPairsSkipped then
      for _, segment in ipairs(segments) do
        local bounds = sweptSegmentAabb(segment, segment.radius, self.cellSize)
        local cellsFit = visitGridCells(bounds, self.maxCellsPerProxy, function(x, y, z)
          return gatherSegmentSegment(segment, broadphase.cell(segmentGrid, x, y, z, false))
        end)
        if not cellsFit then
          for _, other in ipairs(segments) do
            if segment.order < other.order and boundsOverlap(segment.sweepBounds, other.sweepBounds) then
              if not addPair("ss", segment, other) then break end
            end
          end
        end
        for _, other in ipairs(largeSegments) do
          if segment.order < other.order and boundsOverlap(segment.sweepBounds, other.sweepBounds) then
            if not addPair("ss", segment, other) then break end
          end
        end
        if stats.budgetExceeded or stats.segmentPairsSkipped then break end
      end
    end
    for _, pair in ipairs(pairsToCheck) do
      local resolved
      if pair.kind == "pp" then
        resolved = applyPointPoint(pair, dt) or applySweptPointPoint(pair, dt)
      elseif pair.kind == "ss" then
        resolved = applySegmentSegment(pair, dt) or applySweptSegmentSegment(pair, dt)
      else
        resolved = applyPointSegment(pair, dt) or applySweptPointSegment(pair, dt)
      end
      if resolved then
        stats.resolvedContacts = stats.resolvedContacts + 1
        local function mark(proxy)
          local byComponent = stats.contactPoints[proxy.component.id]
          if not byComponent then byComponent = {}; stats.contactPoints[proxy.component.id] = byComponent end
          byComponent[proxy.index] = true
        end
        if pair.kind == "pp" then mark(pair.first); mark(pair.second)
        elseif pair.kind == "ss" then
          mark(pair.first.first); mark(pair.first.second); mark(pair.second.first); mark(pair.second.second)
        else mark(pair.point); mark(pair.segment.first); mark(pair.segment.second) end
      end
    end
  end
  iterationLimit = math.floor(clamp(iterationLimit, 1, self.contactIterations, self.contactIterations))
  for iteration = 1, iterationLimit do
    stats.iterations = iteration
    collidePass()
    if stats.budgetExceeded or stats.segmentPairsSkipped then break end
  end
  -- Contact resolution reads and writes world-space proxies only. Convert each
  -- changed point back to its component once after all contact iterations.
  for _, proxy in ipairs(points) do flushContactPoint(proxy) end
  for _, proxy in ipairs(self.edgeOnlyProxies) do flushContactPoint(proxy) end
  self.diagnostics = stats
  return stats
end

function World:step(dt, components, hooks)
  if components ~= nil then self:setComponents(components) end
  hooks = type(hooks) == "table" and hooks or {}
  dt = clamp(dt, 0, self.maxFrameDt, 0)
  local instructionPressure = hooks.instructionPressure == true
  local timePressure = math.floor(clamp(hooks.timePressure, 0, 2, 0))
  local instructionRatio, loadShedScale
  local configuredPairBudget = self.maxCandidatePairs
  local effectivePairBudget = configuredPairBudget
  local effectiveContactIterations = self.contactIterations
  local effectiveSegmentMode = self.segmentMode
  local configuredWorldQueryBudget = self.maxBlockQueries
  local effectiveWorldQueryBudget = configuredWorldQueryBudget
  if instructionPressure or timePressure > 0 then
    instructionRatio = hooks.instructionRatio
    if not finite(instructionRatio) then instructionRatio = nil end
    local critical = timePressure >= 2 or (instructionPressure and instructionRatio ~= nil and instructionRatio >= 0.90)
    loadShedScale = critical and 0.5 or 0.75
    if configuredPairBudget > 0 then
      effectivePairBudget = math.max(1, math.floor(configuredPairBudget * loadShedScale))
    end
    effectiveContactIterations = critical and 1 or math.max(1, self.contactIterations - 1)
    effectiveSegmentMode = "point_segment"
    effectiveWorldQueryBudget = math.floor(configuredWorldQueryBudget * loadShedScale)
  end
  if loadShedScale == nil then loadShedScale = 1 end
  local configuredStep = self.configuredFixedStep or self.fixedStep or DEFAULTS.fixedStep
  local activeSimulationPoints = countSimulationPoints(self.components)
  local requiredStep = configuredStep
  local simulationQualityReduced = false
  local simulationPointQualityReduced = false
  local simulationTimeReduced = false
  local simulationBudgetExceeded = false
  if self.maxPoints > 0 and activeSimulationPoints > self.maxPoints then
    requiredStep = configuredStep * activeSimulationPoints / self.maxPoints
    simulationQualityReduced = true
    simulationPointQualityReduced = true
    simulationBudgetExceeded = requiredStep > (1 / 20) + 0.000000001
  end
  -- Optional contact reductions cannot prevent a long fixed-step solver from
  -- falling behind Minecraft's tick rate. Under sustained critical time
  -- pressure, keep every chain synchronized at the existing 30 Hz profile
  -- rate, or the 20 Hz floor when point load also exceeds the configured budget.
  local timeLimitedStep = simulationPointQualityReduced and 1 / 20 or 1 / 30
  if timePressure >= 2 and requiredStep < timeLimitedStep then
    requiredStep = timeLimitedStep
    simulationTimeReduced = true
    simulationQualityReduced = true
  end
  local effectiveStep = math.min(1 / 20, requiredStep)
  local previousStep = tonumber(self.fixedStep) or configuredStep
  self.fixedStep = effectiveStep
  -- Preserve a previous partial step across rate changes while keeping the
  -- catch-up buffer bounded if the configured substep limit is too low.
  local carryLimit = self.fixedStep * self.maxSubsteps + math.max(previousStep, self.fixedStep)
  self.accumulator = math.min(self.accumulator + dt, carryLimit)
  -- All components and substeps share this cap for deep-overlap recovery.
  local extraPassBudget = { remaining = 3 }
  local extraPassQueue = self.extraPassQueue or {}
  local extraPassQueued = self.extraPassQueued or {}
  self.extraPassQueue, self.extraPassQueued = extraPassQueue, extraPassQueued
  -- Rotate only among components that actually requested a pass and were
  -- denied; do not consume a turn on calls without a physical substep.
  if self.accumulator + 0.000000001 >= self.fixedStep then
    while #extraPassQueue > 0 do
      local candidate = table.remove(extraPassQueue, 1)
      extraPassQueued[candidate] = nil
      for _, component in ipairs(self.components) do
        if component.id == candidate and component.enabled ~= false then
          extraPassBudget.preferredId = candidate
          break
        end
      end
      if extraPassBudget.preferredId then break end
    end
  end
  local stats = { substeps = 0, alpha = 0, activeComponents = 0, activePoints = 0,
    activeSegments = 0, candidatePairs = 0, selfPairs = 0, pairChecks = 0,
    pairBudgetRemaining = effectivePairBudget, pairBudgetExceeded = false,
    resolvedContacts = 0, budgetExceeded = false,
    segmentSegmentPairs = 0,
    pointBudgetExceeded = false, performance = self.performance,
    activeSimulationPoints = activeSimulationPoints, simulationPointBudget = self.maxPoints,
    configuredSimulationHz = configuredStep > 0 and 1 / configuredStep or 0,
    simulationHz = self.fixedStep > 0 and 1 / self.fixedStep or 0,
    simulationQualityReduced = simulationQualityReduced,
    simulationTimeReduced = simulationTimeReduced,
    simulationFrequencyReduced = self.fixedStep > configuredStep + 0.000000001,
    simulationBudgetExceeded = simulationBudgetExceeded,
    frameUnavailableComponents = 0,
    configuredCandidatePairs = configuredPairBudget, maxCandidatePairs = effectivePairBudget, maxPoints = self.maxPoints,
    maxSubsteps = self.maxSubsteps, contactIterations = self.contactIterations,
    configuredContactIterations = self.contactIterations,
    effectiveContactIterationLimit = effectiveContactIterations, segmentMode = effectiveSegmentMode,
    instructionPressure = instructionPressure, instructionRatio = instructionRatio,
    timePressure = timePressure, loadShedScale = loadShedScale,
    constraintPasses = self.constraintPasses,
    effectiveContactIterations = 0, contactIterationsReduced = (instructionPressure or timePressure > 0)
      and effectiveContactIterations < self.contactIterations or false,
    reducedContactIterationsTo = (instructionPressure or timePressure > 0) and effectiveContactIterations or nil,
    dynamicPassesSkipped = 0, qualityReduced = false, degradationLevel = 0,
    extraLocalPassBudget = 3, extraLocalPassesUsed = 0, extraLocalPassesLimited = false,
    degradationWarnings = {}, degradationCodes = {}, segmentPairsSkipped = false,
    worldQueries = 0, localContacts = 0, selfPairs = 0,
    configuredWorldQueryBudget = configuredWorldQueryBudget,
    worldQueryBudget = effectiveWorldQueryBudget, blockBudgetExceeded = false,
    selfBudgetExceeded = false, worldUnavailable = false }
  if instructionPressure then
    markDegradation(stats, 1, "instruction-budget",
      "TICK превысил порог Figura: на этом тике сокращены дополнительные контакты и запросы блоков.")
  end
  if timePressure > 0 then
    markDegradation(stats, 1, "solver-time-budget",
      "Физический шаг долго выполнялся: сокращены дополнительные контакты и запросы блоков.")
  end
  if simulationPointQualityReduced then
    markDegradation(stats, 6, "simulation-point-budget",
      "Общая частота физики снижена: симулируемых точек " .. tostring(activeSimulationPoints)
        .. " при бюджете " .. tostring(self.maxPoints) .. ".")
  end
  if simulationTimeReduced then
    markDegradation(stats, 6, "simulation-time-budget",
      "Общая частота физики временно снижена до " .. tostring(math.floor(1 / effectiveStep + 0.5))
        .. " Гц из-за долгих тиков.")
  end
  if simulationBudgetExceeded then
    markDegradation(stats, 7, "simulation-point-hard-limit",
      "Даже на минимальной частоте 20 Гц число точек превышает бюджет; физика продолжает работать с возможной нагрузкой.")
  end
  for _, component in ipairs(self.components) do if component.enabled ~= false then stats.activeComponents = stats.activeComponents + 1 end end
  while self.accumulator + 0.000000001 >= self.fixedStep and stats.substeps < self.maxSubsteps do
    if type(hooks.beforeSubstep) == "function" then hooks.beforeSubstep(self.components, self.fixedStep) end
    for _, component in ipairs(self.components) do
      if component.enabled ~= false and type(hooks.integrate) == "function" then hooks.integrate(component, self.fixedStep) end
    end
    local remainingPairs = math.max(0, effectivePairBudget - stats.pairChecks)
    local exhausted = stats.budgetExceeded or stats.pointBudgetExceeded
      or stats.pairChecks >= effectivePairBudget
    local contacts
    if stats.substeps > 0 and exhausted then
      stats.dynamicPassesSkipped = stats.dynamicPassesSkipped + 1
      if stats.budgetExceeded or stats.pointBudgetExceeded or effectivePairBudget > 0 then
        markDegradation(stats, 3, "dynamic-substep-budget",
          "Динамические контакты пропущены в оставшихся подшагах: общий бюджет уже израсходован.")
      end
      contacts = { activePoints = stats.activePoints, activeSegments = stats.activeSegments,
        candidatePairs = 0, resolvedContacts = 0, segmentSegmentPairs = 0,
        iterations = 0, budgetExceeded = false, pointBudgetExceeded = false,
        segmentPairsSkipped = false, qualityReduced = false, contactPoints = {} }
    else
      local iterationLimit = effectiveContactIterations
      if stats.substeps > 0 and effectivePairBudget > 0 and remainingPairs > 0
        and remainingPairs <= math.floor(effectivePairBudget * 0.25)
        and iterationLimit > 1 then
        iterationLimit = 1
        stats.contactIterationsReduced = true
        stats.reducedContactIterationsTo = iterationLimit
        markDegradation(stats, 2, "contact-iteration-budget",
          "Сокращены дополнительные проходы контактов, чтобы сохранить бюджет для следующих подшагов.")
      end
      contacts = self:resolveDynamicContacts(nil, self.fixedStep, remainingPairs, iterationLimit, true,
        effectiveSegmentMode)
      stats.effectiveContactIterations = math.max(stats.effectiveContactIterations, contacts.iterations or 0)
      mergeDegradation(stats, contacts)
    end
    stats.activePoints = math.max(stats.activePoints, contacts.activePoints)
    stats.activeSegments = math.max(stats.activeSegments, contacts.activeSegments)
    stats.candidatePairs = stats.candidatePairs + contacts.candidatePairs
    stats.pairChecks = stats.pairChecks + contacts.candidatePairs
    stats.pairBudgetRemaining = math.max(0, effectivePairBudget - stats.pairChecks)
    stats.resolvedContacts = stats.resolvedContacts + contacts.resolvedContacts
    stats.segmentSegmentPairs = stats.segmentSegmentPairs + (contacts.segmentSegmentPairs or 0)
    stats.frameUnavailableComponents = math.max(stats.frameUnavailableComponents, contacts.frameUnavailableComponents or 0)
    stats.budgetExceeded = stats.budgetExceeded or contacts.budgetExceeded or contacts.pointBudgetExceeded
    stats.pairBudgetExceeded = stats.pairBudgetExceeded or contacts.budgetExceeded == true
    stats.pointBudgetExceeded = stats.pointBudgetExceeded or contacts.pointBudgetExceeded
    stats.segmentPairsSkipped = stats.segmentPairsSkipped or contacts.segmentPairsSkipped == true
    if type(hooks.contacts) == "function" then hooks.contacts(self.components, self.fixedStep, contacts) end
    for _, component in ipairs(self.components) do
      if component.enabled ~= false and type(hooks.resolveLocal) == "function" then
        local remainingLocalPairs = math.max(0, effectivePairBudget - stats.pairChecks)
        extraPassBudget.componentId = component.id
        local localStats = hooks.resolveLocal(component, self.fixedStep,
          contacts.contactPoints[component.id] or {}, contacts, remainingLocalPairs, extraPassBudget)
        if component.id == extraPassBudget.preferredId then extraPassBudget.preferredVisited = true end
        stats.extraLocalPassesUsed = stats.extraLocalPassBudget - extraPassBudget.remaining
        if type(localStats) == "table" then
          stats.worldQueries = stats.worldQueries + (tonumber(localStats.worldQueries) or 0)
          stats.localContacts = stats.localContacts + (tonumber(localStats.contacts) or 0)
          local reportedSelfPairs = math.max(0, math.floor(tonumber(localStats.selfPairs) or 0))
          local acceptedSelfPairs = math.min(reportedSelfPairs, remainingLocalPairs)
          stats.selfPairs = stats.selfPairs + acceptedSelfPairs
          stats.pairChecks = stats.pairChecks + acceptedSelfPairs
          stats.pairBudgetRemaining = math.max(0, effectivePairBudget - stats.pairChecks)
          stats.blockBudgetExceeded = stats.blockBudgetExceeded or localStats.budgetExceeded == true
          stats.selfBudgetExceeded = stats.selfBudgetExceeded or localStats.selfBudgetExceeded == true
          stats.worldUnavailable = stats.worldUnavailable or localStats.worldUnavailable == true
          stats.pairBudgetExceeded = stats.pairBudgetExceeded or localStats.selfBudgetExceeded == true
            or reportedSelfPairs > remainingLocalPairs
          if localStats.budgetExceeded == true then
            markDegradation(stats, 5, "block-query-budget",
              "Сокращены проверки блоков мира: исчерпан общий бюджет запросов.")
          end
          if localStats.selfBudgetExceeded == true then
            markDegradation(stats, 4, "self-contact-budget",
              "Часть самостолкновений пропущена: исчерпан бюджет пар.")
          end
          if localStats.deepContactBudgetExceeded == true then
            stats.extraLocalPassesLimited = true
            if not extraPassQueued[component.id] then
              extraPassQueue[#extraPassQueue + 1] = component.id
              extraPassQueued[component.id] = true
            end
            markDegradation(stats, 4, "deep-contact-budget",
              "Дополнительные проходы глубоких контактов ограничены общим бюджетом тика.")
          end
        end
      end
    end
    self.accumulator = math.max(0, self.accumulator - self.fixedStep)
    stats.substeps = stats.substeps + 1
  end
  stats.alpha = math.max(0, math.min(1, self.accumulator / self.fixedStep))
  self.diagnostics = stats
  if type(hooks.finish) == "function" then hooks.finish(self.components, stats.alpha, stats) end
  return stats
end

return worldApi
