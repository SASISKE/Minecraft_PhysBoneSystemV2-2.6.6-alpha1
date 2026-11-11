-- Lightweight Figura instruction sampling plus opt-in render diagnostics.
local diagnosticsApi = {}

local WARNING_RATIO = 0.70
local CRITICAL_RATIO = 0.90
local RECOVERY_RATIO = 0.55
local RECOVERY_SAMPLES = 5

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function getMethod(api, methodName)
  if api == nil then return nil end
  -- Figura APIs may be exposed as Lua userdata proxies rather than tables.
  -- Protect both property lookup and invocation so unsupported API versions
  -- simply report the counter as unavailable.
  local okMethod, method = pcall(function() return api[methodName] end)
  if not okMethod or type(method) ~= "function" then return nil end
  return method
end

local function readCounter(api, method)
  if api == nil or type(method) ~= "function" then return nil end
  local ok, value = pcall(method, api)
  if not ok then return nil end
  value = tonumber(value)
  if not finite(value) or value < 0 then return nil end
  return math.floor(value)
end

local function updatePair(target, api, usedMethod, limitMethod)
  local used, limit = readCounter(api, usedMethod), readCounter(api, limitMethod)
  local ratio = limit and limit > 0 and used and used / limit or nil
  target.used = used
  target.limit = limit
  target.ratio = ratio
  target.warning = ratio ~= nil and ratio > WARNING_RATIO or false
end

local function loadShedScale(diagnostics)
  if diagnostics.timePressure >= 2
    or (diagnostics.instructionPressure and diagnostics.tick.ratio ~= nil
      and diagnostics.tick.ratio >= CRITICAL_RATIO) then return 0.5 end
  if diagnostics.timePressure >= 1 or diagnostics.instructionPressure then return 0.75 end
  return 1
end

function diagnosticsApi.new()
  local diagnostics = {
    enabled = false,
    tick = { used = nil, limit = nil, ratio = nil, warning = false },
    render = { used = nil, limit = nil, ratio = nil, warning = false },
    instructionPressure = false,
    recoverySamples = 0,
    timePressure = 0,
    slowTimeSamples = 0,
    criticalTimeSamples = 0,
    criticalAverageSamples = 0,
    timeRecoverySamples = 0,
    timeWindow = {}, timeWindowIndex = 1, timeWindowSum = 0,
    tickCounterApi = nil,
    renderCounterApi = nil,
    tickUsedMethod = nil,
    tickLimitMethod = nil,
    renderUsedMethod = nil,
    renderLimitMethod = nil,
  }

  function diagnostics:bindTickCounters(api)
    if self.tickCounterApi == api then return end
    self.tickCounterApi = api
    self.tickUsedMethod = getMethod(api, "getTickCount")
    self.tickLimitMethod = getMethod(api, "getMaxTickCount")
  end

  function diagnostics:bindRenderCounters(api)
    if self.renderCounterApi == api then return end
    self.renderCounterApi = api
    self.renderUsedMethod = getMethod(api, "getRenderCount")
    self.renderLimitMethod = getMethod(api, "getMaxRenderCount")
  end

  function diagnostics:setEnabled(enabled)
    self.enabled = enabled == true
    return self.enabled
  end

  function diagnostics:sampleTick(api, lightweight)
    if not self.enabled and lightweight ~= true then return false end
    self:bindTickCounters(api)
    updatePair(self.tick, api, self.tickUsedMethod, self.tickLimitMethod)
    if self.tick.ratio ~= nil then
      if self.tick.warning then
        self.instructionPressure = true
        self.recoverySamples = 0
      elseif self.instructionPressure then
        if self.tick.ratio < RECOVERY_RATIO then
          self.recoverySamples = self.recoverySamples + 1
          if self.recoverySamples >= RECOVERY_SAMPLES then
            self.instructionPressure = false
            self.recoverySamples = 0
          end
        else
          self.recoverySamples = 0
        end
      end
    end
    return self.tick.used ~= nil or self.tick.limit ~= nil
  end

  function diagnostics:sampleRender(api)
    if not self.enabled then return false end
    self:bindRenderCounters(api)
    updatePair(self.render, api, self.renderUsedMethod, self.renderLimitMethod)
    return self.render.used ~= nil or self.render.limit ~= nil
  end

  -- A Figura MAX permission can expose an effectively unlimited instruction
  -- budget, so protect frame time separately using a rolling timing window.
  function diagnostics:sampleSolverTime(milliseconds)
    milliseconds = tonumber(milliseconds)
    if not finite(milliseconds) or milliseconds < 0 then
      self.slowTimeSamples, self.criticalTimeSamples, self.criticalAverageSamples, self.timeRecoverySamples = 0, 0, 0, 0
      self.timeWindow, self.timeWindowIndex, self.timeWindowSum = {}, 1, 0
      return false
    end
    local window, index = self.timeWindow, self.timeWindowIndex
    self.timeWindowSum = self.timeWindowSum - (window[index] or 0) + milliseconds
    window[index] = milliseconds
    self.timeWindowIndex = index % 4 + 1
    local average = self.timeWindowSum / #window
    self.slowTimeSamples = average > 20 and self.slowTimeSamples + 1 or 0
    self.criticalTimeSamples = milliseconds > 35 and self.criticalTimeSamples + 1 or 0
    self.criticalAverageSamples = average > 35 and self.criticalAverageSamples + 1 or 0
    if self.criticalTimeSamples >= 2 or self.criticalAverageSamples >= 2 then
      self.timePressure, self.timeRecoverySamples = 2, 0
    elseif self.slowTimeSamples >= 3 and self.timePressure < 1 then
      self.timePressure, self.timeRecoverySamples = 1, 0
    elseif self.timePressure > 0 then
      local recoveryLimit = self.timePressure == 2 and 20 or 12
      if #window >= 4 and average < recoveryLimit then
        self.timeRecoverySamples = self.timeRecoverySamples + 1
        if self.timeRecoverySamples >= 5 then
          self.timePressure = self.timePressure - 1
          self.timeRecoverySamples = 0
        end
      else
        self.timeRecoverySamples = 0
      end
    end
    return true
  end

  function diagnostics:snapshot()
    local function copy(source)
      return { used = source.used, limit = source.limit, ratio = source.ratio, warning = source.warning }
    end
    return {
      enabled = self.enabled, tick = copy(self.tick), render = copy(self.render),
      instructionPressure = self.instructionPressure, timePressure = self.timePressure,
      loadShedScale = loadShedScale(self),
    }
  end

  function diagnostics:loadShedScale()
    return loadShedScale(self)
  end

  function diagnostics:budgetLimit(configured)
    configured = tonumber(configured)
    if not finite(configured) then return 0 end
    return math.max(0, math.floor(math.max(0, configured) * loadShedScale(self)))
  end

  return diagnostics
end

return diagnosticsApi
