-- v3.2 2026/3/30 fork
local component = require("component")
local sides = require("sides")
local os = require("os")
local io = require("io")
 
local CONFIG = {
    POWER_SWITCH_PORT = sides.west,
    TOTAL_POWER = 0,
    CACHED_CONFIG = {},
    CACHED_LEVELS = {},
    LAST_PLANT_STATUS = nil,
    SYSTEM_EMERGENCY_STOPPED = false,
    LAST_ACTIVE_LEVEL = nil,
    CHECK_INTERVAL_STOPPED = 5,
    CHECK_INTERVAL_RUNNING = 20,
    IS_PLANT_SHUTDOWN_FROM_RUNNING = false,
    CALCULATED = {
        SUGGEST_SINGLE_PARALLEL = {},
        SINGLE_MACHINE_POWER = {},
        LEVEL_TOTAL_POWER = {},
        LEVEL_TOTAL_PARALLEL = {}
    }
}
 
-- 常量配置
local CONST = {
    MAX_STOCK_MULTIPLIER = 5,          -- 库存上限倍率
    RS_SIDE = sides.east,             -- 红石拉杆侧
    MAX_SINGLE_PARALLEL = 2147484,     -- 单台最大并行
    GT_SHOW_LOWER_TIER = 4,            -- GT电压等级计算参数
    MAX_VOLTAGE_VALUE = 2147483640,    -- 最大电压值
    POWER_LEVELS = {                   -- 各等级单并行功耗
        [1] = 30720, [2] = 30720, [3] = 122880, [4] = 122880,
        [5] = 491520, [6] = 491520, [7] = 1966080, [8] = 7864320
    },
    FLUID_NAMES = {                    -- 各等级水流体名
        [1] = "grade1purifiedwater", [2] = "grade2purifiedwater",
        [3] = "grade3purifiedwater", [4] = "grade4purifiedwater",
        [5] = "grade5purifiedwater", [6] = "grade6purifiedwater",
        [7] = "grade7purifiedwater", [8] = "grade8purifiedwater"
    },
    MACHINE_NAMES = {                  -- 机器名对应等级
        ["multimachine.purificationplant"] = 0,
        ["multimachine.purificationunitclarifier"] = 1,
        ["multimachine.purificationunitozonation"] = 2,
        ["multimachine.purificationunitflocculator"] = 3,
        ["multimachine.purificationunitphadjustment"] = 4,
        ["multimachine.purificationunitplasmaheater"] = 5,
        ["multimachine.purificationunituvtreatment"] = 6,
        ["multimachine.purificationunitdegasifier"] = 7,
        ["multimachine.purificationunitextractor"] = 8
    },
    COLOR = {                          -- 颜色配置
        VOLTAGE = "\27[35m",
        RESET = "\27[37m",
        GREEN = "\27[32m",
        RED = "\27[31m"
    },
    VOLTAGE_NAMES = {                  -- 电压等级名
        "ULV", "LV", "MV", "HV", "EV", "IV",
        "LUV", "ZPM", "UV", "UHV", "UEV", "UIV", "UMV","UXV"
    }
}
 
-- 全局变量
local machines = {}
for level = 0, 8 do machines[level] = { proxies = {} } end
local MACHINE_SCAN_RESULT = { total = 0, host = 0, units = {} }
local rsComponent = component.isAvailable("redstone") and component.proxy(component.list("redstone")()) or nil
 
-- ==================== 工具函数 ====================
-- 清屏
local function clearScreen()
    os.execute(string.find(os.getenv("OS") or "", "Windows") and "cls" or "clear")
end
 
-- 打印系统标题
local function printSystemTitle()
    print("================================ 净化水线总控系统 ================================")
end
 
-- 数字格式化
local function formatNumber(num)
    if not num or num == 0 then return "0" end
    local str = tostring(math.floor(num))
    local reversed = string.reverse(str)
    local formatted = string.gsub(reversed, "(%d%d%d)", "%1,")
    return string.reverse(formatted):gsub("^,", "")
end
 
-- 用户输入等待
local function waitForUserInput(promptMsg)
    print("\n================================ 操作提示 ================================")
    print(promptMsg)
    print("输入 'n' 退出程序，输入其他任意键继续运行")
    io.write("> ")
    local input = io.read():lower()
    if input == "n" or input == "no" then
        print("用户选择退出程序，正在关闭...")
        os.execute("sleep 1")
        os.exit(0)
    end
    return true
