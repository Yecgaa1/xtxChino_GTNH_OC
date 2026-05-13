-- 2026/5/10 fork
local os = require("os")
local component = require("component")
local sides = require("sides")
 
local mei = component.me_interface
local database = component.database
local gtm = component.gt_machine
local trans = component.transposer
 
local eohSide = sides.east  -- 转运器连接的方向
 
local targetName = ""
local eohTier = 0
local fcFluidDrop = "ae2fc:fluid_drop"
local fluidAmount = 0
local isAstralMode = false
local astralArrayAmount = 0  -- 用于存储星阵模式的数量
local lastAstralArrayAmount = 0  -- 用于存储上一次的星阵数量
 
function getTierFromTransposer()
    local stack = trans.getStackInSlot(eohSide,2)
    local tier = 0
 
    if stack.label then
        tier = tonumber(string.match(stack.label, "%d+")) or 0
    end
 
    return math.min(tier + 1, 10)
end
 
function checkTierUpdate()
    if gtm.getWorkProgress() ~= 0 then
        return
    end
 
    local newTier = getTierFromTransposer()
 
    if newTier ~= eohTier then
        eohTier = newTier
        refreshPattern()
    end
end
 
function generateUniqueName()
    local time = math.floor(os.time())
    local name = "Eoh" .. tostring(time) .. tostring(math.random(100,999))
    return name
end
 
function initF()
    checkPatternVaild(2)
    initDatabase()
 
    -- 读取运行等级
    eohTier = getTierFromTransposer()
 
    -- 生成假合成封包名称
    targetName = generateUniqueName()
    print("自动生成假合成ID: " .. targetName)
 
    initPatern()
    
    -- 读取星阵数量
    local info = gtm.getSensorInformation()
    astralArrayAmount = tonumber(extractNumbersFromInfo(info[16])) or 0
 
    isAstralMode = (astralArrayAmount > 0)
    lastAstralArrayAmount = astralArrayAmount
 
    print("检测到星阵数量: " .. tostring(astralArrayAmount) .. " -> 星阵模式: " .. (isAstralMode and "已启用" or "未启用"))
    refreshPattern()
end
 
function extractNumbersFromInfo(infoString)
    if not infoString then return nil end
    local numbers = {}
    for number in string.gmatch(infoString, "%d+") do
        table.insert(numbers, number)
    end
 
    if #numbers >= 1 then
        table.remove(numbers, 1)
    end
 
    local finalNumber = table.concat(numbers)
    return finalNumber
end
 
function checkPatternVaild(patternCount)
    print("检测样板是否存在,检测样板数: " .. patternCount)
    for i = 1, patternCount do
        local pa = mei.getInterfacePattern(i)
        if not pa then
            print("样板未找到...")
            while true do os.sleep(5) end
        end
    end
end
 
function initDatabase()
    print("初始化数据库...")
    database.set(1, fcFluidDrop, 0, "{Fluid:hydrogen}")
    database.set(2, fcFluidDrop, 0, "{Fluid:helium}")
    database.set(3, fcFluidDrop, 0, "{Fluid:rawstarmatter}")
    mei.storeInterfacePatternOutput(1, 1, database.address, 4)
    mei.storeInterfacePatternOutput(2, 1, database.address, 5)
end
 
function setInput(paSlot, paIndex, entrySlot, amount)
    mei.setInterfacePatternInput(paSlot, database.address, entrySlot, amount, paIndex)
end
 
function setOutput(paSlot, paIndex, entrySlot, amount)
    mei.setInterfacePatternOutput(paSlot, database.address, entrySlot, amount, paIndex)
end
 
function initPatern()
    print("样板假合成命名初始化...")
    local item = database.get(4)
    database.set(4, item.name, item.damage, "{display:{Name:" .. targetName .. "}}")
    item = database.get(5)
    database.set(5, item.name, item.damage, "{display:{Name:" .. targetName .. "-液滴对应的封包}}")
    setOutput(1, 1, 4, 1)
    setOutput(2, 1, 5, 1)
    setInput(1, 1, 5, 1)
