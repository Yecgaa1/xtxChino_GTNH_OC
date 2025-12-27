component = require("component")
sides = require("sides")
os = require("os")
gpu = component.gpu
gold_chest_side = sides.bottom -- 箱子连接在传送器的底部
diamond_chest_side = sides.up -- 箱子连接在传送器的底部
diamond_chest_multiple = 10000;
try_times_half = 6;
function init()
    print("脚本版本v2.0 2025/12/27")
    -- local componentList = component.list() -- 这个函数返回一个迭代器用于遍历所有可用组件地址、名称，
    print("全设备地址")
    for address, name in component.list() do -- 循环遍历所有组件，此处的list()支持两个额外参数，第一个是过滤字符串，第二个是是否精确匹配，例如component.list("red",true)
        print(address .. "  " .. name)
    end
    print("--------------")
    me_interface = component.me_interface -- 获取所连接的主网ME接口组件
    if me_interface then
        print("主网ME接口组件地址:")
        print(me_interface.address)
    else
        print("未连接主网ME接口组件")
        os.exit()
    end

    me_controller = component.me_controller -- 获取所连接的子网ME控制器组件
    if me_controller then
        print("子网ME控制器组件地址:")
        print(me_controller.address)
    else
        print("未连接子网ME控制器")
        os.exit()
    end

    transposer = component.transposer -- 获取所连接的传送器组件
    if transposer then
        print("传送器组件地址:")
        print(transposer.address)
    else
        print("未连接传送器组件")
        os.exit()
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

function craftItem(item_label, quantity)
    local Craftables = me_controller.getCraftables({
        label = item_label
    })
    if #Craftables == 0 then
        print("物品 " .. item_label .. " 不可合成，跳过")
        return
    end

    while me_controller.getCpus()[1].busy do
        print("ME合成器忙碌中，等待1秒...")
        os.sleep(1)
    end
    try_times = try_times_half
    local craft =nil
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

    while true do
        if not craft.isDone() then
            print("合成未完成，等待5秒...")
            os.sleep(5)
        elseif craft.isCanceled() then
            print("合成被取消，结束等待")
            break
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
            gpu.setForeground(0xFFFFFF)
            return -- 如果当前槽位为空，结束检查
        end
        print("------")
    end
    print("结束本次检查")
    gpu.setForeground(0xFFFFFF)
end

function main()
    init()
    local waitMins;
    while true do
        gpu.setForeground(0xFF0000)
        print("倪哥正在超辛勤工作")
        check_diamond_chest()
        gpu.setForeground(0xFF0000)
        print("激爽下班")
        waitMins = 30 -- 设置等待时间，单位为分钟
        print("等待" .. waitMins .. "分钟后再次检查")
        while waitMins > 0 do
            print("倪哥正在快乐摸鱼，还有" .. waitMins .. "分钟上班")
            waitMins = waitMins - 1
            os.sleep(60)
        end
    end
end

main()
