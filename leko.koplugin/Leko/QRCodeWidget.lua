local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")

local QRCodeWidget = Widget:extend{}

function QRCodeWidget:init()
    self.matrix = self.matrix or {}
    self.size = tonumber(self.size or #self.matrix) or #self.matrix
    self.module_size = math.max(1, math.floor(tonumber(self.module_size or 8) or 8))
    self.quiet_zone = math.max(4, math.floor(tonumber(self.quiet_zone or 4) or 4))
    local dimension = (self.size + self.quiet_zone * 2) * self.module_size
    self.dimen = Geom:new{ x = 0, y = 0, w = dimension, h = dimension }
end

function QRCodeWidget:paintTo(bb, x, y)
    local dimension = self.dimen.w
    bb:paintRect(x, y, dimension, dimension, Blitbuffer.COLOR_WHITE)
    local origin = self.quiet_zone * self.module_size
    for row = 1, self.size do
        for column = 1, self.size do
            if self.matrix[row] and self.matrix[row][column] then
                bb:paintRect(
                    x + origin + (column - 1) * self.module_size,
                    y + origin + (row - 1) * self.module_size,
                    self.module_size,
                    self.module_size,
                    Blitbuffer.COLOR_BLACK
                )
            end
        end
    end
end

return QRCodeWidget
