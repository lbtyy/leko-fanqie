-- Small, self-contained QR Code encoder for the local phone-import page.
--
-- The encoder deliberately uses byte mode and error-correction level M.  The
-- payload is a short local HTTP address, so versions 1-10 cover the complete
-- range needed by this feature while keeping the implementation compact.
local QRCode = {}

local TOTAL_CODEWORDS = { 26, 44, 70, 100, 134, 172, 196, 242, 292, 346 }
local ECC_CODEWORDS_PER_BLOCK = { 10, 16, 26, 18, 24, 16, 18, 22, 22, 26 }
local NUM_ERROR_CORRECTION_BLOCKS = { 1, 1, 1, 2, 2, 4, 4, 4, 5, 5 }
local ALIGNMENT_POSITIONS = {
    {},
    { 6, 18 },
    { 6, 22 },
    { 6, 26 },
    { 6, 30 },
    { 6, 34 },
    { 6, 22, 38 },
    { 6, 24, 42 },
    { 6, 26, 46 },
    { 6, 28, 50 },
}

-- Lua 5.1/LuaJIT compatible integer helpers.  Keeping these here avoids a
-- dependency on a platform-specific bit library in the QR implementation.
local function xor(a, b)
    local result, place = 0, 1
    while a > 0 or b > 0 do
        local abit = a % 2
        local bbit = b % 2
        if abit ~= bbit then result = result + place end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        place = place * 2
    end
    return result
end

local function getBit(value, index)
    return math.floor(value / (2 ^ index)) % 2 == 1
end

