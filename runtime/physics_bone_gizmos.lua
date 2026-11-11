local physicsGizmos = {}
local WIRE_SEGMENTS = 8

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local args = { ... }
  local ok, value = pcall(fn, object, (table.unpack or unpack)(args))
  if ok then return value end
  return nil
end

local function vectorFromPivot(node, nextNode)
  local from = safeCall(node and node.part, "getPivot")
  local to = safeCall(nextNode and nextNode.part, "getPivot")
  if not from or not to then return { x = 0, y = -1, z = 0 }, 1 end
  local delta = { x = to.x - from.x, y = to.y - from.y, z = to.z - from.z }
  local length = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
  if length < 0.001 then return { x = 0, y = -1, z = 0 }, 1 end
  return delta, length
end

local function vectorToEuler(direction)
  local from = { x = 0, y = 1, z = 0 }
  local toLength = math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
  if toLength < 0.001 then return 0, 0, 0 end
  local to = { x = direction.x / toLength, y = direction.y / toLength, z = direction.z / toLength }
  local axis = {
    x = from.y * to.z - from.z * to.y,
    y = from.z * to.x - from.x * to.z,
    z = from.x * to.y - from.y * to.x,
  }
  local axisLength = math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
  local dot = math.max(-1, math.min(1, from.x * to.x + from.y * to.y + from.z * to.z))
  local angle = math.acos(dot)
  if axisLength < 0.001 then return dot < 0 and 180 or 0, 0, 0 end
  axis.x, axis.y, axis.z = axis.x / axisLength, axis.y / axisLength, axis.z / axisLength
  local s, c, t = math.sin(angle), math.cos(angle), 1 - math.cos(angle)
  local r11 = t * axis.x * axis.x + c
  local r21 = t * axis.x * axis.y + s * axis.z
  local r31 = t * axis.x * axis.z - s * axis.y
  local r32 = t * axis.y * axis.z + s * axis.x
  local r33 = t * axis.z * axis.z + c
  local y = math.asin(math.max(-1, math.min(1, -r31)))
  local function atan2(yValue, xValue)
    if math.atan2 then return math.atan2(yValue, xValue) end
    if xValue > 0 then return math.atan(yValue / xValue) end
    if xValue < 0 and yValue >= 0 then return math.atan(yValue / xValue) + math.pi end
    if xValue < 0 and yValue < 0 then return math.atan(yValue / xValue) - math.pi end
    if xValue == 0 and yValue > 0 then return math.pi / 2 end
    if xValue == 0 and yValue < 0 then return -math.pi / 2 end
    return 0
  end
  local x = atan2(r32, r33)
  local z = atan2(r21, r11)
  return math.deg(x), math.deg(y), math.deg(z)
end

local function addLine(lines, first, second)
  lines[#lines + 1] = {
    from = { x = first.x, y = first.y, z = first.z },
    to = { x = second.x, y = second.y, z = second.z },
  }
end

local function vectorLength(value)
  return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

local function normalize(value, fallback)
  local magnitude = vectorLength(value)
  if magnitude <= 0.000001 or magnitude ~= magnitude or magnitude == math.huge then
    return fallback or { x = 0, y = 1, z = 0 }
  end
  return { x = value.x / magnitude, y = value.y / magnitude, z = value.z / magnitude }
end

local function cross(first, second)
  return { x = first.y * second.z - first.z * second.y,
    y = first.z * second.x - first.x * second.z,
    z = first.x * second.y - first.y * second.x }
end

local function addScaled(origin, first, firstScale, second, secondScale)
  return { x = origin.x + first.x * firstScale + second.x * secondScale,
    y = origin.y + first.y * firstScale + second.y * secondScale,
    z = origin.z + first.z * firstScale + second.z * secondScale }
end

local function appendRing(lines, center, firstAxis, secondAxis, radius)
  local previous
  for index = 0, WIRE_SEGMENTS do
    local angle = index * math.pi * 2 / WIRE_SEGMENTS
    local current = addScaled(center, firstAxis, math.cos(angle) * radius,
      secondAxis, math.sin(angle) * radius)
    if previous then addLine(lines, previous, current) end
    previous = current
  end
end