end
 
function refreshPattern()
    -- 执行刷新逻辑
    if not isAstralMode then
        fluidAmount = math.pow(10, 9)
        setInput(1, 1, 5, eohTier)    -- 设置假合成液滴封包样板数量
        setInput(2, 1, 1, fluidAmount)  -- 设置氢气数量
        setInput(2, 2, 2, fluidAmount)  -- 设置氦气数量
    else
        -- 星阵模式：计算需要的流体数量
        fluidAmount = math.pow(2, math.floor(math.log(8 * astralArrayAmount) / math.log(1.7))) * 12400 * eohTier
        
        if fluidAmount < math.pow(2, 31) then
            setInput(1, 1, 5, 1)  -- 星阵模式下最小保证有 1 个液滴封包
            setInput(2, 1, 3, fluidAmount)  -- 设置岩浆数量
            setInput(2, 2, 8, 0)  -- 清空第二槽位
        else
            local fac = 2
            while fluidAmount / fac > math.pow(2, 31) do
                fac = fac * 2
            end
            setInput(1, 1, 5, fac)  -- 设置假合成液滴封包样板数量
            setInput(2, 1, 3, math.floor(fluidAmount / fac))
            setInput(2, 2, 8, 0)  -- 清空第二槽位
        end
    end
end
 
function cancelCpu()
    local cpus = mei.getCpus()
    for i = 1, #cpus do
        local out = cpus[i].cpu.finalOutput()
        if out ~= nil then
            if out.label == targetName then
                cpus[i].cpu.cancel()
            end
        end
    end
end
 
function main()
    initF()
    
    while true do
        checkTierUpdate()
 
        local ok, info = pcall(function() return gtm.getSensorInformation() end)
        if ok and info and info[16] then
            local finalNumber = extractNumbersFromInfo(info[16])
            local currentAstralArrayAmount = tonumber(finalNumber) or 0
            if currentAstralArrayAmount ~= lastAstralArrayAmount then
                print("检测到星阵数量变化: 上次=" .. tostring(lastAstralArrayAmount) .. " 现在=" .. tostring(currentAstralArrayAmount))
                astralArrayAmount = currentAstralArrayAmount
                local prevMode = isAstralMode
                isAstralMode = (astralArrayAmount > 0)
                print("星阵模式 -> " .. (isAstralMode and "已启用" or "未启用"))
                refreshPattern()
                lastAstralArrayAmount = astralArrayAmount
            end
        end
 
        if gtm.getWorkProgress() == 0 then
            gtm.setWorkAllowed(true)
            print("当前执行的是" .. (isAstralMode and "星阵模式" or "普通模式") .. ",假合成对应id:" .. targetName)
            print("执行启动流体转运逻辑...")
 
            ::res::            
            local craftables = mei.getCraftables({label = targetName})
            if not craftables or not craftables[1] then
                print("未找到指定假合成: " .. tostring(targetName) .. "，等待10秒后重试...")
                os.sleep(10)
                goto res
            end
 
            local requestOk, resObj = pcall(function() return craftables[1].request(1) end)
            if not requestOk or (resObj and resObj.hasFailed and resObj.hasFailed()) then
                os.sleep(10)
                goto res
            end
 
            while gtm.getWorkProgress() == 0 do
                os.sleep(5)
            end
            print("鸿蒙已经正常开机...")
            cancelCpu()
            print("本次运行开机逻辑结束, 已取消假合成订单供其他OC使用")
            while gtm.getWorkProgress() ~= 0 do
                os.sleep(5)
            end
            gtm.setWorkAllowed(false)
            print("鸿蒙已经结束运行...")
        end
        os.sleep(5)
        os.execute("cls")
    end
end
 
main()