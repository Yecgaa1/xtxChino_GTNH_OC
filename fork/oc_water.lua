-- v3.0 2026/3/13 fork
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
    
    -- 核心：存储程序计算出的参数，后续逻辑全程使用这些数值
    CALCULATED = {
        SUGGEST_SINGLE_PARALLEL = {}, -- 程序算出的单台建议并行数（即用户设置值）
        SINGLE_MACHINE_POWER = {},     -- 单台机器按建议并行运行的功耗
        LEVEL_TOTAL_POWER = {},         -- 该等级所有机器按建议并行全开的总功耗
        LEVEL_TOTAL_PARALLEL = {}       -- 该等级总并行数
    }
}
 
local machines = {}
for level = 0, 8 do machines[level] = { proxies = {} } end
local MACHINE_SCAN_RESULT = {}
 
local MAX_SINGLE_PARALLEL = 2147484 -- 仅用于计算建议值的硬件上限
local POWER_LEVELS = {
    [1] = 30720, [2] = 30720, [3] = 122880, [4] = 122880,
    [5] = 491520, [6] = 491520, [7] = 1966080, [8] = 7864320
}
 
local FLUID_NAMES = {
    [1] = "grade1purifiedwater", [2] = "grade2purifiedwater",
    [3] = "grade3purifiedwater", [4] = "grade4purifiedwater",
    [5] = "grade5purifiedwater", [6] = "grade6purifiedwater",
    [7] = "grade7purifiedwater", [8] = "grade8purifiedwater"
}
 
local MACHINE_NAMES = {
    ["multimachine.purificationplant"] = 0,
    ["multimachine.purificationunitclarifier"] = 1,
    ["multimachine.purificationunitozonation"] = 2,
    ["multimachine.purificationunitflocculator"] = 3,
    ["multimachine.purificationunitphadjustment"] = 4,
    ["multimachine.purificationunitplasmaheater"] = 5,
    ["multimachine.purificationunituvtreatment"] = 6,
    ["multimachine.purificationunitdegasifier"] = 7,
    ["multimachine.purificationunitextractor"] = 8
}
 
-- ============================================================================
-- 工具函数
-- ============================================================================
local function clearScreen()
    os.execute(string.find(os.getenv("OS") or "", "Windows") and "cls" or "clear")
end
 
local function printSystemTitle()
    print("================================ 净化水线总控系统 ================================")
end
 
local function formatNumber(num)
    if not num or num == 0 then return "0" end
    local str = tostring(math.floor(num))
    local reversed = string.reverse(str)
    local formatted = string.gsub(reversed, "(%d%d%d)", "%1,")
    formatted = string.reverse(formatted)
    return formatted:sub(1, 1) == "," and formatted:sub(2) or formatted
end
 
local function waitForUserInput(promptMsg)
    print("\n================================ 操作提示 ================================")
    print("请确认机器连接情况，")
    print(promptMsg)
    print("输入 'n' 退出程序，输入其他任意键继续运行")
    io.write("> ")
    local input = io.read():lower()
    if input == "n" or input == "no" then
        print("用户选择退出程序，正在关闭...")
        os.execute("sleep 1")
        os.exit(0)
    else
        return true
    end
end
 
local function getFluidAmount(fluidName)
    if not component.isAvailable("me_interface") then return 0 end
    local success, fluids = pcall(component.me_interface.getFluidsInNetwork)
    if not success or not fluids then return 0 end
    for _, fluid in ipairs(fluids) do
        if fluid.name == fluidName then return tonumber(fluid.amount) or 0 end
    end
    return 0
end
 
-- ============================================================================
-- 扫描与初始化 (核心：计算并存档所有运行参数)
-- ============================================================================
 
local function scanAndCalculateTotalPower()
    local totalPower = 0
    local hasValidEnergyHatch = false
    for address, _ in component.list("gt_machine") do
        local proxy = component.proxy(address)
        if not proxy then goto continue end
        local success, machineName = pcall(proxy.getName)
        if not success then goto continue end
 
        if machineName:find("hatch.energytunnel") then
            local maxStored = proxy.getEUCapacity()
            totalPower = totalPower + math.floor(maxStored / 24)
            hasValidEnergyHatch = true
        elseif machineName:find("hatch.energymulti") or machineName:find("hatch.energywirelessmulti") then
            local multiNumStr = machineName:match("tier.(%d+)") or machineName:match("multi(%d+)")
            local multiNum = tonumber(multiNumStr)
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
 
