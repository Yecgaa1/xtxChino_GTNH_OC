local os = require("os")
local component = require("component")
local sides = require("sides")

local sideOrb = sides.up                                    -- 宝珠的方向(需要单个槽位的容器) 推荐微型箱
local sideItemInput = sides.north                           -- 输入的方向(单个槽位的容器就行) 抽屉或者JABBA桶
local sideItemOutput = sides.south                          -- 输出的方向(输出祭坛的产物) 推荐ME接口
local sideAltar = sides.east                                -- 祭坛的方向
local inputSlot = 2                                         -- 输入容器的槽位 如果是抽屉或者JABBA的桶就写 2 否则 1
local LPGradient = 50000                                    -- 启动加速器需求的最低LP值 低于这个值不会启动防止苦难井LP干完
local minimumLPGradient = 0.5                               -- 启动苦难之井需要网络的LP乘数 这个参数防止网络LP不够启动苦难井,低于这个百分比就开启苦难井
local sleepTime = 1                                         -- 合成时每次检测的时间,越小越卡 0.05 为 1tick检测, 可以适当调节
local isArmokOrb = true                                     -- 如果使用过了阿蒙克气血宝珠 必须填写 true 因为无法检测到对应的网络LP
-- 当这个选项开启 那么只有执行非宝珠充能时会 开启加速
local altarAddress = "6aa7c26e-0a87-4a3b-bcde-34bcc2a932e9" -- 祭坛的世界加速器地址

local trans                                                 -- 转运器对象
local gtmWellAccelerator = {}                               -- 用于存储世界加速器
local altar                                                 -- 需要血魔法祭坛搭配适配器 推荐祭坛使用一个MFU链接 祭坛底部刚好放个加速器(美观考虑。。)
local craftingItem                                          -- 缓存正在合成的物品
local craftingItemCount                                     -- 缓存合成物品的数量
local noneCrafting                                          -- 缓存状态用的
local gtmAccelerator_altar                                  -- 祭坛的加速器对象

function initF()
    local iCount = 1
    -- for k,v in component.list("gt_machine",true) do print(k, v) end
    for k, v in pairs(component.list("gt_machine", true)) do -- 获取所有的加速器对象 避免了手动输入地址 同时不限制加速器的数量
        if k == altarAddress then
            gtmAccelerator_altar = component.proxy(k)      -- 定义祭坛加速器对象
        else
            gtmWellAccelerator[iCount] = component.proxy(k)
            iCount = iCount + 1
        end
    end
    if gtmAccelerator_altar == nil then
        print("找不到祭坛的加速器，程序退出", gtmWellAccelerator.size)
        os.exit(1)
    end
    trans = component.transposer
    altar = component.blood_altar
end

function getItemFromSide(side, slotNum)
    return trans.getStackInSlot(side, slotNum)
end

function getItemCountFromSide(side, slotNum)
    return trans.getSlotStackSize(side, slotNum)
end

function transItemForAltar()
    return trans.transferItem(sideItemInput, sideAltar, craftingItemCount, inputSlot, 1)
end

function checkAltarIsEmpty()
    return trans.getStackInSlot(sideAltar, 1) == nil
end

function checkOrbIsEmpty()
    return trans.getStackInSlot(sideAltar, 1) == nil and trans.getStackInSlot(sideOrb, 1) == nil
end

function refundOrb()
    trans.transferItem(sideAltar, sideOrb)
end

function transferOrb()
    trans.transferItem(sideOrb, sideAltar, 1, 1, 1)
end

function setOutput()
    print("成功合成了", craftingItemCount .. " * " .. getItemFromSide(sideAltar, 1).label)
    trans.transferItem(sideAltar, sideItemOutput)
end

function setWellAcceleratorState(boolean)
    for i = 1, #gtmWellAccelerator do
        if gtmWellAccelerator[i].isMachineActive() ~= boolean then
            gtmWellAccelerator[i].setWorkAllowed(boolean)
        end
    end
end

function setAltarAcceleratorState(boolean)
    if gtmAccelerator_altar.isMachineActive() ~= boolean then
        gtmAccelerator_altar.setWorkAllowed(boolean)
    end
end

function getMaxSoulNetworkEssence(item)
    -- 返回LP网络基于宝珠符文增益后的最大值
    if isArmokOrb then
        return 2147483647
    else
        return item.maxEssence * altar.getOrbMultiplier() - 100
    end
end

