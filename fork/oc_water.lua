-- v2.0 2026/3/7 fork
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
    IS_PLANT_SHUTDOWN_FROM_RUNNING = false
}
 
-- 机器结构：proxies=代理, parallel=实际并行分配, calc_info=计算详情
local machines = {}
for level = 0, 8 do machines[level] = { proxies = {}, parallel = {}, calc_info = {} } end
local MACHINE_SCAN_RESULT = {}
 
local MAX_SINGLE_PARALLEL = 2147484  -- 单台机器并行数硬上限
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
 
local function clearScreen()
    os.execute(string.find(os.getenv("OS") or "", "Windows") and "cls" or "clear")
end
 
local function printSystemTitle()
    print("================================ 净化水线总控系统 ================================")
end
 
-- 数字千分位格式化
local function formatNumber(num)
    if not num or num == 0 then return "0" end
    local str = tostring(math.floor(num))
    local reversed = string.reverse(str)
    local formatted = string.gsub(reversed, "(%d%d%d)", "%1,")
    formatted = string.reverse(formatted)
    return formatted:sub(1, 1) == "," and formatted:sub(2) or formatted
end
 
-- 初始化确认交互：任意键继续，n退出
local function waitForUserInput(promptMsg)
    print("\n================================ 操作提示 ================================")
    print(promptMsg)
    print("👉 输入 'n' 退出程序，其他任意键直接进入监控")
    io.write("> ")
    local input = io.read():lower()
    if input == "n" or input == "no" then
        print("❌ 用户选择退出程序，正在关闭...")
        os.execute("sleep 1")
        os.exit(0)
    else
        return true
    end
end
 
-- 获取流体存储量
local function getFluidAmount(fluidName)
    if not component.isAvailable("me_interface") then
        print("警告：未检测到ME接口，无法读取流体存储量")
        return 0
    end
    local fluids = component.me_interface.getFluidsInNetwork()
    for _, fluid in ipairs(fluids) do
        if fluid.name == fluidName then return tonumber(fluid.amount) or 0 end
    end
    return 0
end
 
-- 获取最低缺水量等级
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
 