local function loadCacheConfigFromRequesters()
    local levelMaintainers = {}
    for address, _ in component.list("level_maintainer") do
        local proxy = component.proxy(address)
        if proxy then table.insert(levelMaintainers, proxy) end
    end
 
    local cacheSlots = {}
    for _, maintainer in ipairs(levelMaintainers) do
        for slot = 2, 5 do
            local success, slotData = pcall(maintainer.getSlot, slot)
            if success and slotData and slotData.isEnable and slotData.isFluid then
                local fluidName = slotData.fluid and slotData.fluid.name or slotData.name
                local levelStr = string.match(fluidName:lower(), "grade(%d+)%s*[_-]?%s*purifiedwater")
                local waterLevel = levelStr and tonumber(levelStr)
                if waterLevel and waterLevel >= 1 and waterLevel <= 8 then
                    cacheSlots[waterLevel] = { buffer = slotData.quantity or 0, fluidId = fluidName }
                end
            end
        end
    end
 
    CONFIG.CACHED_LEVELS = {}
    for level = 1, 8 do
        local slotInfo = cacheSlots[level]
        if slotInfo then
            CONFIG.CACHED_CONFIG[level] = { threshold = slotInfo.buffer, enabled = true, fluidId = slotInfo.fluidId }
            table.insert(CONFIG.CACHED_LEVELS, level)
        else
            CONFIG.CACHED_CONFIG[level] = { threshold = 0, enabled = false, fluidId = FLUID_NAMES[level] }
        end
    end
    return true
end
 
-- 【核心修复】计算并存储所有等级的运行参数，全程使用此结果
local function calculateAndSaveLevelParams()
    for level = 1, 8 do
        local deployedCount = #machines[level].proxies
        local powerPerParallel = POWER_LEVELS[level]
        
        if deployedCount > 0 and powerPerParallel and powerPerParallel > 0 then
            -- 1. 计算系统总功率允许的总并行上限
            local systemMaxTotalParallel = math.floor(CONFIG.TOTAL_POWER / powerPerParallel)
            
            -- 2. 计算建议单台并行数（总上限 / 机器数，且不超过硬件上限）
            local suggestSingleParallel = math.floor(systemMaxTotalParallel / deployedCount)
            suggestSingleParallel = math.min(suggestSingleParallel, MAX_SINGLE_PARALLEL)
            
            -- 3. 基于建议并行数，计算单台功耗和该等级总功耗
            local singleMachinePower = powerPerParallel * suggestSingleParallel
            local levelTotalPower = deployedCount * singleMachinePower
            local levelTotalParallel = deployedCount * suggestSingleParallel
 
            -- 4. 存入全局配置，后续所有逻辑直接读取这里
            CONFIG.CALCULATED.SUGGEST_SINGLE_PARALLEL[level] = suggestSingleParallel
            CONFIG.CALCULATED.SINGLE_MACHINE_POWER[level] = singleMachinePower
            CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] = levelTotalPower
            CONFIG.CALCULATED.LEVEL_TOTAL_PARALLEL[level] = levelTotalParallel
        else
            CONFIG.CALCULATED.SUGGEST_SINGLE_PARALLEL[level] = 0
            CONFIG.CALCULATED.SINGLE_MACHINE_POWER[level] = 0
            CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] = 0
            CONFIG.CALCULATED.LEVEL_TOTAL_PARALLEL[level] = 0
        end
    end
end
 