function physicsGizmos.colliderLines(collider)
  collider = type(collider) == "table" and collider or {}
  local offset = collider.offset or {}
  local center = { x = tonumber(offset.x) or 0, y = tonumber(offset.y) or 0, z = tonumber(offset.z) or 0 }
  local radius = math.max(0.001, tonumber(collider.radius) or 0.5)
  local lines = {}
  if collider.shape ~= "capsule" then
    appendRing(lines, center, { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, radius)
    appendRing(lines, center, { x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }, radius)
    appendRing(lines, center, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }, radius)
    return lines
  end

  local axisSource = collider.axis or { x = 0, y = 1, z = 0 }
  local axis = normalize({ x = tonumber(axisSource.x) or 0, y = tonumber(axisSource.y) or 0,
    z = tonumber(axisSource.z) or 0 })
  local height = math.max(0, tonumber(collider.height) or 0)
  if height <= 0.0001 then
    appendRing(lines, center, { x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }, radius)
    appendRing(lines, center, { x = 1, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }, radius)
    appendRing(lines, center, { x = 0, y = 1, z = 0 }, { x = 0, y = 0, z = 1 }, radius)
    return lines
  end

  local reference = math.abs(axis.x) < 0.75 and { x = 1, y = 0, z = 0 } or { x = 0, y = 1, z = 0 }
  local firstAxis = normalize(cross(axis, reference), { x = 0, y = 0, z = 1 })
  local secondAxis = normalize(cross(axis, firstAxis), { x = 1, y = 0, z = 0 })
  local halfHeight = height * 0.5
  local negativeCenter = { x = center.x - axis.x * halfHeight,
    y = center.y - axis.y * halfHeight, z = center.z - axis.z * halfHeight }
  local positiveCenter = { x = center.x + axis.x * halfHeight,
    y = center.y + axis.y * halfHeight, z = center.z + axis.z * halfHeight }
  appendRing(lines, negativeCenter, firstAxis, secondAxis, radius)
  appendRing(lines, positiveCenter, firstAxis, secondAxis, radius)
  for index = 0, WIRE_SEGMENTS - 1 do
    local angle = index * math.pi * 2 / WIRE_SEGMENTS
    local radialFirst, radialSecond = math.cos(angle) * radius, math.sin(angle) * radius
    addLine(lines, addScaled(negativeCenter, firstAxis, radialFirst, secondAxis, radialSecond),
      addScaled(positiveCenter, firstAxis, radialFirst, secondAxis, radialSecond))
  end
  return lines
end

local function createTexture()
  local ok, texture = pcall(function() return textures:newTexture("PhysBoneV2GizmoWhite", 1, 1) end)
  if not ok or not texture then return nil end
  safeCall(texture, "setPixel", 0, 0, vec(1, 1, 1, 1))
  safeCall(texture, "update")
  return texture
end

local function addBeam(parent, texture, name, color, length, direction, position)
  local group = safeCall(parent, "newPart", name)
  if not group then return nil end
  local pitch, yaw, roll = vectorToEuler(direction)
  if position then safeCall(group, "setPos", position.x, position.y, position.z) end
  safeCall(group, "setRot", pitch, yaw, roll)
  safeCall(group, "setScale", 1, math.max(0.05, length), 1)
  for index = 1, 4 do
    local sprite = safeCall(group, "newSprite", name .. "Face" .. index)
    if sprite then
      safeCall(sprite, "setTexture", texture, 1, 1)
      safeCall(sprite, "setColor", color[1], color[2], color[3])
      safeCall(sprite, "setRenderType", "EMISSIVE_SOLID")
      local angle = (index - 1) * 90
      local matrix = matrices.mat4():translate(0.5, 0, 0.5):scale(0.10, 1, 0.10):rotate(0, angle, 0) * 0.12
      safeCall(sprite, "setMatrix", matrix)
    end
  end
  return group
end

local function addMarker(parent, texture, name, color)
  local marker = safeCall(parent, "newPart", name, "Camera")
  local sprite = marker and safeCall(marker, "newSprite", name .. "Sprite")
  if not sprite then return marker end
  safeCall(sprite, "setTexture", texture, 1, 1)
  safeCall(sprite, "setColor", color[1], color[2], color[3])
  safeCall(sprite, "setRenderType", "EMISSIVE_SOLID")
  safeCall(sprite, "setMatrix", matrices.mat4():translate(0.5, 0.5, 0.5):scale(0.16, 0.16, 0.16) * 0.1)
  return marker
end