local function appendBits(bits, value, length)
    for index = length - 1, 0, -1 do
        bits[#bits + 1] = getBit(value, index) and 1 or 0
    end
end

local gf_exp, gf_log = {}, {}
do
    local value = 1
    for index = 0, 254 do
        gf_exp[index] = value
        gf_log[value] = index
        value = value * 2
        if value >= 256 then value = xor(value, 0x11d) end
    end
    for index = 255, 510 do gf_exp[index] = gf_exp[index - 255] end
end

local function multiply(a, b)
    if a == 0 or b == 0 then return 0 end
    return gf_exp[(gf_log[a] + gf_log[b]) % 255]
end

local generator_cache = {}
local function generatorPolynomial(degree)
    if generator_cache[degree] then return generator_cache[degree] end
    local polynomial = { 1 }
    for index = 0, degree - 1 do
        local next_polynomial = {}
        for position = 1, #polynomial do
            next_polynomial[position] = xor(next_polynomial[position] or 0, polynomial[position])
            next_polynomial[position + 1] = xor(
                next_polynomial[position + 1] or 0,
                multiply(polynomial[position], gf_exp[index])
            )
        end
        polynomial = next_polynomial
    end
    generator_cache[degree] = polynomial
    return polynomial
end

local function reedSolomonRemainder(data, degree)
    local generator = generatorPolynomial(degree)
    local remainder = {}
    for index = 1, degree do remainder[index] = 0 end
    for _, value in ipairs(data) do
        local factor = xor(value, remainder[1])
        for index = 1, degree - 1 do
            remainder[index] = xor(remainder[index + 1], multiply(generator[index + 1], factor))
        end
        remainder[degree] = multiply(generator[degree + 1], factor)
    end
    return remainder
end

local function makeDataCodewords(text, version)
    local bytes = { string.byte(text, 1, #text) }
    local data_capacity = (TOTAL_CODEWORDS[version] - ECC_CODEWORDS_PER_BLOCK[version]
        * NUM_ERROR_CORRECTION_BLOCKS[version]) * 8
    local bits = {}
    appendBits(bits, 0x4, 4) -- byte mode
    appendBits(bits, #bytes, version < 10 and 8 or 16)
    for _, value in ipairs(bytes) do appendBits(bits, value, 8) end
    if #bits > data_capacity then return nil end

    for _ = 1, math.min(4, data_capacity - #bits) do bits[#bits + 1] = 0 end
    while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end

    local codewords = {}
    for index = 1, #bits, 8 do
        local value = 0
        for offset = 0, 7 do value = value * 2 + bits[index + offset] end
        codewords[#codewords + 1] = value
    end
    local pad = 0
    while #codewords < data_capacity / 8 do
        codewords[#codewords + 1] = pad % 2 == 0 and 0xec or 0x11
        pad = pad + 1
    end
    return codewords
end

local function makeCodewords(data, version)
    local total = TOTAL_CODEWORDS[version]
    local ecc_per_block = ECC_CODEWORDS_PER_BLOCK[version]
    local block_count = NUM_ERROR_CORRECTION_BLOCKS[version]
    local short_block_count = block_count - total % block_count
    local short_block_length = math.floor(total / block_count)
    local data_index = 1
    local data_blocks, ecc_blocks = {}, {}

    for block = 1, block_count do
        local block_length = short_block_length + (block > short_block_count and 1 or 0)
        local data_length = block_length - ecc_per_block
        local data_block = {}
        for index = 1, data_length do
            data_block[index] = data[data_index]
            data_index = data_index + 1
        end
        data_blocks[block] = data_block
        ecc_blocks[block] = reedSolomonRemainder(data_block, ecc_per_block)
    end

    local result = {}
    local max_data_length = short_block_length - ecc_per_block + 1
    for index = 1, max_data_length do
        for block = 1, block_count do
            if data_blocks[block][index] ~= nil then result[#result + 1] = data_blocks[block][index] end
        end
    end
    for index = 1, ecc_per_block do
        for block = 1, block_count do result[#result + 1] = ecc_blocks[block][index] end
    end
    return result
end

local function newMatrix(size)
    local matrix = {}
    for row = 1, size do
        matrix[row] = {}
        for column = 1, size do matrix[row][column] = nil end
    end
    return matrix
end

local function setModule(matrix, x, y, value)
    matrix[y + 1][x + 1] = value == true
end

local function drawFinder(matrix, x, y)
    local size = #matrix
    for dy = -1, 7 do
        for dx = -1, 7 do
            local px, py = x + dx, y + dy
            if px >= 0 and px < size and py >= 0 and py < size then
                local black = (dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6)
                    and (dx == 0 or dx == 6 or dy == 0 or dy == 6
                        or (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4))
                setModule(matrix, px, py, black)
            end
        end
    end
end

local function drawFunctionPatterns(matrix, version)
    local size = #matrix
    drawFinder(matrix, 0, 0)
    drawFinder(matrix, size - 7, 0)
    drawFinder(matrix, 0, size - 7)

    local positions = ALIGNMENT_POSITIONS[version]
    for _, y in ipairs(positions) do
        for _, x in ipairs(positions) do
            if matrix[y + 1][x + 1] == nil then
                for dy = -2, 2 do
                    for dx = -2, 2 do
                        setModule(matrix, x + dx, y + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1)
                    end
                end
            end
        end
    end

    for index = 8, size - 9 do
        if matrix[6 + 1][index + 1] == nil then setModule(matrix, index, 6, index % 2 == 0) end
        if matrix[index + 1][6 + 1] == nil then setModule(matrix, 6, index, index % 2 == 0) end
    end
    setModule(matrix, 8, size - 8, true)

    if version >= 7 then
        local remainder = version * 0x1000
        for index = 17, 12, -1 do
            if getBit(remainder, index) then
                remainder = xor(remainder, 0x1f25 * (2 ^ (index - 12)))
            end
        end
        local bits = version * 0x1000 + remainder
        for index = 0, 17 do
            local value = getBit(bits, index)
            setModule(matrix, size - 11 + index % 3, math.floor(index / 3), value)
            setModule(matrix, math.floor(index / 3), size - 11 + index % 3, value)
        end
    end

    -- Reserve the two format-information strips before data placement. The
    -- actual mask-dependent bits are written after the best mask is chosen.
    for index = 0, 14 do
        if index < 6 then
            setModule(matrix, 8, index, false)
        elseif index < 8 then
            setModule(matrix, 8, index + 1, false)
        else
            setModule(matrix, 8, size - 15 + index, false)
        end
        if index < 8 then
            setModule(matrix, size - index - 1, 8, false)
        elseif index < 9 then
            setModule(matrix, 15 - index, 8, false)
        else
            setModule(matrix, 15 - index - 1, 8, false)
        end
    end
    setModule(matrix, 8, size - 8, true)
end

local function formatBits(mask)
    local data = mask -- M has format bits 00, followed by the mask id.
    local remainder = data * 0x400
    for index = 14, 10, -1 do
        if getBit(remainder, index) then
            remainder = xor(remainder, 0x537 * (2 ^ (index - 10)))
        end
    end
    return xor(data * 0x400 + remainder, 0x5412)
end

local function drawFormatBits(matrix, mask)
    local size = #matrix
    local bits = formatBits(mask)
    for index = 0, 14 do
        local value = getBit(bits, index)
        if index < 6 then
            setModule(matrix, 8, index, value)
        elseif index < 8 then
            setModule(matrix, 8, index + 1, value)
        else
            setModule(matrix, 8, size - 15 + index, value)
        end
        if index < 8 then
            setModule(matrix, size - index - 1, 8, value)
        elseif index < 9 then
            setModule(matrix, 15 - index, 8, value)
        else
            setModule(matrix, 15 - index - 1, 8, value)
        end
    end
    setModule(matrix, 8, size - 8, true)
end

local function maskApplies(mask, row, column)
    if mask == 0 then return (row + column) % 2 == 0 end
    if mask == 1 then return row % 2 == 0 end
    if mask == 2 then return column % 3 == 0 end
    if mask == 3 then return (row + column) % 3 == 0 end
    if mask == 4 then return (math.floor(row / 2) + math.floor(column / 3)) % 2 == 0 end
    if mask == 5 then return (row * column) % 2 + (row * column) % 3 == 0 end
    if mask == 6 then return ((row * column) % 2 + (row * column) % 3) % 2 == 0 end
    return ((row + column) % 2 + (row * column) % 3) % 2 == 0
end

local function dataBit(codewords, index)
    local byte = codewords[math.floor(index / 8) + 1]
    return getBit(byte, 7 - index % 8)
end

local function placeData(matrix, codewords, mask)
    local size = #matrix
    local bit_index, upward = 0, true
    local column = size - 1
    while column >= 1 do
        if column == 6 then column = column - 1 end
        for offset = 0, size - 1 do
            local row = upward and size - 1 - offset or offset
            for side = 0, 1 do
                local x = column - side
                if matrix[row + 1][x + 1] == nil then
                    local value = bit_index < #codewords * 8 and dataBit(codewords, bit_index) or false
                    if maskApplies(mask, row, x) then value = not value end
                    setModule(matrix, x, row, value)
                    bit_index = bit_index + 1
                end
            end
        end
        upward = not upward
        column = column - 2
    end
end

local function copyMatrix(matrix)
    local copy = {}
    for row = 1, #matrix do
        copy[row] = {}
        for column = 1, #matrix do copy[row][column] = matrix[row][column] end
    end
    return copy
end

local function penaltyScore(matrix)
    local size, score = #matrix, 0
    local function color(row, column) return matrix[row][column] and 1 or 0 end
    local function scoreLine(values)
        local line_score, run_color, run_length = 0, values[1], 1
        for index = 2, #values do
            if values[index] == run_color then
                run_length = run_length + 1
            else
                if run_length >= 5 then line_score = line_score + 3 + run_length - 5 end
                run_color, run_length = values[index], 1
            end
        end
        if run_length >= 5 then line_score = line_score + 3 + run_length - 5 end
        return line_score
    end

    for row = 1, size do
        local values = {}
        for column = 1, size do values[column] = color(row, column) end
        score = score + scoreLine(values)
        for index = 1, size - 10 do
            local pattern = ""
            for position = index, index + 10 do pattern = pattern .. tostring(values[position]) end
            if pattern == "10111010000" or pattern == "00001011101" then score = score + 40 end
        end
    end
    for column = 1, size do
        local values = {}
        for row = 1, size do values[row] = color(row, column) end
        score = score + scoreLine(values)
        for index = 1, size - 10 do
            local pattern = ""
            for position = index, index + 10 do pattern = pattern .. tostring(values[position]) end
            if pattern == "10111010000" or pattern == "00001011101" then score = score + 40 end
        end
    end
    for row = 1, size - 1 do
        for column = 1, size - 1 do
            local value = matrix[row][column]
            if matrix[row + 1][column] == value and matrix[row][column + 1] == value
                    and matrix[row + 1][column + 1] == value then
                score = score + 3
            end
        end
    end
    local dark = 0
    for row = 1, size do
        for column = 1, size do if matrix[row][column] then dark = dark + 1 end end
    end
    score = score + math.floor(math.abs(dark * 100 / (size * size) - 50) / 5) * 10
    return score
end

function QRCode:encode(text)
    text = tostring(text or "")
    if text == "" then return nil, "二维码内容为空" end
    for index = 1, #text do
        if text:byte(index) > 255 then return nil, "二维码内容无法编码" end
    end

    local version, data
    for candidate = 1, #TOTAL_CODEWORDS do
        data = makeDataCodewords(text, candidate)
        if data then version = candidate; break end
    end
    if not version then return nil, "二维码内容过长" end

    local codewords = makeCodewords(data, version)
    local size = version * 4 + 17
    local base = newMatrix(size)
    drawFunctionPatterns(base, version)
    local best, best_score
    for mask = 0, 7 do
        local candidate = copyMatrix(base)
        placeData(candidate, codewords, mask)
        drawFormatBits(candidate, mask)
        local score = penaltyScore(candidate)
        if not best_score or score < best_score then
            best, best_score = candidate, score
        end
    end
    return { modules = best, size = size, version = version, error_correction = "M" }
end

return QRCode