-- 等级详情查看界面
local function selectLevelForDetail()
    while true do
        clearScreen()
        printSystemTitle()
        print("\n================================ 等级选择 ================================")
        print(string.format("系统总可用功率：%s EU/t", formatNumber(CONFIG.TOTAL_POWER)))
        print(string.format("单台机器最大并行上限：%s", formatNumber(MAX_SINGLE_PARALLEL)))
        print("\n操作说明：")
        print("   1. 输入 1-8 查看对应等级详细配置与并行设置建议")
        print("   2. 按除数字外任意键直接进入系统初始化")
        io.write("\n请输入操作指令：> ")
        
        local input = io.read():lower()
        local level = tonumber(input)
        if level and level >= 1 and level <= 8 then
            clearScreen()
            printSystemTitle()
            print("\n==================== T"..level.."级净水单元详细配置 ====================")
            local deployedCount = #machines[level].proxies
            local powerPerParallel = POWER_LEVELS[level]
            
            if deployedCount > 0 and powerPerParallel > 0 then
                local calc = CONFIG.CALCULATED
                print(string.format("已部署机器数量：%d 台", deployedCount))
                print(string.format("单并行功耗：%s EU/t", formatNumber(powerPerParallel)))
                print(string.format("单台机器最大并行上限：%s", formatNumber(MAX_SINGLE_PARALLEL)))
                print(string.format("系统总功率允许的总并行上限：%s", formatNumber(math.floor(CONFIG.TOTAL_POWER / powerPerParallel))))
                print("----------------------------------------------------------------------")
                print(string.format("✅ **建议每台设置并行数：%s**", formatNumber(calc.SUGGEST_SINGLE_PARALLEL[level])))
                print(string.format("   （按此设置后，单台功耗：%s EU/t，该等级全开总功耗：%s EU/t）", 
                    formatNumber(calc.SINGLE_MACHINE_POWER[level]), 
                    formatNumber(calc.LEVEL_TOTAL_POWER[level])))
            else
                print(string.format("T%d级净水单元：未部署有效机器", level))
            end
            
            print("\n----------------------------------------")
            print("按任意键返回等级选择界面")
            io.write("> ")
            io.read()
        else
            print("\n结束等级查看，进入系统初始化流程...")
            os.execute("sleep 1")
            clearScreen()
            return
        end
    end
end
 
local function initializeMachinesAndPower()
    for level = 0, 8 do machines[level].proxies = {} end
    local totalMachine = 0
    local levelMachineCount = {}
    
    for address, _ in component.list("gt_machine") do
        local proxy = component.proxy(address)
        if not proxy then goto continue end
        local success, machineName = pcall(proxy.getName)
        if not success then goto continue end
        local level = MACHINE_NAMES[machineName]
        if level then 
            table.insert(machines[level].proxies, proxy)
            totalMachine = totalMachine + 1
            levelMachineCount[level] = (levelMachineCount[level] or 0) + 1
        end
        ::continue::
    end
    
    if #machines[0].proxies == 0 then
        print("初始化失败：未检测到净水厂主机（T0级），请先绑定！")
        return false
    end
    
    MACHINE_SCAN_RESULT.total = totalMachine
    MACHINE_SCAN_RESULT.host = #machines[0].proxies
    MACHINE_SCAN_RESULT.units = levelMachineCount
 
    local hasValidEnergy, totalPower = scanAndCalculateTotalPower()
    
    clearScreen()
    printSystemTitle()
    print("\n==================== 初始化扫描结果 ====================")
    print(string.format("净水机器总数量：%d 台", MACHINE_SCAN_RESULT.total))
    print(string.format("净水厂主机（T0级）：%d 台", MACHINE_SCAN_RESULT.host))
    print("\n净水单元部署情况：")
    for level = 1, 8 do
        local count = MACHINE_SCAN_RESULT.units[level] or 0
        print(string.format("  T%d级：%d 台", level, count))
    end
 
    print("\n供能系统：")
    if hasValidEnergy then
        print(string.format("  系统总可用功率：%s EU/t", formatNumber(totalPower)))
    else
        print("  错误：未检测到任何有效供能方块！")
    end
 
    return hasValidEnergy
end
 
-- ============================================================================
-- 核心逻辑：全程使用 CONFIG.CALCULATED 中的数据
-- ============================================================================
 
function isWaterPlantRunning()
    local plantProxies = machines[0].proxies
    if #plantProxies == 0 then return false end
    for _, plant in ipairs(plantProxies) do
        local success, result = pcall(function()
            if plant.isMachineActive then return plant.isMachineActive() end
            if plant.getEUStored then return plant.getEUStored() > 0 end
            return plant.getName() ~= nil
        end)
        if success and result then return true end
    end
    return false
end
 
local function getLowestShortageLevel()
    local shortageLevels = {}
    for _, level in ipairs(CONFIG.CACHED_LEVELS) do
        local fluidName = CONFIG.CACHED_CONFIG[level].fluidId or ("grade"..level.."purifiedwater")
        local current = getFluidAmount(fluidName)
        local expected = CONFIG.CACHED_CONFIG[level].threshold or 0
        if current < expected then
            table.insert(shortageLevels, level)
        end
    end
    table.sort(shortageLevels)
    return shortageLevels[1]
end
 
