-- 2026/5/13 fork
local os = require("os")
local sides = require("sides")
local component = require("component")
 
local trans = component.transposer      -- 唯一的转运器
local sideTransOutput = sides.east         -- 盈余的反物质输出的方向（按实际搭建方向修改）
local sideTransReservedTank = sides.up      -- 保留/缓存量对应的量子缸 (相对于转运器的方向)
local sideTransMaintainTank = sides.down    -- 维持量对应的量子缸 (相对于转运器的方向)
 
local reservedAmount = 50000                    -- 保留的反物质数量
local maintainAntimatterAmount = 64000000       -- 自动化维持总的反物质
 
local rsSideCBUS = sides.south                   --相对于转运器的方向，即屏幕面对的方向（按实际搭建方向修改）
local rsCompontControlBus = component.redstone  -- 整个自动化唯一的红石组件
 
local logCount = 30     -- 屏幕日志最多保留数量
 
local gtmTank       -- 获取超级缸/量子缸
local gtmMachine    -- 获取反物质主机
 
-- 保存过去30次的输出数量
local outputAmounts = {}
 
--- 主要是用于初始化对应的组件, 
--- 因为量子/超级缸和反物质主机都是 component.gt_machine 需要正确地去初始化
function initCompont()
    local i = 0
    for k,v in pairs(component.list()) do
        if i >= 2 then break end
        if v == "gt_machine" then
            i = i + 1
            local c = component.proxy(k)
            if c.getName() == "antimatterForge" then
                gtmMachine = component.proxy(k)
            else
                gtmTank = component.proxy(k)
            end
        end
    end
end
 
-- 每次启动都需要清除一些缓存状态&获取相关数值
function initF()
    initCompont()
    gtmTank.setWorkAllowed(false)
    gtmMachine.setWorkAllowed(false)
    if maintainAntimatterAmount == 0 then
        print("输入反物质需要维持的数量:")
        maintainAntimatterAmount = tonumber(io.read())
    end
    if reservedAmount == 0 then
        print("请输入整个系统保留的反物质数量, 盈余的反物质将被输出.")
        reservedAmount = tonumber(io.read())
    end
end
 
-- 计算平均值
function calculateAverage()
    local sum = 0
    for _, amount in ipairs(outputAmounts) do
        sum = sum + amount
    end
    return sum / #outputAmounts
end
 
function main()
    initF()
 
    local cleaner = 0
 
    while true do
        cleaner = cleaner + 1
        if cleaner > logCount then
            os.execute("cls")
            cleaner = 0
 
            -- 清屏后打印过去 30 次的平均输出量
            if #outputAmounts > 0 then
                local average = calculateAverage()
                print(string.format("过去 30 次输出的平均值: %.2f", average))
            end
        end
 
        gtmTank.setWorkAllowed(false)
 
        local stopped = false
        -- 控制总线
        while rsCompontControlBus.getInput(rsSideCBUS) == 0 do
            os.sleep(1)
            if not stopped then
                stopped = true
                print("停机.....")
                gtmMachine.setWorkAllowed(false)
            end
        end
 
        -- 这一步依赖于覆盖板 5tick或者更低的tick 把全部的流体瞬间输出
        -- 由于必须是一次性全部输出完毕  所以就需要把覆盖板子调到能瞬间输出完毕
        while trans.getTankLevel(sideTransMaintainTank) == 0 do end
 
        local tankResAmount = trans.getTankLevel(sideTransReservedTank)
        local tankMainAmount = trans.getTankLevel(sideTransMaintainTank)
 
        local outputAmount = 0
        local transToResAmount = 0
        if tankMainAmount >= maintainAntimatterAmount then
            transToResAmount = reservedAmount - tankResAmount
            if transToResAmount < 0 then transToResAmount = 0 end
            local remain = tankMainAmount - maintainAntimatterAmount
            if transToResAmount >= remain then
                transToResAmount = remain
                remain = 0
            elseif transToResAmount < remain then
                remain = remain - transToResAmount
            end
            if remain > 0 then outputAmount = remain end
        else
            local c = tankMainAmount + tankResAmount
            if c >= maintainAntimatterAmount then
                c = maintainAntimatterAmount - tankMainAmount
                trans.transferFluid(sideTransReservedTank, sideTransMaintainTank, c)
            else
                local leave = tankMainAmount % 16
                local t = (leave + tankResAmount) / 16
                if t > 1 then trans.transferFluid(sideTransReservedTank, sideTransMaintainTank, 16 * t)
                else trans.transferFluid(sideTransMaintainTank, sideTransReservedTank, leave) end
            end
        end
 
        print(string.format("执行输出: 向缓存处输出 %d, 向外界输出 %d", transToResAmount, outputAmount))
        if transToResAmount > 0 then trans.transferFluid(sideTransMaintainTank, sideTransReservedTank, transToResAmount) end
        if outputAmount > 0 then 
            trans.transferFluid(sideTransMaintainTank, sideTransOutput, outputAmount)
            -- 保存每次的输出数量
            table.insert(outputAmounts, outputAmount)
            if #outputAmounts > 30 then
                table.remove(outputAmounts, 1)  -- 保证数组长度不超过30
            end
        end
 
        gtmTank.setWorkAllowed(true)
        while trans.getTankLevel(sideTransMaintainTank) ~= 0 do end
        gtmMachine.setWorkAllowed(true)
        while gtmMachine.getWorkProgress() >= 2 do os.sleep(0.05) end
    end
end
 
main()