-- Bounded gzip compatibility for Legado Java bridge scripts.
-- Uses KOReader's bundled zlib through LuaJIT FFI; no external process is
-- required on the device.
local CompressionCompat = {}

local ffi_ok, ffi = pcall(require, "ffi")
local libz
if ffi_ok then
    pcall(ffi.cdef, [[
        typedef void *voidpf;
        typedef unsigned char Bytef;
        typedef unsigned int uInt;
        typedef unsigned long uLong;
        typedef struct internal_state internal_state;
        typedef struct z_stream_s {
            Bytef *next_in;
            uInt avail_in;
            uLong total_in;
            Bytef *next_out;
            uInt avail_out;
            uLong total_out;
            char *msg;
            internal_state *state;
            voidpf zalloc;
            voidpf zfree;
            voidpf opaque;
            int data_type;
            uLong adler;
            uLong reserved;
        } z_stream;
        const char *zlibVersion(void);
        int deflateInit2_(z_stream *, int, int, int, int, int, const char *, int);
        int deflate(z_stream *, int);
        int deflateEnd(z_stream *);
        int inflateInit2_(z_stream *, int, const char *, int);
        int inflate(z_stream *, int);
        int inflateEnd(z_stream *);
    ]])
    local ok, loaded = pcall(function()
        if type(ffi.loadlib) == "function" then return ffi.loadlib("z", 1) end
        return ffi.load("z")
    end)
    if ok then libz = loaded end
end

local Z_NO_FLUSH, Z_FINISH, Z_OK, Z_STREAM_END = 0, 4, 0, 1
local Z_DEFLATED, Z_DEFAULT_STRATEGY = 8, 0
local CHUNK, MAX_OUTPUT = 32768, 8 * 1024 * 1024

local function version()
    if not libz then return nil end
    local ok, value = pcall(function() return ffi.string(libz.zlibVersion()) end)
    return ok and value or nil
end

local function transform(input, encode, options)
    options = options or {}
    input = tostring(input or "")
    if not libz then return nil, "zlib unavailable" end
    local max_input = tonumber(options.max_input or MAX_OUTPUT) or MAX_OUTPUT
    local max_output = tonumber(options.max_output or MAX_OUTPUT) or MAX_OUTPUT
    local max_ratio = tonumber(options.max_ratio or 100) or 100
    if #input > max_input then return nil, "gzip input exceeds safety limit" end
    local stream = ffi.new("z_stream[1]")
    stream[0].next_in = ffi.cast("Bytef *", input)
    stream[0].avail_in = #input
    local ver = version()
    if not ver then return nil, "zlib version unavailable" end
    local init
    if encode then
        -- windowBits=15+16 emits a standards-compliant gzip wrapper.
        init = libz.deflateInit2_(stream, 9, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ver, ffi.sizeof("z_stream"))
    else
        -- windowBits=15+32 accepts both gzip and zlib wrapped input.
        init = libz.inflateInit2_(stream, 47, ver, ffi.sizeof("z_stream"))
    end
    if init ~= Z_OK then return nil, "zlib init failed: " .. tostring(init) end

    local chunks, total, rc = {}, 0, Z_OK
    repeat
        local output = ffi.new("Bytef[?]", CHUNK)
        stream[0].next_out = output
        stream[0].avail_out = CHUNK
        rc = encode and libz.deflate(stream, Z_FINISH) or libz.inflate(stream, Z_NO_FLUSH)
        local produced = CHUNK - tonumber(stream[0].avail_out)
        if produced > 0 then
            total = total + produced
            if total > max_output or (not encode and total > math.max(1, #input) * max_ratio) then
                if encode then libz.deflateEnd(stream) else libz.inflateEnd(stream) end
                return nil, "gzip output exceeds safety limit"
            end
            chunks[#chunks + 1] = ffi.string(output, produced)
        end
        if rc ~= Z_OK and rc ~= Z_STREAM_END then break end
    until rc == Z_STREAM_END
    if encode then libz.deflateEnd(stream) else libz.inflateEnd(stream) end
    if rc ~= Z_STREAM_END then return nil, "zlib stream failed: " .. tostring(rc) end
    return table.concat(chunks)
end

function CompressionCompat:isAvailable() return libz ~= nil and version() ~= nil end
function CompressionCompat:gzip(value, options) return transform(value, true, options) end
function CompressionCompat:gunzip(value, options) return transform(value, false, options) end

return CompressionCompat
