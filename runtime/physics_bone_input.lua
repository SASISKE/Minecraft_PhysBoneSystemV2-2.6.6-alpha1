local sampler = {}
sampler.__index = sampler

local MAX_POSITION_DELTA = 3.0
local MAX_YAW_DELTA = 90.0
local MAX_ACCELERATION = 48.0
local MAX_ROOT_SPEED = 24.0
local MAX_YAW_ACCELERATION = math.rad(900)

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function safeCall(object, method)
  if not object then return nil end
  local fn = object[method]
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, object)
  if ok then return value end
  return nil
end

local function wrapDegrees(value) return (value + 180) % 360 - 180 end

local function clampVector(value, maximum)
  local magnitude = math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
  if not finite(magnitude) or magnitude <= maximum or magnitude < 0.000001 then return value end
  local scale = maximum / magnitude
  return { x = value.x * scale, y = value.y * scale, z = value.z * scale }
end

-- Tracks the actual world-space pivot of an animated component. This lets a
-- body animation move a tail/ear root even when the Minecraft player is still.
local positionTracker = {}
positionTracker.__index = positionTracker

function sampler.newPositionTracker()
  return setmetatable({ previousPos = nil, previousVelocity = nil }, positionTracker)
end

function positionTracker:reset()
  self.previousPos, self.previousVelocity, self.previousDt = nil, nil, nil
end

function positionTracker:sample(position, dt)
  local zero = { x = 0, y = 0, z = 0 }
  if not position or not finite(position.x) or not finite(position.y) or not finite(position.z) then
    self:reset()
    return { available = false, velocity = zero, acceleration = zero }
  end
  dt = tonumber(dt)
  if not finite(dt) or dt <= 0 then dt = 1 / 20 end
  dt = math.max(1 / 240, math.min(0.25, dt))
  local current = { x = position.x, y = position.y, z = position.z }
  local previous = self.previousPos
  local previousVelocity = self.previousVelocity
  self.previousPos = current
  if not previous then
    self.previousVelocity, self.previousDt = nil, nil
    return { available = false, velocity = zero, acceleration = zero }
  end
  local delta = { x = current.x - previous.x, y = current.y - previous.y, z = current.z - previous.z }
  local distance = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
  if not finite(distance) or distance > MAX_POSITION_DELTA then
    self.previousVelocity, self.previousDt = nil, nil
    return { available = false, velocity = zero, acceleration = zero }
  end
  local velocity = clampVector({ x = delta.x / dt, y = delta.y / dt, z = delta.z / dt }, MAX_ROOT_SPEED)
  local acceleration = zero
  if previousVelocity then
    local velocityDt = (dt + (self.previousDt or dt)) * 0.5
    acceleration = clampVector({ x = (velocity.x - previousVelocity.x) / velocityDt,
      y = (velocity.y - previousVelocity.y) / velocityDt, z = (velocity.z - previousVelocity.z) / velocityDt }, MAX_ACCELERATION)
  end
  self.previousVelocity, self.previousDt = velocity, dt
  return { available = true, velocity = velocity, acceleration = acceleration }
end

function sampler.new()
  return setmetatable({ previousPos = nil, previousYaw = nil, previousVelocity = nil, previousYawRate = nil }, sampler)
end

function sampler:reset()
  self.previousPos, self.previousYaw = nil, nil
  self.previousVelocity, self.previousYawRate = nil, nil
end

function sampler:sample(playerObject, bodyYaw, dt)
  local position = safeCall(playerObject, "getPos")
  local yaw = tonumber(bodyYaw)
  if not position or not finite(position.x) or not finite(position.y) or not finite(position.z) or not finite(yaw) then
    self:reset()
    return { rootDelta = { x = 0, y = 0, z = 0 }, rootVelocity = { x = 0, y = 0, z = 0 }, rootAcceleration = { x = 0, y = 0, z = 0 }, rootAngularVelocity = { x = 0, y = 0, z = 0 }, rootYawAcceleration = 0, yawDelta = 0, available = false }
  end
  dt = tonumber(dt)
  if not finite(dt) or dt <= 0 then dt = 1 / 20 end
  dt = math.max(1 / 240, math.min(0.25, dt))
  local current = { x = position.x, y = position.y, z = position.z }
  local output = { rootDelta = { x = 0, y = 0, z = 0 }, rootVelocity = { x = 0, y = 0, z = 0 }, rootAcceleration = { x = 0, y = 0, z = 0 }, rootAngularVelocity = { x = 0, y = 0, z = 0 }, rootYawAcceleration = 0, yawDelta = 0, available = true }
  local nextVelocity, nextYawRate = { x = 0, y = 0, z = 0 }, 0
  if self.previousPos and self.previousYaw then
    local delta = { x = current.x - self.previousPos.x, y = current.y - self.previousPos.y, z = current.z - self.previousPos.z }
    local yawDelta = wrapDegrees(yaw - self.previousYaw)
    local distance = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    if distance <= MAX_POSITION_DELTA and math.abs(yawDelta) <= MAX_YAW_DELTA then
      nextVelocity = { x = delta.x / dt, y = delta.y / dt, z = delta.z / dt }
      nextVelocity = clampVector(nextVelocity, MAX_ROOT_SPEED)
      output.rootVelocity = { x = nextVelocity.x, y = nextVelocity.y, z = nextVelocity.z }
      output.rootDelta = delta
      output.yawDelta = math.rad(yawDelta)
      nextYawRate = output.yawDelta / dt
      if self.previousVelocity then
        output.rootAcceleration = clampVector({
          x = (nextVelocity.x - self.previousVelocity.x) / dt,
          y = (nextVelocity.y - self.previousVelocity.y) / dt,
          z = (nextVelocity.z - self.previousVelocity.z) / dt,
        }, MAX_ACCELERATION)
      end
      if self.previousYawRate then
        output.rootYawAcceleration = math.max(-MAX_YAW_ACCELERATION,
          math.min(MAX_YAW_ACCELERATION, (nextYawRate - self.previousYawRate) / dt))
      end
    end
  end
  output.rootAngularVelocity.y = nextYawRate
  self.previousPos, self.previousYaw = current, yaw
  self.previousVelocity, self.previousYawRate = nextVelocity, nextYawRate
  return output
end

return sampler
