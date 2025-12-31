component = require("component")
sides = require("sides")
os = require("os")
gpu = component.gpu
is_Redstone_mode = true -- 是否存在红石控制
isWork = false
-- 定义配置文件名
local CONFIG_FILE = "config.lua"

-- 定义默认配置内容
local DEFAULT_CONFIG = [[
sides = require("sides")
-- 配置文件版本号
config_version = "v1"

-- 应用设置
wireless = 601; -- 无线红石频率
waitMins = 5; -- 默认等待时间，单位为分钟
gold_chest_multiple = 100; -- 黄金箱子物品维持库存倍数
diamond_chest_multiple = 10000; -- 钻石箱子物品维持库存倍数
try_times_half = 6; -- 合成失败后尝试减半数量重新请求的次数
gold_chest_side = sides.bottom -- 金箱子连接在传送器的底部
diamond_chest_side = sides.up -- 钻石箱子连接在传送器的底部
]]

-- 检查并创建配置文件的函数
local function check_and_create_config(filename, content)
    local f = io.open(filename, "r")
    if f then
        print("[-] 发现配置文件: " .. filename)
        f:close()
    else
        print("[!] 配置文件不存在，正在生成默认配置...")
        f = io.open(filename, "w")
        if f then
            f:write(content)
            f:close()
            print("[+] 已成功创建默认配置文件,请先修改配置文件再次运行本程序: " .. filename)
            os.exit() -- 创建完配置文件后退出程序，等待用户修改配置
        else
            error("无法写入文件: " .. filename)
        end
    end
end

-- 加载配置到全局变量的函数
local function load_config(filename)
    -- 使用 pcall 捕获可能存在的语法错误（防止用户修改配置导致崩溃）
    local status, err = pcall(dofile, filename)
    if not status then
        print("[错误] 加载配置文件失败: " .. err)
        os.exit(1)
    else
        print("[+] 配置文件加载成功。")
        print("---------------------------------------")
        print("当前配置:")
        print("无线红石频率: " .. wireless)
        print("等待时间(分钟): " .. waitMins)
        print("黄金箱子物品维持库存倍数: " .. gold_chest_multiple)
        print("钻石箱子物品维持库存倍数: " .. diamond_chest_multiple)
        print("合成失败后尝试减半数量重新请求的次数: " .. try_times_half)
        print("---------------------------------------")
    end
end

function init()
    print("脚本版本v3.0 2025/12/31")
    -- local componentList = component.list() -- 这个函数返回一个迭代器用于遍历所有可用组件地址、名称，
    print("全设备地址")
    for address, name in component.list() do -- 循环遍历所有组件，此处的list()支持两个额外参数，第一个是过滤字符串，第二个是是否精确匹配，例如component.list("red",true)
        print(address .. "  " .. name)
    end
    print("--------------")
    
    if component.isAvailable("me_interface") then
        me_interface = component.me_interface -- 获取所连接的主网ME接口组件
        print("主网ME接口组件地址:")
        print(me_interface.address)
    else
        print("未连接主网ME接口组件")
        os.exit()
    end

    if component.isAvailable("me_controller") then
        me_controller = component.me_controller -- 获取所连接的子网ME控制器组件
        print("子网ME控制器组件地址:")
        print(me_controller.address)
    else
        print("未连接子网ME控制器")
        os.exit()
    end

    if component.isAvailable("transposer") then
        transposer = component.transposer -- 获取所连接的传送器组件
        print("传送器组件地址:")
        print(transposer.address)
    else
        print("未连接传送器组件")
        os.exit()
    end

    if not component.isAvailable("redstone") then
        is_Redstone_mode = false
        print("未连接红石卡，关闭红石模式")
    else
        redstone = component.redstone -- 获取所连接的红石卡
        redstone.setWirelessFrequency(wireless)
        if redstone then
            print("红石卡组件地址:")
            print(redstone.address)
        else
            print("未连接红石卡")
            os.exit()
        end
    end

    if #me_controller.getCpus() == 0 then
        print("子网未连接合成存储器")
        os.exit()
    end

    -- db = component.database
    -- if db then
    --     print("数据库组件地址:")
    --     print(db.address)
    -- else
    --     print("未连接数据库组件")
    --     os.exit()
    -- end

    print("脚本初始化完成")

end
function redstoneWork(mode)
    if is_Redstone_mode then
        if mode then
            redstone.setWirelessOutput(true)
        else
            redstone.setWirelessOutput(false)
        end
    end
