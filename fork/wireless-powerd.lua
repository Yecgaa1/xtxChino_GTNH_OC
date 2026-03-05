local component = require("component")
local gtm = component.gt_machine
local term = require("term")
local gpu = component.gpu
local event = require("event")
-- #region config
 
-- 眼镜文字大小
local textScale = 1
-- 相对屏幕左上角, 眼镜文字横向偏移量
local glassesOffsetX = 3
-- 相对屏幕左上角, 眼镜文字纵向偏移量
local glassesOffsetY = 16
-- 存电只够一小时则红字警告
local exhaustWarningSeconds = 3600
-- 小于等于该值时使用逗号三位分隔；大于该值时使用科学计数法
local displayScientificNumbersIfAbove = 1e15
-- #endregion config
-- #region constants
 
-- 存储多少秒的数据, 内存不足时可以适量改小该值
local SECOND_DATA_SIZE = 3600 * 24
-- MAX电压的大小
local maxVoltageValue = 2147483640
-- GT功率显示会往下显示几个电压等级，方便计算
local GT_SHOW_LOWER = 4
local EU_Monitor = {
    secondEU = {},     -- 存储每秒的EU
    secondCounter = 0,
    voltageNamesNoColor = {
        "ULV", "LV", "MV", "HV", "EV", "IV",
        "LUV", "ZPM", "UV", "UHV", "UEV", "UIV", "UMV","UXV"
    },
    maxVoltageNameNoColor = "MAX",
    voltageNames = {},
    maxVoltageName = ""
}
-- 设置各种前景色
local VOLTAGE_NAME_COLOR = "\27[35m"
local SCREEN_RESET_COLOR = "\27[37m"
local SCREEN_GREEN_COLOR = "\27[32m"
local SCREEN_RED_COLOR = "\27[31m"
local SCREEN_WIDTH = 80 -- 分辨率
local SCREEN_HEIGHT = 14 -- 分辨率
 
for _, str in ipairs(EU_Monitor.voltageNamesNoColor) do
    local coloredStr = VOLTAGE_NAME_COLOR .. str .. SCREEN_RESET_COLOR
    table.insert(EU_Monitor.voltageNames, coloredStr)
end
EU_Monitor.maxVoltageName = VOLTAGE_NAME_COLOR .. EU_Monitor.maxVoltageNameNoColor .. SCREEN_RESET_COLOR
 
--- @type table<string, Text2D>
local texts = {}
local GLASSES_BLACK_COLOR = { 0, 0, 0 }
local GLASSES_RED_COLOR = { 255, 85, 85 }
local GLASSES_GREEN_COLOR = { 85, 255, 85 }
local GLASSES_WHITE_COLOR = { 255, 255, 255 }
local glasses = component.glasses
-- #endregion constants
 
-- main loop variable
local doContinue = true
 
local function formatNumber(number)
    if math.abs(number) > displayScientificNumbersIfAbove then
        return string.format("%.2e", number)
    end
    local i, j, minus, int, fraction = string.format("%.1f", number):find('([-]?)(%d+)([.]?%d*)')
    int = int:reverse():gsub("(%d%d%d)", "%1,") -- reverse the int-string and append a comma to all blocks of 3 digits
    return minus .. int:reverse():gsub("^,", "") -- reverse the int-string back remove an optional comma and put the optional minus and fractional part back
end
 
local function extractNumber(alfanum)
    return alfanum:match("([%d,]+)")
end
 
local function getWirelessEU()
    local WirelessEUInfo = gtm.getSensorInformation()[23]
    -- GTNH 2.7.0之前需要将上面这行中的 gtm.getSensorInformation()[23] 改为 gtm.getSensorInformation()[19]
    local function getEU(text)
        local match = extractNumber(text)
        if match then
            local cleanMatch = string.gsub(match,",","")
            return tonumber(cleanMatch)  -- 将匹配到的字符串转换为数值
        else
            return nil
        end
    end
    return getEU(WirelessEUInfo)
end
 
---@param glasses glasses # The glasses component.
---@param key string # The key for the text.
---@param x number # The x position of the text.
---@param y number # The y position of the text.
local function createShadowText(glasses, key, x, y)
    y = y * 10
    texts[key .. "shadow"] = glasses.addTextLabel()
    texts[key .. "shadow"].setPosition(x + 1, y + 1)
    texts[key .. "shadow"].setScale(textScale)
    texts[key .. "shadow"].setColor(63 / 255, 63 / 255, 63 / 255)
    texts[key] = glasses.addTextLabel()
    texts[key].setPosition(x, y)
    texts[key].setScale(textScale)
    texts[key].setColor(1, 1, 1)