-- 原料检查：使用计算出的总并行数
local function checkMaterialSufficient(targetLevel)
    if targetLevel == 1 then return true end
    local inputLevel = targetLevel - 1
    local inputFluid = FLUID_NAMES[inputLevel]
    local currentStock = getFluidAmount(inputFluid)
    local totalParallel = CONFIG.CALCULATED.LEVEL_TOTAL_PARALLEL[targetLevel] or 0
    
    if totalParallel == 0 then return false end
    
    local requiredAmount = totalParallel * 1000
    return currentStock > requiredAmount
end
 
local function isLevelInShortage(level)
    local cfg = CONFIG.CACHED_CONFIG[level]
    if not cfg or not cfg.enabled then return false end
    local fluidName = cfg.fluidId or FLUID_NAMES[level]
    local current = getFluidAmount(fluidName)
    return current < (cfg.threshold or 0)
end
 
-- 功率分配：使用计算出的等级总功耗
local function calculateMultiLevelAllocation(lowestLevel)
    local allocation = {}
    local remainingPower = CONFIG.TOTAL_POWER
 
    if not lowestLevel then return {} end
    
    local lowestLevelPower = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[lowestLevel] or 0
    local machineCount = #machines[lowestLevel].proxies
    
    if lowestLevelPower == 0 or machineCount == 0 then return {} end
 
    -- 第一步：满足最低缺水等级全开（功耗按计算值算）
    if lowestLevelPower > remainingPower then
        return {}
    end
    allocation[lowestLevel] = true
    remainingPower = remainingPower - lowestLevelPower
 
    -- 第二步：剩余功率向下轮询
    if remainingPower > 0 then
        local currentCheckLevel = lowestLevel - 1
        while currentCheckLevel >= 1 do
            local levelPower = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[currentCheckLevel] or 0
            local count = #machines[currentCheckLevel].proxies
            
            if levelPower > 0 and count > 0 then
                if levelPower <= remainingPower and checkMaterialSufficient(currentCheckLevel) then
                    allocation[currentCheckLevel] = true
                    remainingPower = remainingPower - levelPower
                end
            end
            currentCheckLevel = currentCheckLevel - 1
        end
    end
 
    -- 第三步：剩余功率向上轮询
    if remainingPower > 0 then
        for level = lowestLevel + 1, 8 do
            local levelPower = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] or 0
            local count = #machines[level].proxies
            
            if levelPower > 0 and count > 0 and levelPower <= remainingPower then
                if isLevelInShortage(level) and checkMaterialSufficient(level) then
                    allocation[level] = true
                    remainingPower = remainingPower - levelPower
                end
            end
        end
    end
 
    return allocation
end
 
local function isAllocationSame(oldAlloc, newAlloc)
    if type(oldAlloc) ~= "table" or type(newAlloc) ~= "table" then return false end
    for level = 1, 8 do
        if (oldAlloc[level] and true or false) ~= (newAlloc[level] and true or false) then
            return false
        end
    end
    return true
end
 
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
 
local function startProductionByAllocation(allocationPlan)
    if CONFIG.SYSTEM_EMERGENCY_STOPPED or not allocationPlan then
        return false
    end
 
    for level = 1, 8 do
        local shouldEnable = allocationPlan[level] == true
        for _, machine in ipairs(machines[level].proxies) do
            pcall(machine.setWorkAllowed, shouldEnable)
        end
    end
 
    CONFIG.LAST_ACTIVE_LEVEL = allocationPlan
    return true
end
 
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
 
-- 【核心优化】按需求修改了状态显示逻辑
local function printCacheWaterStatus()
    print("\n==================== 缓存水量状态 ====================")
    for _, level in ipairs(CONFIG.CACHED_LEVELS) do
        local fluidName = CONFIG.CACHED_CONFIG[level].fluidId or ("grade"..level.."purifiedwater")
        local current = getFluidAmount(fluidName)
        local expected = CONFIG.CACHED_CONFIG[level].threshold or 0
        local isOn = CONFIG.LAST_ACTIVE_LEVEL and CONFIG.LAST_ACTIVE_LEVEL[level]
        
        local percentage = expected > 0 and (current / expected) * 100 or 0
        local percentStr = string.format("(%.1f%%)", percentage)
        
        -- 优先判断是否在生产中，再显示对应状态
        if isOn then
            if current < expected then
                -- 生产中且库存未达标，保留缺料提示
                print(string.format("T%d级水：目标 %s mB | 当前 %s mB | 库存不足 %s 【生产中】", 
                    level, formatNumber(expected), formatNumber(current), percentStr))
            else
                -- 生产中但库存已达标，改为补充备货提示，替代原有的库存充足
                print(string.format("T%d级水：目标 %s mB | 当前 %s mB | 补充备货 %s 【生产中】", 
                    level, formatNumber(expected), formatNumber(current), percentStr))
            end
        else
            -- 未生产的等级，保留原有库存状态
            if current < expected then
                print(string.format("T%d级水：目标 %s mB | 当前 %s mB | 库存不足 %s", 
                    level, formatNumber(expected), formatNumber(current), percentStr))
            else
                print(string.format("T%d级水：目标 %s mB | 当前 %s mB | 库存充足 %s", 
                    level, formatNumber(expected), formatNumber(current), percentStr))
            end
        end
    end
