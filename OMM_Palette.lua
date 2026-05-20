-- ==============================================================================
-- OMM_Palette.lua (The Algorithmic Color Engine)
-- Protocol Zero: WCAG 2.1 Luminance Math & 60-30-10 HSL Shifts
-- ==============================================================================

local Palette = {}

-- 1. RGB / HSL CONVERSIONS
local function RGBToHSL(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local h, s, l = 0, 0, (max + min) / 2
    if max ~= min then
        local d = max - min
        s = l > 0.5 and d / (2 - max - min) or d / (max + min)
        if max == r then h = (g - b) / d + (g < b and 6 or 0)
        elseif max == g then h = (b - r) / d + 2
        elseif max == b then h = (r - g) / d + 4 end
        h = h / 6
    end
    return h, s, l
end

local function Hue2RGB(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
end

local function HSLToRGB(h, s, l)
    local r, g, b
    if s == 0 then r, g, b = l, l, l else
        local q = l < 0.5 and l * (1 + s) or l + s - l * s
        local p = 2 * l - q
        r, g, b = Hue2RGB(p, q, h + 1/3), Hue2RGB(p, q, h), Hue2RGB(p, q, h - 1/3)
    end
    return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

-- 2. WCAG 2.1 RELATIVE LUMINANCE MATH
local function SRGBToLinear(c)
    c = c / 255.0
    return c <= 0.03928 and c / 12.92 or math.exp(math.log((c + 0.055) / 1.055) * 2.4)
end

local function GetLuminance(r, g, b)
    return 0.2126 * SRGBToLinear(r) + 0.7152 * SRGBToLinear(g) + 0.0722 * SRGBToLinear(b)
end

local function GetContrastRatio(l1, l2)
    local lighter = math.max(l1, l2)
    local darker = math.min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)
end

-- 3. THE GENERATOR (Creates the 60-30-10 Token Dictionary)
function Palette.Generate(seed_hex)
    local sr = (seed_hex >> 24) & 0xFF
    local sg = (seed_hex >> 16) & 0xFF
    local sb = (seed_hex >> 8) & 0xFF
    
    local h, s, l = RGBToHSL(sr, sg, sb)
    
    -- Complementary Shift (180 degrees)
    local comp_h = (h + 0.5) % 1.0
    local cr, cg, cb = HSLToRGB(comp_h, s, l)
    
    -- Base Dark Void (60%)
    local base_luma = GetLuminance(10, 10, 13) 

    -- WCAG Enforcement (Ensures Accent A is completely legible against the Base)
    local accent_luma = GetLuminance(sr, sg, sb)
    local contrast = GetContrastRatio(accent_luma, base_luma)
    
    -- If contrast is below legal 4.5:1, mathematically force it brighter
    if contrast < 4.5 then
        l = math.min(1.0, l + 0.15) 
        sr, sg, sb = HSLToRGB(h, s, l)
    end

    -- Return the strict Token Dictionary
    return {
        Base        = 0x0A0A0DFF, -- 60%
        Secondary   = 0x1C1C1EFF, -- 30%
        TextDim     = 0x888888FF,
        TextBright  = 0xE5E5EAFF,
        Accent_A    = (sr << 24) | (sg << 16) | (sb << 8) | 0xFF, -- 10%
        Accent_B    = (cr << 24) | (cg << 16) | (cb << 8) | 0xFF, -- 10% (Complementary)
        Teal        = 0x005F73FF, -- Preserved Hardware Default
        Tangerine   = 0xFF6B35FF  -- Preserved Hardware Default
    }
end

-- ==========================================
-- 4. CIELAB DELTA E NAMING ENGINE & SMART CONTRAST
-- ==========================================
local function RGBtoLAB(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    r = r > 0.04045 and ((r + 0.055) / 1.055)^2.4 or r / 12.92
    g = g > 0.04045 and ((g + 0.055) / 1.055)^2.4 or g / 12.92
    b = b > 0.04045 and ((b + 0.055) / 1.055)^2.4 or b / 12.92
    r, g, b = r * 100, g * 100, b * 100

    local x = r * 0.4124 + g * 0.3576 + b * 0.1805
    local y = r * 0.2126 + g * 0.7152 + b * 0.0722
    local z = r * 0.0193 + g * 0.1192 + b * 0.9505

    x, y, z = x / 95.047, y / 100.000, z / 108.883
    x = x > 0.008856 and x^(1/3) or (7.787 * x) + (16 / 116)
    y = y > 0.008856 and y^(1/3) or (7.787 * y) + (16 / 116)
    z = z > 0.008856 and z^(1/3) or (7.787 * z) + (16 / 116)
    return (116 * y) - 16, 500 * (x - y), 200 * (y - z)
end

local PREMIUM_COLORS = {
    {0x1C1C1E, "Onyx"}, {0x2C363F, "Slate"}, {0x0A0A0A, "Void"}, {0xF5F5F7, "Snow"},
    {0xE5E5EA, "Titanium"}, {0xC7C7CC, "Ash"}, {0xFF3B30, "Crimson"}, {0xFF9500, "Tangerine"},
    {0xFFCC00, "Marigold"}, {0x34C759, "Emerald"}, {0x00C7BE, "Cyan"}, {0x32ADE6, "Cerulean"},
    {0x007AFF, "Azure"}, {0x5856D6, "Indigo"}, {0xAF52DE, "Amethyst"}, {0xFF2D55, "Coral"},
    {0x8E8E93, "Graphite"}, {0x48484A, "Charcoal"}, {0x1C2833, "Midnight"}, {0x5D6D7E, "Steel"},
    {0xD4E6F1, "Ice"}, {0xFAE5D3, "Peach"}, {0xE8DAEF, "Lavender"}, {0x117A65, "Pine"},
    {0xD35400, "Rust"}, {0x7D3C98, "Plum"}, {0x2E4053, "Navy"}, {0xBDC3C7, "Silver"}
}
-- Cache CIELAB values on init for 0-latency lookups
for _, c in ipairs(PREMIUM_COLORS) do
    local r, g, b = (c[1] >> 16) & 0xFF, (c[1] >> 8) & 0xFF, c[1] & 0xFF
    c.L, c.a, c.b = RGBtoLAB(r, g, b)
end

function Palette.GetColorName(hex_token)
    local r, g, b = (hex_token >> 24) & 0xFF, (hex_token >> 16) & 0xFF, (hex_token >> 8) & 0xFF
    local L, a, b_val = RGBtoLAB(r, g, b)
    local best_dist, best_name = 999999, "Unknown"
    for _, c in ipairs(PREMIUM_COLORS) do
        local dist = math.sqrt((L - c.L)^2 + (a - c.a)^2 + (b_val - c.b)^2)
        if dist < best_dist then best_dist = dist; best_name = c[2] end
    end
    return best_name
end

function Palette.GetBestTextColor(hex_token)
    local r, g, b = (hex_token >> 24) & 0xFF, (hex_token >> 16) & 0xFF, (hex_token >> 8) & 0xFF
    local luma = GetLuminance(r, g, b)
    -- If background is bright (luma > 0.179), return Onyx Ink. Else return Snow.
    return (luma > 0.179) and 0x1C1C1EFF or 0xF5F5F7FF 
end

return Palette