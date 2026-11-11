local core = {}
local constraints = require("physics_bone_constraints")
local collisionSolver = require("physics_bone_collisions")

local FIXED_STEP = 1 / 60
local MAX_SUBSTEPS = 5
local MAX_FRAME_DT = 0.10
local CONSTRAINT_PASSES = 5
local AXIAL_AIR_DRAG_RATIO = 0.12

local function v(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, n) return v(a.x * n, a.y * n, a.z * n) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function length(a) return math.sqrt(dot(a, a)) end
local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function validVector(a) return a and finite(a.x) and finite(a.y) and finite(a.z) end
local function clamp(value, minimum, maximum, fallback)
  value = tonumber(value)
  if not finite(value) then value = fallback end
  return math.max(minimum, math.min(maximum, value))
end

local function clonePoint(point)
  return v(point and point.x or 0, point and point.y or 0, point and point.z or 0)
end

local function clonePoints(points)
  local result = {}
  for index, point in ipairs(points or {}) do result[index] = clonePoint(point) end
  return result
end

local function identity()
  return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
end

local function multiplyMatrix(a, b)
  local result = { {}, {}, {} }
  for row = 1, 3 do
    for column = 1, 3 do
      result[row][column] = a[row][1] * b[1][column]
        + a[row][2] * b[2][column] + a[row][3] * b[3][column]
    end
  end
  return result
end

local function transposeMatrix(matrix)
  return {
    { matrix[1][1], matrix[2][1], matrix[3][1] },
    { matrix[1][2], matrix[2][2], matrix[3][2] },
    { matrix[1][3], matrix[2][3], matrix[3][3] },
  }
end

local function axisAngleMatrix(rotation)
  local angle = length(rotation)
  if angle < 0.000001 then return identity() end
  local x, y, z = rotation.x / angle, rotation.y / angle, rotation.z / angle
  local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
  return {
    { t * x * x + c, t * x * y - s * z, t * x * z + s * y },
    { t * x * y + s * z, t * y * y + c, t * y * z - s * x },
    { t * x * z - s * y, t * y * z + s * x, t * z * z + c },
  }
end

local function eulerMatrix(rotation)
  local sx, cx = math.sin(rotation.x), math.cos(rotation.x)
  local sy, cy = math.sin(rotation.y), math.cos(rotation.y)
  local sz, cz = math.sin(rotation.z), math.cos(rotation.z)
  return {
    { cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx },
    { sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx },
    { -sy, cy * sx, cy * cx },
  }
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

local function matrixEuler(matrix)
  local pitch = math.asin(math.max(-1, math.min(1, -matrix[3][1])))
  local roll, yaw
  if math.abs(math.cos(pitch)) > 0.000001 then
    roll = atan2(matrix[3][2], matrix[3][3])
    yaw = atan2(matrix[2][1], matrix[1][1])
  else
    roll = atan2(-matrix[2][3], matrix[2][2])
    yaw = 0
  end
  return v(roll, pitch, yaw)
end

local function wrapAngle(angle)
  return (angle + math.pi) % (math.pi * 2) - math.pi
end

local function matrixAxisAngle(matrix)
  local cosine = math.max(-1, math.min(1,
    (matrix[1][1] + matrix[2][2] + matrix[3][3] - 1) * 0.5))
  local angle = math.acos(cosine)
  if angle < 0.000001 then
    return v((matrix[3][2] - matrix[2][3]) * 0.5,
      (matrix[1][3] - matrix[3][1]) * 0.5,
      (matrix[2][1] - matrix[1][2]) * 0.5)
  end
  local sine = math.sin(angle)
  if math.abs(sine) > 0.000001 then
    local scale = angle / (2 * sine)
    return v((matrix[3][2] - matrix[2][3]) * scale,
      (matrix[1][3] - matrix[3][1]) * scale,
      (matrix[2][1] - matrix[1][2]) * scale)
  end
  local x = math.sqrt(math.max(0, (matrix[1][1] + 1) * 0.5))
  local y = math.sqrt(math.max(0, (matrix[2][2] + 1) * 0.5))
  local z = math.sqrt(math.max(0, (matrix[3][3] + 1) * 0.5))
  if x >= y and x >= z and x > 0.000001 then
    y, z = (matrix[1][2] + matrix[2][1]) / (4 * x), (matrix[1][3] + matrix[3][1]) / (4 * x)
  elseif y >= z and y > 0.000001 then
    x, z = (matrix[1][2] + matrix[2][1]) / (4 * y), (matrix[2][3] + matrix[3][2]) / (4 * y)
  elseif z > 0.000001 then
    x, y = (matrix[1][3] + matrix[3][1]) / (4 * z), (matrix[2][3] + matrix[3][2]) / (4 * z)
  else
    return v(0, angle, 0)
  end
  local axis = v(x, y, z)
  return mul(axis, angle / math.max(length(axis), 0.000001))
end

local function transform(matrix, point)
  if type(matrix) ~= "table" then return clonePoint(point) end
  return v(
    (matrix[1][1] or 0) * point.x + (matrix[1][2] or 0) * point.y + (matrix[1][3] or 0) * point.z,
    (matrix[2][1] or 0) * point.x + (matrix[2][2] or 0) * point.y + (matrix[2][3] or 0) * point.z,
    (matrix[3][1] or 0) * point.x + (matrix[3][2] or 0) * point.y + (matrix[3][3] or 0) * point.z)
end

local function validMatrix(matrix)
  if type(matrix) ~= "table" then return false end
  for row = 1, 3 do
    if type(matrix[row]) ~= "table" then return false end
    for column = 1, 3 do
      if not finite(tonumber(matrix[row][column])) then return false end
    end
  end
  return true
end

local function cloneMatrix(matrix)
  if not validMatrix(matrix) then return identity() end
  return {
    { matrix[1][1], matrix[1][2], matrix[1][3] },
    { matrix[2][1], matrix[2][2], matrix[2][3] },
    { matrix[3][1], matrix[3][2], matrix[3][3] },
  }
end

-- Extract the nearest orthogonal factor of the inverse parent transform. This
-- removes ordinary nonuniform scale on either side of a rotation; the full
-- inverse remains in use for the physical acceleration itself. Complex nested
-- scale/shear and reflection have no unique rotation and remain approximate.
local function orientationFromInverse(frame)
  if not validMatrix(frame) then return nil end
  local norm = 0
  for row=1,3 do for col=1,3 do norm=norm+frame[row][col]^2 end end
  norm=math.sqrt(norm/3)
  if not finite(norm) or norm < 0.000001 then return nil end
  local m={{},{},{}}
  for row=1,3 do for col=1,3 do m[row][col]=frame[row][col]/norm end end
  for _=1,24 do
    local a,b,c=m[1][1],m[1][2],m[1][3]
    local d,e,f=m[2][1],m[2][2],m[2][3]
    local g,h,i=m[3][1],m[3][2],m[3][3]
    local cof={{e*i-f*h,f*g-d*i,d*h-e*g},
      {c*h-b*i,a*i-c*g,b*g-a*h}, {b*f-c*e,c*d-a*f,a*e-b*d}}
    local determinant=a*cof[1][1]+b*cof[1][2]+c*cof[1][3]
    if not finite(determinant) or math.abs(determinant)<0.000000000001 then return nil end
    local nextMatrix, difference={{},{},{}},0
    for row=1,3 do for col=1,3 do
      local value=(m[row][col]+cof[row][col]/determinant)*.5
      difference=math.max(difference,math.abs(value-m[row][col]))
      nextMatrix[row][col]=value
    end end
    m=nextMatrix
    if difference<0.00000001 then return m end
  end
  return nil
end

local function copyOffsetList(offsets)
  local result = {}
  for index, offset in ipairs(offsets or {}) do result[index] = clonePoint(offset) end
  return result
end

local function zeroOffsets(count)
  local result = {}
  for index = 1, count do result[index] = v(0, 0, 0) end
  return result
end

local function capMagnitude(vector, maximum)
  local magnitude = length(vector)
  if magnitude <= maximum or magnitude < 0.000001 then return vector end
  return mul(vector, maximum / magnitude)
end

local function quadraticDragVelocity(velocity, dragRate, dt, mass)
  local speed = length(velocity)
  if speed < 0.000001 or dragRate <= 0 then return velocity end
  -- Implicit integration of dv/dt = -k|v|v stays stable at high speeds and
  -- preserves the continuous response of the drag control instead of clipping it.
  return mul(velocity, 1 / (1 + dragRate * speed * dt / mass))
end