function checkAcceleration()
    local item = getItemFromSide(sideAltar, 1)
    local shouldWellAccelerate = false
    local shouldAltarAccelerate = false
    if not isArmokOrb and item ~= nil then
        -- 这一步判断是比较 网络的LP 和 祭坛宝珠符文增益效果的总和LP(网络最大LP)
        -- item.maxEssence 是宝珠对应的网络最大LP,没有计算宝珠符文的增益
        -- 当网络中的LP接近满了就自动关闭加速器,减少TPS压力
        -- 宝珠的等级为nil 即 宝珠没绑定或者其他问题 直接执行加速的逻辑
        -- altar.getCurrentBlood() 即获取祭坛上面的血量
        if altar.getCurrentBlood() >= LPGradient then
            -- 祭坛目前血量充足
            if item.orbTier == nil or item.networkEssence <= getMaxSoulNetworkEssence(item) then
                shouldWellAccelerate = true
                shouldAltarAccelerate = true
            end
        else
            -- 祭坛没有血，则单独加速苦难之井
            shouldWellAccelerate = true
        end
    end
    if isArmokOrb then
        if item ~= nil and item.orbTier == nil then
            shouldWellAccelerate = true
            shouldAltarAccelerate = true
        end
    end
    setWellAcceleratorState(shouldWellAccelerate)
    setAltarAcceleratorState(shouldAltarAccelerate)
end

function checkSoulNetworkEssence()
    -- 先检测祭坛 如果祭坛没有宝珠则检测 存储宝珠的箱子
    local item = getItemFromSide(sideAltar, 1) --获取宝珠物品
    if item == nil then item = getItemFromSide(sideOrb, 1) end
    if item == nil then return end
    -- print("检测到宝珠, 等级:", item.orbTier, "当前网络LP:", item.networkEssence, "最大网络LP:", getMaxSoulNetworkEssence(item))
    if item.orbTier ~= nil then
        if item.networkEssence <= minimumLPGradient * getMaxSoulNetworkEssence(item) then
            print("宝珠充能中, 防止苦难之井的LP供给出现问题")
            shouldWellAccelerate = true
            shouldAltarAccelerate = true
            setWellAcceleratorState(shouldWellAccelerate)
            setAltarAcceleratorState(shouldAltarAccelerate)
            -- 需要充能 如果宝珠没存放在祭坛 则转运宝珠
            if getItemFromSide(sideAltar, 1) == nil then transferOrb() end
            while getItemFromSide(sideAltar, 1).networkEssence < getMaxSoulNetworkEssence(getItemFromSide(sideAltar, 1)) do
                os.sleep(5) -- 宝珠充能时 每次检测间隔 可以调小
            end
            print("宝珠充能完毕。")
            shouldWellAccelerate = false
            shouldAltarAccelerate = false
            setWellAcceleratorState(shouldWellAccelerate)
            setAltarAcceleratorState(shouldAltarAccelerate)
        end
    end
end

function main()
    initF()

    os.execute("cls")
    print("OC祭坛自动化&宝珠常驻程序启动！")
    while true do
        ::LabelRE::

        checkAcceleration()

        craftingItem = getItemFromSide(sideItemInput, inputSlot)

        if craftingItem ~= nil then
            noneCrafting = true
            craftingItemCount = getItemCountFromSide(sideItemInput, inputSlot)

            checkSoulNetworkEssence()

            if not checkAltarIsEmpty() then
                -- 如果是宝珠则转运到宝珠存储箱子, 否则直接输出ME接口
                -- 没绑定的宝珠会也会被转运到ME接口输出
                local tier = getItemFromSide(sideAltar, 1).orbTier
                if tier == nil then
                    trans.transferItem(sideAltar, sideItemOutput)
                else
                    refundOrb()
                end
            end

            if transItemForAltar() ~= craftingItemCount then
                print("祭坛输入存在问题, 数量错误, 请检查")
            else
                while getItemFromSide(sideAltar, 1) ~= nil do
                    checkAcceleration()
                    if getItemFromSide(sideAltar, 1).label ~= craftingItem.label then
                        setOutput()
                        goto LabelRE
                    end
                    os.sleep(sleepTime)
                end
                print("祭坛合成中遇到问题, 中途物品已取出, 请检查")
                goto LabelRE
            end
        elseif not checkOrbIsEmpty() then
            noneCrafting = true
            -- 没有合成时同时存在宝珠 则会自动把宝珠输出到祭坛
            if getItemFromSide(sideAltar, 1) == nil then
                transferOrb()
            end
        elseif noneCrafting then
            noneCrafting = false
            print("无合成&宝珠充能, 摸鱼中...")
        end

        os.sleep(5) -- 每次执行完毕后整体的休眠时间, 可以适当调节
    end
end

main()
