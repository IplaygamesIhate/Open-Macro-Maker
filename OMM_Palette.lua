-- ==============================================================================
-- OMM_Palette.lua (Premium Orchestration Engine v5.0 - Absolute Mastery)
-- Protocol Zero: Bifurcated State Machine, ZigZag Harmonics, Bounded Gamut
-- ==============================================================================
local Palette = {}

-- ==========================================
-- 1. MATH & COLOR SCIENCE UTILITIES
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

local function RGBToOKLCH(r, g, b)
    local function lin(c) c = c / 255.0; return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055)^2.4 end
    local lr, lg, lb = lin(r), lin(g), lin(b)
    local l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
    local m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
    local s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb
    l, m, s = l > 0 and l^(1/3) or 0, m > 0 and m^(1/3) or 0, s > 0 and s^(1/3) or 0
    local L = 0.2104542553*l + 0.7936177850*m - 0.0040720468*s
    local a = 1.9779984951*l - 2.4285922050*m + 0.4505937099*s
    local b_val = 0.0259040371*l + 0.7827717662*m - 0.8086757660*s
    local C = math.sqrt(a^2 + b_val^2); local H = math.atan(b_val, a)
    if H < 0 then H = H + math.pi * 2 end
    return L, C, H
end

local function OKLCHToRGB_Raw(L, C, H)
    local a, b_val = C * math.cos(H), C * math.sin(H)
    local l = L + 0.3963377774 * a + 0.2158037573 * b_val
    local m = L - 0.1055613458 * a - 0.0638541728 * b_val
    local s = L - 0.0894841775 * a - 1.2914855480 * b_val
    l, m, s = l^3, m^3, s^3
    local lr = 4.0767416621*l - 3.3077115913*m + 0.2309699292*s
    local lg = -1.2684380046*l + 2.6097574011*m - 0.3413193965*s
    local lb = -0.0041960863*l - 0.7034186147*m + 1.7076147010*s
    local function unlin(c) return c <= 0.0031308 and c * 12.92 or 1.055 * c^(1/2.4) - 0.055 end
    return unlin(lr) * 255, unlin(lg) * 255, unlin(lb) * 255
end

-- ANALYTICAL GAMUT CLIPPING (4-Step Binary Search = 0 Thread Lag)
local function OKLCHToRGB_Safe(L, C, H)
    local r, g, b = OKLCHToRGB_Raw(L, C, H)
    if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 then
        local c_min, c_max = 0, C
        for i = 1, 4 do
            C = (c_min + c_max) / 2
            r, g, b = OKLCHToRGB_Raw(L, C, H)
            if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 then
                c_max = C
            else
                c_min = C
            end
        end
    end
    return math.max(0, math.min(255, math.floor(r + 0.5))),
           math.max(0, math.min(255, math.floor(g + 0.5))),
           math.max(0, math.min(255, math.floor(b + 0.5)))
end

-- ==========================================
-- 2. KNOWLEDGE BASE & MATRIX INIT
-- ==========================================
local PREMIUM_COLORS = { {0x1C1C1E, "Onyx"}, {0x2C363F, "Slate"}, {0x0A0A0A, "Void"}, {0xF5F5F7, "Snow"}, {0xE5E5EA, "Titanium"}, {0xC7C7CC, "Ash"}, {0xFF3B30, "Crimson"}, {0xFF9500, "Tangerine"}, {0xFFCC00, "Marigold"}, {0x34C759, "Emerald"}, {0x00C7BE, "Cyan"}, {0x32ADE6, "Cerulean"}, {0x007AFF, "Azure"}, {0x5856D6, "Indigo"}, {0xAF52DE, "Amethyst"}, {0xFF2D55, "Coral"}, {0x8E8E93, "Graphite"}, {0x48484A, "Charcoal"}, {0x1C2833, "Midnight"}, {0x5D6D7E, "Steel"}, {0xD4E6F1, "Ice"}, {0xFAE5D3, "Peach"}, {0xE8DAEF, "Lavender"}, {0x117A65, "Pine"}, {0xD35400, "Rust"}, {0x7D3C98, "Plum"}, {0x2E4053, "Navy"}, {0xBDC3C7, "Silver"} }
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
    local luma = 0.2126 * (r/255) + 0.7152 * (g/255) + 0.0722 * (b/255)
    return (luma > 0.179) and 0x1C1C1EFF or 0xF5F5F7FF 
