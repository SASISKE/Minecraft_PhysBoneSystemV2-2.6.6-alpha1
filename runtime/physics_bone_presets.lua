local presetsApi = {}

local KINDS = {
  { id = "body", label = "Тело" },
  { id = "hair", label = "Волосы" },
  { id = "ears", label = "Уши" },
  { id = "tail", label = "Хвост" },
  { id = "clothing", label = "Одежда" },
  { id = "accessories", label = "Аксессуары" },
  { id = "custom", label = "Своя" },
}

local PRESETS = {
  { id = "soft_hair", kind = "hair", label = "Мягкие волосы", settings = {
    poseFollow = 0.34, poseFollowFalloff = 1.25,
    pull = 82, spring = 2.0, restitution = 0.16, damping = 13, mass = 0.7, tipMass = 1.5,
    rootMotionResponse = 0.5, motionDrag = 0.35,
    avatarMotionResponse = 0.45, joint = { type = "cone", angle = 24, angularSpeed = 210 },
  } },
  { id = "long_hair", kind = "hair", label = "Длинные волосы", settings = {
    poseFollow = 0.28, poseFollowFalloff = 1.5,
    pull = 42, spring = 0.8, restitution = 0.2, damping = 9, mass = 1.1, tipMass = 2.4,
    rootMotionResponse = 0.7, motionDrag = 0.55,
    avatarMotionResponse = 0.6, joint = { type = "cone", angle = 42, angularSpeed = 270 },
  } },
  { id = "heavy_hair", kind = "hair", label = "Тяжёлые волосы", settings = {
    poseFollow = 0.36, poseFollowFalloff = 1.0,
    pull = 72, spring = 3.2, restitution = 0.12, damping = 17, mass = 2.8, tipMass = 1.7,
    rootMotionResponse = 0.45, motionDrag = 0.65,
    avatarMotionResponse = 0.5, joint = { type = "cone", angle = 19, angularSpeed = 150 },
  } },
  { id = "flexible_ears", kind = "ears", label = "Подвижные уши", settings = {
    poseFollow = 0.46, poseFollowFalloff = 1.1,
    pull = 90, spring = 2.6, restitution = 0.14, damping = 14, mass = 0.75, tipMass = 1.25,
    rootMotionResponse = 0.3, motionDrag = 0.3,
    avatarMotionResponse = 0.65, gravityTiltResponse = 1, restShapeReturn = 0.5,
    joint = { type = "cone", angle = 20, angularSpeed = 180 },
  } },
  { id = "heavy_ears", kind = "ears", label = "Тяжёлые уши", settings = {
    poseFollow = 0.50, poseFollowFalloff = 1.0,
    pull = 105, spring = 4.2, restitution = 0.1, damping = 18, mass = 2.1, tipMass = 1.15,
    rootMotionResponse = 0.25, motionDrag = 0.45,
    avatarMotionResponse = 0.4, gravityTiltResponse = 1, restShapeReturn = 0.5,
    joint = { type = "cone", angle = 14, angularSpeed = 120 },
  } },
  { id = "natural_tail", kind = "tail", label = "Естественный хвост", settings = {
    poseFollow = 0.30, poseFollowFalloff = 1.2,
    pull = 34, spring = 0.8, restitution = 0.2, damping = 9, mass = 1.0, tipMass = 2.1,
    rootMotionResponse = 0.65, motionDrag = 0.55,
    avatarMotionResponse = 0.65, gravityTiltResponse = 1, restShapeReturn = 0.5,
    joint = { type = "cone", angle = 34, angularSpeed = 240 },
  } },
  { id = "heavy_tail", kind = "tail", label = "Тяжёлый хвост", settings = {
    poseFollow = 0.34, poseFollowFalloff = 1.0,
    pull = 52, spring = 2.4, restitution = 0.12, damping = 15, mass = 2.6, tipMass = 1.6,
    rootMotionResponse = 0.7, motionDrag = 0.7,
    avatarMotionResponse = 0.65, gravityTiltResponse = 1, restShapeReturn = 0.5,
    joint = { type = "cone", angle = 24, angularSpeed = 170 },
  } },
  { id = "lightweight_tail", kind = "tail", label = "Лёгкий хвост", settings = {
    poseFollow = 0.24, poseFollowFalloff = 1.4,
    pull = 22, spring = 0.5, restitution = 0.26, damping = 6, mass = 0.45, tipMass = 2.8,
    rootMotionResponse = 0.8, motionDrag = 0.38,
    avatarMotionResponse = 0.85, gravityTiltResponse = 1, restShapeReturn = 0.5,
    joint = { type = "cone", angle = 48, angularSpeed = 320 },
  } },
  { id = "hanging_accessories", kind = "accessories", label = "Свисающие аксессуары", settings = {
    poseFollow = 0.30, poseFollowFalloff = 1.25,
    pull = 38, spring = 1.6, restitution = 0.12, damping = 11, mass = 0.65, tipMass = 1.2,
    rootMotionResponse = 0.45, motionDrag = 0.4,
    avatarMotionResponse = 0.5, joint = { type = "cone", angle = 28, angularSpeed = 180 },
  } },
  { id = "bone_based_clothing", kind = "clothing", label = "Одежда на костях", settings = {
    poseFollow = 0.40, poseFollowFalloff = 1.0,
    pull = 78, spring = 5.5, restitution = 0.08, damping = 17, mass = 0.8, tipMass = 1.0,
    rootMotionResponse = 0.55, motionDrag = 0.25,
    avatarMotionResponse = 0.45, joint = { type = "cone", angle = 12, angularSpeed = 120 },
  } },
}

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

function presetsApi.componentKinds()
  return clone(KINDS)
end

function presetsApi.kindLabel(kind)
  for _, item in ipairs(KINDS) do if item.id == kind then return item.label end end
  return "Своя"
end

function presetsApi.presetsForKind(kind)
  local result = {}
  for _, preset in ipairs(PRESETS) do
    if preset.kind == kind then result[#result + 1] = clone(preset) end
  end
  return result
end

function presetsApi.get(id)
  for _, preset in ipairs(PRESETS) do if preset.id == id then return clone(preset) end end
  return nil
end

return presetsApi