end
 
---@param key string # The key for the text.
---@param text string # The text to display.
---@param r number? # The red component from `0` to `255`.
---@param g number? # The green component from `0` to `255`.
---@param b number? # The blue component from `0` to `255 `.
local function setShadowText(key, text, r, g, b)
    texts[key .. "shadow"].setText(text)
    texts[key].setText(text)
    if r == nil or g == nil or b == nil then
        return
    end
    texts[key .. "shadow"].setColor(r / 1028, g / 1028, b / 1028)
    texts[key].setColor(r / 255, g / 255, b / 255)
end
 
---@param glasses glasses # The glasses component.
local function glassesSetup(glasses)
    glasses.removeAll()
    createShadowText(glasses, "income_5m", glassesOffsetX, glassesOffsetY + 1)
    createShadowText(glasses, "income_1h", glassesOffsetX, glassesOffsetY + 2)
    createShadowText(glasses, "storage", glassesOffsetX, glassesOffsetY + 3)
    createShadowText(glasses, "exhaustTime", glassesOffsetX, glassesOffsetY + 4)
end
 
-- 设置前景色并打印消息
local function toColorString(value)
    if value == 0 then
        return "0"
    end
    local colorCode = value < 0 and SCREEN_RED_COLOR or SCREEN_GREEN_COLOR  -- 绿色或红色
    return string.format(colorCode.."%s"..SCREEN_RESET_COLOR,formatNumber(value))
end
 