end
 
-- 获取流体数量
local function getFluidAmount(fluidName)
    if not component.isAvailable("me_interface") then return 0 end
    local success, fluids = pcall(component.me_interface.getFluidsInNetwork)
    if not success or not fluids then return 0 end
    for _, fluid in ipairs(fluids) do
        if fluid.name == fluidName then return tonumber(fluid.amount) or 0 end
    end
    return 0
end
 
-- GT功率格式化
local function getGTInfo(euPerTick, withColor)
    withColor = withColor ~= false
    local voltageNames = CONST.VOLTAGE_NAMES
    local maxVoltageName = "MAX"
    
    if withColor then
        voltageNames = {}
        for _, name in ipairs(CONST.VOLTAGE_NAMES) do
            table.insert(voltageNames, CONST.COLOR.VOLTAGE .. name .. CONST.COLOR.RESET)
        end
        maxVoltageName = CONST.COLOR.VOLTAGE .. maxVoltageName .. CONST.COLOR.RESET
    end
 
    if euPerTick == 0 then
        return "0A " .. voltageNames[1]
    end
 
    local absValue = math.abs(euPerTick)
    if absValue >= CONST.MAX_VOLTAGE_VALUE then
        return string.format("%sA %s", formatNumber(absValue/CONST.MAX_VOLTAGE_VALUE), maxVoltageName)
    end
 
    local voltage_for_tier = absValue / 2 / (4 ^ CONST.GT_SHOW_LOWER_TIER)
    local tier = voltage_for_tier < 4 and 1 or math.floor(math.log(voltage_for_tier) / math.log(4))
    tier = math.max(1, math.min(tier, #voltageNames))
    
    local baseVoltage = 8 * (4 ^ (tier - 1))
    local current = absValue / baseVoltage
    return string.format("%.0fA %s", current, voltageNames[tier])
end
 
-- ==================== 红石控制 ====================
local function isRedstoneActive()
    return rsComponent and rsComponent.getInput(CONST.RS_SIDE) > 0
end
 
-- ==================== 库存/机器状态判断 ====================
-- 判断等级是否超库存上限
local function isLevelOverMaxStock(level)
    local cfg = CONFIG.CACHED_CONFIG[level]
    if not cfg or not cfg.enabled then return true end
    local threshold = cfg.threshold or 0
    if threshold <= 0 then return true end
    local fluidName = cfg.fluidId or CONST.FLUID_NAMES[level]
    return getFluidAmount(fluidName) >= threshold * CONST.MAX_STOCK_MULTIPLIER
end
 
-- 判断等级是否缺水
local function isLevelInShortage(level)
    local cfg = CONFIG.CACHED_CONFIG[level]
    if not cfg or not cfg.enabled then return false end
    local fluidName = cfg.fluidId or CONST.FLUID_NAMES[level]
    local current = getFluidAmount(fluidName)
    return current < (cfg.threshold or 0)
end
 
-- 检查物料是否充足
local function checkMaterialSufficient(targetLevel)
    if targetLevel == 1 then return true end
    local inputLevel = targetLevel - 1
    local inputFluid = CONST.FLUID_NAMES[inputLevel]
    local currentStock = getFluidAmount(inputFluid)
    local totalParallel = CONFIG.CALCULATED.LEVEL_TOTAL_PARALLEL[targetLevel] or 0
    return totalParallel > 0 and currentStock > totalParallel * 1000
end
 
-- 检查主机是否运行
local function isWaterPlantRunning()
    for _, plant in ipairs(machines[0].proxies) do
        local success, result = pcall(function()
            if plant.isMachineActive then return plant.isMachineActive() end
            return plant.getEUStored and plant.getEUStored() > 0
        end)
        if success and result then return true end
    end
    return false
end
 
-- ==================== 核心业务逻辑 ====================
-- 扫描并计算总功率
local function scanAndCalculateTotalPower()
    local totalPower = 0
    local hasValidEnergyHatch = false
    for address, _ in component.list("gt_machine") do
        local proxy = component.proxy(address)
        if not proxy then goto continue end
        local success, machineName = pcall(proxy.getName)
        if not success then goto continue end
        
        if machineName:find("hatch.energytunnel") then
            totalPower = totalPower + math.floor(proxy.getEUCapacity() / 24)
            hasValidEnergyHatch = true
        elseif machineName:find("hatch.energywirelesstunnel") then
            totalPower = totalPower + math.floor(proxy.getEUCapacity() / 4000)
            hasValidEnergyHatch = true
        elseif machineName:find("hatch.energymulti") or machineName:find("hatch.energywirelessmulti") then
            local multiNum = tonumber(machineName:match("tier.(%d+)") or machineName:match("multi(%d+)"))
            local inputVoltage = proxy.getInputVoltage()
            if multiNum and inputVoltage and inputVoltage > 0 then
                totalPower = totalPower + multiNum * inputVoltage
                hasValidEnergyHatch = true
            end
        end
        ::continue::
    end
    CONFIG.TOTAL_POWER = totalPower
    return hasValidEnergyHatch, totalPower
end
 
-- 加载缓存配置
local function loadCacheConfigFromRequesters()
    local cacheSlots = {}
    for address, _ in component.list("level_maintainer") do
        local proxy = component.proxy(address)
        if not proxy then goto continue end
        for slot = 1, 5 do
            local success, slotData = pcall(proxy.getSlot, slot)
            if success and slotData and slotData.isEnable and slotData.isFluid then
                local fluidName = slotData.fluid and slotData.fluid.name or slotData.name
                local level = tonumber(string.match(fluidName:lower(), "grade(%d+)%s*[_-]?%s*purifiedwater"))
                if level and level >= 1 and level <= 8 then
                    cacheSlots[level] = { buffer = slotData.quantity or 0, fluidId = fluidName }
                end
            end
        end
        ::continue::
    end
 
    CONFIG.CACHED_LEVELS = {}
    for level = 1, 8 do
        local slotInfo = cacheSlots[level]
        if slotInfo then
            CONFIG.CACHED_CONFIG[level] = { threshold = slotInfo.buffer, enabled = true, fluidId = slotInfo.fluidId }
            table.insert(CONFIG.CACHED_LEVELS, level)
        else
            CONFIG.CACHED_CONFIG[level] = { threshold = 0, enabled = false, fluidId = CONST.FLUID_NAMES[level] }
        end
    end
    return true
end
 
-- 计算等级参数
local function calculateAndSaveLevelParams()
    for level = 1, 8 do
        local deployedCount = #machines[level].proxies
        local powerPerParallel = CONST.POWER_LEVELS[level] or 0
        
        if deployedCount > 0 and powerPerParallel > 0 then
            local systemMaxTotalParallel = math.floor(CONFIG.TOTAL_POWER / powerPerParallel)
            local suggestSingleParallel = math.min(math.floor(systemMaxTotalParallel / deployedCount), CONST.MAX_SINGLE_PARALLEL)
            
            CONFIG.CALCULATED.SUGGEST_SINGLE_PARALLEL[level] = suggestSingleParallel
            CONFIG.CALCULATED.SINGLE_MACHINE_POWER[level] = powerPerParallel * suggestSingleParallel
            CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] = deployedCount * CONFIG.CALCULATED.SINGLE_MACHINE_POWER[level]
            CONFIG.CALCULATED.LEVEL_TOTAL_PARALLEL[level] = deployedCount * suggestSingleParallel
        else
            CONFIG.CALCULATED.SUGGEST_SINGLE_PARALLEL[level] = 0
            CONFIG.CALCULATED.SINGLE_MACHINE_POWER[level] = 0
            CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] = 0
            CONFIG.CALCULATED.LEVEL_TOTAL_PARALLEL[level] = 0
        end
    end