end

local CURATED_MATRIX = {
  { id=1, theme="Vercel", Base=0x000000FF, Neutral=0x111111FF, Primary=0x0070F3FF, Accent=0xF81CE5FF, Text=0xFFFFFFFF },
  { id=2, theme="Raycast", Base=0x151515FF, Neutral=0x252525FF, Primary=0xFF6363FF, Accent=0x5E5CE6FF, Text=0xE5E5EAFF },
  { id=3, theme="Linear", Base=0x111216FF, Neutral=0x1D1F27FF, Primary=0x5E6AD2FF, Accent=0xE35885FF, Text=0xFFFFFFFF },
  { id=4, theme="Cosmos", Base=0x0A0A0CFF, Neutral=0x151519FF, Primary=0x4C6FFFFF, Accent=0xFFA7C4FF, Text=0xE3EEFFFF },
  { id=5, theme="Apple Ti", Base=0x2B2C2EFF, Neutral=0x3A3B3DFF, Primary=0x8E8E93FF, Accent=0xE5E5EAFF, Text=0xFFFFFFFF },
  { id=6, theme="Apple Mid", Base=0x000000FF, Neutral=0x1C1C1EFF, Primary=0x0A84FFFF, Accent=0x30D158FF, Text=0xE2E2E2FF },
  { id=7, theme="Stripe", Base=0x0B0F19FF, Neutral=0x161B2EFF, Primary=0x635BFFFF, Accent=0x00D4FFFF, Text=0xFFFFFFFF },
  { id=8, theme="Figma", Base=0x1E1E1EFF, Neutral=0x2C2C2CFF, Primary=0x18A0FBFF, Accent=0xF24E1EFF, Text=0xFFFFFFFF },
  { id=9, theme="Notion", Base=0x191919FF, Neutral=0x2F2F2FFF, Primary=0xEB5757FF, Accent=0xD9A521FF, Text=0xE0E0E0FF },
  { id=10, theme="Arc", Base=0x1C1C1EFF, Neutral=0x2A2A2DFF, Primary=0xFF5A5FFF, Accent=0xFFB800FF, Text=0xFFFFFFFF },
  { id=11, theme="Ableton", Base=0x1C1C1EFF, Neutral=0x2A2A2AFF, Primary=0xFF7600FF, Accent=0x00D0FFFF, Text=0xFFFFFFFF },
  { id=12, theme="OP-1", Base=0xE6E6E6FF, Neutral=0xC4C4C4FF, Primary=0xFF4A00FF, Accent=0x00D348FF, Text=0x000000FF },
  { id=13, theme="TX-6", Base=0x1C1C1EFF, Neutral=0x3A3A3AFF, Primary=0xFF5500FF, Accent=0x00E5FFFF, Text=0xB0B3B8FF },
  { id=14, theme="Elektron", Base=0x181818FF, Neutral=0x282828FF, Primary=0xE53935FF, Accent=0xFDD835FF, Text=0xE0E0E0FF },
  { id=15, theme="Moog", Base=0x1A1512FF, Neutral=0x3E2723FF, Primary=0xD35400FF, Accent=0xF39C12FF, Text=0xE0E0E0FF },
  { id=16, theme="TR-808", Base=0x111111FF, Neutral=0x222222FF, Primary=0xFF4500FF, Accent=0xFFD700FF, Text=0xE0E0E0FF },
  { id=17, theme="Strymon", Base=0x2980B9FF, Neutral=0x3498DBFF, Primary=0xECF0F1FF, Accent=0xE74C3CFF, Text=0xFFFFFFFF },
  { id=18, theme="Maths", Base=0x2B2B2BFF, Neutral=0x3D3D3DFF, Primary=0x2ECC71FF, Accent=0x9B59B6FF, Text=0xFFFFFFFF },
  { id=19, theme="Arturia", Base=0xEAEAEAFF, Neutral=0xD5D5D5FF, Primary=0x2C3E50FF, Accent=0xE67E22FF, Text=0x000000FF },
  { id=20, theme="Polybrute", Base=0x151010FF, Neutral=0x2D2626FF, Primary=0x20B2AAFF, Accent=0xE63946FF, Text=0xF4A261FF },
  { id=21, theme="Peach", Base=0x2B2220FF, Neutral=0x463835FF, Primary=0xFFBE98FF, Accent=0x508A88FF, Text=0xFDECEFFF },
  { id=22, theme="Very Peri", Base=0x1A1A24FF, Neutral=0x2A2A38FF, Primary=0x6667ABFF, Accent=0xFF7F66FF, Text=0xE2E2E2FF },
  { id=23, theme="Ult Gray", Base=0x222222FF, Neutral=0x444444FF, Primary=0xF5DF4DFF, Accent=0x939597FF, Text=0xFFFFFFFF },
  { id=24, theme="Blue", Base=0x0B132BFF, Neutral=0x1C2541FF, Primary=0x0F4C81FF, Accent=0xF2545BFF, Text=0xE9D2C0FF },
  { id=25, theme="Coral", Base=0x19323CFF, Neutral=0x2A4C58FF, Primary=0xFF6F61FF, Accent=0x2D728FFF, Text=0xFDE4D0FF },
  { id=26, theme="Bauhaus", Base=0xF0EAD6FF, Neutral=0xD4CFC2FF, Primary=0xC0392BFF, Accent=0x2980B9FF, Text=0x2E3436FF },
  { id=27, theme="Swiss", Base=0xFDFDFDFF, Neutral=0xE0E0E0FF, Primary=0xE74C3CFF, Accent=0x1C1C1EFF, Text=0x000000FF },
  { id=28, theme="Braun", Base=0xF4F4F4FF, Neutral=0xD1D1D1FF, Primary=0x2C3E50FF, Accent=0x27AE60FF, Text=0x000000FF },
  { id=29, theme="Synth84", Base=0x2B213AFF, Neutral=0x4D3C65FF, Primary=0xFF2A6DFF, Accent=0x05D9E8FF, Text=0xF1C40FFF },
  { id=30, theme="Cyberpunk", Base=0x0F0F1AFF, Neutral=0x1A1A33FF, Primary=0xFCEE09FF, Accent=0x00F0FFFF, Text=0xFF003CFF },
  { id=31, theme="Dracula", Base=0x282A36FF, Neutral=0x44475AFF, Primary=0xFF79C6FF, Accent=0xBD93F9FF, Text=0xF8F8F2FF },
  { id=32, theme="Nord", Base=0x2E3440FF, Neutral=0x4C566AFF, Primary=0x88C0D0FF, Accent=0xBF616AFF, Text=0xD8DEE9FF },
  { id=33, theme="Gruvbox", Base=0x282828FF, Neutral=0x504945FF, Primary=0xFE8019FF, Accent=0x8EC07CFF, Text=0xEBDBB2FF },
  { id=34, theme="Monokai", Base=0x2D2A2EFF, Neutral=0x727072FF, Primary=0xFF6188FF, Accent=0xA9DC76FF, Text=0xFC9867FF },
  { id=35, theme="Solarized", Base=0x002B36FF, Neutral=0x073642FF, Primary=0x268BD2FF, Accent=0xDC322FFF, Text=0x93A1A1FF },
  { id=36, theme="OneDark", Base=0x282C34FF, Neutral=0x3E4451FF, Primary=0xC678DDFF, Accent=0x56B6C2FF, Text=0xABB2BFFF },
  { id=37, theme="Tokyo", Base=0x1A1B26FF, Neutral=0x24283BFF, Primary=0xBB9AF7FF, Accent=0x7DCFFFFF, Text=0xC0CAF5FF },
  { id=38, theme="Catppuccin", Base=0x1E1E2EFF, Neutral=0x313244FF, Primary=0xCBA6F7FF, Accent=0x89B4FAFF, Text=0xCDD6F4FF },
  { id=39, theme="RoséPine", Base=0x191724FF, Neutral=0x26233AFF, Primary=0xEB6F92FF, Accent=0x9CCFD8FF, Text=0xE0DEF4FF },
  { id=40, theme="NightOwl", Base=0x011627FF, Neutral=0x011627FF, Primary=0xC792EAFF, Accent=0x82AAFFFF, Text=0xD6DEEBFF },
  { id=41, theme="Winamp", Base=0x1A1C23FF, Neutral=0x2E323FFF, Primary=0xFF8C00FF, Accent=0x00BFFFFF, Text=0xD9DCE3FF },
  { id=42, theme="Y2K Cyber", Base=0x030303FF, Neutral=0x1A1A1AFF, Primary=0x00FF41FF, Accent=0x0A84FFFF, Text=0xE2E2E2FF },
  { id=43, theme="A24", Base=0x1A1A1AFF, Neutral=0x333333FF, Primary=0xF9F9F9FF, Accent=0xC8102EFF, Text=0xF2C94CFF },
  { id=44, theme="Monocle", Base=0x2C3E50FF, Neutral=0x34495EFF, Primary=0xD4AC0DFF, Accent=0xE74C3CFF, Text=0xFDFEFEFF },
  { id=45, theme="Superhuman", Base=0x1A1A24FF, Neutral=0x2A2A38FF, Primary=0x7B61FFFF, Accent=0xE94E77FF, Text=0x43D8C9FF },
  { id=46, theme="KO-II", Base=0xE5E5E5FF, Neutral=0xCCCCCCFF, Primary=0xFF5722FF, Accent=0x1C1C1EFF, Text=0xFF0000FF },
  { id=47, theme="Switch", Base=0x262626FF, Neutral=0x404040FF, Primary=0xE60012FF, Accent=0x00C3E3FF, Text=0xFFFFFFFF },
  { id=48, theme="PS5 Dark", Base=0x121212FF, Neutral=0x222222FF, Primary=0x00439CFF, Accent=0xFFFFFFFF, Text=0x0070D1FF },
  { id=49, theme="Xbox Orig", Base=0x051005FF, Neutral=0x1A331AFF, Primary=0x38EA11FF, Accent=0xA8FF9EFF, Text=0x004000FF },
  { id=50, theme="Vinted", Base=0xFFFFFFFF, Neutral=0xF0F0F0FF, Primary=0x09B1BAFF, Accent=0x1C1C1EFF, Text=0xFDE4D0FF }
}