end
function craftItem(item_label, quantity)
    local Craftables = me_controller.getCraftables({
        label = item_label
    })
    if #Craftables == 0 then
        print("物品 " .. item_label .. " 缺少配方，跳过")
        return
    end

    while me_controller.getCpus()[1].busy do
        print("ME合成器忙碌中，等待1秒...")
        os.sleep(1)
    end
    try_times = try_times_half
    local craft = nil
    while true do
        try_times = try_times - 1
        print("请求合成物品: " .. item_label .. " 数量: " .. quantity)
        craft = Craftables[1].request(quantity)
        os.sleep(0.5)
        while craft.isComputing() do
            print("合成计算中，等待1秒...")
            os.sleep(1)
        end

        if craft.hasFailed() then
            print("合成请求失败，跳过")
            if try_times == 0 then
                print("多次尝试合成失败，放弃本次合成请求")
                return
            else
                quantity = math.ceil(quantity / 2)
                print("尝试减少合成数量至: " .. quantity .. " 后重新请求")
            end
        else
            break
        end
    end
    print("合成请求已成功提交，等待合成完成...")
    isWork = true
    while true do
        if not craft.isDone() then
            if craft.isCanceled() then
                print("合成被取消，结束等待")
                break
            end
            print("合成未完成，等待5秒...")
            os.sleep(5)
        else
            print("合成已完成")
            break
        end
    end
end

function check_diamond_chest()
    gpu.setForeground(0x00FF00)
    -- 遍历钻石箱子的东西me_interface中是否存在
    local diamond_chest_slots = transposer.getInventorySize(diamond_chest_side)
    for slot = 1, diamond_chest_slots do
        local item = transposer.getStackInSlot(diamond_chest_side, slot)
        if item then
            local item_label = item.label
            local item_count = item.size
            print("检测到钻石箱子中第" .. slot .. "格子的物品: " .. item_label .. " 数量: " ..
                      item_count .. " 意味着需要维持库存: " .. item_count * diamond_chest_multiple)
            local stored_items = me_interface.getItemsInNetwork({
                label = item_label
            })
            local total_count = 0
            for _, stored_item in ipairs(stored_items) do
                total_count = total_count + stored_item.size
            end
            print("ME网络中该物品的总数量: " .. total_count)
            if total_count < item_count * diamond_chest_multiple then
                local to_craft_count = item_count * diamond_chest_multiple - total_count
                print("需要合成的数量: " .. to_craft_count)
                gpu.setForeground(0x66ccFF)
                craftItem(item_label, to_craft_count)
                gpu.setForeground(0x00FF00)
            else
                print("ME网络中该物品数量已达预期，无需合成")
            end
        else
            print(slot .. "槽位为空，结束本次检查")
            gpu.setForeground(0xFF0000)
            return -- 如果当前槽位为空，结束检查
        end
        print("------")
    end
    print("结束本次检查")
    gpu.setForeground(0xFF0000)
end

function check_gold_chest()
    gpu.setForeground(0x00FF00)
    -- 遍历金箱子的东西me_interface中是否存在
    local gold_chest_slots = transposer.getInventorySize(gold_chest_side)
    for slot = 1, gold_chest_slots do
        local item = transposer.getStackInSlot(gold_chest_side, slot)
        if item then
            local item_label = item.label
            local item_count = item.size
            print("检测到金箱子中第" .. slot .. "格子的物品: " .. item_label .. " 数量: " ..
                      item_count .. " 意味着需要维持库存: " .. item_count * gold_chest_multiple)
            local stored_items = me_interface.getItemsInNetwork({
                label = item_label
            })
            local total_count = 0
            for _, stored_item in ipairs(stored_items) do
                total_count = total_count + stored_item.size
            end
            print("ME网络中该物品的总数量: " .. total_count)
            if total_count < item_count * gold_chest_multiple then
                local to_craft_count = item_count * gold_chest_multiple - total_count
                print("需要合成的数量: " .. to_craft_count)
                gpu.setForeground(0x66ccFF)
                craftItem(item_label, to_craft_count)
                gpu.setForeground(0x00FF00)
            else
                print("ME网络中该物品数量已达预期，无需合成")
            end
        else
            print(slot .. "槽位为空，结束本次检查")
            gpu.setForeground(0xFF0000)
            return -- 如果当前槽位为空，结束检查
        end
        print("------")
    end
    print("结束本次检查")
    gpu.setForeground(0xFF0000)
end

function main()
    check_and_create_config(CONFIG_FILE, DEFAULT_CONFIG)
    load_config(CONFIG_FILE)

    init()
    local t;
    while true do
        ::continue::
        gpu.setForeground(0xFF0000)
        print("倪哥正在超辛勤工作")
        isWork = false
        redstoneWork(true)
        print("开始检查钻石箱子")
        check_diamond_chest()
        print("开始检查金箱子")
        check_gold_chest()
        redstoneWork(false)
        gpu.setForeground(0xFF0000)
        if isWork then
            print("本次有工作，继续下次检查")
            goto continue
        end
        print("激爽下班")
        t = waitMins -- 设置等待时间，单位为分钟
        print("等待" .. waitMins .. "分钟后再次检查")
        while t > 0 do
            print("倪哥正在快乐摸鱼，还有" .. t .. "分钟上班")
            t = t - 1
            os.sleep(60)
        end
    end
end

main()