end
 
-- 选择等级查看详情
local function selectLevelForDetail()
    while true do
        clearScreen()
        printSystemTitle()
        print("\n================================ 等级选择 ================================")
        print(string.format("系统总可用功率：%s EU/t (%s)", formatNumber(CONFIG.TOTAL_POWER), getGTInfo(CONFIG.TOTAL_POWER)))
        print(string.format("单台机器最大并行上限：%s", formatNumber(CONST.MAX_SINGLE_PARALLEL)))
        print("\n操作说明：")
        print("   1. 输入 1-8 查看对应等级详细配置与并行设置建议")
        print("   2. 按除数字外任意键直接进入系统初始化")
        io.write("\n请输入操作指令：> ")
        
        local input = io.read():lower()
        local level = tonumber(input)
        if not (level and level >= 1 and level <= 8) then
            print("\n结束等级查看，进入系统初始化流程...")
            os.execute("sleep 1")
            clearScreen()
            return
        end
 
        clearScreen()
        printSystemTitle()
        print("\n==================== T"..level.."级净水单元详细配置 ====================")
        local deployedCount = #machines[level].proxies
        local powerPerParallel = CONST.POWER_LEVELS[level] or 0
        
        if deployedCount > 0 and powerPerParallel > 0 then
            local calc = CONFIG.CALCULATED
            print(string.format("已部署机器数量：%d 台", deployedCount))
            print(string.format("单并行功耗：%s EU/t (%s)", formatNumber(powerPerParallel), getGTInfo(powerPerParallel)))
            print(string.format("单台机器最大并行上限：%s", formatNumber(CONST.MAX_SINGLE_PARALLEL)))
            print(string.format("系统总功率允许的总并行上限：%s", formatNumber(math.floor(CONFIG.TOTAL_POWER / powerPerParallel))))
            print("----------------------------------------------------------------------")
            print(string.format("✅ **建议每台设置并行数：%s**", formatNumber(calc.SUGGEST_SINGLE_PARALLEL[level])))
            print(string.format("   （按此设置后，单台功耗：%s EU/t (%s)）", 
                formatNumber(calc.SINGLE_MACHINE_POWER[level]), getGTInfo(calc.SINGLE_MACHINE_POWER[level])))
            print(string.format("   （该等级全开总功耗：%s EU/t (%s)）", 
                formatNumber(calc.LEVEL_TOTAL_POWER[level]), getGTInfo(calc.LEVEL_TOTAL_POWER[level])))
        else
            print(string.format("T%d级净水单元：未部署有效机器", level))
        end
        
        print("\n----------------------------------------")
        print("按任意键返回等级选择界面")
        io.write("> ")
        io.read()
    end