-- 获取监控目标（请求器配置，不含等级选择）
local function loadConfigFromRequesters()
    local levelMaintainers = {}
    for address, _ in component.list("level_maintainer") do
        table.insert(levelMaintainers, component.proxy(address))
    end
    
    local targets = { powerSlots = {}, cacheSlots = {} }
    for reqIndex, maintainer in ipairs(levelMaintainers) do
        for slot = 1, 5 do
            local success, slotData = pcall(maintainer.getSlot, slot)
            if success and slotData and slotData.isEnable then
                if slot == 1 then
                    targets.powerSlots[reqIndex] = {
                        buffer = slotData.quantity or 0,
                        paras = slotData.batch or 0
                    }
                elseif slot >= 2 and slot <= 5 and slotData.isFluid then
                    local fluidName = slotData.fluid and slotData.fluid.name or slotData.name
                    local levelStr = string.match(fluidName:lower(), "grade(%d+)%s*[_-]?%s*purifiedwater")
                    local waterLevel = levelStr and tonumber(levelStr)
                    
                    if waterLevel and waterLevel >= 1 and waterLevel <= 8 then
                        targets.cacheSlots[waterLevel] = {
                            buffer = slotData.quantity or 0,
                            fluidId = fluidName
                        }
                    end
                end
            end
        end
    end
 
    local validPowers = {}
    for reqIndex = 1, 2 do
        local slotInfo = targets.powerSlots[reqIndex]
        if slotInfo then
            local power = slotInfo.buffer * slotInfo.paras
            if power > 0 then table.insert(validPowers, power) end
        end
    end
    
    if #validPowers == 0 then
        local req1Power = targets.powerSlots[1] and (targets.powerSlots[1].buffer * targets.powerSlots[1].paras) or 0
        local req2Power = targets.powerSlots[2] and (targets.powerSlots[2].buffer * targets.powerSlots[2].paras) or 0
        local errMsg = string.format("错误：请求器功率配置无效 | 请求器1：%s | 请求器2：%s",
                          formatNumber(req1Power), formatNumber(req2Power))
        print("🚨 " .. errMsg)
        return false, errMsg
    end
    
    CONFIG.CACHED_LEVELS = {}
    for level = 1, 8 do
        local slotInfo = targets.cacheSlots[level]
        if slotInfo then
            CONFIG.CACHED_CONFIG[level] = {
                threshold = slotInfo.buffer,
                enabled = true,
                fluidId = slotInfo.fluidId
            }
            table.insert(CONFIG.CACHED_LEVELS, level)
        else
            CONFIG.CACHED_CONFIG[level] = { threshold = 0, enabled = false, fluidId = FLUID_NAMES[level] }
        end
    end
    
    CONFIG.TOTAL_POWER = #validPowers == 2 and math.max(validPowers[1], validPowers[2]) or validPowers[1]
    
    print("\n==================== 实时请求器配置 ====================")
    print(string.format("▸ 系统总功率配置：%s EU", formatNumber(CONFIG.TOTAL_POWER)))
    print(string.format("▸ 启用缓存等级：%s（共%d个）", 
        #CONFIG.CACHED_LEVELS > 0 and table.concat(CONFIG.CACHED_LEVELS, "、") or "无",
        #CONFIG.CACHED_LEVELS))
 
    return true
end
 
-- 核心：并行数计算+分配
local function calculateMaxParallel(level)
    local powerPerMachine = POWER_LEVELS[level]
    local deployedMachineCount = #machines[level].proxies
    
    if not powerPerMachine or deployedMachineCount == 0 then 
        machines[level].parallel = {}
        machines[level].calc_info = {}
        return 0 
    end
 
    local totalPowerAvailable = CONFIG.TOTAL_POWER
    local powerBasedMaxParallel = math.floor(totalPowerAvailable / powerPerMachine)
    local theoreticalMaxParallel = math.max(0, powerBasedMaxParallel)
    
    local requiredMachineCount = math.ceil(theoreticalMaxParallel / MAX_SINGLE_PARALLEL)
    local usableMachineCount = math.min(requiredMachineCount, deployedMachineCount)
    local actualTotalParallel = math.min(theoreticalMaxParallel, usableMachineCount * MAX_SINGLE_PARALLEL)
 
    local machineParallels = {}
    if usableMachineCount > 0 and actualTotalParallel > 0 then
        local fullMachineCount = usableMachineCount - 1
        local remainingParallel = actualTotalParallel - (fullMachineCount * MAX_SINGLE_PARALLEL)
        
        for i = 1, fullMachineCount do
            table.insert(machineParallels, MAX_SINGLE_PARALLEL)
        end
        if usableMachineCount >= 1 then
            table.insert(machineParallels, math.max(0, remainingParallel))
        end
    end
 
    machines[level].calc_info = {
        theoretical_max = theoreticalMaxParallel,
        required_machines = requiredMachineCount,
        deployed_machines = deployedMachineCount,
        usable_machines = usableMachineCount,
        actual_total = actualTotalParallel
    }
    
    machines[level].parallel = machineParallels
    return theoreticalMaxParallel
end
 
-- 等级选择交互：1-8跳转，其他任意输入直接退出查看
local function selectLevelForDetail()
    while true do
        clearScreen()
        printSystemTitle()
        print("\n================================ 等级选择 ================================")
        print("📋 操作说明：")
        print("   1~8 → 查看对应等级详情")
        print("   任意键 → 退出查看，进入系统初始化")
        io.write("\n请输入指令：> ")
        
        local input = io.read():lower()
        
        -- 输入1-8数字 → 查看对应等级
        local level = tonumber(input)
        if level and level >= 1 and level <= 8 then
            print("\n==================== T"..level.."级净水单元详细配置 ====================")
            calculateMaxParallel(level)
            local calcInfo = machines[level].calc_info
            local machineParallels = machines[level].parallel
            
            print(string.format("▸ T%d级净水单元（已部署%d台）：", level, #machines[level].proxies))
            print(string.format("  ├ 电量允许的并行上限：%s", formatNumber(calcInfo.theoretical_max)))
            print(string.format("  ├ 理论需要机器数量：%d台（单台上限%s）", 
                calcInfo.required_machines, formatNumber(MAX_SINGLE_PARALLEL)))
            print(string.format("  ├ 实际使用机器数量：%d台 | 实际可运行总并行：%s", 
                calcInfo.usable_machines, formatNumber(calcInfo.actual_total)))
            
            if next(machineParallels) then
                print("  └ 并行数分配规则：")
                for i, p in ipairs(machineParallels) do
                    print(string.format("     机器%d：%s", i, formatNumber(p)))
                end
            end
            
            print("\n----------------------------------------")
            print("输入 1~8 继续查看，输入其他任意键退出查看")
            io.write("请输入：> ")
            local nextInput = io.read():lower()
            
            -- 二次输入：只有1-8继续查看，其他直接退出
            local nextLevel = tonumber(nextInput)
            if not (nextLevel and nextLevel >= 1 and nextLevel <= 8) then
                print("\n✅ 结束等级查看，进入系统初始化...")
                os.execute("sleep 1")
                clearScreen()
                return
            end
        else
            -- 输入n/空/其他字符 → 直接退出查看
            print("\n✅ 结束等级查看，进入系统初始化...")
            os.execute("sleep 1")
            clearScreen()
            return
        end
    end
end
 
-- 打印缓存水量状态
local function printCacheWaterStatus()
    print("\n==================== 缓存水量配置与状态 ====================")
    for _, level in ipairs(CONFIG.CACHED_LEVELS) do
        local fluidName = CONFIG.CACHED_CONFIG[level].fluidId or ("grade"..level.."purifiedwater")
        local current = getFluidAmount(fluidName)
        local expected = CONFIG.CACHED_CONFIG[level].threshold or 0
        local shortage = expected - current
        if current < expected then
            print(string.format("▸ T%d级水：目标 %s mB | 当前 %s mB | 库存不足（缺口 %s mB）%s", 
                level, formatNumber(expected), formatNumber(current), formatNumber(shortage),
                level == CONFIG.LAST_ACTIVE_LEVEL and "【当前生产】" or ""))
        else
            print(string.format("▸ T%d级水：目标 %s mB | 当前 %s mB | 库存充足", 
                level, formatNumber(expected), formatNumber(current)))
        end
    end
end
 
-- 打印运行状态
local function printFullSystemStatus()
    local plantStatus = isWaterPlantRunning()
    print("\n==================== 实时运行状态 ====================")
    print(string.format("▸ 净水主机状态：%s（刷新间隔：%d秒）",
        plantStatus and "运行中" or "已停机（初始状态）",
        plantStatus and CONFIG.CHECK_INTERVAL_RUNNING or CONFIG.CHECK_INTERVAL_STOPPED))
    
    if CONFIG.LAST_ACTIVE_LEVEL then
        local level = CONFIG.LAST_ACTIVE_LEVEL
        local calcInfo = machines[level].calc_info
        local machineParallels = machines[level].parallel
        if next(calcInfo) and next(machineParallels) then
            print(string.format("▸ 生产等级：T%d级净水单元", level))
            print(string.format("  ├ 电量允许的并行上限：%s", formatNumber(calcInfo.theoretical_max)))
            print(string.format("  ├ 理论需要机器数量：%d台（单台上限%s）", 
                calcInfo.required_machines, formatNumber(MAX_SINGLE_PARALLEL)))
            print(string.format("  ├ 已部署机器数量：%d台 | 实际使用：%d台", 
                calcInfo.deployed_machines, calcInfo.usable_machines))
            print(string.format("  ├ 实际可运行总并行数：%s", formatNumber(calcInfo.actual_total)))
            print("  └ 每台机器实际并行数分配：")
            for i, p in ipairs(machineParallels) do
                print(string.format("     机器%d：%s（%s）", i, formatNumber(p),
                    p == MAX_SINGLE_PARALLEL and "已至单台上限" or "承担剩余并行"))
            end
        end
    else
        print("▸ 已开启机器：无（所有等级库存充足）")
    end
    printCacheWaterStatus()
end
 
-- 初始化机器扫描
local function initializeMachines()
    for level = 0, 8 do 
        machines[level].proxies = {}
        machines[level].parallel = {}
        machines[level].calc_info = {}
    end
    local totalMachine = 0
    local levelMachineCount = {}
    
    for address, _ in component.list("gt_machine") do
        local proxy = component.proxy(address)
        local machineName = proxy.getName()
        local level = MACHINE_NAMES[machineName]
        if level then 
            table.insert(machines[level].proxies, proxy)
            totalMachine = totalMachine + 1
            levelMachineCount[level] = (levelMachineCount[level] or 0) + 1
        end
    end
    
    if #machines[0].proxies == 0 then
        print("❌ 初始化失败：未检测到净水厂主机（T0级），请先绑定！")
        return false
    end
    
    MACHINE_SCAN_RESULT.total = totalMachine
    MACHINE_SCAN_RESULT.host = #machines[0].proxies
    MACHINE_SCAN_RESULT.units = levelMachineCount
    
    clearScreen()
    printSystemTitle()
    print("\n==================== 机器扫描结果 ====================")
    print(string.format("▸ 总扫描到净水机器：%d台", MACHINE_SCAN_RESULT.total))
    print(string.format("▸ 净水厂主机（T0级）：%d台", MACHINE_SCAN_RESULT.host))
    print("▸ 净水单元（T1-T8级）：")
    for level = 1, 8 do
        if MACHINE_SCAN_RESULT.units[level] and MACHINE_SCAN_RESULT.units[level] > 0 then
            print(string.format("  └ T%d级：%d台", level, MACHINE_SCAN_RESULT.units[level]))
        end
    end
    return true
end
 
-- 判断净水主机是否运行
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
 
-- 紧急停机所有机器
local function emergencyShutdownAllMachines()
    for level = 1, 8 do
        for _, machine in ipairs(machines[level].proxies) do
            pcall(machine.setWorkAllowed, false)
        end
        machines[level].parallel = {}
        machines[level].calc_info = {}
    end
    CONFIG.LAST_ACTIVE_LEVEL = nil
    CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING = true
    CONFIG.SYSTEM_EMERGENCY_STOPPED = true
    print("🚨 紧急停机：所有净水机器已强制关闭！")
    print("❌ 净水厂主机发生故障！请修复后重启程序")
end
 
-- 启动生产
local function startProduction(level)
    if CONFIG.SYSTEM_EMERGENCY_STOPPED or not level then return false end
    
    for l = 1, 8 do
        if l ~= level then
            for _, machine in ipairs(machines[l].proxies) do
                pcall(machine.setWorkAllowed, false)
            end
            machines[l].parallel = {}
            machines[l].calc_info = {}
        end
    end
    
    local machineCount = #machines[level].proxies
    if machineCount == 0 then
        CONFIG.LAST_ACTIVE_LEVEL = nil
        return false
    end
 
    calculateMaxParallel(level)
    local usableMachineCount = machines[level].calc_info.usable_machines or 0
    local machineParallels = machines[level].parallel or {}
    
    local allStarted = true
    for i, machine in ipairs(machines[level].proxies) do
        if i <= usableMachineCount and machineParallels[i] then
            local success1 = pcall(machine.setWorkAllowed, true)
            local success2 = pcall(machine.setParallel, machineParallels[i])
            if not success1 or not success2 then
                allStarted = false
                print(string.format("⚠️  T%d级机器%d开启/设置并行数失败", level, i))
            end
        else
            pcall(machine.setWorkAllowed, false)
        end
    end
 
    CONFIG.LAST_ACTIVE_LEVEL = level
    return allStarted
end
 
-- 判断是否可以启动生产
local function canStartProduction(level)
    if level == 1 then return true end
    local prevLevel = level - 1
    local prevFluidName = CONFIG.CACHED_CONFIG[prevLevel].fluidId or FLUID_NAMES[prevLevel]
    local prevCurrent = getFluidAmount(prevFluidName)
    local required = 1000 * (machines[level].calc_info.actual_total or 0)
    return prevCurrent >= required
end
 
-- 监控净水主机状态
local function monitorPlantStatus()
    local currentStatus = isWaterPlantRunning()
    local lastStatus = CONFIG.LAST_PLANT_STATUS
    
    if lastStatus == false and currentStatus == true then
        CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING = false
        clearScreen()
        printSystemTitle()
        print("✅ 检测到净水主机已开启！恢复正常生产监控逻辑")
        local lowestLevel = getLowestShortageLevel()
        if lowestLevel then startProduction(lowestLevel) end
    end
    
    if lastStatus == true and currentStatus == false then
        clearScreen()
        printSystemTitle()
        emergencyShutdownAllMachines()
        os.exit(1)
    end
    
    CONFIG.LAST_PLANT_STATUS = currentStatus
    return currentStatus
end
 
-- 系统初始化
local function initialize()
    CONFIG.LAST_PLANT_STATUS = isWaterPlantRunning()
    for level = 1, 8 do
        for _, machine in ipairs(machines[level].proxies) do
            pcall(machine.setWorkAllowed, false)
        end
        machines[level].parallel = {}
        machines[level].calc_info = {}
    end
    CONFIG.LAST_ACTIVE_LEVEL = nil
    
    local initStartLevel = nil
    if not CONFIG.LAST_PLANT_STATUS and not CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING then
        local lowestLevel = getLowestShortageLevel()
        if lowestLevel and canStartProduction(lowestLevel) then
            startProduction(lowestLevel)
            initStartLevel = lowestLevel
        end
    end
    
    clearScreen()
    printSystemTitle()
    print("\n==================== 系统初始化完成 ====================")
    print(string.format("▸ 初始主机状态：%s", CONFIG.LAST_PLANT_STATUS and "运行中" or "已停机"))
    if initStartLevel then
        local calcInfo = machines[initStartLevel].calc_info
        local machineParallels = machines[initStartLevel].parallel
        if next(calcInfo) and next(machineParallels) then
            print(string.format("▸ 初始净水单元状态：T%d级净水单元开启（最低缺水量等级）", initStartLevel))
            print(string.format("  ├ 电量允许并行数上限：%s | 理论需要机器：%d台", 
                formatNumber(calcInfo.theoretical_max), calcInfo.required_machines))
            print(string.format("  ├ 已部署机器：%d台 | 实际使用：%d台", 
                calcInfo.deployed_machines, calcInfo.usable_machines))
            print("  └ 并行数分配：")
            for i, p in ipairs(machineParallels) do
                print(string.format("     机器%d：%s", i, formatNumber(p)))
            end
        end
    else
        print(string.format("▸ 初始净水单元状态：所有净水单元关闭"))
    end
 
    waitForUserInput("系统初始化完成，是否进入主监控程序？")
end
 
-- 主监控循环
local function mainLoop()
    while true do
        if CONFIG.SYSTEM_EMERGENCY_STOPPED then
            break
        end
        
        local configLoaded, errMsg = loadConfigFromRequesters()
        if not configLoaded then
            print("❌ 请求器配置加载失败，本次循环将沿用上次配置（若存在）")
            local interval = CONFIG.LAST_PLANT_STATUS and CONFIG.CHECK_INTERVAL_RUNNING or CONFIG.CHECK_INTERVAL_STOPPED
            os.execute("sleep " .. tostring(interval))
        else
            local isRunning = monitorPlantStatus()
            
            local productionHint = ""
            if not CONFIG.IS_PLANT_SHUTDOWN_FROM_RUNNING then
                local lowestLevel = getLowestShortageLevel()
                if lowestLevel then
                    calculateMaxParallel(lowestLevel)
                    local calcInfo = machines[lowestLevel].calc_info
                    local machineParallels = machines[lowestLevel].parallel
                    local totalParallel = calcInfo.theoretical_max or 0
                    if lowestLevel ~= CONFIG.LAST_ACTIVE_LEVEL then
                        local startSuccess = startProduction(lowestLevel)
                        if startSuccess then
                            productionHint = string.format("\n✅ 已切换至T%d级净水生产（最低缺水量等级）", lowestLevel)
                            productionHint = productionHint .. string.format("\n   ├ 电量允许上限：%s | 理论需要机器：%d台", 
                                formatNumber(totalParallel), calcInfo.required_machines)
                            productionHint = productionHint .. string.format("\n   ├ 实际使用：%d台 | 实际总并行：%s", 
                                calcInfo.usable_machines, formatNumber(calcInfo.actual_total))
                        else
                            productionHint = string.format("\n❌ T%d级（最低缺水量）机器开启失败，无法生产", lowestLevel)
                            productionHint = productionHint .. string.format("\n   ├ 理论并行上限：%s | 需要机器：%d台", 
                                formatNumber(totalParallel), calcInfo.required_machines)
                        end
                    else
                        productionHint = string.format("\n🔄 持续生产T%d级净水（当前最低缺水量等级）", lowestLevel)
                        productionHint = productionHint .. string.format("\n   ├ 电量允许上限：%s | 理论需要机器：%d台", 
                            formatNumber(totalParallel), calcInfo.required_machines)
                        productionHint = productionHint .. string.format("\n   ├ 实际使用：%d台 | 实际总并行：%s", 
                            calcInfo.usable_machines, formatNumber(calcInfo.actual_total))
                    end
                    if next(machineParallels) then
                        productionHint = productionHint .. "\n   └ 并行分配："
                        for i, p in ipairs(machineParallels) do
                            productionHint = productionHint .. string.format(" 机器%d：%s", i, formatNumber(p))
                        end
                    end
                else
                    for level = 1, 8 do
                        for _, machine in ipairs(machines[level].proxies) do
                            pcall(machine.setWorkAllowed, false)
                        end
                        machines[level].parallel = {}
                        machines[level].calc_info = {}
                    end
                    CONFIG.LAST_ACTIVE_LEVEL = nil
                    productionHint = "\n✅ 所有等级水量充足，已强制关闭所有净水机器"
                end
            else
                productionHint = "\n⚠️  主机从运行切至停机，已锁定所有机器（禁止自动开启）"
            end
            
            clearScreen()
            printSystemTitle()
            printFullSystemStatus()
            if productionHint ~= "" then
                print(productionHint)
            end
            
            local interval = isRunning and CONFIG.CHECK_INTERVAL_RUNNING or CONFIG.CHECK_INTERVAL_STOPPED
            os.execute("sleep " .. tostring(interval))
        end
    end
end
 
-- 主程序入口
local function main()
    if not initializeMachines() then
        return
    end
 
    local initConfigLoaded, errMsg = loadConfigFromRequesters()
    if not initConfigLoaded then
        print("❌ 初始化失败：" .. errMsg)
        print("❌ 程序无法继续运行，3秒后退出...")
        os.execute("sleep 3")
        return
    end
 
    selectLevelForDetail()
    initialize()
    mainLoop()
end
 
main()
