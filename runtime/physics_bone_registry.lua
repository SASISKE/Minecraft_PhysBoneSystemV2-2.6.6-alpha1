local registryApi = {}

local function safeCall(object, method, ...)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local args = { ... }
  local ok, value = pcall(fn, object, (table.unpack or unpack)(args))
  if ok then return value end
  return nil
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function nameOf(part)
  local value = safeCall(part, "getName")
  return type(value) == "string" and value or "<unnamed>"
end

local function typeOf(part)
  local value = safeCall(part, "getType")
  return type(value) == "string" and value or "UNKNOWN"
end

local function pivotOf(part)
  local pivot = safeCall(part, "getPivot")
  if not pivot or not finite(pivot.x) or not finite(pivot.y) or not finite(pivot.z) then return nil end
  return { x = pivot.x, y = pivot.y, z = pivot.z }
end

local function escaped(value)
  return tostring(value):gsub("([^%w_%-])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

function registryApi.pathKey(path)
  local parts = {}
  for index, segment in ipairs(path or {}) do
    parts[index] = escaped(segment.name) .. "[" .. tostring(segment.sameNameIndex) .. "]"
  end
  return table.concat(parts, "/")
end

local function copyPath(path)
  if type(path) ~= "table" or #path == 0 then return nil end
  local result = {}
  for index, segment in ipairs(path) do
    if type(segment) ~= "table" or type(segment.name) ~= "string"
      or type(segment.sameNameIndex) ~= "number" or segment.sameNameIndex < 1 then return nil end
    result[index] = { name = segment.name, sameNameIndex = math.floor(segment.sameNameIndex) }
  end
  return result
end

local function childrenOf(part)
  local raw = safeCall(part, "getChildren")
  local children = {}
  if type(raw) ~= "table" then return children end
  for order, child in pairs(raw) do
    if child then
      local pivot = pivotOf(child) or { x = 0, y = 0, z = 0 }
      children[#children + 1] = {
        part = child, name = nameOf(child), partType = typeOf(child), pivot = pivot,
        order = type(order) == "number" and order or (#children + 1),
      }
    end
  end
  table.sort(children, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.partType ~= b.partType then return a.partType < b.partType end
    if a.pivot.x ~= b.pivot.x then return a.pivot.x < b.pivot.x end
    if a.pivot.y ~= b.pivot.y then return a.pivot.y < b.pivot.y end
    if a.pivot.z ~= b.pivot.z then return a.pivot.z < b.pivot.z end
    return a.order < b.order
  end)
  return children
end

local function isTransformable(partType, part)
  return partType == "GROUP" and type(part and part.setOffsetRot) == "function"
end

function registryApi.scan(rootPart)
  if not rootPart then return nil, "не найден корень модели" end
  local result = { root = rootPart, flat = {}, roots = {}, byKey = {} }
  local maxNodes = 4096

  local function visit(part, path, parentKey, depth)
    if depth > 256 then error("иерархия модели глубже безопасного лимита 256") end
    if #result.flat >= maxNodes then error("в модели превышен лимит 4096 ModelPart") end
    local key = registryApi.pathKey(path)
    local partType = typeOf(part)
    local node = {
      key = key, name = nameOf(part), partType = partType, part = part,
      path = copyPath(path), parentKey = parentKey, children = {}, childKeys = {}, depth = depth,
      pivot = pivotOf(part), transformable = isTransformable(partType, part),
    }
    result.flat[#result.flat + 1] = node
    result.byKey[key] = node
    if parentKey then
      local parent = result.byKey[parentKey]
      if parent then
        parent.children[#parent.children + 1] = node
        parent.childKeys[#parent.childKeys + 1] = key
      end
    else
      result.roots[#result.roots + 1] = node
    end

    local sameNameCount = {}
    for _, child in ipairs(childrenOf(part)) do
      local index = (sameNameCount[child.name] or 0) + 1
      sameNameCount[child.name] = index
      local childPath = copyPath(path)
      childPath[#childPath + 1] = { name = child.name, sameNameIndex = index }
      visit(child.part, childPath, key, depth + 1)
    end
  end

  local ok, err = pcall(function()
    visit(rootPart, { { name = nameOf(rootPart), sameNameIndex = 1 } }, nil, 0)
  end)
  if not ok then return nil, tostring(err) end
  return result
end

function registryApi.resolve(rootPart, path)
  local clean = copyPath(path)
  if not rootPart or not clean then return nil, "путь ModelPart некорректен" end
  if clean[1].name ~= nameOf(rootPart) or clean[1].sameNameIndex ~= 1 then
    return nil, "корень пути не совпадает с моделью"
  end
  local current = rootPart
  for pathIndex = 2, #clean do
    local segment = clean[pathIndex]
    local occurrence, found = 0, nil
    for _, child in ipairs(childrenOf(current)) do
      if child.name == segment.name then
        occurrence = occurrence + 1
        if occurrence == segment.sameNameIndex then found = child.part; break end
      end
    end
    if not found then return nil, "часть модели отсутствует: " .. segment.name end
    current = found
  end
  return current
end

function registryApi.copyPath(path)
  return copyPath(path)
end

return registryApi