end
 
-- 初始化机器和功率
local function initializeMachinesAndPower()
    -- 重置机器列表
    for level = 0, 8 do machines[level].proxies = {} end
    MACHINE_SCAN_RESULT = { total = 0, host = 0, units = {} }
 
    -- 扫描机器
    for address, _ in component.list("gt_machine") do
        local proxy = component.proxy(address)
        if not proxy then goto continue end
        local success, machineName = pcall(proxy.getName)
        if not success then goto continue end
        
        local level = CONST.MACHINE_NAMES[machineName]
        if level then 
            table.insert(machines[level].proxies, proxy)
            MACHINE_SCAN_RESULT.total = MACHINE_SCAN_RESULT.total + 1
            MACHINE_SCAN_RESULT.units[level] = (MACHINE_SCAN_RESULT.units[level] or 0) + 1
            if level == 0 then MACHINE_SCAN_RESULT.host = MACHINE_SCAN_RESULT.host + 1 end
        end
        ::continue::
    end
    
    if #machines[0].proxies == 0 then
        print("初始化失败：未检测到净水厂主机（T0级），请先绑定！")
        return false
    end
 
    -- 扫描功率
    local hasValidEnergy, totalPower = scanAndCalculateTotalPower()
    
    clearScreen()
    printSystemTitle()
    print("\n==================== 初始化扫描结果 ====================")
    print(string.format("净水机器总数量：%d 台", MACHINE_SCAN_RESULT.total))
    print(string.format("净水厂主机（T0级）：%d 台", MACHINE_SCAN_RESULT.host))
    print("\n净水单元部署情况：")
    for level = 1, 8 do
        print(string.format("  T%d级：%d 台", level, MACHINE_SCAN_RESULT.units[level] or 0))
    end
    print("\n供能系统：")
    if hasValidEnergy then
        print(string.format("  系统总可用功率：%s EU/t (%s)", formatNumber(totalPower), getGTInfo(totalPower)))
    else
        print("  错误：未检测到任何有效供能方块！")
    end
    return hasValidEnergy
end
 
-- 获取最低缺水等级
local function getLowestShortageLevel()
    local shortageLevels = {}
    for _, level in ipairs(CONFIG.CACHED_LEVELS) do
        if isLevelInShortage(level) and not isLevelOverMaxStock(level) then
            table.insert(shortageLevels, level)
        end
    end
    table.sort(shortageLevels)
    return shortageLevels[1]
