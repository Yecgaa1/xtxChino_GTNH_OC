-- 2026/3/7 fork
local component = require("component")
local event = require("event")
 
local me = nil
local craftingCPUs = {}
local levelMaintainers = {}
 
local function initComponents()
    me = component.me_interface
    if not me then error("未找到ME接口") end
    
    levelMaintainers = {}
    for address, name in component.list("level_maintainer") do
        local maintainer = component.proxy(address)
        table.insert(levelMaintainers, maintainer)
    end
    
    craftingCPUs = {}
    for _, cpu in ipairs(me.getCpus() or {}) do
        if cpu.coprocessors and cpu.coprocessors > 0 then
            table.insert(craftingCPUs, cpu)
        end
    end
    
    if #craftingCPUs == 0 then error("未找到有效合成CPU") end
end
 
local function getMonitoringTargets()
    local targets = {items = {}, fluids = {}}
    local processedCount = 0
    
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
                        craftAmount = slotData.batch or 1,
                        isFluid = slotData.isFluid or false
                    }
                    
                    if target.isFluid then
                        target.id = slotData.fluid and slotData.fluid.name or slotData.name
                        table.insert(targets.fluids, target)
                        processedCount = processedCount + 1
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
                        table.insert(targets.items, target)
                        processedCount = processedCount + 1
                    end
                end
            else
                if not success then
                    print(string.format("[警告] 获取缓存器槽位 %d 数据失败: %s", slot, tostring(slotData)))
                end
            end
        end
    end
    
    print(string.format("[缓存器] 已处理 %d 个监控目标 (%d 物品, %d 流体)", 
          processedCount, #targets.items, #targets.fluids))
    
    return targets
end
 
local function isRealCraftingItem(content, monitoringTargets)
    -- 检查是否为监控目标中的物品
    if content.type == "item" then
        for _, item in ipairs(monitoringTargets.items) do
            if content.name == item.name and content.damage == (item.damage or 0) then
                return true
            end
        end
    elseif content.type == "fluid" then
        for _, fluid in ipairs(monitoringTargets.fluids) do
            if content.name == fluid.id then
                return true
            end
        end
    end
    
    -- 额外的过滤条件：排除可疑的进度指示器
    local suspiciousPatterns = {
        -- 排除常见的非终产物
        "circuit", "wafer", "processor", "chip", "crystal",
        -- 排除合成相关物品
        "craft", "pattern", "template"
    }
    
    local contentName = content.name:lower()
    for _, pattern in ipairs(suspiciousPatterns) do
        if contentName:find(pattern) then
            return false
        end
    end
    
    -- 如果数量在特定范围内（可能是进度指示器），则排除
    local amount = content.amount or 0
    if amount > 100000 and amount < 200000 then -- 100K-200K范围
        return false
    end
    
    return true
end
 
local function getAllCPUCraftingContents(monitoringTargets)
    local allContents = {}
    local cpus = craftingCPUs or {}
    
    for _, cpuInfo in ipairs(cpus) do
        local cpu = cpuInfo.cpu
        if cpu then
            local cpuContents = {
                cpuName = cpuInfo.name or "未知CPU", 
                contents = {}, 
                isBusy = pcall(function() return cpu.isBusy() end),
                totalItems = 0,
                realItems = 0
            }
            
            if cpuContents.isBusy then
                -- 检查存储内容
                local storageSuccess, storage = pcall(function() return cpu.getStorage() end)
                if storageSuccess and type(storage) == "table" then
                    for _, item in ipairs(storage) do
                        if item and item.size and item.size > 0 then
                            cpuContents.totalItems = cpuContents.totalItems + 1
                            
                            local itemType = item.fluidDrop and "fluid" or "item"
                            local itemName = item.fluidDrop and item.fluidDrop.name or item.name
                            local itemDamage = item.damage or 0
                            
                            local contentData = {
                                type = itemType,
                                name = itemName,
                                damage = itemDamage,
                                amount = item.size or 0,
                                source = "storage",
                                rawData = item
                            }
                            
                            -- 检查是否为真正的合成物品
                            if isRealCraftingItem(contentData, monitoringTargets) then
                                cpuContents.realItems = cpuContents.realItems + 1
                                table.insert(cpuContents.contents, contentData)
                            end
                        end
                    end
                end
                
                -- 检查最终输出（这里更可能是真正的终产物）
                local outputSuccess, output = pcall(function() return cpu.finalOutput() end)
                if outputSuccess and output and output.size and output.size > 0 then
                    cpuContents.totalItems = cpuContents.totalItems + 1
                    
                    local outputType = output.fluidDrop and "fluid" or "item"
                    local outputName = output.fluidDrop and output.fluidDrop.name or output.name
                    local outputDamage = output.damage or 0
                    
                    local contentData = {
                        type = outputType,
                        name = outputName,
                        damage = outputDamage,
                        amount = output.size or 0,
                        source = "finalOutput",
                        rawData = output
                    }
                    
                    -- 最终输出总是认为是真正的合成物品
                    cpuContents.realItems = cpuContents.realItems + 1
                    table.insert(cpuContents.contents, contentData)
                end
                
                -- 添加调试信息
                if cpuContents.totalItems > 0 then
                    cpuContents.debugInfo = string.format("CPU:%s, 总物品:%d, 真实物品:%d", 
                        cpuInfo.name or "未知", cpuContents.totalItems, cpuContents.realItems)
                end
            end
            
            table.insert(allContents, cpuContents)
        end
    end
    
    return allContents
end
 
return {
    initComponents = initComponents, 
    me = function() return me end, 
    craftingCPUs = function() return craftingCPUs end, 
    levelMaintainers = function() return levelMaintainers end, 
    getMonitoringTargets = getMonitoringTargets, 
    getAllCPUCraftingContents = function(monitoringTargets) 
        return getAllCPUCraftingContents(monitoringTargets) 
    end
}