function physicsGizmos.new()
  return {
    visible = false,
    roots = {},
    entries = {},
    colliderRoots = {},
    colliderEntries = {},
    texture = nil,
    chainsRef = nil,
    selectedRootKey = nil,
    settingsRef = nil,
    uiRevision = nil,
    page = nil,
    colliderMode = nil,
    selectedColliderId = nil,
    colliderScope = nil,
    colliderVisible = false,
    colliderKey = nil,
    colliderNode = nil,
    colliderObject = nil,
    colliderRevision = nil,
  }
end

local function clearColliderLines(manager)
  for _, root in ipairs(manager.colliderRoots or {}) do safeCall(root, "remove") end
  manager.colliderRoots, manager.colliderEntries = {}, {}
  manager.colliderKey, manager.colliderNode, manager.colliderObject = nil, nil, nil
  manager.colliderRevision = nil
end

function physicsGizmos.clear(manager)
  if not manager then return end
  for _, root in ipairs(manager.roots or {}) do safeCall(root, "remove") end
  clearColliderLines(manager)
  manager.roots, manager.entries = {}, {}
  manager.chainsRef, manager.selectedRootKey = nil, nil
  manager.settingsRef, manager.uiRevision = nil, nil
  manager.page, manager.colliderMode, manager.selectedColliderId, manager.colliderScope = nil, nil, nil, nil
  manager.colliderVisible = false
end

function physicsGizmos.editorState(ui, registry, registryApi)
  ui = type(ui) == "table" and ui or {}
  registry = type(registry) == "table" and registry or {}
  registryApi = type(registryApi) == "table" and registryApi or {}
  local component = type(ui.selection) == "function" and ui:selection() or nil
  local selectedRootKey = component and type(registryApi.pathKey) == "function"
    and registryApi.pathKey(component.rootPath) or nil
  local collider, _, _, scope
  if type(ui.selectedCollider) == "function" then collider, _, _, scope = ui:selectedCollider() end
  scope = scope or ui.colliderScope or "component"
  local node
  if collider and collider.path and type(registryApi.pathKey) == "function" then
    local key = registryApi.pathKey(collider.path)
    node = registry.byKey and registry.byKey[key] or nil
  end
  local colliderId = collider and collider.id or ui.selectedColliderId
  local colliderKey = collider and (tostring(scope) .. ":" .. tostring(colliderId)) or nil
  local showCollider = ui.open == true and collider ~= nil and node ~= nil
    and (ui.page == "colliders" or ui.colliderMode == true)
  return {
    selectedRootKey = selectedRootKey,
    selectedCollider = collider,
    selectedColliderNode = node,
    selectedColliderKey = colliderKey,
    settingsRef = ui.draft,
    uiRevision = tonumber(ui.revision) or 0,
    page = ui.page,
    colliderMode = ui.colliderMode,
    selectedColliderId = ui.selectedColliderId,
    colliderScope = scope,
    showCollider = showCollider,
  }
end

local function updateColliderLine(entry, line)
  local dx, dy, dz = line.to.x - line.from.x, line.to.y - line.from.y, line.to.z - line.from.z
  local length = math.sqrt(dx * dx + dy * dy + dz * dz)
  local pitch, yaw, roll = vectorToEuler({ x = dx, y = dy, z = dz })
  safeCall(entry.root, "setPos", (line.from.x + line.to.x) * 0.5,
    (line.from.y + line.to.y) * 0.5, (line.from.z + line.to.z) * 0.5)
  safeCall(entry.root, "setRot", pitch, yaw, roll)
  safeCall(entry.root, "setScale", 1, math.max(0.001, length), 1)
end

