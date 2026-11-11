-- Auto-loaded Figura entry point for Physics Bone System v2.
local ok, studio = pcall(require, "physics_bone_studio")
if not ok then
  if type(log) == "function" then pcall(log, "[PhysBone v2] load error: " .. tostring(studio)) end
  return nil
end
return studio