end
 
-- 核心：计算生产分配
local function calculateMultiLevelAllocation(lowestLevel)
    -- 红石激活：全力生产8级水
    if isRedstoneActive() then
        local allocation = {}
        local remainingPower = CONFIG.TOTAL_POWER
        -- 从8级倒推，优先保证8级
        for level = 8, 1, -1 do
            local levelPower = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] or 0
            local machineCount = #machines[level].proxies
            
            if levelPower > 0 and machineCount > 0 and levelPower <= remainingPower then
                local materialOk = level == 1 or checkMaterialSufficient(level)
                if materialOk then
                    allocation[level] = true
                    remainingPower = remainingPower - levelPower
                end
            end
        end
        return allocation
    end
 
    -- 非红石激活：按库存+机器数规则生产
    local allocation = {}
    local remainingPower = CONFIG.TOTAL_POWER
    if not lowestLevel then return allocation end
    
    -- 激活最低缺水等级
    local lowestLevelPower = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[lowestLevel] or 0
    local lowestMachineCount = #machines[lowestLevel].proxies
    if lowestLevelPower > 0 and lowestMachineCount > 0 and lowestLevelPower <= remainingPower and not isLevelOverMaxStock(lowestLevel) then
        allocation[lowestLevel] = true
        remainingPower = remainingPower - lowestLevelPower
    else
        return allocation
    end
 
    -- 向下轮询
    if remainingPower > 0 then
        local currentCheckLevel = lowestLevel - 1
        while currentCheckLevel >= 1 do
            local levelPower = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[currentCheckLevel] or 0
            local count = #machines[currentCheckLevel].proxies
            
            if levelPower > 0 and count > 0 and levelPower <= remainingPower and checkMaterialSufficient(currentCheckLevel) and not isLevelOverMaxStock(currentCheckLevel) then
                allocation[currentCheckLevel] = true
                remainingPower = remainingPower - levelPower
            end
            currentCheckLevel = currentCheckLevel - 1
        end
    end
 
    -- 向上轮询
    if remainingPower > 0 then
        local currentCheckLevel = lowestLevel + 1
        while currentCheckLevel <= 8 do
            local levelPower = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[currentCheckLevel] or 0
            local currMachineCount = #machines[currentCheckLevel].proxies
            local nextLevel = currentCheckLevel + 1
            local nextMachineCount = nextLevel <= 8 and #machines[nextLevel].proxies or 0
 
            -- 所有条件必须同时满足
            local condition = (levelPower > 0) 
                and (currMachineCount > 0) 
                and (levelPower <= remainingPower)
                and isLevelInShortage(currentCheckLevel)
                and not isLevelOverMaxStock(currentCheckLevel)
                and (currMachineCount > nextMachineCount) -- 核心：当前>下一级
            
            if condition then
                allocation[currentCheckLevel] = true
                remainingPower = remainingPower - levelPower
                currentCheckLevel = currentCheckLevel + 1
            else
                break -- 不满足则终止轮询
            end
        end
    end
 
    return allocation
end
 
-- 判断分配是否变化
local function isAllocationSame(oldAlloc, newAlloc)
    if type(oldAlloc) ~= "table" or type(newAlloc) ~= "table" then return false end
    for level = 1, 8 do
        if (oldAlloc[level] or false) ~= (newAlloc[level] or false) then
            return false
        end
    end
    return true
end
 
-- 紧急停机
local function emergencyShutdownAllMachines()
    for level = 1, 8 do
        for _, machine in ipairs(machines[level].proxies) do
            pcall(machine.setWorkAllowed, false)
        end
    end
    CONFIG.LAST_ACTIVE_LEVEL = nil
    CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING = true
    CONFIG.SYSTEM_EMERGENCY_STOPPED = true
    print("紧急停机：所有净水机器已强制关闭！")
end
 
-- 启动生产
local function startProductionByAllocation(allocationPlan)
    if CONFIG.SYSTEM_EMERGENCY_STOPPED or not allocationPlan then return false end
    for level = 1, 8 do
        local shouldEnable = allocationPlan[level] == true
        for _, machine in ipairs(machines[level].proxies) do
            pcall(machine.setWorkAllowed, shouldEnable)
        end
    end
    CONFIG.LAST_ACTIVE_LEVEL = allocationPlan
    return true