local function setColliderLines(manager, texture, collider, node, key, revision)
  if not collider or not node or not node.part then
    clearColliderLines(manager)
    return
  end
  if manager.colliderKey ~= key or manager.colliderNode ~= node then
    clearColliderLines(manager)
    manager.colliderKey, manager.colliderNode = key, node
    local lines = physicsGizmos.colliderLines(collider)
    for index, line in ipairs(lines) do
      local midpoint = { x = (line.from.x + line.to.x) * 0.5,
        y = (line.from.y + line.to.y) * 0.5, z = (line.from.z + line.to.z) * 0.5 }
      local direction = { x = line.to.x - line.from.x,
        y = line.to.y - line.from.y, z = line.to.z - line.from.z }
      local beam = addBeam(node.part, texture, "PhysBoneV2Collider_" .. index,
        { 1, 0.3, 0.12 }, vectorLength(direction), direction, midpoint)
      if beam then
        manager.colliderRoots[#manager.colliderRoots + 1] = beam
        manager.colliderEntries[#manager.colliderEntries + 1] = { root = beam }
      end
    end
    manager.colliderObject, manager.colliderRevision = collider, revision
    return
  end
  if manager.colliderObject == collider and manager.colliderRevision == revision then return end
  local lines = physicsGizmos.colliderLines(collider)
  if #lines ~= #manager.colliderEntries then
    clearColliderLines(manager)
    setColliderLines(manager, texture, collider, node, key, revision)
    return
  end
  for index, line in ipairs(lines) do updateColliderLine(manager.colliderEntries[index], line) end
  manager.colliderObject, manager.colliderRevision = collider, revision
end

function physicsGizmos.setVisible(manager, chains, visible, selectedRootKey,
    selectedCollider, selectedColliderNode, selectedColliderKey, settingsRef, uiRevision,
    page, colliderMode, selectedColliderId, colliderScope, showCollider)
  if not manager then return end
  local shouldShow = visible == true
  if not shouldShow then
    manager.visible = false
    manager.colliderVisible = false
    for _, root in ipairs(manager.roots or {}) do safeCall(root, "setVisible", false) end
    for _, root in ipairs(manager.colliderRoots or {}) do safeCall(root, "setVisible", false) end
    return
  end
  manager.visible = true
  local rebuildChains = manager.chainsRef ~= chains or manager.selectedRootKey ~= selectedRootKey
  if rebuildChains then physicsGizmos.clear(manager); manager.visible = true end
  manager.chainsRef, manager.selectedRootKey = chains, selectedRootKey
  manager.settingsRef, manager.uiRevision = settingsRef, uiRevision
  manager.page, manager.colliderMode = page, colliderMode
  manager.selectedColliderId, manager.colliderScope = selectedColliderId, colliderScope
  manager.texture = manager.texture or createTexture()
  if not manager.texture then return end
  if rebuildChains then
    for _, component in ipairs(chains or {}) do
      local color = component.key == selectedRootKey and { 0.2, 1, 0.35 } or { 0.15, 0.65, 1 }
      local graph = component.graph or {}
      for index, node in ipairs(component.linkNodes or {}) do
        local marker = addMarker(node.part, manager.texture, "PhysBoneV2Joint_" .. index, color)
        if marker then
          manager.roots[#manager.roots + 1] = marker
          manager.entries[#manager.entries + 1] = { root = marker, chainKey = component.key, index = index, kind = "joint" }
        end
        for edgeIndex, edge in ipairs((graph.edgesByLink and graph.edgesByLink[index]) or {}) do
          local direction = edge.restVector or { x = 0, y = -1, z = 0 }
          local beam = addBeam(node.part, manager.texture, "PhysBoneV2Link_" .. index .. "_" .. edgeIndex,
            color, edge.restLength or 1, direction)
          if beam then
            manager.roots[#manager.roots + 1] = beam
            manager.entries[#manager.entries + 1] = { root = beam, chainKey = component.key, index = index, kind = "link" }
          end
          if edge.terminal then
            local endpoint = addMarker(node.part, manager.texture, "PhysBoneV2Tip_" .. index, { 1, 0.35, 0.15 })
            if endpoint then
              safeCall(endpoint, "setPos", direction.x, direction.y, direction.z)
              manager.roots[#manager.roots + 1] = endpoint
              manager.entries[#manager.entries + 1] = { root = endpoint, chainKey = component.key, index = index, kind = "endpoint" }
            end
          end
        end
      end
    end
  end
  for _, entry in ipairs(manager.entries or {}) do
    local selected = entry.chainKey == selectedRootKey
    if entry.root then
      safeCall(entry.root, "setVisible", true)
      safeCall(entry.root, "setColor", selected and 0.2 or 0.15, selected and 1 or 0.65, selected and 0.35 or 1)
    end
  end
  local shouldShowCollider = showCollider == true and selectedCollider ~= nil and selectedColliderNode ~= nil
  manager.colliderVisible = shouldShowCollider
  if not shouldShowCollider then
    clearColliderLines(manager)
    return
  end
  setColliderLines(manager, manager.texture, selectedCollider, selectedColliderNode,
    selectedColliderKey, uiRevision)
  for _, root in ipairs(manager.colliderRoots or {}) do safeCall(root, "setVisible", true) end
end

return physicsGizmos