local function settingsFor(componentSettings, linkOverrides, linkKey)
  local result = componentSettings or {}
  local override = linkOverrides and linkOverrides[linkKey]
  if type(override) ~= "table" then return result end
  local merged = {}
  for key, value in pairs(result) do merged[key] = value end
  for key, value in pairs(override) do
    if type(value) == "table" and type(result[key]) == "table" then
      local child = {}
      for childKey, childValue in pairs(result[key]) do child[childKey] = childValue end
      for childKey, childValue in pairs(value) do child[childKey] = childValue end
      merged[key] = child
    else merged[key] = value end
  end
  return merged
end

local function newOffsets(count)
  local result = {}
  for index = 1, count do result[index] = v(0, 0, 0) end
  return result
end

function core.newComponentState(graph, animatedPoints, restPose, restPoseRootFrame)
  local count = math.max(0, tonumber(graph and graph.pointCount) or #(animatedPoints or {}))
  local points = clonePoints(animatedPoints)
  for index = #points + 1, count do points[index] = v(0, 0, 0) end
  local restPoints = type(restPose) == "table" and #restPose == count and restPose or points
  return {
    points = points,
    previousPoints = clonePoints(points),
    springRestPoints = clonePoints(restPoints),
    springRestRootFrame = validMatrix(restPoseRootFrame) and cloneMatrix(restPoseRootFrame) or nil,
    renderPreviousOffsets = newOffsets(#(graph and graph.links or {})),
    offsets = newOffsets(#(graph and graph.links or {})),
    gravityReferenceByLink = {},
    accumulator = 0,
    initialized = true,
    diagnostics = {},
  }
end

local function stateMatches(state, graph, targets)
  return type(state) == "table" and type(state.points) == "table"
    and #state.points == (graph.pointCount or #targets)
    and #(state.offsets or {}) == #(graph.links or {})
end

local function preservingConstraintSolve(state, graph, targets, settingsForLink, dt, contactPoints, jointReferencePoints,
    constraintPasses, hasAngularConstraints)
  -- Constraint projection changes positions but should not erase the velocity
  -- produced by integration. Keep the pre-projection coordinates as scalars:
  -- cloning every vector here and then allocating two more vectors per point
  -- created avoidable garbage on every solver substep.
  local beforeX, beforeY, beforeZ = {}, {}, {}
  for index, point in ipairs(state.points) do
    beforeX[index], beforeY[index], beforeZ[index] = point.x, point.y, point.z
  end
  local lengthPasses = math.floor(clamp(constraintPasses, 1, 12, CONSTRAINT_PASSES))
  constraints.solveLengths(state.points, graph, lengthPasses, targets[1], contactPoints)
  -- Contacts do not pin articulated points or exempt them from joint limits;
  -- otherwise a root-adjacent contact can stretch the bone.
  -- Joint limits describe the physical rest articulation. Using the live
  -- animated targets here would make every link chase its animation even when
  -- pose-follow is disabled, effectively creating hidden distributed anchors.
  if hasAngularConstraints ~= false then
    constraints.solveAngle(state.points, graph, settingsForLink, jointReferencePoints or targets, dt, contactPoints)
  end
  -- Re-project segment lengths from the pinned root outward after all angular
  -- corrections so the final state has exact bone lengths.
  constraints.solveLengths(state.points, graph, 1, targets[1], contactPoints, true)
  for index, point in ipairs(state.points) do
    local prior = state.previousPoints[index]
    local oldX, oldY, oldZ = beforeX[index], beforeY[index], beforeZ[index]
    if oldX ~= nil and oldY ~= nil and oldZ ~= nil and prior then
      local correctionX, correctionY, correctionZ = point.x - oldX, point.y - oldY, point.z - oldZ
      state.previousPoints[index] = v(
        prior.x + correctionX,
        prior.y + correctionY,
        prior.z + correctionZ)
    end
  end
end

local function springReferencePoints(state, animatedPoints, restPose, currentRootFrame, restRootFrame)
  local explicitRest = type(restPose) == "table" and #restPose == #animatedPoints
  currentRootFrame = validMatrix(currentRootFrame) and currentRootFrame or identity()
  if explicitRest then
    state.springRestPoints = clonePoints(restPose)
    state.springRestRootFrame = validMatrix(restRootFrame) and cloneMatrix(restRootFrame) or identity()
  elseif type(state.springRestPoints) ~= "table" or #state.springRestPoints ~= #animatedPoints then
    state.springRestPoints = clonePoints(animatedPoints)
    state.springRestRootFrame = cloneMatrix(currentRootFrame)
  elseif not validMatrix(state.springRestRootFrame) then
    state.springRestRootFrame = cloneMatrix(currentRootFrame)
  end

  local source = state.springRestPoints
  if type(source) ~= "table" or #source ~= #animatedPoints then return clonePoints(animatedPoints) end
  local relativeRootRotation = multiplyMatrix(currentRootFrame,
    transposeMatrix(cloneMatrix(state.springRestRootFrame)))
  local sourceOrigin = validVector(source[1]) and source[1] or v(0, 0, 0)
  local currentOrigin = validVector(animatedPoints[1]) and animatedPoints[1] or v(0, 0, 0)
  local result = {}
  for index, point in ipairs(source) do
    if validVector(point) then
      result[index] = add(currentOrigin, transform(relativeRootRotation, sub(point, sourceOrigin)))
    else
      result[index] = clonePoint(animatedPoints[index])
    end
  end
  return result
end

local function emptyCollisionStats()
  return { contacts = 0, worldQueries = 0, selfPairs = 0, selfBudgetExceeded = false,
    budgetExceeded = false, worldUnavailable = false, avatarShapeCandidates = 0, contactPoints = {} }
end

local function mergeCollisionStats(target, source)
  source = source or {}
  target.contacts = target.contacts + (tonumber(source.contacts) or 0)
  target.worldQueries = math.max(target.worldQueries, tonumber(source.worldQueries) or 0)
  target.selfPairs = target.selfPairs + (tonumber(source.selfPairs) or 0)
  target.selfBudgetExceeded = target.selfBudgetExceeded or source.selfBudgetExceeded == true
  target.budgetExceeded = target.budgetExceeded or source.budgetExceeded == true
  target.worldUnavailable = target.worldUnavailable or source.worldUnavailable == true
  target.avatarShapeCandidates = target.avatarShapeCandidates + (tonumber(source.avatarShapeCandidates) or 0)
  for pointIndex in pairs(source.contactPoints or {}) do target.contactPoints[pointIndex] = true end
  return target
end

local function mergeContactPoints(target, source)
  for pointIndex in pairs(source or {}) do target[pointIndex] = true end
  return target
end

local function resolveLocalContacts(state, context, dt, extraContactPoints, pairBudgetRemaining, extraPassBudget)
  local stats = emptyCollisionStats()
  pairBudgetRemaining = pairBudgetRemaining ~= nil
    and math.max(0, math.floor(tonumber(pairBudgetRemaining) or 0)) or nil
  mergeContactPoints(stats.contactPoints, extraContactPoints)
  local collisionContext = context.collisionContext
  if not collisionContext or not collisionContext.enabled then
    state.collisionDiagnostics = stats
    return stats
  end
  local rootCollision = context.effectiveSettings[1] and context.effectiveSettings[1].collision or {}
  local iterations = math.max(1, math.min(4, math.floor(tonumber(rootCollision.iterations) or 2)))
  local maximumIterations = math.min(5, iterations + 3)
  local hadExternalContacts = next(stats.contactPoints) ~= nil
  local iteration = 1
  while iteration <= iterations do
    local pass = collisionSolver.resolveState(state, context.graph, collisionContext,
      context.effectiveSettings, context.collisionOwners, dt, iteration == 1, pairBudgetRemaining,
      context.inverseMassByPoint)
    -- Deep overlaps can need extra projections to converge with root-anchored
    -- length constraints. Stop once shallow and never exceed five passes.
    if iteration == iterations and pass.deepPenetration and iterations < maximumIterations then
      local reservedForOther = type(extraPassBudget) == "table" and extraPassBudget.preferredId ~= nil
        and extraPassBudget.preferredVisited ~= true and extraPassBudget.componentId ~= extraPassBudget.preferredId
        and (tonumber(extraPassBudget.remaining) or 0) <= 1
      if type(extraPassBudget) ~= "table" or ((tonumber(extraPassBudget.remaining) or 0) > 0 and not reservedForOther) then
        if type(extraPassBudget) == "table" then extraPassBudget.remaining = extraPassBudget.remaining - 1 end
        iterations = iterations + 1
        stats.deepContactExtraPass = true
      else
        stats.deepContactBudgetExceeded = true
      end
    end
    mergeCollisionStats(stats, pass)
    if pairBudgetRemaining ~= nil then
      pairBudgetRemaining = math.max(0, pairBudgetRemaining - (tonumber(pass.selfPairs) or 0))
    end
    local foundContacts = (tonumber(pass.contacts) or 0) > 0
    if foundContacts or hadExternalContacts then
      preservingConstraintSolve(state, context.graph, context.targets,
        function(index) return context.constraintSettings[index] end, dt, stats.contactPoints,
        context.springReferencePoints, context.constraintPasses, context.hasAngularConstraints)
    end
    local preserveExternalContact = iteration == 1 and hadExternalContacts
    hadExternalContacts = false
    if not foundContacts and not preserveExternalContact then break end
    iteration = iteration + 1
  end
  -- Keep length/angle constraints last so contact projection cannot stretch links.
  state.collisionDiagnostics = stats
  return stats
end

local function simulateStep(state, graph, targets, input, effectiveSettings, gravityByLink, pointOwners,
    tipMassByLink, inverseMassByPoint, poseFollowByPoint, dt, collisionContext, deferContacts, stepContext, extraPassBudget)
  -- Verlet stores velocity as displacement per previous substep. Preserve that
  -- velocity when the shared scheduler changes its fixed step.
  local oldStep = tonumber(state.lastSimulationStep)
  if finite(oldStep) and oldStep > 0 and math.abs(oldStep - dt) > 0.000000001 then
    local ratio = dt / oldStep
    for index = 2, #state.points do
      local point, previous = state.points[index], state.previousPoints[index]
      if validVector(point) and validVector(previous) then
        previous.x = point.x - (point.x - previous.x) * ratio
        previous.y = point.y - (point.y - previous.y) * ratio
        previous.z = point.z - (point.z - previous.z) * ratio
      end
    end
  end
  state.lastSimulationStep = dt
  local captureForceDiagnostics = stepContext and stepContext.captureForceDiagnostics == true
  if stepContext then
    stepContext.accelerationBreakdownByPoint = captureForceDiagnostics and {} or nil
    stepContext.constraintCorrectionByPoint = nil
  end
  local rootTarget = targets[1] or v(0, 0, 0)
  local rootAcceleration = input and input.rootAcceleration or v(0, 0, 0)
  if not validVector(rootAcceleration) then rootAcceleration = v(0, 0, 0) end
  local rootVelocity = input and input.rootVelocity or v(0, 0, 0)
  if not validVector(rootVelocity) then rootVelocity = v(0, 0, 0) end
  local angularAcceleration = tonumber(input and input.rootYawAcceleration) or 0
  if not finite(angularAcceleration) then angularAcceleration = 0 end
  local alpha = validVector(input and input.rootAngularAcceleration)
    and clonePoint(input.rootAngularAcceleration) or v(0, angularAcceleration, 0)
  local angularVelocity = validVector(input and input.rootAngularVelocity)
    and clonePoint(input.rootAngularVelocity) or v(0, 0, 0)
  local springReferencePoints = stepContext and stepContext.springReferencePoints or targets
  local bendAcceleration = {}
  if not stepContext or stepContext.hasBendStiffness ~= false then
    bendAcceleration = constraints.bendAccelerations(state.points, graph,
      effectiveSettings, springReferencePoints, inverseMassByPoint,
      stepContext and stepContext.bendStiffnessWeightByEdge)
  end
  for pointIndex = 2, #state.points do
    local target = targets[pointIndex] or state.points[pointIndex]
    local current = state.points[pointIndex]
    local previous = state.previousPoints[pointIndex]
    if validVector(target) and validVector(current) and validVector(previous) then
      local ownerIndex = pointOwners[pointIndex] or pointIndex
      local setting = effectiveSettings[ownerIndex] or effectiveSettings[1] or {}
      local gravity = gravityByLink[ownerIndex] or v(0, -9.81, 0)
      local tipMass = math.max(1, tonumber(tipMassByLink and tipMassByLink[ownerIndex]) or 1)
      local falloff = math.max(0, math.min(1, tonumber(setting.gravityFalloff) or 0))
      local mass = math.max(0.05, tonumber(setting.mass) or 1)
      local effectiveMass = mass * tipMass
      local pull = math.max(0, tonumber(setting.pull) or 0) / effectiveMass
      local poseFollow = math.max(0, math.min(1,
        tonumber(poseFollowByPoint and poseFollowByPoint[pointIndex]) or 0))
      local springWeight = math.max(0, math.min(1,
        tonumber(stepContext and stepContext.springWeightByPoint
          and stepContext.springWeightByPoint[pointIndex]) or 0))
      local restitution = math.max(0, math.min(1, tonumber(setting.restitution) or 0))
      local damping = math.max(0, tonumber(setting.damping) or 0) / math.sqrt(effectiveMass)
      local offset = sub(current, target)
      local gravityScale = 1
      if falloff > 0 then gravityScale = 1 - falloff * math.exp(-length(offset) * 2.0) end
      local gravityAcceleration = mul(gravity, gravityScale)
      local animationFollowAcceleration = mul(sub(target, current), pull * poseFollow)
      local acceleration = add(gravityAcceleration, animationFollowAcceleration)
      local springStrength = math.max(0, tonumber(setting.spring) or 0) / effectiveMass
      local restSpringAcceleration
      local bendSpringAcceleration = bendAcceleration[pointIndex]
      if springStrength > 0 and springWeight > 0 then
        local springTarget = springReferencePoints[pointIndex] or target
        restSpringAcceleration = mul(sub(springTarget, current), springStrength * springWeight)
        acceleration = add(acceleration, restSpringAcceleration)
      end
      if bendSpringAcceleration then acceleration = add(acceleration, bendSpringAcceleration) end
      -- Fictitious acceleration from the moving avatar frame is independent of
      -- mass. Tip mass increases lag by weakening pose-follow and drag below,
      -- not by multiplying the external acceleration itself.
      local rootMotionAcceleration = mul(rootAcceleration,
        (tonumber(setting.rootMotionResponse) or 0))
      local avatarTranslationAcceleration = captureForceDiagnostics
        and mul(rootMotionAcceleration, -1) or nil
      acceleration = sub(acceleration, rootMotionAcceleration)
      local relative = sub(current, rootTarget)
      local angularResponse = tonumber(setting.avatarMotionResponse) or 0
      -- Coriolis inertia is required when a link already moves relative to an
      -- animated rotating parent. Verlet position deltas are expressed in the
      -- parent frame, so convert that delta to velocity before applying it.
      local angularInertia
      if captureForceDiagnostics then
        local relativeVelocity = mul(sub(current, previous), 1 / math.max(dt, 0.000001))
        local angularAccelerationInertia = mul(cross(alpha, relative), -angularResponse)
        local centripetalInertia = mul(cross(angularVelocity, cross(angularVelocity, relative)), -angularResponse)
        local coriolisInertia = mul(cross(angularVelocity, relativeVelocity), -2 * angularResponse)
        angularInertia = add(add(angularAccelerationInertia, centripetalInertia), coriolisInertia)
      else
        -- Keep the same three inertial terms without allocating temporary
        -- vectors for each cross product on every point and substep.
        local wx, wy, wz = angularVelocity.x, angularVelocity.y, angularVelocity.z
        local rx, ry, rz = relative.x, relative.y, relative.z
        local sx, sy, sz = wy * rz - wz * ry, wz * rx - wx * rz, wx * ry - wy * rx
        local invDt = 1 / math.max(dt, 0.000001)
        local vx, vy, vz = (current.x - previous.x) * invDt,
          (current.y - previous.y) * invDt, (current.z - previous.z) * invDt
        local response, coriolis = -angularResponse, -2 * angularResponse
        angularInertia = v(
          response * (alpha.y * rz - alpha.z * ry) + response * (wy * sz - wz * sy) + coriolis * (wy * vz - wz * vy),
          response * (alpha.z * rx - alpha.x * rz) + response * (wz * sx - wx * sz) + coriolis * (wz * vx - wx * vz),
          response * (alpha.x * ry - alpha.y * rx) + response * (wx * sy - wy * sx) + coriolis * (wx * vy - wy * vx))
      end
      acceleration = add(acceleration, angularInertia)
      local rawVelocity = captureForceDiagnostics
        and mul(sub(current, previous), 1 / math.max(dt, 0.000001)) or nil
      local dragRate = math.max(0, tonumber(setting.motionDrag) or 0)
      local dampingFactor = damping > 0 and math.exp(-damping * dt) or 1
      local velocity = mul(sub(current, previous), dampingFactor)
      local dampingAcceleration
      if captureForceDiagnostics then
        dampingAcceleration = mul(sub(mul(velocity, 1 / math.max(dt, 0.000001)), rawVelocity),
          1 / math.max(dt, 0.000001))
      end
      local maxSpeed = math.max(0, tonumber(setting.maxLinearSpeed) or 24)
      local velocityBeforeSpeedLimit = captureForceDiagnostics and clonePoint(velocity) or nil
      velocity = capMagnitude(velocity, maxSpeed * dt)
      local speedLimitAcceleration
      if captureForceDiagnostics then
        speedLimitAcceleration = mul(sub(mul(velocity, 1 / math.max(dt, 0.000001)),
          mul(velocityBeforeSpeedLimit, 1 / math.max(dt, 0.000001))), 1 / math.max(dt, 0.000001))
      end
      local nextVelocity = add(mul(velocity, 1 / math.max(dt, 0.000001)), mul(acceleration, dt))
      local velocityBeforeEnvironmentDrag = captureForceDiagnostics and clonePoint(nextVelocity) or nil
      if dragRate > 0 then
        -- Resist motion through the stationary environment. Avatar translation
        -- and rotation are added to the point's local velocity before drag, so
        -- each link trails when its animated root moves without any wind force.
        local airRelativeVelocity = add(add(nextVelocity, rootVelocity), cross(angularVelocity, relative))
        local parentPointIndex = pointIndex - 1
        if stepContext and stepContext.settings.linkControlMode == "bone" then
          parentPointIndex = stepContext.edgeParentByPoint[pointIndex] or parentPointIndex
        else
          local link = graph.links and graph.links[ownerIndex]
          if pointIndex <= #(graph.links or {}) and link and tonumber(link.parentIndex) then
            parentPointIndex = tonumber(link.parentIndex)
          end
        end
        local linkDirection = parentPointIndex >= 1 and sub(current, state.points[parentPointIndex]) or v(0, 0, 0)
        local linkLength = length(linkDirection)
        if linkLength > 0.000001 then
          local tangent = mul(linkDirection, 1 / linkLength)
          local axialVelocity = mul(tangent, dot(airRelativeVelocity, tangent))
          local transverseVelocity = sub(airRelativeVelocity, axialVelocity)
          local dampedTransverse = quadraticDragVelocity(transverseVelocity, dragRate, dt, mass * tipMass)
          local dampedAxial = quadraticDragVelocity(axialVelocity, dragRate * AXIAL_AIR_DRAG_RATIO, dt, mass * tipMass)
          nextVelocity = add(nextVelocity, sub(add(dampedTransverse, dampedAxial), airRelativeVelocity))
        else
          local dampedVelocity = quadraticDragVelocity(airRelativeVelocity, dragRate, dt, mass * tipMass)
          nextVelocity = add(nextVelocity, sub(dampedVelocity, airRelativeVelocity))
        end
      end
      local environmentDragAcceleration = captureForceDiagnostics
        and mul(sub(nextVelocity, velocityBeforeEnvironmentDrag), 1 / math.max(dt, 0.000001)) or nil
      local velocityBeforeRestitution = captureForceDiagnostics and clonePoint(nextVelocity) or nil
      if restitution > 0 and poseFollow > 0 then
        -- Legacy rebound is kept separate from the physical angular spring.
        -- It only acts when a pose-following point crosses its animated target.
        local nextPoint = add(current, mul(nextVelocity, dt))
        local nextOffset = sub(nextPoint, target)
        local offsetLength = length(offset)
        if offsetLength > 0.000001 and dot(offset, nextOffset) < 0 then
          local outward = mul(offset, 1 / offsetLength)
          local inwardSpeed = dot(nextVelocity, outward)
          if inwardSpeed < 0 then
            nextVelocity = sub(nextVelocity, mul(outward, (1 + restitution) * inwardSpeed))
          end
        end
      end
      local restitutionAcceleration = captureForceDiagnostics
        and mul(sub(nextVelocity, velocityBeforeRestitution), 1 / math.max(dt, 0.000001)) or nil
      if captureForceDiagnostics then
        local netAcceleration = clonePoint(acceleration)
        netAcceleration = add(netAcceleration, dampingAcceleration)
        netAcceleration = add(netAcceleration, speedLimitAcceleration)
        netAcceleration = add(netAcceleration, environmentDragAcceleration)
        netAcceleration = add(netAcceleration, restitutionAcceleration)
        stepContext.accelerationBreakdownByPoint[pointIndex] = {
          gravity = clonePoint(gravityAcceleration),
          animationFollow = clonePoint(animationFollowAcceleration),
          restSpring = clonePoint(restSpringAcceleration or v(0, 0, 0)),
          bendSpring = clonePoint(bendSpringAcceleration or v(0, 0, 0)),
          avatarTranslation = clonePoint(avatarTranslationAcceleration),
          avatarRotation = clonePoint(angularInertia),
          damping = dampingAcceleration,
          speedLimit = speedLimitAcceleration,
          environmentDrag = environmentDragAcceleration,
          restitution = restitutionAcceleration,
          net = netAcceleration,
        }
      end
      state.previousPoints[pointIndex] = clonePoint(current)
      state.points[pointIndex] = add(current, mul(nextVelocity, dt))
      if not validVector(state.points[pointIndex]) then
        state.points[pointIndex], state.previousPoints[pointIndex] = clonePoint(target), clonePoint(target)
      end
    end
  end
  state.points[1], state.previousPoints[1] = clonePoint(rootTarget), clonePoint(rootTarget)

  local function effective(index) return effectiveSettings[index] end
  local pointsBeforeConstraints = captureForceDiagnostics and clonePoints(state.points) or nil
  preservingConstraintSolve(state, graph, targets, effective, dt, nil,
    stepContext and stepContext.springReferencePoints,
    stepContext and stepContext.constraintPasses,
    stepContext and stepContext.hasAngularConstraints)
  if captureForceDiagnostics then
    local corrections = {}
    for pointIndex, point in ipairs(state.points) do
      local before = pointsBeforeConstraints and pointsBeforeConstraints[pointIndex]
      if before then corrections[pointIndex] = sub(point, before) end
    end
    stepContext.constraintCorrectionByPoint = corrections
  end
  if deferContacts then
    state.collisionDiagnostics = { contacts = 0, worldQueries = 0, selfPairs = 0,
      selfBudgetExceeded = false, budgetExceeded = false, worldUnavailable = false, deferred = true }
  elseif collisionContext and collisionContext.enabled then
    if stepContext then resolveLocalContacts(state, stepContext, dt, nil, nil, extraPassBudget) end
  else
    state.collisionDiagnostics = emptyCollisionStats()
  end
  state.points[1], state.previousPoints[1] = clonePoint(rootTarget), clonePoint(rootTarget)
end

local function averageEdgeDirection(points, graph, linkIndex)
  local sum = v(0, 0, 0)
  local count = 0
  for _, edge in ipairs((graph.edgesByLink and graph.edgesByLink[linkIndex]) or {}) do
      local delta = sub(points[edge.to], points[edge.from])
      local magnitude = length(delta)
      if magnitude > 0.000001 then sum = add(sum, mul(delta, 1 / magnitude)); count = count + 1 end
  end
  if count == 0 then return nil end
  return v(sum.x / count, sum.y / count, sum.z / count)
end

local function matchingEdgeDirections(animated, solved, graph, linkIndex)
  for _, edge in ipairs((graph.edgesByLink and graph.edgesByLink[linkIndex]) or {}) do
    local fromAnimated, toAnimated = animated[edge.from], animated[edge.to]
    local fromSolved, toSolved = solved[edge.from], solved[edge.to]
    if validVector(fromAnimated) and validVector(toAnimated)
      and validVector(fromSolved) and validVector(toSolved) then
      local animatedDirection = sub(toAnimated, fromAnimated)
      local solvedDirection = sub(toSolved, fromSolved)
      if length(animatedDirection) > 0.000001 and length(solvedDirection) > 0.000001 then
        return animatedDirection, solvedDirection
      end
    end
  end
end

-- Fit one parent rotation to all outgoing branches. A single-vector average
-- loses rotation about its own axis; the symmetric 4x4 eigenproblem below
-- minimizes the summed direction error without that ambiguity. Ordinary
-- unbranched links stay on the cheaper shortest-arc path.
local function fitBranchRotation(animated, solved, graph, linkIndex, parentMotion, priorRotation)
  local edges = (graph.edgesByLink and graph.edgesByLink[linkIndex]) or {}
  if #edges < 2 then return nil end
  local b = { {0,0,0}, {0,0,0}, {0,0,0} }
  local count = 0
  for _, edge in ipairs(edges) do
    local aa, ab, sa, sb = animated[edge.from], animated[edge.to], solved[edge.from], solved[edge.to]
    if validVector(aa) and validVector(ab) and validVector(sa) and validVector(sb) then
      local u, w = transform(parentMotion, sub(ab, aa)), sub(sb, sa)
      local ul, wl = length(u), length(w)
      if ul > 0.000001 and wl > 0.000001 then
        u, w = mul(u, 1 / ul), mul(w, 1 / wl)
        local us, ws = {u.x, u.y, u.z}, {w.x, w.y, w.z}
        for row = 1, 3 do for column = 1, 3 do
          b[row][column] = b[row][column] + ws[row] * us[column]
        end end
        count = count + 1
      end
    end
  end
  if count < 2 then return nil end
  local sigma = b[1][1] + b[2][2] + b[3][3]
  local x, y, z = b[3][2]-b[2][3], b[1][3]-b[3][1], b[2][1]-b[1][2]
  local a = {
    {sigma, x, y, z},
    {x, 2*b[1][1]-sigma, b[1][2]+b[2][1], b[1][3]+b[3][1]},
    {y, b[1][2]+b[2][1], 2*b[2][2]-sigma, b[2][3]+b[3][2]},
    {z, b[1][3]+b[3][1], b[2][3]+b[3][2], 2*b[3][3]-sigma},
  }
  local eigenvectors = { {1,0,0,0}, {0,1,0,0}, {0,0,1,0}, {0,0,0,1} }
  for _ = 1, 32 do
    local p, q, largest = 1, 2, 0
    for row = 1, 3 do for column = row + 1, 4 do
      local magnitude = math.abs(a[row][column])
      if magnitude > largest then p, q, largest = row, column, magnitude end
    end end
    if largest < 0.0000000001 then break end
    local apq = a[p][q]
    local tau = (a[q][q] - a[p][p]) / (2 * apq)
    local t = (tau >= 0 and 1 or -1) / (math.abs(tau) + math.sqrt(1 + tau * tau))
    local c = 1 / math.sqrt(1 + t * t)
    local s = t * c
    a[p][p], a[q][q], a[p][q], a[q][p] = a[p][p] - t * apq, a[q][q] + t * apq, 0, 0
    for i = 1, 4 do
      if i ~= p and i ~= q then
        local aip, aiq = a[i][p], a[i][q]
        a[i][p], a[p][i] = c * aip - s * aiq, c * aip - s * aiq
        a[i][q], a[q][i] = s * aip + c * aiq, s * aip + c * aiq
      end
      local vip, viq = eigenvectors[i][p], eigenvectors[i][q]
      eigenvectors[i][p], eigenvectors[i][q] = c * vip - s * viq, s * vip + c * viq
    end
  end
  local best = 1
  for i = 2, 4 do if a[i][i] > a[best][best] then best = i end end
  local qw, qx, qy, qz = eigenvectors[1][best], eigenvectors[2][best], eigenvectors[3][best], eigenvectors[4][best]
  -- Blend the previous world correction into the nearly optimal eigenspace
  -- near an undetermined twist; this avoids an abrupt eigengap switch.
  local priorLength = length(priorRotation or v(0,0,0))
  local priorScale = priorLength > 0.000001 and math.sin(priorLength * 0.5) / priorLength or 0
  local prior = { math.cos(priorLength * 0.5), (priorRotation and priorRotation.x or 0) * priorScale,
    (priorRotation and priorRotation.y or 0) * priorScale, (priorRotation and priorRotation.z or 0) * priorScale }
  local band, projected = 0.0001 * count, { 0, 0, 0, 0 }
  for column = 1, 4 do
    local fraction = math.max(0, math.min(1, 1 - (a[best][best] - a[column][column]) / band))
    local weight = fraction * fraction * (3 - 2 * fraction)
    if weight > 0 then
      local alignment = 0
      for row = 1, 4 do alignment = alignment + eigenvectors[row][column] * prior[row] end
      for row = 1, 4 do projected[row] = projected[row] + weight * alignment * eigenvectors[row][column] end
    end
  end
  local projectionLength = math.sqrt(projected[1]^2 + projected[2]^2 + projected[3]^2 + projected[4]^2)
  if projectionLength > 0.000001 then
    qw, qx, qy, qz = projected[1]/projectionLength, projected[2]/projectionLength,
      projected[3]/projectionLength, projected[4]/projectionLength
  end
  if qw < 0 then qw, qx, qy, qz = -qw, -qx, -qy, -qz end
  local vectorLength = math.sqrt(qx*qx + qy*qy + qz*qz)
  if vectorLength < 0.000001 then return v(0,0,0) end
  local angle = 2 * atan2(vectorLength, qw)
  return v(qx * angle / vectorLength, qy * angle / vectorLength, qz * angle / vectorLength)
end

local function inverseRotate(matrix, vector)
  if type(matrix) ~= "table" then return clonePoint(vector) end
  return v(
    matrix[1][1] * vector.x + matrix[2][1] * vector.y + matrix[3][1] * vector.z,
    matrix[1][2] * vector.x + matrix[2][2] * vector.y + matrix[3][2] * vector.z,
    matrix[1][3] * vector.x + matrix[2][3] * vector.y + matrix[3][3] * vector.z)
end

local function rotationQuaternion(rotation)
  local angle = length(rotation)
  local factor = angle > 0.000001 and math.sin(angle * 0.5) / angle or 0.5
  return { math.cos(angle * 0.5), rotation.x * factor, rotation.y * factor, rotation.z * factor }
end

local function quaternionRotation(q)
  if q[1] < 0 then for i = 1, 4 do q[i] = -q[i] end end
  local magnitude = math.sqrt(q[2]^2 + q[3]^2 + q[4]^2)
  if magnitude < 0.000001 then return v(0,0,0) end
  local factor = 2 * atan2(magnitude, q[1]) / magnitude
  return v(q[2] * factor, q[3] * factor, q[4] * factor)
end

local function shortestRotationBlend(previous, current, blend, maximum)
  if not maximum and blend <= 0 then return clonePoint(previous) end
  if not maximum and blend >= 1 then return clonePoint(current) end
  local difference = sub(current, previous)
  if dot(difference, difference) < 0.000000000001 then return clonePoint(current) end
  local a, b = rotationQuaternion(previous), rotationQuaternion(current)
  local cosine = a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4]
  if cosine < 0 then
    cosine = -cosine
    for i = 1, 4 do b[i] = -b[i] end
  end
  cosine = math.max(-1, math.min(1, cosine))
  local angle = 2 * math.acos(cosine)
  if maximum and angle > maximum and angle > 0.000001 then blend = maximum / angle end
  blend = math.max(0, math.min(1, blend))
  local weightA, weightB
  if cosine > 0.9995 then
    weightA, weightB = 1 - blend, blend
  else
    local halfAngle = math.acos(cosine)
    local denominator = math.sin(halfAngle)
    weightA, weightB = math.sin((1-blend)*halfAngle)/denominator, math.sin(blend*halfAngle)/denominator
  end
  local result, magnitude = {}, 0
  for i = 1, 4 do result[i] = a[i]*weightA + b[i]*weightB; magnitude = magnitude + result[i]^2 end
  magnitude = math.sqrt(magnitude)
  if magnitude < 0.000001 then return clonePoint(previous) end
  for i = 1, 4 do result[i] = result[i] / magnitude end
  return quaternionRotation(result)
end

local function rotationDistance(first, second)
  local a, b = rotationQuaternion(first), rotationQuaternion(second)
  local cosine = math.abs(a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4])
  return 2 * math.acos(math.max(-1, math.min(1, cosine)))
end

local function capOffsetChange(current, previous, maximum, boneMode)
  if boneMode then
    return shortestRotationBlend(previous, current, 1, maximum)
  end
  local delta = sub(current, previous)
  local distance = length(delta)
  if distance <= maximum or distance < 0.000001 then return current end
  return add(previous, mul(delta, maximum / distance))
end

local function computeOffsets(state, graph, targets, linkFrames, jointFrames, dt, effectiveSettings,
    includeDiagnostics, boneMode)
  local offsets, solvedFrames = {}, {}
  local diagnostics
  if includeDiagnostics ~= false then diagnostics = {} end
  for linkIndex, link in ipairs(graph.links or {}) do
    local animatedDirection = averageEdgeDirection(targets, graph, linkIndex)
    local solvedDirection = averageEdgeDirection(state.points, graph, linkIndex)
    -- Symmetric branches can cancel out even when one common parent rotation
    -- maps them all. Use the same nonzero edge from each pose in bone mode.
    if boneMode and animatedDirection and solvedDirection
      and (length(animatedDirection) < 0.000001 or length(solvedDirection) < 0.000001) then
      animatedDirection, solvedDirection = matchingEdgeDirections(targets, state.points, graph, linkIndex)
    end
    local animatedParentFrame = linkFrames and linkFrames[linkIndex] or identity()
    local actualParentFrame = link.parentIndex and solvedFrames[link.parentIndex] or animatedParentFrame
    local parentMotion = multiplyMatrix(actualParentFrame, transposeMatrix(animatedParentFrame))
    local animatedPartFrame = jointFrames and jointFrames[linkIndex] or animatedParentFrame
    local animatedLocalFrame = multiplyMatrix(transposeMatrix(animatedParentFrame), animatedPartFrame)
    local animatedLocalEuler = matrixEuler(animatedLocalFrame)
    local offset = v(0, 0, 0)
    if animatedDirection and solvedDirection then
      -- Child targets already include their animated ancestors. Carry that
      -- target through each solved parent bend before computing this joint's
      -- own correction; otherwise every child reapplies the parent's full
      -- world-space bend as another local rotation and the chain corkscrews.
      local carriedDirection = transform(parentMotion, animatedDirection)
      -- The shortest-arc axis is ambiguous at a 180-degree reversal. Carry the
      -- previous local bend axis only in that singular region; ordinary links
      -- avoid the extra normalization and matrix transform.
      local preferredWorldAxis
      local directionDot = dot(carriedDirection, solvedDirection)
      if directionDot < 0 and directionDot < -0.999999995 * length(carriedDirection) * length(solvedDirection) then
        local previousOffset = state.offsets[linkIndex] or v(0, 0, 0)
        local previousOffsetLength = length(previousOffset)
        if previousOffsetLength > 0.000001 then
          preferredWorldAxis = transform(actualParentFrame, mul(previousOffset, 1 / previousOffsetLength))
        end
      end
      local actualBasePartFrame = multiplyMatrix(parentMotion, animatedPartFrame)
      local worldAxisAngle
      if boneMode and #((graph.edgesByLink and graph.edgesByLink[linkIndex]) or {}) > 1 then
        local previousOffset = state.offsets[linkIndex] or v(0, 0, 0)
        local previousEuler = matrixEuler(axisAngleMatrix(previousOffset))
        local previousFrame = multiplyMatrix(actualParentFrame, eulerMatrix(add(animatedLocalEuler, previousEuler)))
        local priorCorrection = matrixAxisAngle(multiplyMatrix(previousFrame, transposeMatrix(actualBasePartFrame)))
        worldAxisAngle = fitBranchRotation(targets, state.points, graph, linkIndex, parentMotion, priorCorrection)
      end
      worldAxisAngle = worldAxisAngle or constraints.directionRotation(carriedDirection, solvedDirection, preferredWorldAxis)
      local desiredPartFrame = multiplyMatrix(axisAngleMatrix(worldAxisAngle), actualBasePartFrame)
      local desiredLocalFrame = multiplyMatrix(transposeMatrix(actualParentFrame), desiredPartFrame)
      local desiredLocalEuler = matrixEuler(desiredLocalFrame)
      offset = matrixAxisAngle(eulerMatrix(v(
        wrapAngle(desiredLocalEuler.x - animatedLocalEuler.x),
        wrapAngle(desiredLocalEuler.y - animatedLocalEuler.y),
        wrapAngle(desiredLocalEuler.z - animatedLocalEuler.z))))
    end
    local setting = effectiveSettings[linkIndex] or effectiveSettings[1] or {}
    local maximum = math.rad(math.max(0, tonumber(setting.joint and setting.joint.angularSpeed) or 180)) * dt
    offset = capOffsetChange(offset, state.offsets[linkIndex] or v(0, 0, 0), maximum, boneMode)
    offsets[linkIndex] = offset
    local appliedEuler = matrixEuler(axisAngleMatrix(offset))
    solvedFrames[linkIndex] = multiplyMatrix(actualParentFrame,
      eulerMatrix(add(animatedLocalEuler, appliedEuler)))
    if diagnostics then
      diagnostics[linkIndex] = {
        offsetRadians = length(offset),
        angleDegrees = math.deg(length(offset)),
        speedDegrees = dt > 0 and math.deg((boneMode
          and rotationDistance(offset, state.offsets[linkIndex] or v(0, 0, 0))
          or length(sub(offset, state.offsets[linkIndex] or v(0, 0, 0)))) / dt) or 0,
      }
    end
  end
  return offsets, diagnostics
end

function core.prepareWorldStep(state, graph, animatedPoints, input, settings, dt, gravityFrame,
    linkFrames, linkOverrides, jointFrames, collisionContext, restPose, restPoseRootFrame, constraintPasses)
  settings = settings or {}
  restPose = type(restPose) == "table" and restPose or settings.restPose
  restPoseRootFrame = restPoseRootFrame or settings.restPoseRootFrame
  local safeDt = tonumber(dt)
  if not finite(safeDt) or safeDt <= 0 then safeDt = 1 / 20 end
  safeDt = math.min(MAX_FRAME_DT, safeDt)
  if not stateMatches(state, graph, animatedPoints) then
    state = core.newComponentState(graph, animatedPoints, restPose, restPoseRootFrame)
  end
  state.renderPreviousOffsets = copyOffsetList(state.offsets)
  local frame = gravityFrame or identity()
  local effectiveSettings, constraintSettings, gravityByLink, pointOwners, tipMassByLink = {}, {}, {}, {}, {}
  local collisionOwners = {}
  state.gravityReferenceByLink = state.gravityReferenceByLink or {}
  state.boneGravityReferenceByLink = state.boneGravityReferenceByLink or {}
  local maximumDepth = 0
  for index, link in ipairs(graph.links or {}) do
    maximumDepth = math.max(maximumDepth, tonumber(link.depth) or (index - 1))
  end
  local hasEnabledCollision, hasAngularConstraints = false, false
  local boneGravityFrame = settings.linkControlMode == "bone" and orientationFromInverse(gravityFrame) or nil
  for index, link in ipairs(graph.links or {}) do
    local setting = settingsFor(settings, linkOverrides, link.key)
    effectiveSettings[index] = setting
    local depth = math.max(0, tonumber(link.depth) or (index - 1))
    local progress = maximumDepth > 0 and math.max(0, math.min(1, depth / maximumDepth)) or 0
    local tipMultiplier = math.max(1, math.min(6, tonumber(setting.tipMass) or 1))
    local tipMass = 1 + (tipMultiplier - 1) * progress
    tipMassByLink[index] = tipMass
    if setting.collision and setting.collision.enabled == true then hasEnabledCollision = true end
    local joint = setting.joint
    if not joint or joint.type ~= "free" then hasAngularConstraints = true end
    if joint and joint.type == "hinge" then
      -- Hinge solving needs its axis transformed into the animated joint frame.
      -- Free and cone joints only read their settings, so reuse the already
      -- merged per-link table instead of allocating two copies per link/tick.
      local constraintSetting = {}
      for key, value in pairs(setting) do constraintSetting[key] = value end
      constraintSetting.joint = {}
      for key, value in pairs(joint) do constraintSetting.joint[key] = value end
      constraintSetting.joint.axis = transform((jointFrames and jointFrames[index]) or identity(),
        joint.axis or v(0, 1, 0))
      constraintSettings[index] = constraintSetting
    else
      constraintSettings[index] = setting
    end
    local rawGravity = setting.gravity or { x = 0, y = -9.81, z = 0 }
    local gravitySpace = setting.gravitySpace == "local" and "local" or "world"
    local boneReference = state.boneGravityReferenceByLink[index]
    if settings.linkControlMode == "bone" and boneGravityFrame
      and (not boneReference or boneReference.mode ~= "bone") then
      boneReference = {mode="bone", orientation=cloneMatrix(boneGravityFrame)}
      state.boneGravityReferenceByLink[index] = boneReference
    end
    local gravity = gravitySpace == "local"
      and v(rawGravity.x or 0, rawGravity.y or 0, rawGravity.z or 0)
      or transform(frame, rawGravity)
    local sourceMagnitude = length(rawGravity)
    if settings.linkControlMode == "bone" and gravitySpace == "world" then
      local reference = boneReference
      local tiltResponse = math.max(0, math.min(1, tonumber(setting.gravityTiltResponse) or 0))
      if tiltResponse > 0 and sourceMagnitude > 0.000001 then
        if boneGravityFrame and reference and reference.orientation then
          -- Compare the same current gravity direction in the startup and
          -- current orientation, so changing the gravity vector while tilted
          -- does not silently reset the neutral reference.
          local currentDirection = transform(boneGravityFrame, rawGravity)
          local referenceDirection = transform(reference.orientation, rawGravity)
          local denominator = length(currentDirection) * length(referenceDirection)
          local cosine = denominator > 0.000001 and dot(currentDirection, referenceDirection) / denominator or 1
          local tilt = math.min(1, math.sqrt(math.max(0, 1 - math.max(-1, math.min(1, cosine)))))
          gravity = mul(gravity, (1 - tiltResponse) + tiltResponse * tilt)
        else
          gravity = mul(gravity, 1 - tiltResponse)
        end
      end
    elseif sourceMagnitude > 0.000001 then
      local sourceDirection = mul(rawGravity, 1 / sourceMagnitude)
      local reference = state.gravityReferenceByLink[index]
      local referenceFrameAvailable = gravitySpace ~= "world" or validMatrix(gravityFrame)
      if referenceFrameAvailable and (not reference or reference.space ~= gravitySpace
        or not reference.sourceDirection
        or length(sub(reference.sourceDirection, sourceDirection)) > 0.0001) then
        local gravityMagnitude = length(gravity)
        state.gravityReferenceByLink[index] = {
          direction = gravityMagnitude > 0.000001 and mul(gravity, 1 / gravityMagnitude) or nil,
          sourceDirection = sourceDirection,
          space = gravitySpace,
        }
        reference = state.gravityReferenceByLink[index]
      end
      local tiltResponse = gravitySpace == "world"
        and math.max(0, math.min(1, tonumber(setting.gravityTiltResponse) or 0)) or 0
      if tiltResponse > 0 and referenceFrameAvailable and reference and reference.direction then
        -- Preserve the previous vector-difference behavior for old profiles.
        local referenceGravity = mul(reference.direction, length(gravity))
        local dynamicGravity = sub(gravity, referenceGravity)
        dynamicGravity = capMagnitude(dynamicGravity, length(gravity))
        gravity = add(mul(gravity, 1 - tiltResponse), mul(dynamicGravity, tiltResponse))
      elseif tiltResponse > 0 and not referenceFrameAvailable then
        -- Do not calibrate against the identity fallback before POST_RENDER
        -- supplies a real parent frame. Apply only the uncompensated fraction.
        gravity = mul(gravity, 1 - tiltResponse)
      end
    end
    gravityByLink[index] = validVector(gravity) and gravity or v(0, -9.81, 0)
    pointOwners[index], collisionOwners[index] = index, index
  end
  local terminalPoint, returnOwner, edgeParentByPoint = {}, {}, {}
  for _, edge in ipairs(graph.edges or {}) do
    returnOwner[edge.to] = edge.fromLink
    edgeParentByPoint[edge.to] = edge.from
    if settings.linkControlMode == "bone" then
      pointOwners[edge.to], collisionOwners[edge.to] = edge.fromLink, edge.fromLink
    end
    if edge.terminal then
      pointOwners[edge.to] = edge.fromLink
      collisionOwners[edge.to] = edge.fromLink
      terminalPoint[edge.to] = true
    end
  end
  local inverseMassByPoint = { [1] = 0 }
  for pointIndex = 2, graph.pointCount or #animatedPoints do
    local owner = pointOwners[pointIndex] or pointIndex
    local setting = effectiveSettings[owner] or effectiveSettings[1] or {}
    local mass = math.max(0.05, tonumber(setting.mass) or 1)
    local tipMass = math.max(1, tonumber(tipMassByLink[owner]) or 1)
    inverseMassByPoint[pointIndex] = 1 / (mass * tipMass)
  end
  -- Point 1 is the kinematic root. Every other point follows animation only
  -- partially, with a smooth depth falloff and a fully free terminal point.
  local pointDepths, maximumPointDepth = { [1] = 0 }, 0
  for index, link in ipairs(graph.links or {}) do
    local depth = math.max(0, tonumber(link.depth) or (index - 1))
    pointDepths[index] = depth
    maximumPointDepth = math.max(maximumPointDepth, depth)
  end
  for _, edge in ipairs(graph.edges or {}) do
    if edge.terminal then
      local parentDepth = pointDepths[edge.from]
        or math.max(0, tonumber(graph.links and graph.links[edge.fromLink]
          and graph.links[edge.fromLink].depth) or (edge.fromLink - 1))
      pointDepths[edge.to] = parentDepth + 1
      maximumPointDepth = math.max(maximumPointDepth, parentDepth + 1)
    end
  end
  local poseFollowByPoint, springWeightByPoint = {}, {}
  for pointIndex = 2, graph.pointCount or #animatedPoints do
    local owner = pointOwners[pointIndex] or pointIndex
    local setting = effectiveSettings[owner] or effectiveSettings[1] or {}
    local base = math.max(0, math.min(1, tonumber(setting.poseFollow) or 1))
    local falloff = math.max(0, math.min(4, tonumber(setting.poseFollowFalloff) or 0))
    local depth = math.max(0, tonumber(pointDepths[pointIndex]) or (owner - 1))
    local progress = maximumPointDepth > 0
      and math.max(0, math.min(1, depth / maximumPointDepth)) or 0
    local fade = terminalPoint[pointIndex] and 0 or ((1 - progress) ^ falloff)
    -- Older profiles leave the terminal point free. A component may opt in to
    -- a minimum restoring weight so even a one-bone chain recovers its shape.
    local returnSetting = effectiveSettings[returnOwner[pointIndex]] or setting
    local shapeReturn = math.max(0, math.min(1, tonumber(returnSetting.restShapeReturn) or 0))
    fade = math.max(fade, shapeReturn)
    poseFollowByPoint[pointIndex] = base * fade
    springWeightByPoint[pointIndex] = fade
  end
  local bendStiffnessWeightByEdge, hasBendStiffness = {}, false
  for edgeIndex, edge in ipairs(graph.edges or {}) do
    local owner = tonumber(edge.fromLink) or tonumber(edge.from) or 1
    local setting = effectiveSettings[owner] or effectiveSettings[1] or {}
    local falloff = math.max(0, math.min(4, tonumber(setting.bendStiffnessFalloff) or 1.2))
    local depth = math.max(0, tonumber(pointDepths[edge.from]) or (owner - 1))
    local progress = maximumPointDepth > 0
      and math.max(0, math.min(1, depth / maximumPointDepth)) or 0
    local weight = (1 - progress) ^ falloff
    bendStiffnessWeightByEdge[edgeIndex] = weight
    if weight > 0 and math.max(0, tonumber(setting.bendStiffness) or 0) > 0 then
      hasBendStiffness = true
    end
  end
  local restPoseAvailable = type(restPose) == "table" and #restPose == #animatedPoints
  -- Free joints without spring/rest behavior have no consumer for the carried
  -- rest curve. Avoid rebuilding its per-point root-frame transform each tick.
  local needsSpringReference = hasAngularConstraints or restPoseAvailable
  for _, setting in ipairs(effectiveSettings) do
    local mode = setting.animationTargetMode
    if math.max(0, tonumber(setting.spring) or 0) > 0
      or math.max(0, tonumber(setting.bendStiffness) or 0) > 0
      or mode == "rest" or mode == "hybrid" then
      needsSpringReference = true
      break
    end
  end
  local springTargets = needsSpringReference and springReferencePoints(state, animatedPoints, restPose,
    jointFrames and jointFrames[1], restPoseRootFrame) or nil
  -- Animation mode reads these points without mutation; copy only when Rest or
  -- Hybrid mode actually needs to replace selected targets.
  local targets = animatedPoints
  for pointIndex = 2, #targets do
    local owner = pointOwners[pointIndex] or pointIndex
    local setting = effectiveSettings[owner] or effectiveSettings[1] or {}
    local mode = setting.animationTargetMode
    -- A saved neutral pose is the stable reference when one exists. Until then,
    -- use the startup pose already captured by springReferencePoints so Hybrid
    -- does not silently become full animation-follow and Rest still has a
    -- deterministic reference. Explicit calibration replaces this fallback.
    -- Both calibrated and bind references must be carried into the current
    -- root frame; using saved coordinates directly makes pull fight the spring
    -- whenever the root rotates or translates after calibration.
    local rest = springTargets and springTargets[pointIndex] or nil
    if validVector(rest) then
      if mode == "rest" then
        if targets == animatedPoints then targets = clonePoints(animatedPoints) end
        targets[pointIndex] = clonePoint(rest)
      elseif mode == "hybrid" then
        if targets == animatedPoints then targets = clonePoints(animatedPoints) end
        local influence = math.max(0, math.min(1, tonumber(setting.animationInfluence) or 1))
        targets[pointIndex] = add(rest, mul(sub(animatedPoints[pointIndex], rest), influence))
      end
    end
  end
  if collisionContext then collisionContext.enabled = hasEnabledCollision and collisionContext.frameAvailable == true end
  local context = {
    state = state, graph = graph, targets = targets, animatedTargets = animatedPoints,
    restPose = restPose, restPoseAvailable = restPoseAvailable, springReferencePoints = springTargets, input = input,
    settings = settings, linkFrames = linkFrames, jointFrames = jointFrames,
    collisionContext = collisionContext, effectiveSettings = effectiveSettings,
    constraintSettings = constraintSettings, gravityByLink = gravityByLink,
    pointOwners = pointOwners, collisionOwners = collisionOwners, edgeParentByPoint = edgeParentByPoint,
    tipMassByLink = tipMassByLink,
    inverseMassByPoint = inverseMassByPoint,
    poseFollowByPoint = poseFollowByPoint, springWeightByPoint = springWeightByPoint,
    bendStiffnessWeightByEdge = bendStiffnessWeightByEdge,
    hasBendStiffness = hasBendStiffness,
    hasAngularConstraints = hasAngularConstraints,
    captureForceDiagnostics = settings.captureForceDiagnostics == true,
    accelerationBreakdownByPoint = nil, constraintCorrectionByPoint = nil,
    hasEnabledCollision = hasEnabledCollision, safeDt = safeDt,
    constraintPasses = math.floor(clamp(constraintPasses, 1, 12, CONSTRAINT_PASSES)),
    frameCollisionDiagnostics = emptyCollisionStats(),
  }
  return state, context
end

function core.advanceWorldSubstep(context, dt)
  if type(context) ~= "table" or type(context.state) ~= "table" then return nil end
  dt = tonumber(dt)
  if not finite(dt) or dt <= 0 then dt = FIXED_STEP end
  simulateStep(context.state, context.graph, context.targets, context.input,
    context.constraintSettings, context.gravityByLink, context.pointOwners,
    context.tipMassByLink, context.inverseMassByPoint, context.poseFollowByPoint,
    dt, context.collisionContext, true, context)
  context.substeps = (context.substeps or 0) + 1
  return context.state
end

function core.resolveWorldContacts(context, dt, contactPoints, pairBudgetRemaining, extraPassBudget)
  if type(context) ~= "table" or type(context.state) ~= "table" then return emptyCollisionStats() end
  dt = tonumber(dt)
  if not finite(dt) or dt <= 0 then dt = FIXED_STEP end
  local stats
  if context.collisionContext and context.collisionContext.enabled then
    stats = resolveLocalContacts(context.state, context, dt, contactPoints, pairBudgetRemaining, extraPassBudget)
  else
    stats = emptyCollisionStats()
    -- Integration already projected lengths and joints. Repeat that work only
    -- when the shared PhysicsWorld actually moved one of this chain's points.
    if type(contactPoints) == "table" and next(contactPoints) ~= nil then
      preservingConstraintSolve(context.state, context.graph, context.targets,
        function(index) return context.constraintSettings[index] end, dt, contactPoints,
        context.springReferencePoints, context.constraintPasses, context.hasAngularConstraints)
    end
    context.state.collisionDiagnostics = stats
  end
  local frame = context.frameCollisionDiagnostics
  frame.contacts = frame.contacts + stats.contacts
  frame.worldQueries = frame.worldQueries + stats.worldQueries
  frame.selfPairs = frame.selfPairs + stats.selfPairs
  frame.selfBudgetExceeded = frame.selfBudgetExceeded or stats.selfBudgetExceeded
  frame.budgetExceeded = frame.budgetExceeded or stats.budgetExceeded
  frame.worldUnavailable = frame.worldUnavailable or stats.worldUnavailable
  return stats
end

function core.finishWorldFrame(context, dt, includeDiagnostics)
  if type(context) ~= "table" or type(context.state) ~= "table" then return nil, {}, {} end
  local safeDt = tonumber(dt) or context.safeDt or 1 / 20
  local state = context.state
  -- Bone mode renders offsets against the actual animated bones. The solver's
  -- target can be a rest/hybrid blend; legacy profiles retain their previous
  -- interpretation to avoid silently changing their saved appearance.
  local renderTargets = context.settings.linkControlMode == "bone"
    and context.animatedTargets or context.targets
  local offsets, diagnostics = computeOffsets(state, context.graph, renderTargets,
    context.linkFrames, context.jointFrames, safeDt, context.effectiveSettings, includeDiagnostics,
    context.settings.linkControlMode == "bone")
  for index, diagnostic in ipairs(diagnostics or {}) do
    diagnostic.gravityInParent = clonePoint(context.gravityByLink[index] or v(0, -9.81, 0))
  end
  state.offsets, state.diagnostics = offsets, diagnostics
  state.interpolateRotations = context.settings.linkControlMode == "bone"
  local frameStats = context.frameCollisionDiagnostics or emptyCollisionStats()
  frameStats.frameUnavailable = context.hasEnabledCollision
    and context.collisionContext ~= nil and context.collisionContext.frameAvailable ~= true or false
  state.collisionDiagnostics = frameStats
  return state, offsets, diagnostics
end

function core.worldPointInfo(context)
  local result = {}
  if type(context) ~= "table" or type(context.state) ~= "table" then return result end
  local worldScale = tonumber(context.collisionContext and context.collisionContext.worldScale)
  if not finite(worldScale) or worldScale <= 0 then worldScale = 1 end
  for pointIndex = 1, #context.state.points do
    local owner = context.collisionOwners[pointIndex] or (pointIndex == 1 and 1 or nil)
    local setting = owner and (context.effectiveSettings[owner] or context.effectiveSettings[1]) or nil
    local collision = setting and setting.collision or {}
    local enabled = collision.enabled == true and collision.dynamic ~= false
    -- Bone mode uses model-unit radii in every collision system. Existing
    -- legacy profiles retain their historical world-proxy radius semantics.
    local radiusScale = context.settings.linkControlMode == "bone" and worldScale or 1
    local radius = enabled and math.max(0, tonumber(collision.radius) or 0) * radiusScale or 0
    result[pointIndex] = {
      radius = radius,
      inverseMass = tonumber(context.inverseMassByPoint[pointIndex]) or 0,
      group = collision.group or "custom",
      mask = collision.mask,
      friction = collision.friction,
      restitution = collision.restitution,
      selfCollision = collision.enabled == true and collision.self == true,
      selfNeighborDepth = collision.selfNeighborDepth,
      dynamic = radius > 0,
    }
  end
  return result
end

function core.step(state, graph, animatedPoints, input, settings, dt, gravityFrame, linkFrames, linkOverrides,
    jointFrames, collisionContext, restPose, restPoseRootFrame, constraintPasses)
  local safeDt = tonumber(dt)
  if not finite(safeDt) or safeDt <= 0 then safeDt = 1 / 20 end
  safeDt = math.min(MAX_FRAME_DT, safeDt)
  local context
  state, context = core.prepareWorldStep(state, graph, animatedPoints, input, settings, safeDt,
    gravityFrame, linkFrames, linkOverrides, jointFrames, collisionContext, restPose, restPoseRootFrame, constraintPasses)
  state.accumulator = math.min((state.accumulator or 0) + safeDt, FIXED_STEP * MAX_SUBSTEPS)
  local extraPassBudget = { remaining = 3 }
  local steps = 0
  while state.accumulator >= FIXED_STEP and steps < MAX_SUBSTEPS do
    simulateStep(state, graph, context.targets, input, context.constraintSettings,
      context.gravityByLink, context.pointOwners, context.tipMassByLink,
      context.inverseMassByPoint, context.poseFollowByPoint,
      FIXED_STEP, context.collisionContext, false, context, extraPassBudget)
    local stepStats = state.collisionDiagnostics or {}
    context.frameCollisionDiagnostics.contacts = context.frameCollisionDiagnostics.contacts + (tonumber(stepStats.contacts) or 0)
    context.frameCollisionDiagnostics.worldQueries = context.frameCollisionDiagnostics.worldQueries + (tonumber(stepStats.worldQueries) or 0)
    context.frameCollisionDiagnostics.selfPairs = context.frameCollisionDiagnostics.selfPairs + (tonumber(stepStats.selfPairs) or 0)
    context.frameCollisionDiagnostics.selfBudgetExceeded = context.frameCollisionDiagnostics.selfBudgetExceeded or stepStats.selfBudgetExceeded == true
    context.frameCollisionDiagnostics.budgetExceeded = context.frameCollisionDiagnostics.budgetExceeded or stepStats.budgetExceeded == true
    context.frameCollisionDiagnostics.worldUnavailable = context.frameCollisionDiagnostics.worldUnavailable or stepStats.worldUnavailable == true
    context.frameCollisionDiagnostics.deepContactBudgetExceeded = context.frameCollisionDiagnostics.deepContactBudgetExceeded
      or stepStats.deepContactBudgetExceeded == true
    state.accumulator = state.accumulator - FIXED_STEP
    steps = steps + 1
  end
  return core.finishWorldFrame(context, safeDt)
end

function core.interpolate(state, alpha)
  local blend = math.max(0, math.min(1, tonumber(alpha) or 1))
  local result = {}
  for index, current in ipairs(state and state.offsets or {}) do
    local previous = state.renderPreviousOffsets and state.renderPreviousOffsets[index] or current
    if state.interpolateRotations then
      result[index] = shortestRotationBlend(previous, current, blend)
    else
      result[index] = v(
        previous.x + (current.x - previous.x) * blend,
        previous.y + (current.y - previous.y) * blend,
        previous.z + (current.z - previous.z) * blend)
    end
  end
  return result
end

return core
