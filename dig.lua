local robot_api = require("robot")
local component = require("component")
local computer = require("computer")
local os = require("os")

local swing_count = 0

--检查初始电量(其实就是强制充电)
local current_energy = computer.energy()
local max_energy = computer.maxEnergy()
if current_energy / max_energy < 1.0 then
  -- 向上飞行，直到头顶有方块挡住（up() 返回 false）
  local ascend_height = 0
  while true do
    -- 检测上方是否有方块
    if robot_api.detectUp() then
      break
    end
    local moved = robot_api.up()
    if moved then
      ascend_height = ascend_height + 1
    else
      -- 无法继续上升（被挡住），停止
      break
    end
  end

  -- 等待电量充满到 100%
  while computer.energy() / computer.maxEnergy() < 0.95 do
    os.sleep(5)
  end

  -- 下降回到起飞前的高度
  for i = 1, ascend_height do
    robot_api.down()
  end
end

while true do
  robot_api.swingDown()
  swing_count = swing_count + 1
  os.sleep(0.1)
  if swing_count >= 32 then
    swing_count = 0
    
    -- 检查电量是否低于 10%
    local current_energy = computer.energy()
    local max_energy = computer.maxEnergy()
    if current_energy / max_energy < 0.3 then
      -- 向上飞行，直到头顶有方块挡住（up() 返回 false）
      local ascend_height = 0
      while true do
        -- 检测上方是否有方块
        if robot_api.detectUp() then
          break
        end
        local moved = robot_api.up()
        if moved then
          ascend_height = ascend_height + 1
        else
          -- 无法继续上升（被挡住），停止
          break
        end
      end

      -- 等待电量充满到 100%
      while computer.energy() / computer.maxEnergy() < 0.95 do
        os.sleep(1)
      end

      -- 下降回到起飞前的高度
      for i = 1, ascend_height do
        robot_api.down()
      end
    end
  end
end