local ENVELOPES = {
    Base =    { L_min = 0.05, L_max = 0.20, C_min = 0.00, C_max = 0.05 },
    Neutral = { L_min = 0.20, L_max = 0.40, C_min = 0.00, C_max = 0.10 },
    Primary = { L_min = 0.40, L_max = 0.75, C_min = 0.15, C_max = 0.35 },
    Accent =  { L_min = 0.85, L_max = 0.95, C_min = 0.25, C_max = 0.50 }, 
    Text =    { L_min = 0.85, L_max = 1.00, C_min = 0.00, C_max = 0.05 }
}

for _, row in ipairs(CURATED_MATRIX) do
    row.oklch = {}
    for _, role in ipairs({"Base", "Neutral", "Primary", "Accent", "Text"}) do
        local hex = row[role]
        local r, g, b = (hex >> 24) & 0xFF, (hex >> 16) & 0xFF, (hex >> 8) & 0xFF
        local L, C, H = RGBToOKLCH(r, g, b)
        row.oklch[role] = {L=L, C=C, H=H}
    end
end

-- ==========================================
-- 3. THE GATEKEEPER & BRIDGES
-- ==========================================
local function MapToRole(token_name)
    if not token_name then return "Primary" end
    local t = string.lower(tostring(token_name))
    if string.find(t, "base") or string.find(t, "void") or string.find(t, "onyx") or string.find(t, "graphite") then return "Base"
    elseif string.find(t, "text") or string.find(t, "snow") then return "Text"
    elseif string.find(t, "accent") or string.find(t, "tangerine") or string.find(t, "cyan") then return "Accent"
    elseif string.find(t, "neutral") or string.find(t, "secondary") then return "Neutral"
    else return "Primary" end