end
 
local function printFullSystemStatus()
    local plantStatus = isWaterPlantRunning()
    print("\n==================== 实时运行状态 ====================")
    print(string.format("净水主机状态：%s（刷新间隔：%d秒）",
        plantStatus and "运行中" or "已停机",
        plantStatus and CONFIG.CHECK_INTERVAL_RUNNING or CONFIG.CHECK_INTERVAL_STOPPED))
    
    if CONFIG.LAST_ACTIVE_LEVEL and next(CONFIG.LAST_ACTIVE_LEVEL) then
        print("当前开启等级：")
        local totalPowerUsed = 0
        for level = 8, 1, -1 do
            if CONFIG.LAST_ACTIVE_LEVEL[level] then
                local power = CONFIG.CALCULATED.LEVEL_TOTAL_POWER[level] or 0
                totalPowerUsed = totalPowerUsed + power
                print(string.format("  T%d级：开启 (预计耗电 %s EU/t)", level, formatNumber(power)))
            end
        end
        local usagePercent = CONFIG.TOTAL_POWER > 0 and (totalPowerUsed / CONFIG.TOTAL_POWER) * 100 or 0
        print(string.format("  总功率预计：%s / %s EU/t (%.1f%%)", 
            formatNumber(totalPowerUsed), formatNumber(CONFIG.TOTAL_POWER), usagePercent))
    else
        print("已开启机器：无")
    end
    printCacheWaterStatus()
end
 
local function initialize()
    CONFIG.LAST_PLANT_STATUS = isWaterPlantRunning()
    for level = 1, 8 do
        for _, machine in ipairs(machines[level].proxies) do
            pcall(machine.setWorkAllowed, false)
        end
    end
    CONFIG.LAST_ACTIVE_LEVEL = nil
    
    -- 确保参数已计算
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
        for level = 8, 1, -1 do
            if initAllocation[level] then
                print(string.format("  T%d级：开启", level))
            end
        end
    else
        print("初始状态：所有净水单元关闭")
    end
 
    waitForUserInput("系统初始化完成，是否进入主监控程序？")
end
 
local function mainLoop()
    while true do
        if CONFIG.SYSTEM_EMERGENCY_STOPPED then break end
        
        loadCacheConfigFromRequesters()
        local isRunning = monitorPlantStatus()
        local productionHint = ""
        
        if not CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING then
            local lowestLevel = getLowestShortageLevel()
            if lowestLevel then
                local allocationPlan = calculateMultiLevelAllocation(lowestLevel)
                local needApply = not isAllocationSame(CONFIG.LAST_ACTIVE_LEVEL, allocationPlan)
                
                if needApply then
                    startProductionByAllocation(allocationPlan)
                    if next(allocationPlan) then
                        productionHint = "\n已更新生产方案，开启等级："
                        local levels = {}
                        for l in pairs(allocationPlan) do table.insert(levels, l) end
                        table.sort(levels)
                        for _, l in ipairs(levels) do productionHint = productionHint .. " T"..l end
                    else
                        productionHint = string.format("\nT%d级水短缺，但功率不足无法开启生产。", lowestLevel)
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
        
        local interval = isRunning and CONFIG.CHECK_INTERVAL_RUNNING or CONFIG.CHECK_INTERVAL_STOPPED
        os.execute("sleep " .. tostring(interval))
    end
end
 
local function main()
    if not initializeMachinesAndPower() then
        print("初始化失败：供能方块扫描失败或缺失，程序无法运行。")
        os.execute("sleep 3")
        return
    end
 
    loadCacheConfigFromRequesters()
    -- 【关键】在进入配置界面前，先把所有参数算好
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
 
main()