end
 
-- 监控主机状态
local function monitorPlantStatus()
    local currentStatus = isWaterPlantRunning()
    if CONFIG.LAST_PLANT_STATUS ~= currentStatus then
        if currentStatus then
            CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING = false
            print("净水主机已恢复运行，解除机器锁定")
        else
            CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING = true
            emergencyShutdownAllMachines()
            print("净水主机停机，已紧急关闭所有净水单元")
        end
        CONFIG.LAST_PLANT_STATUS = currentStatus
    end
    return currentStatus
end
 
-- 打印水量状态
local function printCacheWaterStatus()
    print("\n==================== 缓存水量状态 ====================")
    for _, level in ipairs(CONFIG.CACHED_LEVELS) do
        local cfg = CONFIG.CACHED_CONFIG[level]
        local fluidName = cfg.fluidId or CONST.FLUID_NAMES[level]
        local current = getFluidAmount(fluidName)
        local expected = cfg.threshold or 0
        local isOn = CONFIG.LAST_ACTIVE_LEVEL and CONFIG.LAST_ACTIVE_LEVEL[level]
        local isOverMax = isLevelOverMaxStock(level)
        
        local percentage = expected > 0 and (current / expected) * 100 or 0
        local percentStr = string.format("(%.1f%%)", percentage)
        local statusStr = ""
 
        if isOn then
            statusStr = current < expected and "库存不足 " .. percentStr .. " 【生产中】" or "补充备货 " .. percentStr .. " 【生产中】"
        else
            statusStr = isOverMax and "超上限停产 " .. percentStr or (current < expected and "库存不足 " .. percentStr or "库存充足 " .. percentStr)
        end
 
        print(string.format("T%d级水：目标 %s mB | 当前 %s mB | %s", 
            level, formatNumber(expected), formatNumber(current), statusStr))
    end
end
 
-- 打印系统状态
local function printFullSystemStatus()
    local plantStatus = isWaterPlantRunning()
    print("\n==================== 实时运行状态 ====================")
    print(string.format("净水主机状态：%s（刷新间隔：%d秒）",
        plantStatus and "运行中" or "已停机",
        plantStatus and CONFIG.CHECK_INTERVAL_RUNNING or CONFIG.CHECK_INTERVAL_STOPPED))
    print(string.format("库存停产规则：达到目标阈值 %.0f%% 强制停止生产", CONST.MAX_STOCK_MULTIPLIER * 100))
    local rsActive = isRedstoneActive()
    print(string.format("八级水全力生产模式：%s（%s）",
        rsActive and "激活" or "未激活",
        rsActive and "全力生产8级水" or "按库存/机器数规则生产"))
    
    if CONFIG.LAST_ACTIVE_LEVEL and next(CONFIG.LAST_ACTIVE_LEVEL) then
        print("当前开启等级：")
        local totalPowerUsed = 0
        for level = 8, 1, -1 do
            if CONFIG.LAST_ACTIVE_LEVEL[level] then
                local power = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] or 0
                totalPowerUsed = totalPowerUsed + power
                print(string.format("  T%d级：开启 (预计耗电 %s EU/t | %s)", 
                    level, formatNumber(power), getGTInfo(power)))
            end
        end
        local usagePercent = CONFIG.TOTAL_POWER > 0 and (totalPowerUsed / CONFIG.TOTAL_POWER) * 100 or 0
        print(string.format("  总功率预计：%s / %s EU/t (%.1f%%) | %s", 
            formatNumber(totalPowerUsed), formatNumber(CONFIG.TOTAL_POWER), usagePercent, getGTInfo(totalPowerUsed)))
    else
        print("已开启机器：无")
    end
    printCacheWaterStatus()
end
 
