local os = require("os")
local component = require("component")

local sleepTime = 120 --检测间隔（秒）
local pumpBatch = 64  --此处可设置所有钻机批处理数。设为nil时关闭自动设置。
local allowRandomMine = false
local version = "2.0"

local pumps = {}
local miners = {}
for address, name in component.list("gt_machine") do
    local gtm = component.proxy(address)
    if gtm.getName():match("projectmodulepump(.+)$") then table.insert(pumps, gtm) end
    if gtm.getName():match("projectmoduleminer(.+)$") then table.insert(miners, gtm) end
end

local levelMaintainers = {}
for address, name in component.list("level_maintainer") do
    local maintainer = component.proxy(address)
    table.insert(levelMaintainers, maintainer)
end

local me = component.me_interface
local db = component.database
function GetUtf8Len(str) --获取包含中文的字符串的显示宽度
    local len = 0
    local currentIndex = 1
    while currentIndex <= #str do
        local char = string.byte(str, currentIndex)
        currentIndex = currentIndex + (char > 240 and 4 or char > 225 and 3 or char > 192 and 2 or 1)
        len = len + (char > 192 and 2 or 1)
    end
    return len
end

local function getMonitoringTargets()
    local targets = { items = {}, fluids = {} }
    local processedCount = 0
    -- 去重哈希表：确保相同目标只读取一次
    local existingTargets = {}

    for _, maintainer in ipairs(levelMaintainers) do
        for slot = 1, 5 do
            local success, slotData = pcall(function()
                return maintainer.getSlot(slot)
            end)
            if success and slotData then
                if slotData.isEnable then
                    local target = {
                        id = slotData.name,
                        displayName = slotData.label or slotData.name,
                        buffer = slotData.quantity or 0,
                        paras = slotData.batch or 0,
                        isFluid = slotData.isFluid or false
                    }

                    -- 第一步：先完整解析目标信息（流体/物品）
                    if target.isFluid then
                        target.id = slotData.fluid and slotData.fluid.name or slotData.name
                    else
                        target.damage = slotData.damage or 0
                        local nameFromID, damageFromID = target.id:match("^(.+):(%d+)$")
                        if nameFromID and damageFromID then
                            target.name = nameFromID
                            target.damage = tonumber(damageFromID)
                        else
                            target.name = target.id
                        end
                        if slotData.damage and slotData.damage > 0 then
                            target.damage = slotData.damage
                        end
                    end

                    -- 第二步：生成唯一标识（核心修复：统一在解析后生成，避免覆盖）
                    local uniqueKey = target.id .. (target.damage or 0) .. tostring(target.isFluid)

                    -- 第三步：仅当目标未存在时才添加和打印
                    if not existingTargets[uniqueKey] then
                        existingTargets[uniqueKey] = true -- 标记为已读取

                        -- 添加到目标列表
                        if target.isFluid then
                            table.insert(targets.fluids, target)
                        else
                            table.insert(targets.items, target)
                        end
                        processedCount = processedCount + 1

                        -- 打印目标信息（仅非重复目标）
                        io.write(target.displayName, string.rep(" ", 20 - GetUtf8Len(target.displayName)))
                        print(string.format("%-20d%-20d", target.buffer, target.paras))
                    end
                end
            else
                if not success then
                    print(string.format("[警告] 获取缓存器槽位 %d 数据失败: %s", slot, tostring(slotData)))
                end
            end
        end
    end
    print(string.format("[缓存器] 已读取 %d 个监控目标 (%d 物品, %d 流体)",
        processedCount, #targets.items, #targets.fluids))

    return targets
end

local function getFluidRatio(targetFluids)
    -- 空流体目标时返回空表，避免报错
    if #targetFluids == 0 then
        return {}
    end

    local success, fluids = pcall(function() return me.getFluidsInNetwork() end)
    if not success then return {} end
    fluids = fluids or {}
    local stockRatio = {}
    for _, tfluid in ipairs(targetFluids) do
        table.insert(stockRatio, 0)
        for __, fluid in ipairs(fluids) do
            if fluid and fluid.name == tfluid.id then
                -- 除以0保护
                local buffer = tfluid.buffer ~= 0 and tfluid.buffer or 1
                stockRatio[_] = fluid.amount / buffer
                if stockRatio[_] > 1 and tfluid.paras > 100000 then stockRatio[_] = math.huge end
                break
            end
        end
    end
    io.write("流体名称：              ")
    for _, tfluid in ipairs(targetFluids) do
        io.write(tfluid.displayName,
            string.rep(" ", 20 - GetUtf8Len(tfluid.displayName)))
    end
    io.write("\n流体储量与目标值比例：  ")
    for _, stockRatio1 in ipairs(stockRatio) do
        if stockRatio1 * 100 > 100 then stockRatio1 = 1 end
        local s = string.format("%.6f%%", stockRatio1 * 100)
        io.write(string.format("%-20s", s))
    end
    print()
    return stockRatio
end

local function getItemRatio(targetItems)
    local stockRatio = {}
    for _, item in ipairs(targetItems) do
        local filter = { name = item.name }
        if item.damage and item.damage > 0 then filter.damage = item.damage end

        local success, items = pcall(function() return me.getItemsInNetwork(filter) end)
        if not success then
            print("寻找:", item.name, item.damage, item.displayName, "时出错，退出程序")
            exit(114514)
        end

        items = items or {}
        local currentAmount = 0

        for __, itemStack in ipairs(items) do
            if itemStack and itemStack.name == item.name and (itemStack.damage or 0) == item.damage then
                currentAmount = currentAmount + (itemStack.size or 0)
            end
        end
        -- 除以0保护
        local buffer = item.buffer ~= 0 and item.buffer or 1
        table.insert(stockRatio, currentAmount / buffer)
        if stockRatio[_] > 1 and item.paras > 100000 then stockRatio[_] = math.huge end
    end
    io.write("物品名称：              ")
    for _, tItem in ipairs(targetItems) do
        io.write(tItem.displayName,
            string.rep(" ", 20 - GetUtf8Len(tItem.displayName)))
    end
    io.write("\n物品储量与目标值比例：  ")
    for _, stockRatio1 in ipairs(stockRatio) do
        if stockRatio1 * 100 > 100 then stockRatio1 = 1 end
        local s = string.format("%.6f%%", stockRatio1 * 100)
        io.write(string.format("%-20s", s))
    end
    print()
    return stockRatio
end

local function minIndex(t)
    -- 空表返回nil，避免索引错误
    if #t == 0 then return nil end
    local min_idx = 1
    local min_val = t[1]
    for i = 2, #t do
        if t[i] < min_val then
            min_val = t[i]
            min_idx = i
        end
    end
    return min_idx, min_val
end

local function stopMachine(machines)
    print("正在关闭机器")
    for _, machine in ipairs(machines) do machine.setWorkAllowed(false) end
    local gtmWork = true
    local stoptime = 0
    while gtmWork do
        gtmWork = false
        for _, machine in ipairs(machines) do
            if machine.isMachineActive() then
                gtmWork = true
                break
            end
        end
        os.sleep(1)
        stoptime = stoptime + 1
        if stoptime > 129 then
            print("停机超时")
        end
    end
end

local function adjustPumpFluid(pumps, param1, param2)
    print("正在修改钻机参数", param1, param2)
    for _, pump in ipairs(pumps) do
        for i = 0, 6, 2 do
            pcall(pump.setParameters, i, 0, param1)
            pcall(pump.setParameters, i, 1, param2)
        end
    end
end

local function adjustParameters(machines, idx1, idx2, param)
    print("正在修改参数", idx1, idx2, param)
    for _, machine in ipairs(machines) do
        pcall(machine.setParameters, idx1, idx2, param)
    end
end

local function changeDrone(droneLevel)
    print("正在修改无人机配方，等级：", droneLevel)
    local droneSlot = 2 * (droneLevel - 1) + 1
    if db.get(droneSlot) and db.get(droneSlot + 1) then
        me.setInterfaceConfiguration(1, db.address, droneSlot, 64)
        me.setInterfaceConfiguration(2, db.address, droneSlot + 1, 64)
    else
        print("无人机等级设置失败，数据库槽位读取异常")
    end
end

if pumpBatch then
    stopMachine(pumps)
    adjustParameters(pumps, 9, 1, pumpBatch)
end
-- if plasmaLevel then adjustParameters(miners, 1, 0, minerOC) end
local preFluidPara, preItemPara = 0, 0
while true do
    os.execute("cls")
    print("太空电梯智能控制系统 ", version, "\n==================================\n正在读取监控目标")
    local targets = getMonitoringTargets()
    print("==================================\n正在读取当前库存")
    local fluidIdx, fluidMin = minIndex(getFluidRatio(targets.fluids))
    local itemIdx, itemMin = minIndex(getItemRatio(targets.items))

    -- 检查fluidIdx有效性，避免nil索引
    if fluidIdx and targets.fluids[fluidIdx] then
        if fluidMin < 1 or allowRandomMine then
            local fluidPara = targets.fluids[fluidIdx].paras
            if fluidPara ~= preFluidPara then
                print("==================================\n正在调整全部钻机至：", targets.fluids[fluidIdx].displayName, "参数：",
                    fluidPara)
                stopMachine(pumps)
                adjustPumpFluid(pumps, (fluidPara // 1000) % 100, fluidPara % 1000)
                for _, pump in ipairs(pumps) do pump.setWorkAllowed(true) end
                preFluidPara = fluidPara
            end
        else
            print("当前流体库存充足，无需启动钻机")
            stopMachine(pumps)
        end
    end

    -- 检查itemIdx有效性，避免nil索引
    if itemIdx and targets.items[itemIdx] then
        if itemMin < 1 or allowRandomMine then
            local itemPara = targets.items[itemIdx].paras
            if itemPara ~= preItemPara then --本质上两个列表在比较
                print("==================================\n正在调整全部矿机至：", targets.items[itemIdx].displayName, "参数：",
                    itemPara)
                --检查无人机等级配方
                changeDrone(itemPara // 10000000)
                stopMachine(miners)
                adjustParameters(miners, 0, 0, (itemPara // 10000) % 1000)   --距离
                adjustParameters(miners, 1, 0, (itemPara % 10000) / 1000)    --OD参数
                for _, miner in ipairs(miners) do miner.setWorkAllowed(true) end --重启
                preItemPara = itemPara
            end
        else
            print("当前物品库存充足，无需启动矿机")
            stopMachine(miners)
        end
    end

    print("==================================\n调整完成，等待下一周期")
    os.sleep(sleepTime)
end