-- 计算GT功率信息
local function getGTInfo(euPerTick, withColor)
    withColor = withColor == nil or withColor -- default to true
    local voltageNames = withColor and EU_Monitor.voltageNames or EU_Monitor.voltageNamesNoColor
    local maxVoltageName = withColor and EU_Monitor.maxVoltageName or EU_Monitor.maxVoltageNameNoColor
    if euPerTick == 0 then return "0A "..voltageNames[1] end
    local absValue = math.abs(euPerTick)
    local voltage_for_tier = absValue / 2 / (4 ^ GT_SHOW_LOWER)
    -- 处理MAX电压特殊情况
    if absValue >= maxVoltageValue then
        return string.format("%sA "..maxVoltageName, formatNumber(absValue/maxVoltageValue))
    end
    -- 计算电压等级
    local tier = voltage_for_tier < 4 and 1 or math.floor(math.log(voltage_for_tier) / math.log(4))
    tier = math.max(1, math.min(tier, #voltageNames))
    -- 处理超出命名范围的情况
    if tier > #EU_Monitor.voltageNames then
        return string.format("%sA "..maxVoltageName, formatNumber(absValue/maxVoltageValue))
    end
    -- 计算电流值和电压名称
    local baseVoltage = 8 * (4 ^ (tier - 1))
    local current = absValue / baseVoltage
    return string.format("%.0fA %s", current, voltageNames[tier])
end
 
-- 计算最后 n 条记录的差值并且得到之间的变化量的平均值（不计入时间间隔，单纯把一前一后两个数的差值除以条目数，请在之后自行除以时间间隔）
local function calculateAverage(data, n)
    local count = math.min(n, #data)
    if count == 0 then return 0 end
    local now = data[1]
    local prev = data[count]
    return (now-prev) / count
end
 
--- 将秒数转换为更易读的时间格式
-- @param seconds number 输入的秒数
-- @return string 格式化后的时间字符串
local function formatTimeFromSeconds(seconds)
    if seconds < 0 then
        return "无效时间"
    end
    if seconds < 60 then return string.format("%.1f 秒", seconds)
    elseif seconds < 3600 then return string.format("%.1f 分钟", seconds / 60)
    elseif seconds < 86400 then return string.format("%.1f 小时", seconds / 3600)
    elseif seconds < 2592000 then return string.format("%.1f 天", seconds / 86400)
    elseif seconds < 31536000 then return string.format("%.1f 月", seconds / 2592000)
    elseif seconds < 31536000 * 1000 then return string.format("%.1f 年", seconds / 31536000)
    else return ">1000年" end
end
 
-- 更新监控数据
function EU_Monitor.update()
    local currentEU = getWirelessEU()
    -- 每秒钟存一个值
    table.insert(EU_Monitor.secondEU, 1, currentEU)
    if #EU_Monitor.secondEU > SECOND_DATA_SIZE then
        table.remove(EU_Monitor.secondEU)
    end
    -- 准备输出数据
    local fiveSecAvg = calculateAverage(EU_Monitor.secondEU, 5)/20
    local minuteAvg = calculateAverage(EU_Monitor.secondEU, 60)/20
    local fiveMinAvg = calculateAverage(EU_Monitor.secondEU, 300)/20
    local hourAvg = calculateAverage(EU_Monitor.secondEU, 3600)/20
    local dayAvg = calculateAverage(EU_Monitor.secondEU, 86400)/20
    -- 绘制屏幕
    term.clear()
    print(string.format("存量: %.2e EU", currentEU))
    print(string.format("可用功率(秒): %.1e EU/s (%s)", currentEU/20, getGTInfo(currentEU/20)))
    print(string.format("可用功率(小时): %.1e EU/hour (%s)", currentEU/3600/20, getGTInfo(currentEU/3600/20)))
    print(string.format("可用功率(天): %.1e EU/day (%s)", currentEU/3600/20/24, getGTInfo(currentEU/3600/20/24)))
    print()
    print(string.format("每五秒均值: %s EU/t (%s)", toColorString(fiveSecAvg), getGTInfo(fiveSecAvg)))
    print(string.format("每分钟均值: %s EU/t (%s)", toColorString(minuteAvg), getGTInfo(minuteAvg)))
    print(string.format("五分钟均值: %s EU/t (%s)", toColorString(fiveMinAvg), getGTInfo(fiveMinAvg)))
    print(string.format("每小时均值: %s EU/t (%s)", toColorString(hourAvg), getGTInfo(hourAvg)))
    print(string.format("每天均值: %s EU/t (%s)", toColorString(dayAvg), getGTInfo(dayAvg)))
    print()
    print("(按 Ctrl+C 关闭程序)")
    -- 绘制眼镜
    -- 无线电网数据更新时间大于1秒，间隔太小没有意义; 蓝波顿上传间隔是5分钟，取5分钟可以避免蓝波顿上传带来的峰，这里取5分钟均值和小时均值
    -- 耗尽时间基于小时均值计算，小于一小时则红字报警
    local exhaustSeconds = currentEU / (-hourAvg) / 20
    setShadowText("income_5m", string.format("5m: %s EU/t (%s)", formatNumber(fiveMinAvg), getGTInfo(fiveMinAvg, false)),
        table.unpack(fiveMinAvg < 0 and GLASSES_RED_COLOR or fiveMinAvg > 0 and GLASSES_GREEN_COLOR or GLASSES_WHITE_COLOR))
    setShadowText("income_1h", string.format("1h: %s EU/t (%s)", formatNumber(hourAvg), getGTInfo(hourAvg, false)),
        table.unpack(hourAvg < 0 and GLASSES_RED_COLOR or hourAvg > 0 and GLASSES_GREEN_COLOR or GLASSES_WHITE_COLOR))
    setShadowText("storage", string.format("储量: %s EU", formatNumber(currentEU)))
    setShadowText("exhaustTime", ("耗尽时间: " .. ((exhaustSeconds <= 0) and "N/A" or formatTimeFromSeconds(exhaustSeconds))),
        table.unpack((exhaustSeconds > 0 and exhaustSeconds < exhaustWarningSeconds) and GLASSES_RED_COLOR or GLASSES_WHITE_COLOR))
end
 
-- 捕获 Ctrl+C 事件进行优雅关机
local function onInterrupted()
  doContinue = false
end
 
local function main()
    event.listen("interrupted", onInterrupted)
    glassesSetup(glasses) -- 注册眼镜文字
    gpu.setViewport(SCREEN_WIDTH, SCREEN_HEIGHT)
    -- gpu.setBackground(0x44b6ff) -- 背景颜色，可自行修改
    term.clear()
    term.setCursorBlink(false)
 
    -- 主循环,每秒运行一次
    while doContinue do
        EU_Monitor.update()
        os.sleep(1)
    end
 
    -- 取消事件监听, 防止多次启动脚本后重复注册
    event.ignore("interrupted", onInterrupted)
end
main()