end

function Palette.Generate(seed_hex)
    local matrix_row = CURATED_MATRIX[1] 
    return {
        Base        = matrix_row.Base,
        Secondary   = matrix_row.Neutral,
        TextDim     = 0x888888FF,
        TextBright  = matrix_row.Text,
        Accent_A    = matrix_row.Primary,
        Accent_B    = matrix_row.Accent,
        Teal        = 0x005F73FF, 
        Tangerine   = 0xFF6B35FF
    }
end

-- ==========================================
-- 4. THE AESTHETIC PURE FUNCTION
-- ==========================================
function Palette.GetHarmoniousVariant(hex_32, source_token, gen_index, hue_drift, force_contrast, last_used_row_id)
    gen_index = tonumber(gen_index) or 0
    hue_drift = tonumber(hue_drift) or 0.0
    last_used_row_id = tonumber(last_used_row_id) or 0

    local safe_role = MapToRole(source_token)
    local target_role = force_contrast and "Accent" or safe_role
    
    local r, g, b, alpha = (hex_32 >> 24) & 0xFF, (hex_32 >> 16) & 0xFF, (hex_32 >> 8) & 0xFF, hex_32 & 0xFF
    local L, C, H = RGBToOKLCH(r, g, b)
    local final_row_id = 1

    -- BIFURCATED STATE MACHINE
    if force_contrast then
        -- -----------------------------------------------------------------
        -- STATE A: MATRIX ORCHESTRATION (Expert Contrast Variant)
        -- -----------------------------------------------------------------
        local PENALTY_WEIGHT = 0.15
        local best_score, best_row, raw_dist = 999999, CURATED_MATRIX[1], 0
        
        for _, row in ipairs(CURATED_MATRIX) do
            if row and row.oklch and row.oklch[safe_role] and row.oklch[target_role] then
                local rc = row.oklch[safe_role]
                local dist = math.sqrt((L - rc.L)^2 + (C - rc.C)^2 + (H - rc.H)^2)
                local penalty = (row.id == last_used_row_id) and PENALTY_WEIGHT or 0
                if (dist + penalty) < best_score then 
                    best_score = dist + penalty
                    best_row = row
                    raw_dist = dist 
                end
            end
        end

        if best_row and best_row.oklch and best_row.oklch[target_role] and best_row.oklch[safe_role] then
            final_row_id = best_row.id
            -- CRITICAL FIX: Lower Confidence Gate (0.05) to shatter the lazy loop
            if raw_dist < 0.05 then
                local vec_L = best_row.oklch[target_role].L - best_row.oklch[safe_role].L
                local vec_C = best_row.oklch[target_role].C - best_row.oklch[safe_role].C
                local vec_H = best_row.oklch[target_role].H - best_row.oklch[safe_role].H
                
                local modifier = 1.0 + (gen_index * 0.15)
                L = L + (vec_L * modifier)
                C = C + (vec_C * modifier)
                H = H + (vec_H * modifier) + hue_drift
            else
                H = H + 0.523 + hue_drift
                C = C + 0.10
                L = 0.90
            end
        else
            H = H + 0.523; C = C + 0.10; L = 0.90
        end

    else
        -- -----------------------------------------------------------------
        -- STATE B: ALGORITHMIC HARMONICS (The Bypass for Zero-Vectors)
        -- -----------------------------------------------------------------
        -- 1. Unconditionally shift hue by ~25 degrees
        H = H + 0.436 + hue_drift
        
        -- 2. ZigZag Variance to guarantee immediate visual difference
        if gen_index % 2 == 0 then
            L = L + 0.05
            C = C * 0.90
        else
            L = L - 0.05
            C = C * 1.10
        end

        -- 3. Invisible Grey Overdrive (Injects color if target is pure white/black)
        if safe_role == "Base" or safe_role == "Neutral" or safe_role == "Text" then
            L = L + (gen_index % 2 == 0 and 0.08 or -0.08)
            C = C + 0.05 
        end
        
        final_row_id = last_used_row_id
    end

    -- BOUNDS & CLAMPING
    H = H % (math.pi * 2)

    local env = ENVELOPES[target_role] or ENVELOPES["Primary"]
    if not env then env = { L_min = 0.0, L_max = 1.0, C_min = 0.0, C_max = 1.0 } end
    
    L = math.max(env.L_min, math.min(env.L_max, L))
    C = math.max(env.C_min, math.min(env.C_max, C))
    
    local nr, ng, nb = OKLCHToRGB_Safe(L, C, H)
    local new_hex = (nr << 24) | (ng << 16) | (nb << 8) | alpha
    
    -- ADVANCE STATE FOR NEXT CLICK
    local n_gen = (gen_index + 1) % 5
    local n_drift = (hue_drift + 0.15) % (math.pi * 2)
    
    return new_hex, Palette.GetColorName(new_hex), n_gen, n_drift, final_row_id
end

return Palette