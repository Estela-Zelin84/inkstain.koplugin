-- 墨痕阅读统计面板（全屏，右上角关闭键退出）
-- 由 main.lua 的 InkStain:showStatsScreen() 创建：
--   StatsScreen:new{ dimen = Geom:new{...}, plugin = inkstain_inst, bb = bb, close_rect = {...} }
--
-- 说明：本 widget 不依赖 ImageWidget（部分固件的 ImageWidget 不接收裸 Blitbuffer
-- 作为 image，会导致 "cannot render image" 崩溃）。改为直接重写 paintTo，用
-- Blitbuffer:blitFrom 把已渲染好的面板 bb 贴到屏幕上。
--
-- 关键：KOReader 的 InputContainer 不会自动回调 onTap，必须注册 touch zone（或
-- ges_events）才能响应手势。这里用 registerTouchZones 注册右上角关闭键，并用
-- stop_events_propagation 让面板模态（吞掉其它区域的点击，避免穿透到下层界面）。

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local StatsScreen = InputContainer:extend{
    name = "inkstain_stats_screen",
    plugin = nil,
    bb = nil,          -- 已渲染的 Blitbuffer（统计面板）
    close_rect = nil,  -- 右上角关闭键的屏幕坐标矩形 {x,y,w,h}
    is_doc_only = false,
}

function StatsScreen:init()
    logger.info("[InkStain] 统计面板已加载（全屏，registerTouchZones 关闭键）")
    local w, h = self.dimen.w, self.dimen.h
    -- 模态：吞掉除关闭键以外的所有手势，避免穿透到下层界面
    self.stop_events_propagation = true
    local cr = self.close_rect
    if cr and w > 0 and h > 0 then
        if type(self.registerTouchZones) == "function" then
            -- 标准机制：registerTouchZones（旧版/新版 KOReader 均支持）
            self:registerTouchZones({
                {
                    id = "stats_close",
                    ges = "tap",
                    screen_zone = {
                        ratio_x = cr.x / w,
                        ratio_y = cr.y / h,
                        ratio_w = cr.w / w,
                        ratio_h = cr.h / h,
                    },
                    handler = function()
                        self:closeScreen()
                        return true
                    end,
                },
                {
                    id = "stats_capture",
                    ges = "tap",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function()
                        return true
                    end,
                },
                {
                    id = "stats_swipe_close",
                    ges = "swipe",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function()
                        self:closeScreen()
                        return true
                    end,
                },
            })
        else
            -- 退路：现代 KOReader 用 ges_events（事件名 -> onTapXxx 方法）
            self.ges_events = {
                TapClose = {
                    GestureRange:new{
                        ges = "tap",
                        range = Geom:new{ x = cr.x, y = cr.y, w = cr.w, h = cr.h },
                    },
                },
                TapCapture = {
                    GestureRange:new{
                        ges = "tap",
                        range = Geom:new{ x = 0, y = 0, w = w, h = h },
                    },
                },
                SwipeClose = {
                    GestureRange:new{
                        ges = "swipe",
                        range = Geom:new{ x = 0, y = 0, w = w, h = h },
                    },
                },
            }
        end
    end
end

-- 直接把面板 Blitbuffer 贴到屏幕 bb 上
function StatsScreen:paintTo(bb, x, y)
    if self.bb then
        bb:blitFrom(self.bb, x, y, 0, 0, self.bb.w, self.bb.h)
    end
end

function StatsScreen:closeScreen()
    UIManager:close(self)
    return true
end

function StatsScreen:onTapClose()
    self:closeScreen()
    return true
end

function StatsScreen:onTapCapture()
    return true
end

-- 全屏滑动关闭面板（手势调出/退出）
function StatsScreen:onSwipeClose()
    self:closeScreen()
    return true
end

-- 硬件返回键也可退出
function StatsScreen:onBack()
    self:closeScreen()
    return true
end

-- 关闭时统一释放临时 Blitbuffer
function StatsScreen:onCloseWidget()
    if self.bb and self.bb.free then
        pcall(self.bb.free, self.bb)
        self.bb = nil
    end
    return true
end

return StatsScreen