-- 系统初始化
local function initialize()
    CONFIG.LAST_PLANT_STATUS = isWaterPlantRunning()
    -- 初始关闭所有机器
    for level = 1, 8 do
        for _, machine in ipairs(machines[level].proxies) do
            pcall(machine.setWorkAllowed, false)
        end
    end
    CONFIG.LAST_ACTIVE_LEVEL = nil
    
    calculateAndSaveLevelParams()
    
    local initAllocation = nil
    if not CONFIG.LAST_PLANT_STATUS and not CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING then
        local lowestLevel = getLowestShortageLevel()
        if lowestLevel then
            initAllocation = calculateMultiLevelAllocation(lowestLevel)
            if next(initAllocation) then
                startProductionByAllocation(initAllocation)
            end
        end
    end
    
    clearScreen()
    printSystemTitle()
    print("\n==================== 系统初始化完成 ====================")
    print(string.format("初始主机状态：%s", CONFIG.LAST_PLANT_STATUS and "运行中" or "已停机"))
    if initAllocation and next(initAllocation) then
        print("初始生产分配：")
        local totalPowerUsed = 0
        for level = 8, 1, -1 do
            if initAllocation[level] then
                local power = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] or 0
                totalPowerUsed = totalPowerUsed + power
                print(string.format("  T%d级：开启 (预计耗电 %s EU/t | %s)", 
                    level, formatNumber(power), getGTInfo(power)))
            end
        end
        local usagePercent = CONFIG.TOTAL_POWER > 0 and (totalPowerUsed / CONFIG.TOTAL_POWER) * 100 or 0
        print(string.format("  计划总耗电：%s / %s EU/t (%.1f%%) | %s", 
            formatNumber(totalPowerUsed), formatNumber(CONFIG.TOTAL_POWER), usagePercent, getGTInfo(totalPowerUsed)))
    else
        print("初始状态：所有净水单元关闭")
    end
    waitForUserInput("系统初始化完成，是否进入主监控程序？")
end
 
-- 主循环
local function mainLoop()
    while not CONFIG.SYSTEM_EMERGENCY_STOPPED do
        loadCacheConfigFromRequesters()
        local isRunning = monitorPlantStatus()
        local productionHint = ""
        
        if not CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING then
            local lowestLevel = getLowestShortageLevel()
            if lowestLevel then
                local allocationPlan = calculateMultiLevelAllocation(lowestLevel)
                if not isAllocationSame(CONFIG.LAST_ACTIVE_LEVEL, allocationPlan) then
                    startProductionByAllocation(allocationPlan)
                    if next(allocationPlan) then
                        local levels = {}
                        for l in pairs(allocationPlan) do table.insert(levels, l) end
                        table.sort(levels)
                        productionHint = "\n已更新生产方案，开启等级：" .. table.concat(levels, " T")
                    else
                        productionHint = string.format("\nT%d级水短缺，但功率不足/超库存上限无法开启生产。", lowestLevel)
                    end
                else
                    productionHint = "\n生产方案无变化，持续当前运行状态。"
                end
            else
                if CONFIG.LAST_ACTIVE_LEVEL and next(CONFIG.LAST_ACTIVE_LEVEL) then
                    for level = 1, 8 do
                        for _, machine in ipairs(machines[level].proxies) do
                            pcall(machine.setWorkAllowed, false)
                        end
                    end
                    CONFIG.LAST_ACTIVE_LEVEL = nil
                    productionHint = "\n所有等级水量充足，已关闭所有净水机器。"
                else
                    productionHint = "\n所有等级水量充足，机器保持关闭状态。"
                end
            end
        else
            productionHint = "\n主机停机锁定中，无法自动开启机器，请检查主机状态后重启程序。"
        end
        
        clearScreen()
        printSystemTitle()
        printFullSystemStatus()
        if productionHint ~= "" then print(productionHint) end
        
        os.execute("sleep " .. tostring(isRunning and CONFIG.CHECK_INTERVAL_RUNNING or CONFIG.CHECK_INTERVAL_STOPPED))
    end
end
 
-- 主函数
local function main()
    if not initializeMachinesAndPower() then
        print("初始化失败：供能方块扫描失败或缺失，程序无法运行。")
        os.execute("sleep 3")
        return
    end
    loadCacheConfigFromRequesters()
    calculateAndSaveLevelParams()
    
    waitForUserInput("机器扫描完成，是否继续进入配置查看环节？")
    selectLevelForDetail()
    
    clearScreen()
    printSystemTitle()
    print("\n==================== 缓存等级配置 ====================")
    print(string.format("启用等级：%s（共%d个）",
        #CONFIG.CACHED_LEVELS > 0 and table.concat(CONFIG.CACHED_LEVELS, "、") or "无",
        #CONFIG.CACHED_LEVELS))
    
    waitForUserInput("配置加载完成，确认继续？")
    initialize()
    mainLoop()
end
 
-- 启动程序
main()
