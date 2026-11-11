local chainApi = {}

local function copyPath(path)
  return path and require("physics_bone_registry").copyPath(path) or nil
end

local function isGroup(node)
  return node and node.partType == "GROUP" and node.transformable == true
end

local function isPathPrefix(prefix, path)
  if type(prefix) ~= "table" or type(path) ~= "table" or #prefix > #path then return false end
  for index, segment in ipairs(prefix) do
    local other = path[index]
    if not other or segment.name ~= other.name or segment.sameNameIndex ~= other.sameNameIndex then return false end
  end
  return true
end

local function vectorBetween(a, b)
  if not a or not b or not a.pivot or not b.pivot then return nil end
  local delta = { x = b.pivot.x - a.pivot.x, y = b.pivot.y - a.pivot.y, z = b.pivot.z - a.pivot.z }
  local length = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
  if length ~= length or length == math.huge or length < 0.001 then return nil end
  return delta, length
end

local function groupChildren(node)
  local result = {}
  for _, child in ipairs(node and node.children or {}) do
    if isGroup(child) then result[#result + 1] = child end
  end
  table.sort(result, function(a, b) return a.key < b.key end)
  return result
end

local function hasTransformableDescendant(node, visited)
  visited = visited or {}
  if not node or visited[node.key] then return false end
  visited[node.key] = true
  for _, child in ipairs(groupChildren(node)) do return true end
  return false
end

local function excluded(path, excludedPaths)
  for _, excludedPath in ipairs(excludedPaths or {}) do
    if isPathPrefix(excludedPath, path) then return true end
  end
  return false
end

function chainApi.build(registry, component)
  if type(registry) ~= "table" or type(registry.byKey) ~= "table" then
    return nil, "реестр модели недоступен"
  end
  if type(component) ~= "table" or type(component.rootPath) ~= "table" then
    return nil, "корень компонента не назначен"
  end
  local rootKey = require("physics_bone_registry").pathKey(component.rootPath)
  local root = registry.byKey[rootKey]
  if not isGroup(root) then return nil, "корень должен быть трансформируемой GROUP ModelPart" end

  local graph = {
    rootKey = rootKey, rootPath = copyPath(root.path), links = {}, linkByKey = {},
    branches = {}, attachments = {}, errors = {}, warnings = {}, complete = true,
  }
  local branchMode = component.branchMode == "all" and "all" or "selected"
  local branchChoices = type(component.branchChoices) == "table" and component.branchChoices or {}
  local excludedPaths = component.excludedPaths or {}
  local maxNodes = math.min(#(registry.flat or {}) + 1, 512)

  local function visit(node, parentIndex, depth)
    if #graph.links >= maxNodes then
      graph.errors[#graph.errors + 1] = "компонент превысил безопасный лимит 512 звеньев"
      graph.complete = false
      return
    end
    if excluded(node.path, excludedPaths) then return end
    local index = #graph.links + 1
    local link = {
      index = index, key = node.key, path = copyPath(node.path), name = node.name,
      part = node.part, parentIndex = parentIndex, depth = depth,
      children = {}, attachments = {}, restVector = nil, restLength = nil,
      endpointSource = nil,
    }
    graph.links[index] = link
    graph.linkByKey[node.key] = link
    if parentIndex then graph.links[parentIndex].children[#graph.links[parentIndex].children + 1] = index end

    local rawChildren = node.children or {}
    local candidates = groupChildren(node)
    local selected
    if branchMode == "all" then
      selected = candidates
    elseif #candidates == 1 then
      selected = candidates
    elseif #candidates > 1 then
      local choiceKey = branchChoices[node.key]
      for _, child in ipairs(candidates) do
        if child.key == choiceKey then selected = { child }; break end
      end
      if not selected then
        local candidates = {}
        for _, child in ipairs(groupChildren(node)) do
          if child.key ~= node.key then
          candidates[#candidates + 1] = { key = child.key, name = child.name, path = copyPath(child.path) }
          end
        end
        graph.branches[#graph.branches + 1] = { parentKey = node.key, parentPath = copyPath(node.path), candidates = candidates }
        graph.complete = false
      end
    end

    local selectedSet = {}
    for _, child in ipairs(selected or {}) do selectedSet[child.key] = true end
    for _, child in ipairs(rawChildren) do
      if not selectedSet[child.key] then
        link.attachments[#link.attachments + 1] = child.key
        graph.attachments[#graph.attachments + 1] = {
          key = child.key, path = copyPath(child.path), parentKey = node.key, name = child.name,
        }
      end
    end

    for _, child in ipairs(selected or {}) do
      if excluded(child.path, excludedPaths) then
        link.attachments[#link.attachments + 1] = child.key
        graph.attachments[#graph.attachments + 1] = {
          key = child.key, path = copyPath(child.path), parentKey = node.key, name = child.name, excluded = true,
        }
      else
        visit(child, index, depth + 1)
      end
    end

    if #link.children == 0 then
      local endpoint = component.endpoint
      if type(endpoint) == "table" and endpoint.mode == "manual" and type(endpoint.vector) == "table" then
        local x, y, z = tonumber(endpoint.vector.x), tonumber(endpoint.vector.y), tonumber(endpoint.vector.z)
        local length = x and y and z and math.sqrt(x * x + y * y + z * z) or 0
        if length >= 0.001 and length < 64 then
          link.restVector = { x = x, y = y, z = z }
          link.restLength = length
          link.endpointSource = "manual"
        else
          graph.errors[#graph.errors + 1] = "конечная точка должна иметь длину от 0.001 до 64 блоков: " .. node.name
          graph.complete = false
        end
      elseif endpoint and endpoint.mode == "child" then
        local direct = {}
        for _, child in ipairs(node.children or {}) do
          local delta, length = vectorBetween(node, child)
          if delta then direct[#direct + 1] = { vector = delta, length = length } end
        end
        if #direct > 0 then link.restVector, link.restLength, link.endpointSource = direct[1].vector, direct[1].length, "child"
        else graph.errors[#graph.errors + 1] = "у конечного звена нет дочернего pivot; задай конечную точку вручную: " .. node.name; graph.complete = false end
      else
        graph.errors[#graph.errors + 1] = "конечную точку звена не удалось определить: " .. node.name
        graph.complete = false
      end
    end
    return index
  end

  visit(root, nil, 0)
  if #graph.links == 0 then return nil, "компонент не содержит физических звеньев" end
  graph.edges = {}
  graph.terminalCount = 0
  for _, link in ipairs(graph.links) do
    if #link.children > 0 then
      for _, childIndex in ipairs(link.children) do
        local child = graph.links[childIndex]
        local delta, length = vectorBetween(registry.byKey[link.key], registry.byKey[child.key])
        if delta then
          graph.edges[#graph.edges + 1] = { from = link.index, to = childIndex, fromLink = link.index, restVector = delta, restLength = length }
        else
          graph.errors[#graph.errors + 1] = "нулевая или недоступная длина сегмента: " .. link.name .. " → " .. child.name
          graph.complete = false
        end
      end
    else
      graph.terminalCount = graph.terminalCount + 1
      local terminalPoint = #graph.links + graph.terminalCount
      local endpoint = link.restVector
      if not endpoint then
        local configEndpoint = component.endpoint and component.endpoint.vector or { x = 0, y = -1, z = 0 }
        endpoint = { x = tonumber(configEndpoint.x) or 0, y = tonumber(configEndpoint.y) or -1, z = tonumber(configEndpoint.z) or 0 }
        local length = math.sqrt(endpoint.x * endpoint.x + endpoint.y * endpoint.y + endpoint.z * endpoint.z)
        if length < 0.001 then endpoint, length = { x = 0, y = -1, z = 0 }, 1 end
        link.restVector, link.restLength = endpoint, length
      end
      graph.edges[#graph.edges + 1] = {
        from = link.index, to = terminalPoint, fromLink = link.index,
        restVector = { x = endpoint.x, y = endpoint.y, z = endpoint.z },
        restLength = link.restLength, terminal = true,
      }
      link.terminalPoint = terminalPoint
    end
  end
  graph.edgesByLink = {}
  for _, edge in ipairs(graph.edges) do
    local byLink = graph.edgesByLink[edge.fromLink]
    if not byLink then byLink = {}; graph.edgesByLink[edge.fromLink] = byLink end
    byLink[#byLink + 1] = edge
  end
  graph.pointCount = #graph.links + graph.terminalCount
  if #graph.branches > 0 then graph.warnings[#graph.warnings + 1] = "выбери ветви перед активацией компонента" end
  return graph
end

function chainApi.findOverlap(existingComponents, candidate)
  local function sameOrContains(a, b)
    return isPathPrefix(a, b) or isPathPrefix(b, a)
  end
  for _, existing in ipairs(existingComponents or {}) do
    if existing and candidate and existing.rootPath and candidate.rootPath
      and sameOrContains(existing.rootPath, candidate.rootPath) then
      return existing.rootPath, "перекрываются корни компонентов"
    end
    for _, link in ipairs(existing and existing.links or {}) do
      for _, candidateLink in ipairs(candidate and candidate.links or {}) do
        if isPathPrefix(link.path, candidateLink.path) and #link.path == #candidateLink.path then
          return link.path, "одно звено назначено двум компонентам"
        end
      end
    end
  end
  return nil
end

function chainApi.pathWithin(parentPath, childPath)
  return isPathPrefix(parentPath, childPath)
end

return chainApi
