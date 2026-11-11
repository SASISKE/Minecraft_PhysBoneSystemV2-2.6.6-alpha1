local collisions = {}
local broadphase = require("physics_bone_broadphase")
local selfCollisionGrid = broadphase.new()

local function vec(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function add(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, n) return vec(a.x * n, a.y * n, a.z * n) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function length(a) return math.sqrt(math.max(0, dot(a, a))) end
local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end
local function validVector(value)
  return type(value) == "table" and finite(value.x) and finite(value.y) and finite(value.z)
end
local function normalize(value, fallback)
  local size = length(value)
  if size < 0.000001 then return fallback or vec(1, 0, 0) end
  return mul(value, 1 / size)
end
local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function maskAllows(mask, group)
  return type(mask) ~= "table" or mask[group] ~= false
end

local function collisionGroupsAllow(matrix, firstGroup, firstMask, secondGroup, secondMask)
  if type(firstGroup) ~= "string" or type(secondGroup) ~= "string" then return true end
  local firstRow = type(matrix) == "table" and matrix[firstGroup] or nil
  local secondRow = type(matrix) == "table" and matrix[secondGroup] or nil
  if type(firstRow) == "table" and firstRow[secondGroup] == false then return false end
  if type(secondRow) == "table" and secondRow[firstGroup] == false then return false end
  return maskAllows(firstMask, secondGroup) and maskAllows(secondMask, firstGroup)
end

function collisions.refreshShapeCache(cache, sources, buildShape)
  cache = type(cache) == "table" and cache or {}
  local count = 0
  if type(sources) == "table" and type(buildShape) == "function" then
    for _, source in ipairs(sources) do
      if type(source) == "table" and source.enabled ~= false then
        local shape = buildShape(source, cache[count + 1])
        if type(shape) == "table" then
          count = count + 1
          cache[count] = shape
        end
      end
    end
  end
  for index = #cache, count + 1, -1 do cache[index] = nil end
  return cache, count
end

local function closestOnSegment(point, a, b)
  local axis = sub(b, a)
  local sizeSquared = dot(axis, axis)
  local t = sizeSquared > 0.000001 and clamp(dot(sub(point, a), axis) / sizeSquared, 0, 1) or 0
  return add(a, mul(axis, t))
end

local function stableNormal(axis)
  local direction = normalize(axis, vec(0, 1, 0))
  local basis
  if math.abs(direction.x) <= math.abs(direction.y) and math.abs(direction.x) <= math.abs(direction.z) then
    basis = vec(1, 0, 0)
  elseif math.abs(direction.y) <= math.abs(direction.z) then
    basis = vec(0, 1, 0)
  else
    basis = vec(0, 0, 1)
  end
  local cross = vec(direction.y * basis.z - direction.z * basis.y,
    direction.z * basis.x - direction.x * basis.z,
    direction.x * basis.y - direction.y * basis.x)
  return normalize(cross, vec(1, 0, 0))
end

function collisions.projectSphereAabb(position, radius, box)
  if not validVector(position) or type(box) ~= "table" or not validVector(box.min) or not validVector(box.max) then
    return nil, nil, 0
  end
  radius = tonumber(radius)
  if not finite(radius) or radius <= 0 then return nil, nil, 0 end
  local closest = vec(
    clamp(position.x, box.min.x, box.max.x),
    clamp(position.y, box.min.y, box.max.y),
    clamp(position.z, box.min.z, box.max.z))
  local delta = sub(position, closest)
  local distance = length(delta)
  if distance > 0.000001 then
    if distance >= radius then return nil, nil, 0 end
    local normal = mul(delta, 1 / distance)
    return add(position, mul(normal, radius - distance)), normal, radius - distance
  end

  -- The sphere center is inside the box. Eject through the nearest face using
  -- a deterministic tie order, which prevents zero-normal/NaN contacts.
  local exits = {
    { distance = position.x - box.min.x, normal = vec(-1, 0, 0) },
    { distance = box.max.x - position.x, normal = vec(1, 0, 0) },
    { distance = position.y - box.min.y, normal = vec(0, -1, 0) },
    { distance = box.max.y - position.y, normal = vec(0, 1, 0) },
    { distance = position.z - box.min.z, normal = vec(0, 0, -1) },
    { distance = box.max.z - position.z, normal = vec(0, 0, 1) },
  }
  local best = exits[1]
  for index = 2, #exits do if exits[index].distance < best.distance then best = exits[index] end end
  local penetration = math.max(0, best.distance) + radius
  return add(position, mul(best.normal, penetration)), best.normal, penetration
end

function collisions.projectSphereCapsule(position, radius, a, b, capsuleRadius)
  if not validVector(position) or not validVector(a) or not validVector(b) then return nil, nil, 0 end
  radius, capsuleRadius = tonumber(radius), tonumber(capsuleRadius)
  if not finite(radius) or not finite(capsuleRadius) or radius <= 0 or capsuleRadius <= 0 then return nil, nil, 0 end
  local closest = closestOnSegment(position, a, b)
  local delta = sub(position, closest)
  local distance = length(delta)
  local combined = radius + capsuleRadius
  if distance >= combined then return nil, nil, 0 end
  local normal = distance > 0.000001 and mul(delta, 1 / distance) or stableNormal(sub(b, a))
  local penetration = combined - distance
  return add(position, mul(normal, penetration)), normal, penetration
end

local function projectAgainstShape(position, radius, shape)
  if type(shape) ~= "table" then return nil, nil, 0 end
  if shape.kind == "sphere" then
    return collisions.projectSphereCapsule(position, radius, shape.center, shape.center, shape.radius)
  elseif shape.kind == "capsule" then
    return collisions.projectSphereCapsule(position, radius, shape.a, shape.b, shape.radius)
  end
  return collisions.projectSphereAabb(position, radius, shape)
end

local function sweepSphereAabb(startPoint, endPoint, radius, box)
  if not validVector(startPoint) or not validVector(endPoint) or type(box) ~= "table"
    or not validVector(box.min) or not validVector(box.max) then return nil end
  local direction = sub(endPoint, startPoint)
  local startProjection, startNormal = collisions.projectSphereAabb(startPoint, radius, box)
  if startProjection and dot(direction, startNormal) < -0.000001 then return 0, startNormal end
  if startProjection then return nil end
  local low = { box.min.x - radius, box.min.y - radius, box.min.z - radius }
  local high = { box.max.x + radius, box.max.y + radius, box.max.z + radius }
  local origin = { startPoint.x, startPoint.y, startPoint.z }
  local delta = { direction.x, direction.y, direction.z }
  local enter, leave, enterAxis, enterSign = 0, 1, nil, 0
  for axis = 1, 3 do
    if math.abs(delta[axis]) < 0.000001 then
      if origin[axis] < low[axis] or origin[axis] > high[axis] then return nil end
    else
      local first = (low[axis] - origin[axis]) / delta[axis]
      local second = (high[axis] - origin[axis]) / delta[axis]
      local sign = -1
      if first > second then first, second, sign = second, first, 1 end
      if first > enter then enter, enterAxis, enterSign = first, axis, sign end
      leave = math.min(leave, second)
      if enter > leave then return nil end
    end
  end
  if not enterAxis or enter < 0 or enter > 1 then return nil end
  local normal = vec(0, 0, 0)
  if enterAxis == 1 then normal.x = enterSign
  elseif enterAxis == 2 then normal.y = enterSign
  else normal.z = enterSign end
  return enter, normal
end

local function sweepPointAgainstCapsule(startPoint, endPoint, radius, a, b, capsuleRadius)
  local direction = sub(endPoint, startPoint)
  local travel = length(direction)
  local combined = radius + capsuleRadius
  if travel < 0.000001 or combined <= 0 then return nil end
  local startClosest = closestOnSegment(startPoint, a, b)
  local startDelta = sub(startPoint, startClosest)
  local startDistance = length(startDelta)
  if startDistance <= combined + 0.00001 then
    local startNormal = startDistance > 0.000001 and mul(startDelta, 1 / startDistance) or stableNormal(sub(b, a))
    if dot(direction, startNormal) < -0.000001 then return 0, startNormal end
    return nil
  end
  -- Conservative advancement never steps farther than the distance to the
  -- capsule divided by the point's travel, so it cannot skip a thin contact.
  local time = 0
  for _ = 1, 24 do
    local point = add(startPoint, mul(direction, time))
    local closest = closestOnSegment(point, a, b)
    local delta = sub(point, closest)
    local distance = length(delta)
    local gap = distance - combined
    if gap <= 0.00001 then
      return time, distance > 0.000001 and mul(delta, 1 / distance) or stableNormal(sub(b, a))
    end
    time = time + math.max(gap / travel, 0.000001)
    if time > 1 then return nil end
  end
  local endpoint = add(startPoint, direction)
  local closest = closestOnSegment(endpoint, a, b)
  local delta = sub(endpoint, closest)
  local distance = length(delta)
  if distance <= combined + 0.00001 then
    return 1, distance > 0.000001 and mul(delta, 1 / distance) or stableNormal(sub(b, a))
  end
  return nil
end

local function sweepPointAgainstSphere(startPoint, endPoint, radius, center, sphereRadius)
  local direction = sub(endPoint, startPoint)
  local fromCenter = sub(startPoint, center)
  local combined = radius + sphereRadius
  local startDistance = length(fromCenter)
  local startNormal = startDistance > 0.000001 and mul(fromCenter, 1 / startDistance) or stableNormal(vec(0, 0, 0))
  if startDistance <= combined + 0.00001 then
    if dot(direction, startNormal) < -0.000001 then return 0, startNormal end
    return nil
  end

  local a = dot(direction, direction)
  if a <= 0.000000000001 or combined <= 0 then return nil end
  local b = dot(fromCenter, direction)
  local c = dot(fromCenter, fromCenter) - combined * combined
  local discriminant = b * b - a * c
  if discriminant < 0 then return nil end
  local time = (-b - math.sqrt(math.max(0, discriminant))) / a
  if time < 0 or time > 1 then
    local endDelta = sub(endPoint, center)
    local endDistance = length(endDelta)
    if endDistance <= combined + 0.00001 then
      return 1, endDistance > 0.000001 and mul(endDelta, 1 / endDistance) or startNormal
    end
    return nil
  end

  local hit = add(startPoint, mul(direction, time))
  local hitDelta = sub(hit, center)
  local hitDistance = length(hitDelta)
  return time, hitDistance > 0.000001 and mul(hitDelta, 1 / hitDistance) or startNormal
end

local function sweepAgainstShape(startPoint, endPoint, radius, shape)
  if type(shape) ~= "table" then return nil end
  if shape.kind == "sphere" then
    return sweepPointAgainstSphere(startPoint, endPoint, radius, shape.center, shape.radius)
  elseif shape.kind == "capsule" then
    return sweepPointAgainstCapsule(startPoint, endPoint, radius, shape.a, shape.b, shape.radius)
  end
  return sweepSphereAabb(startPoint, endPoint, radius, shape)
end

local function sweptBoundsMayTouchShape(startPoint, endPoint, radius, shape)
  if type(shape) ~= "table" then return true end
  local minX, minY, minZ, maxX, maxY, maxZ, expansion
  if shape.kind == "sphere" then
    local center, shapeRadius = shape.center, tonumber(shape.radius)
    if not validVector(center) or not finite(shapeRadius) or shapeRadius < 0 then return true end
    expansion = radius + shapeRadius
    minX, minY, minZ = center.x, center.y, center.z
    maxX, maxY, maxZ = center.x, center.y, center.z
  elseif shape.kind == "capsule" then
    local first, second, shapeRadius = shape.a, shape.b, tonumber(shape.radius)
    if not validVector(first) or not validVector(second) or not finite(shapeRadius) or shapeRadius < 0 then return true end
    expansion = radius + shapeRadius
    minX, minY, minZ = math.min(first.x, second.x), math.min(first.y, second.y), math.min(first.z, second.z)
    maxX, maxY, maxZ = math.max(first.x, second.x), math.max(first.y, second.y), math.max(first.z, second.z)
  else
    local minimum, maximum = shape.min, shape.max
    if not validVector(minimum) or not validVector(maximum) then return true end
    expansion = radius
    minX, minY, minZ = minimum.x, minimum.y, minimum.z
    maxX, maxY, maxZ = maximum.x, maximum.y, maximum.z
  end

  return math.max(startPoint.x, endPoint.x) >= minX - expansion
    and math.min(startPoint.x, endPoint.x) <= maxX + expansion
    and math.max(startPoint.y, endPoint.y) >= minY - expansion
    and math.min(startPoint.y, endPoint.y) <= maxY + expansion
    and math.max(startPoint.z, endPoint.z) >= minZ - expansion
    and math.min(startPoint.z, endPoint.z) <= maxZ + expansion
end

local function clearArray(array)
  for index = #array, 1, -1 do array[index] = nil end
end

local function bodyShapeBounds(shape)
  if type(shape) ~= "table" then return nil end
  if shape.kind == "sphere" then
    local center, radius = shape.center, tonumber(shape.radius)
    if not validVector(center) or not finite(radius) or radius < 0 then return nil end
    return center.x - radius, center.y - radius, center.z - radius,
      center.x + radius, center.y + radius, center.z + radius, radius
  elseif shape.kind == "capsule" then
    local first, second, radius = shape.a, shape.b, tonumber(shape.radius)
    if not validVector(first) or not validVector(second) or not finite(radius) or radius < 0 then return nil end
    return math.min(first.x, second.x) - radius, math.min(first.y, second.y) - radius,
      math.min(first.z, second.z) - radius, math.max(first.x, second.x) + radius,
      math.max(first.y, second.y) + radius, math.max(first.z, second.z) + radius, radius
  end
  local minimum, maximum = shape.min, shape.max
  if validVector(minimum) and validVector(maximum) then
    local extent = math.max(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z)
    return minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z, math.max(0, extent)
  end
  return nil
end

function collisions.newShapeGrid(cellSize, maxCellsPerShape, maxCellsPerQuery)
  local grid = {
    cells = broadphase.new(), largeShapes = {}, allShapes = {}, shapeSeen = {},
    shapeOrder = {},
    cellSize = math.max(0.05, tonumber(cellSize) or 1),
    maxCellsPerShape = math.max(1, math.floor(tonumber(maxCellsPerShape) or 256)),
    maxCellsPerQuery = math.max(1, math.floor(tonumber(maxCellsPerQuery) or 512)),
    maxShapeRadius = 0, shapeCount = 0,
  }
  grid.sortByShapeOrder = function(first, second)
    return (grid.shapeOrder[first] or math.huge) < (grid.shapeOrder[second] or math.huge)
  end
  return grid
end

function collisions.refreshShapeGrid(grid, firstShapes, secondShapes)
  grid = type(grid) == "table" and grid or collisions.newShapeGrid()
  grid.cells = type(grid.cells) == "table" and grid.cells or broadphase.new()
  grid.largeShapes = type(grid.largeShapes) == "table" and grid.largeShapes or {}
  grid.allShapes = type(grid.allShapes) == "table" and grid.allShapes or {}
  grid.shapeSeen = type(grid.shapeSeen) == "table" and grid.shapeSeen or {}
  grid.shapeOrder = type(grid.shapeOrder) == "table" and grid.shapeOrder or {}
  broadphase.clear(grid.cells)
  clearArray(grid.largeShapes)
  clearArray(grid.allShapes)
  for shape in pairs(grid.shapeSeen) do grid.shapeSeen[shape] = nil end
  for shape in pairs(grid.shapeOrder) do grid.shapeOrder[shape] = nil end
  grid.maxShapeRadius, grid.shapeCount = 0, 0

  local function insertShapes(shapes)
    for _, shape in ipairs(shapes or {}) do
      if type(shape) == "table" and shape.enabled ~= false and not grid.shapeSeen[shape] then
        grid.shapeSeen[shape] = true
        grid.shapeCount = grid.shapeCount + 1
        grid.allShapes[grid.shapeCount] = shape
        grid.shapeOrder[shape] = grid.shapeCount
        local minX, minY, minZ, maxX, maxY, maxZ, shapeRadius = bodyShapeBounds(shape)
        if minX == nil then
          grid.largeShapes[#grid.largeShapes + 1] = shape
        else
          grid.maxShapeRadius = math.max(grid.maxShapeRadius, shapeRadius or 0)
          local cellSize = grid.cellSize
          local firstX, firstY, firstZ = math.floor(minX / cellSize), math.floor(minY / cellSize), math.floor(minZ / cellSize)
          local lastX, lastY, lastZ = math.floor(maxX / cellSize), math.floor(maxY / cellSize), math.floor(maxZ / cellSize)
          local cellCount = (lastX - firstX + 1) * (lastY - firstY + 1) * (lastZ - firstZ + 1)
          if math.abs(firstX) > 1000000000 or math.abs(firstY) > 1000000000 or math.abs(firstZ) > 1000000000
            or math.abs(lastX) > 1000000000 or math.abs(lastY) > 1000000000 or math.abs(lastZ) > 1000000000
            or not finite(cellCount) or cellCount > grid.maxCellsPerShape then
            grid.largeShapes[#grid.largeShapes + 1] = shape
          else
            for x = firstX, lastX do
              for y = firstY, lastY do
                for z = firstZ, lastZ do broadphase.insert(grid.cells, x, y, z, shape) end
              end
            end
          end
        end
      end
    end
  end
  insertShapes(firstShapes)
  insertShapes(secondShapes)
  return grid
end

function collisions.queryShapeGrid(grid, startPoint, endPoint, radius, output, seen)
  output = type(output) == "table" and output or {}
  seen = type(seen) == "table" and seen or {}
  for index = #output, 1, -1 do
    seen[output[index]] = nil
    output[index] = nil
  end
  for shape in pairs(seen) do seen[shape] = nil end
  if type(grid) ~= "table" or type(grid.cells) ~= "table" or not validVector(startPoint)
    or not validVector(endPoint) then return 0, output, seen end
  local count = 0
  local function append(shape)
    if type(shape) == "table" and not seen[shape] then
      seen[shape] = true
      count = count + 1
      output[count] = shape
    end
  end
  for _, shape in ipairs(grid.largeShapes or {}) do append(shape) end

  radius = math.max(0, tonumber(radius) or 0) + math.max(0, tonumber(grid.maxShapeRadius) or 0)
  local cellSize = math.max(0.05, tonumber(grid.cellSize) or 1)
  local firstX = math.floor((math.min(startPoint.x, endPoint.x) - radius) / cellSize)
  local firstY = math.floor((math.min(startPoint.y, endPoint.y) - radius) / cellSize)
  local firstZ = math.floor((math.min(startPoint.z, endPoint.z) - radius) / cellSize)
  local lastX = math.floor((math.max(startPoint.x, endPoint.x) + radius) / cellSize)
  local lastY = math.floor((math.max(startPoint.y, endPoint.y) + radius) / cellSize)
  local lastZ = math.floor((math.max(startPoint.z, endPoint.z) + radius) / cellSize)
  local cellCount = (lastX - firstX + 1) * (lastY - firstY + 1) * (lastZ - firstZ + 1)
  if math.abs(firstX) > 1000000000 or math.abs(firstY) > 1000000000 or math.abs(firstZ) > 1000000000
    or math.abs(lastX) > 1000000000 or math.abs(lastY) > 1000000000 or math.abs(lastZ) > 1000000000
    or not finite(cellCount) or cellCount > (tonumber(grid.maxCellsPerQuery) or 512) then
    for _, shape in ipairs(grid.allShapes or {}) do append(shape) end
    return count, output, seen
  end
  for x = firstX, lastX do
    for y = firstY, lastY do
      for z = firstZ, lastZ do
        local bucket = broadphase.cell(grid.cells, x, y, z, false)
        for _, shape in ipairs(bucket or {}) do append(shape) end
      end
    end
  end
  table.sort(output, grid.sortByShapeOrder)
  return count, output, seen
end

local function graphNeighborsAtDepth(graph, pointCount, depth)
  local cache = type(graph._physicsNeighborCache) == "table" and graph._physicsNeighborCache or nil
  if not cache then
    local adjacency = {}
    for _, edge in ipairs(graph.edges or {}) do
      adjacency[edge.from] = adjacency[edge.from] or {}
      adjacency[edge.to] = adjacency[edge.to] or {}
      adjacency[edge.from][edge.to], adjacency[edge.to][edge.from] = true, true
    end
    cache = { adjacency = adjacency, byDepth = {}, maxDepth = 0 }
    graph._physicsNeighborCache = cache
  end
  if cache.byDepth[depth] then return cache.byDepth[depth] end
  local excludedByPoint = {}
  for source = 2, pointCount do
    local visited, frontier, excluded = { [source] = true }, { source }, {}
    for _ = 1, depth do
      local nextFrontier = {}
      for _, index in ipairs(frontier) do
        for neighbor in pairs(cache.adjacency[index] or {}) do
          if not visited[neighbor] then
            visited[neighbor], excluded[neighbor] = true, true
            nextFrontier[#nextFrontier + 1] = neighbor
          end
        end
      end
      frontier = nextFrontier
      if #frontier == 0 then break end
    end
    excludedByPoint[source] = excluded
  end
  cache.byDepth[depth] = excludedByPoint
  cache.maxDepth = math.max(cache.maxDepth or 0, depth)
  return excludedByPoint
end

function collisions.resolvePoint(position, previous, radius, shapes, dt, friction, restitution, applyVelocity)
  if applyVelocity == nil then applyVelocity = true end
  if not validVector(position) or not validVector(previous) then return position, previous, 0, {}, 0 end
  radius = tonumber(radius) or 0
  dt = math.max(0.000001, tonumber(dt) or 1 / 60)
  friction = clamp(tonumber(friction) or 0, 0, 1)
  restitution = clamp(tonumber(restitution) or 0, 0, 1)
  if radius <= 0 then return position, previous, 0, {}, 0 end
  local current, prior = vec(position.x, position.y, position.z), vec(previous.x, previous.y, previous.z)
  local contacts, responded, maxPenetration = 0, {}, 0
  local iterations = math.max(1, math.min(4, tonumber(type(shapes) == "table" and shapes.iterations) or 2))
  local list = type(shapes) == "table" and (shapes.items or shapes) or {}
  for _ = 1, iterations do
    local contactsBeforePass = contacts
    for _, shape in ipairs(list) do
      if sweptBoundsMayTouchShape(prior, current, radius, shape) then
        local projected, normal, penetration = projectAgainstShape(current, radius, shape)
        local sweepTime, sweepNormal
        if not projected then sweepTime, sweepNormal = sweepAgainstShape(prior, current, radius, shape) end
        if (projected and penetration > 0) or sweepTime then
          if projected and penetration > 0 then
            maxPenetration = math.max(maxPenetration, penetration)
            local correction = sub(projected, current)
            current, prior = projected, add(prior, correction)
          else
            local displacement = sub(current, prior)
            local hit = add(prior, mul(displacement, sweepTime))
            normal = sweepNormal
            current = add(hit, mul(normal, 0.0001))
            prior = hit
            if applyVelocity then
              local remaining = mul(displacement, 1 - sweepTime)
              local normalTravel = dot(remaining, normal)
              local tangentTravel = sub(remaining, mul(normal, normalTravel))
              local resolvedTravel = add(mul(tangentTravel, 1 - friction),
                mul(normal, normalTravel < 0 and -normalTravel * restitution or normalTravel))
              current = add(current, resolvedTravel)
              responded[shape] = true
            end
          end
          contacts = contacts + 1
          if applyVelocity and not responded[shape] then
            local velocity = mul(sub(current, prior), 1 / dt)
            local normalSpeed = dot(velocity, normal)
            local tangent = sub(velocity, mul(normal, normalSpeed))
            local nextVelocity = add(mul(tangent, 1 - friction),
              mul(normal, normalSpeed < 0 and -normalSpeed * restitution or normalSpeed))
            prior = sub(current, mul(nextVelocity, dt))
            responded[shape] = true
          end
        end
      end
    end
    if contacts == contactsBeforePass then break end
  end
  if contacts == 0 then return position, previous, 0, responded, 0 end
  return current, prior, contacts, responded, maxPenetration
end

function collisions.resolveSelf(points, previousPoints, graph, pointRadii, dt, pointSettings, maxPairs, neighborDepth,
    inverseMassByPoint)
  local contacts, pairsChecked, budgetExceeded, contactPoints = 0, 0, false, {}
  maxPairs = math.max(0, math.floor(tonumber(maxPairs) or 2048))
  local maxRadius = 0
  for index = 2, #points do maxRadius = math.max(maxRadius, tonumber(pointRadii[index]) or 0) end
  if maxRadius <= 0 then return contacts, pairsChecked, false, contactPoints end
  local perPointDepth = type(neighborDepth) == "table"
  local defaultDepth = perPointDepth and 1 or tonumber(neighborDepth)
  if not finite(defaultDepth) then defaultDepth = 1 end
  defaultDepth = math.min(math.max(0, math.floor(defaultDepth)), math.max(0, #points - 1))
  local depthByPoint, graphNeighbors, graphNeighborsByDepth
  if perPointDepth then
    depthByPoint = {}
    for index = 2, #points do
      local depth = tonumber(neighborDepth[index])
      if not finite(depth) then depth = defaultDepth end
      depth = math.min(math.max(0, math.floor(depth)), math.max(0, #points - 1))
      depthByPoint[index] = depth
      if depth > 0 then graphNeighborsAtDepth(graph, #points, depth) end
    end
    local cache = type(graph) == "table" and graph._physicsNeighborCache or nil
    graphNeighborsByDepth = type(cache) == "table" and cache.byDepth or {}
  else
    graphNeighbors = defaultDepth > 0 and graphNeighborsAtDepth(graph, #points, defaultDepth) or nil
  end
  local cellSize = math.max(0.05, maxRadius * 2)
  local function cellOf(point)
    return math.floor(point.x / cellSize), math.floor(point.y / cellSize), math.floor(point.z / cellSize)
  end
  broadphase.clear(selfCollisionGrid)
  for index = 2, #points do
    if (pointRadii[index] or 0) > 0 then
      local x, y, z = cellOf(points[index])
      broadphase.insert(selfCollisionGrid, x, y, z, index)
    end
  end

  local safeDt = math.max(0.000001, tonumber(dt) or 1 / 60)
  local function resolvePair(first, second)
    local a, b = points[first], points[second]
    local delta = sub(a, b)
    local distance = length(delta)
    local combined = (pointRadii[first] or 0) + (pointRadii[second] or 0)
    if combined <= 0 or distance >= combined then return end
    local inverseMassA = tonumber(inverseMassByPoint and inverseMassByPoint[first])
    local inverseMassB = tonumber(inverseMassByPoint and inverseMassByPoint[second])
    if not finite(inverseMassA) then inverseMassA = 1 end
    if not finite(inverseMassB) then inverseMassB = 1 end
    inverseMassA, inverseMassB = math.max(0, inverseMassA), math.max(0, inverseMassB)
    local inverseMassSum = inverseMassA + inverseMassB
    if inverseMassSum <= 0.000001 then return end
    local normal = distance > 0.000001 and mul(delta, 1 / distance) or vec(1, 0, 0)
    local penetration = combined - distance
    local correctionA = mul(normal, penetration * inverseMassA / inverseMassSum)
    local correctionB = mul(normal, penetration * inverseMassB / inverseMassSum)
    points[first], points[second] = add(a, correctionA), sub(b, correctionB)
    previousPoints[first] = add(previousPoints[first], correctionA)
    previousPoints[second] = sub(previousPoints[second], correctionB)
    local settingA = pointSettings and pointSettings[first] or {}
    local settingB = pointSettings and pointSettings[second] or settingA
    local friction = clamp(((tonumber(settingA.friction) or 0) + (tonumber(settingB.friction) or 0)) * 0.5, 0, 1)
    local restitution = clamp(((tonumber(settingA.restitution) or 0) + (tonumber(settingB.restitution) or 0)) * 0.5, 0, 1)
    local va = mul(sub(points[first], previousPoints[first]), 1 / safeDt)
    local vb = mul(sub(points[second], previousPoints[second]), 1 / safeDt)
    local relative = sub(va, vb)
    local normalSpeed = dot(relative, normal)
    if normalSpeed < 0 then
      local normalImpulse = -(1 + restitution) * normalSpeed / inverseMassSum
      va, vb = add(va, mul(normal, normalImpulse * inverseMassA)),
        sub(vb, mul(normal, normalImpulse * inverseMassB))
    end
    local tangent = sub(relative, mul(normal, normalSpeed))
    va = sub(va, mul(tangent, friction * inverseMassA / inverseMassSum))
    vb = add(vb, mul(tangent, friction * inverseMassB / inverseMassSum))
    previousPoints[first] = sub(points[first], mul(va, safeDt))
    previousPoints[second] = sub(points[second], mul(vb, safeDt))
    contacts = contacts + 1
    contactPoints[first], contactPoints[second] = true, true
  end

  for first = 2, #points - 1 do
    if (pointRadii[first] or 0) > 0 then
      local x, y, z = cellOf(points[first])
      for dx = -1, 1 do
        for dy = -1, 1 do
          for dz = -1, 1 do
            local bucket = broadphase.cell(selfCollisionGrid, x + dx, y + dy, z + dz, false)
            if bucket then
              for _, second in ipairs(bucket) do
                local pairExcluded
                if perPointDepth then
                  local pairDepth = math.max(depthByPoint[first] or defaultDepth, depthByPoint[second] or defaultDepth)
                  local neighbors = graphNeighborsByDepth[pairDepth]
                  pairExcluded = pairDepth > 0 and neighbors ~= nil
                    and neighbors[first] ~= nil and neighbors[first][second] == true
                else
                  pairExcluded = graphNeighbors ~= nil and graphNeighbors[first] ~= nil
                    and graphNeighbors[first][second] == true
                end
                if second > first and not pairExcluded then
                  if pairsChecked >= maxPairs then budgetExceeded = true; return contacts, pairsChecked, budgetExceeded, contactPoints end
                  pairsChecked = pairsChecked + 1
                  resolvePair(first, second)
                end
              end
            end
          end
        end
      end
    end
  end
  return contacts, pairsChecked, budgetExceeded, contactPoints
end

function collisions.resolveState(state, graph, context, effectiveSettings, pointOwners, dt, applyVelocity,
    pairBudgetRemaining, inverseMassByPoint)
  local stats = { contacts = 0, worldQueries = 0, selfPairs = 0, selfBudgetExceeded = false,
    budgetExceeded = false, worldUnavailable = false, avatarShapeCandidates = 0, contactPoints = {} }
  if type(context) ~= "table" or type(context.toWorldPoint) ~= "function"
    or type(context.toParentVector) ~= "function" then return stats end
  local pointRadii = {}
  local selfRadii = {}
  local selfSettings = {}
  local selfNeighborDepths = {}
  local selfEnabled = false
  local rootCollision = effectiveSettings[1] and effectiveSettings[1].collision or {}
  local defaultNeighborDepth = rootCollision.selfNeighborDepth or context.selfNeighborDepth or 1
  local commonNeighborDepth, hasDifferentNeighborDepth
  for pointIndex = 2, #state.points do
    local owner = pointOwners[pointIndex] or pointIndex
    local setting = effectiveSettings[owner] or effectiveSettings[1] or {}
    local collisionSettings = setting.collision or {}
    if collisionSettings.enabled == true and collisionSettings.self == true then selfEnabled = true end
    local localRadius = math.max(0, tonumber(collisionSettings.radius) or 0)
    local radius = localRadius * (tonumber(context.worldScale) or 1)
    pointRadii[pointIndex] = radius
    selfRadii[pointIndex] = collisionSettings.enabled == true and collisionSettings.self == true and localRadius or 0
    selfSettings[pointIndex] = collisionSettings
    local neighborDepth = tonumber(collisionSettings.selfNeighborDepth) or defaultNeighborDepth
    selfNeighborDepths[pointIndex] = neighborDepth
    if selfRadii[pointIndex] > 0 then
      if commonNeighborDepth == nil then commonNeighborDepth = neighborDepth
      elseif commonNeighborDepth ~= neighborDepth then hasDifferentNeighborDepth = true end
    end
    if collisionSettings.enabled == true and radius > 0 then
      local currentWorld = context.toWorldPoint(state.points[pointIndex])
      local previousWorld = context.toWorldPoint(state.previousPoints[pointIndex])
      local shapes = context.contactShapeScratch or {}
      clearArray(shapes)
      context.contactShapeScratch = shapes
      if collisionSettings.avatar ~= false then
        local componentGroup = collisionSettings.group or "custom"
        local function appendCompatible(shape)
          if collisionGroupsAllow(context.collisionMatrix, componentGroup, collisionSettings.mask,
              shape.group, shape.mask) then
            shapes[#shapes + 1] = shape
            stats.avatarShapeCandidates = stats.avatarShapeCandidates + 1
          end
        end
        if type(context.avatarShapeGrid) == "table" then
          local candidates = context.avatarShapeCandidates or {}
          local seen = context.avatarShapeSeen or {}
          local candidateCount
          candidateCount, candidates, seen = collisions.queryShapeGrid(context.avatarShapeGrid,
            previousWorld, currentWorld, radius, candidates, seen)
          context.avatarShapeCandidates, context.avatarShapeSeen = candidates, seen
          for index = 1, candidateCount do appendCompatible(candidates[index]) end
        elseif context.sharedAvatarShapes ~= nil then
          for _, shape in ipairs(context.sharedAvatarShapes) do appendCompatible(shape) end
          for _, shape in ipairs(context.componentAvatarShapes or {}) do appendCompatible(shape) end
        else
          for _, shape in ipairs(context.avatarShapes or context.componentAvatarShapes or {}) do
            appendCompatible(shape)
          end
        end
      end
      if collisionSettings.world == true and type(context.queryWorld) == "function" then
        local worldShapes, queryCount, exhausted, available = context.queryWorld(currentWorld, radius)
        for _, shape in ipairs(worldShapes or {}) do shapes[#shapes + 1] = shape end
        stats.worldQueries = stats.worldQueries + (tonumber(queryCount) or 0)
        stats.budgetExceeded = stats.budgetExceeded or exhausted == true
        stats.worldUnavailable = stats.worldUnavailable or available == false
      end
      if #shapes > 0 then
        local resolved, prior, contactCount, _, maxPenetration = collisions.resolvePoint(currentWorld, previousWorld, radius, shapes,
          dt, collisionSettings.friction, collisionSettings.restitution, applyVelocity)
        stats.contacts = stats.contacts + contactCount
        if (tonumber(maxPenetration) or 0) > radius then stats.deepPenetration = true end
        if contactCount > 0 then
          stats.contactPoints[pointIndex] = true
          state.points[pointIndex] = context.toParentVector(sub(resolved, context.rootOriginWorld))
          state.previousPoints[pointIndex] = context.toParentVector(sub(prior, context.rootOriginWorld))
        end
      end
    end
  end
  if selfEnabled then
    local maxSelfPairs = math.max(0, math.floor(tonumber(rootCollision.maxSelfPairs or context.maxSelfPairs) or 2048))
    if pairBudgetRemaining ~= nil then
      maxSelfPairs = math.min(maxSelfPairs, math.max(0, math.floor(tonumber(pairBudgetRemaining) or 0)))
    end
    local contacts, pairsChecked, pairBudgetExceeded, selfContactPoints = collisions.resolveSelf(state.points, state.previousPoints,
      graph, selfRadii, dt, selfSettings, maxSelfPairs,
      hasDifferentNeighborDepth and selfNeighborDepths or commonNeighborDepth or defaultNeighborDepth,
      inverseMassByPoint)
    stats.contacts = stats.contacts + contacts
    stats.selfPairs = stats.selfPairs + pairsChecked
    stats.selfBudgetExceeded = pairBudgetExceeded
    for pointIndex in pairs(selfContactPoints or {}) do stats.contactPoints[pointIndex] = true end
  end
  return stats
end

return collisions
