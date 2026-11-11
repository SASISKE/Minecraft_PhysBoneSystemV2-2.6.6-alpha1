local constraints = {}
local ANGULAR_SPRING_GAIN = 18

local function vec(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function sub(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
local function add(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
local function scale(a, amount) return vec(a.x * amount, a.y * amount, a.z * amount) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return vec(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function length(a) return math.sqrt(dot(a, a)) end
local function normalize(a, fallback)
  local size = length(a)
  if size < 0.000001 or size ~= size or size == math.huge then return fallback or vec(0, -1, 0) end
  return scale(a, 1 / size)
end

local function atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  if x > 0 then return math.atan(y / x) end
  if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
  if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
  if x == 0 and y > 0 then return math.pi / 2 end
  if x == 0 and y < 0 then return -math.pi / 2 end
  return 0
end

local function edgeLength(points, edge)
  return length(sub(points[edge.to], points[edge.from]))
end

-- Acceleration from a discrete angular spring. This is an elastic force toward
-- the component's calibrated/initial rest curvature, not toward the live
-- animation pose. Pose-follow remains a separate, depth-weighted force.
function constraints.bendAccelerations(points, graph, settingsByLink, targetPoints, inverseMassByPoint,
    stiffnessWeightByEdge)
  local accelerations = {}
  if type(points) ~= "table" or type(graph) ~= "table" or type(targetPoints) ~= "table" then
    return accelerations
  end
  local incoming = {}
  for _, edge in ipairs(graph.edges or {}) do incoming[edge.to] = edge end
  for edgeIndex, outgoing in ipairs(graph.edges or {}) do
    local middleIndex = outgoing.from
    local middleLink = graph.links and graph.links[middleIndex]
    local incomingEdge = incoming[middleIndex]
    local parentIndex = middleLink and middleLink.parentIndex
      or (incomingEdge and incomingEdge.from)
    local parent, middle, child = parentIndex and points[parentIndex], points[middleIndex], points[outgoing.to]
    local targetParent = parentIndex and targetPoints[parentIndex]
    local targetMiddle, targetChild = targetPoints[middleIndex], targetPoints[outgoing.to]
    local setting = settingsByLink and settingsByLink[outgoing.fromLink or middleIndex] or nil
    local stiffness = math.max(0, tonumber(setting and setting.bendStiffness) or 0)
    local stiffnessWeight = math.max(0, math.min(1,
      tonumber(stiffnessWeightByEdge and stiffnessWeightByEdge[edgeIndex]) or 1))
    stiffness = stiffness * stiffnessWeight
    if parent and middle and child and targetParent and targetMiddle and targetChild and stiffness > 0 then
      local incomingDelta, outgoingDelta = sub(middle, parent), sub(child, middle)
      local targetIncoming, targetOutgoing = sub(targetMiddle, targetParent), sub(targetChild, targetMiddle)
      local incomingLength, outgoingLength = length(incomingDelta), length(outgoingDelta)
      local targetIncomingLength, targetOutgoingLength = length(targetIncoming), length(targetOutgoing)
      if incomingLength > 0.000001 and outgoingLength > 0.000001
        and targetIncomingLength > 0.000001 and targetOutgoingLength > 0.000001 then
        local incomingDirection = scale(incomingDelta, 1 / incomingLength)
        local outgoingDirection = scale(outgoingDelta, 1 / outgoingLength)
        local targetIncomingDirection = scale(targetIncoming, 1 / targetIncomingLength)
        local targetOutgoingDirection = scale(targetOutgoing, 1 / targetOutgoingLength)
        local currentCurvature = sub(outgoingDirection, incomingDirection)
        local targetCurvature = sub(targetOutgoingDirection, targetIncomingDirection)
        local curvatureError = sub(currentCurvature, targetCurvature)
        local incomingGradient = sub(curvatureError,
          scale(incomingDirection, dot(curvatureError, incomingDirection)))
        local outgoingGradient = sub(curvatureError,
          scale(outgoingDirection, dot(curvatureError, outgoingDirection)))
        local scaleLength = math.max(1, math.min(8, (incomingLength + outgoingLength) * 0.5))
        local spring = stiffness * ANGULAR_SPRING_GAIN * scaleLength
        local parentForce = scale(incomingGradient, -spring / incomingLength)
        local middleForce = add(scale(incomingGradient, spring / incomingLength),
          scale(outgoingGradient, spring / outgoingLength))
        local childForce = scale(outgoingGradient, -spring / outgoingLength)
        local function addAcceleration(pointIndex, force)
          local inverseMass = math.max(0, tonumber(inverseMassByPoint and inverseMassByPoint[pointIndex]) or 0)
          if inverseMass > 0 then
            accelerations[pointIndex] = add(accelerations[pointIndex] or vec(0, 0, 0),
              scale(force, inverseMass))
          end
        end
        addAcceleration(parentIndex, parentForce)
        addAcceleration(middleIndex, middleForce)
        addAcceleration(outgoing.to, childForce)
      end
    end
  end
  return accelerations
end

function constraints.solveLengths(points, graph, passes, pinnedRoot, contactPoints, outwardOnly)
  if type(points) ~= "table" or type(graph) ~= "table" then return points end
  passes = math.max(1, math.min(12, math.floor(tonumber(passes) or 4)))
  pinnedRoot = pinnedRoot or points[1]
  local hasContacts = type(contactPoints) == "table" and next(contactPoints) ~= nil
  if hasContacts then passes = math.min(12, passes * 2) end
  -- A collider contact is a constraint on a particle, not an infinite-mass pin.
  -- Pinning a contacted child beside the anchored root makes its bone impossible
  -- to restore and lets the segment stretch. Keep only the animated root fixed;
  -- the caller alternates this projection with collision resolution.
  if outwardOnly ~= true then
    for _ = 1, passes do
      for _, edge in ipairs(graph.edges or {}) do
        local from, to = points[edge.from], points[edge.to]
        if from and to and edge.restLength and edge.restLength > 0 then
          local deltaX, deltaY, deltaZ = to.x - from.x, to.y - from.y, to.z - from.z
          local current = math.sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
          if current < 0.000001 then
            local fallback = edge.restVector or vec(0, -edge.restLength, 0)
            deltaX, deltaY, deltaZ = fallback.x, fallback.y, fallback.z
            current = math.sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
          end
          local correctionScale = (current - edge.restLength) / math.max(current, 0.000001)
          local correctionX, correctionY, correctionZ =
            deltaX * correctionScale, deltaY * correctionScale, deltaZ * correctionScale
          local fromPinned = edge.from == 1
          local toPinned = edge.to == 1
          if fromPinned then
            points[edge.to] = { x = to.x - correctionX, y = to.y - correctionY, z = to.z - correctionZ }
          elseif toPinned then
            points[edge.from] = { x = from.x + correctionX, y = from.y + correctionY, z = from.z + correctionZ }
          else
            local halfX, halfY, halfZ = correctionX * 0.5, correctionY * 0.5, correctionZ * 0.5
            points[edge.from] = { x = from.x + halfX, y = from.y + halfY, z = from.z + halfZ }
            points[edge.to] = { x = to.x - halfX, y = to.y - halfY, z = to.z - halfZ }
          end
        end
      end
      if points[1] then points[1] = vec(pinnedRoot.x, pinnedRoot.y, pinnedRoot.z) end
    end
  end

  -- Finish with one root-to-tip projection. Earlier symmetric passes let
  -- downstream links pull against the pinned root, leaving residual stretch
  -- on long chains after a hard impulse. Walking the tree outward only moves
  -- each child, so all segment lengths are exact at the end of the solve.
  for _, edge in ipairs(graph.edges or {}) do
    local from, to = points[edge.from], points[edge.to]
    if from and to and edge.restLength and edge.restLength > 0 then
      local deltaX, deltaY, deltaZ = to.x - from.x, to.y - from.y, to.z - from.z
      local current = math.sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
      if current < 0.000001 then
        local fallback = edge.restVector or vec(0, -edge.restLength, 0)
        deltaX, deltaY, deltaZ = fallback.x, fallback.y, fallback.z
        current = math.sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
      end
      local scaleFactor = edge.restLength / math.max(current, 0.000001)
      points[edge.to] = {
        x = from.x + deltaX * scaleFactor,
        y = from.y + deltaY * scaleFactor,
        z = from.z + deltaZ * scaleFactor,
      }
    end
  end
  if points[1] then points[1] = vec(pinnedRoot.x, pinnedRoot.y, pinnedRoot.z) end
  return points
end

local function rotateAroundAxis(v, axis, angle)
  axis = normalize(axis)
  local c, s = math.cos(angle), math.sin(angle)
  return add(add(scale(v, c), scale(cross(axis, v), s)), scale(axis, dot(axis, v) * (1 - c)))
end

local function clampCone(direction, reference, maximumAngle)
  local current = normalize(direction)
  local target = normalize(reference)
  local cosine = math.max(-1, math.min(1, dot(target, current)))
  local angle = math.acos(cosine)
  if angle <= maximumAngle or angle < 0.000001 then return current end
  local axis = cross(target, current)
  if length(axis) < 0.00001 then
    axis = cross(target, math.abs(target.y) < 0.9 and vec(0, 1, 0) or vec(1, 0, 0))
  end
  return normalize(rotateAroundAxis(target, axis, maximumAngle), target)
end

local function clampHinge(direction, reference, axis, maximumAngle)
  axis = normalize(axis, vec(0, 1, 0))
  local base = normalize(reference)
  local current = normalize(direction)
  local basePerpendicular = sub(base, scale(axis, dot(base, axis)))
  local currentPerpendicular = sub(current, scale(axis, dot(current, axis)))
  if length(basePerpendicular) < 0.00001 or length(currentPerpendicular) < 0.00001 then return base end
  basePerpendicular, currentPerpendicular = normalize(basePerpendicular), normalize(currentPerpendicular)
  local angle = atan2(dot(axis, cross(basePerpendicular, currentPerpendicular)), dot(basePerpendicular, currentPerpendicular))
  local limit = math.max(0, maximumAngle)
  return normalize(rotateAroundAxis(base, axis, math.max(-limit, math.min(limit, angle))), base)
end

function constraints.solveAngle(points, graph, settingsForLink, targetPoints, dt, contactPoints)
  if type(points) ~= "table" or type(graph) ~= "table" or type(targetPoints) ~= "table" then return points end
  for _, edge in ipairs(graph.edges or {}) do
    local settings = settingsForLink and settingsForLink(edge.fromLink) or nil
    local joint = settings and settings.joint or {}
    local kind = joint.type or "cone"
    -- Contacts do not disable articulation limits: the joint still has to stay within its configured cone.
    if kind ~= "free" then
      local from, to = points[edge.from], points[edge.to]
      local targetFrom, targetTo = targetPoints[edge.from], targetPoints[edge.to]
      if from and to and targetFrom and targetTo then
        local current = sub(to, from)
        local reference = sub(targetTo, targetFrom)
        local maximum = math.rad(math.max(0, math.min(180, tonumber(joint.angle) or 35)))
        local direction = normalize(current, normalize(reference))
        if kind == "hinge" then
          direction = clampHinge(direction, normalize(reference), joint.axis or vec(0, 1, 0), maximum)
        else
          direction = clampCone(direction, normalize(reference), maximum)
        end
        local distance = edge.restLength or length(current)
        points[edge.to] = add(from, scale(direction, distance))
      end
    end
  end
  return points
end

function constraints.directionRotation(fromDirection, toDirection, preferredAxis)
  local from, to = normalize(fromDirection), normalize(toDirection)
  local cosine = math.max(-1, math.min(1, dot(from, to)))
  local axis = cross(from, to)
  local axisLength = length(axis)
  local angle = math.acos(cosine)
  if angle < 0.000001 then return vec(0, 0, 0) end
  if axisLength < 0.0001 then
    if preferredAxis then
      axis = sub(preferredAxis, scale(from, dot(preferredAxis, from)))
      axisLength = length(axis)
    end
    if axisLength < 0.000001 then
      local x, y, z = math.abs(from.x), math.abs(from.y), math.abs(from.z)
      local reference = x <= y and x <= z and vec(1, 0, 0)
        or y <= z and vec(0, 1, 0) or vec(0, 0, 1)
      axis = cross(from, reference)
      axisLength = length(axis)
    end
  end
  if axisLength < 0.000001 then return vec(0, angle, 0) end
  axis = scale(axis, 1 / math.max(axisLength, 0.000001))
  return scale(axis, angle)
end

return constraints
