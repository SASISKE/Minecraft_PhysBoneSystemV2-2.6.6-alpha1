-- Reusable sparse 3D grid with numeric coordinate keys for collision hot loops.
local broadphase = {}

local MAX_POOLED_BUCKETS = 4096
local MAX_POOLED_MAPS = 1024

local function wipe(value)
  for key in pairs(value) do value[key] = nil end
end

local function take(pool)
  local value = pool[#pool]
  if value then
    pool[#pool] = nil
    return value
  end
  return {}
end

local function recycle(pool, value, limit)
  if #pool < limit then pool[#pool + 1] = value end
end

function broadphase.new()
  return {
    cells = {},
    activeX = {},
    bucketPool = {},
    mapPool = {},
  }
end

function broadphase.cell(grid, x, y, z, create)
  if type(grid) ~= "table" or type(grid.cells) ~= "table"
    or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
    return nil
  end
  x, y, z = math.floor(x), math.floor(y), math.floor(z)
  local xCells = grid.cells[x]
  if not xCells then
    if create ~= true then return nil end
    xCells = take(grid.mapPool)
    grid.cells[x] = xCells
    grid.activeX[#grid.activeX + 1] = x
  end
  local yCells = xCells[y]
  if not yCells then
    if create ~= true then return nil end
    yCells = take(grid.mapPool)
    xCells[y] = yCells
  end
  local bucket = yCells[z]
  if not bucket and create == true then
    bucket = take(grid.bucketPool)
    yCells[z] = bucket
  end
  return bucket
end

function broadphase.insert(grid, x, y, z, value)
  local bucket = broadphase.cell(grid, x, y, z, true)
  bucket[#bucket + 1] = value
  return bucket
end

function broadphase.clear(grid)
  if type(grid) ~= "table" then return end
  local cells = grid.cells or {}
  local activeX = grid.activeX or {}
  local bucketPool = grid.bucketPool or {}
  local mapPool = grid.mapPool or {}
  for index = #activeX, 1, -1 do
    local x = activeX[index]
    local xCells = cells[x]
    if xCells then
      for y, yCells in pairs(xCells) do
        for z, bucket in pairs(yCells) do
          wipe(bucket)
          recycle(bucketPool, bucket, MAX_POOLED_BUCKETS)
          yCells[z] = nil
        end
        wipe(yCells)
        recycle(mapPool, yCells, MAX_POOLED_MAPS)
        xCells[y] = nil
      end
      wipe(xCells)
      recycle(mapPool, xCells, MAX_POOLED_MAPS)
      cells[x] = nil
      activeX[index] = nil
    end
  end
end

return broadphase
