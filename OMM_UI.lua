-- ==============================================================================
-- OMM_UI.lua (The Complete Luxury Graphics Engine + Standalone CAD Factory)
-- Protocol Zero: Seatbelt Drag Logic, Safe Stack Pops & Premium Toolbox
-- ==============================================================================
local UI = { 
    filter_layer = nil, locked_layer = nil, layer_toolbar_collapsed = false,
    toggle_anim_states={}, active_edit_id=nil, edit_buffer="", selected_comp_ids={}, 
    knob_histories={}, physics_states={}, dropdown_states={}, hover_states={},
    snap_enabled=true, theme_seed_hex=0x00A5FFFF, edit_mode=true,
    undo_stack={}, redo_stack={},
    drag_mem={ next_win_x=nil, next_win_y=nil, mouse_start_x=0, mouse_start_y=0, 
               comp_start_x=0, comp_start_y=0, is_snapped_x=false, is_snapped_y=false, 
               locked_x=0, locked_y=0, anchor_mouse_x=0, anchor_mouse_y=0, line_x=0, line_y=0,
               is_marquee=false, marquee_start_x=0, marquee_start_y=0, group_starts={} },
    snap_radius=8, break_tension=24,
    theme_manager = { current_theme = "Default", new_theme_name = "", is_creating = false, list = {} },
    search_filter = "", config = { defaults = {} },
    camera = { pan_x = 0, pan_y = 0, zoom = 1.0 },
    ide_camera = { pan_x = 0, pan_y = 0, zoom = 1.0 }, active_tool = "SELECT",
    palette_open = false, palette_height = 250, drag_col_idx = nil,
    prop_pane_width = 280, -- Added to maintain state across frame reloads
    BASE_GRID = 40.0,
    notifications = {}, notif_counter = 0, palette_search = "",
    active_palette = { 
        { id=1, hex = 0x00E5FFFF, token = "Primary", gen_index=0, hue_drift=0.0 }, 
        { id=2, hex = 0xFF6B35FF, token = "Accent", gen_index=0, hue_drift=0.0 },
        { id=3, hex = 0xF5F5F7FF, token = "Text", gen_index=0, hue_drift=0.0 },
        { id=4, hex = 0x8E8E93FF, token = "Neutral", gen_index=0, hue_drift=0.0 },
        { id=5, hex = 0x1C1C1EFF, token = "Base", gen_index=0, hue_drift=0.0 }
    },
    canvas_physics = {
        target_scale = 1.0, current_scale = 1.0, min_scale = 0.50, max_scale = 2.00,
        lerp_speed = 18.0, is_zooming = false, anchor_world_x = 0, anchor_world_y = 0
    },
    ide_physics = {
        target_scale = 1.0, current_scale = 1.0, min_scale = 0.50, max_scale = 4.00,
        lerp_speed = 18.0, is_zooming = false, anchor_world_x = 0, anchor_world_y = 0, anchor_mx = 0, anchor_my = 0
    }
}

-- ==============================================================================
-- PRO CODE: DOMAIN SCALE REGISTRY & FONT ATLAS
-- ==============================================================================
UI.ScaleRegistry = {
    -- The Immutable Fixed Steps (Min 50% to Max 200%)
    steps = { 0.50, 0.75, 0.90, 1.0, 1.10, 1.25, 1.50 },
    
    -- Independent Domain Tracking (Storing the Index, Default is 4 -> 1.0x)
    DeviceLane_Idx = 4,
    IDE_Idx = 4,
    
    -- The Canvas uses continuous oversampling, so it tracks the raw float
    Canvas_Scale = 1.0, 
    
    -- GPU Memory Pointers
    Fonts = {},         -- Holds the Fixed-Step fonts
    Canvas_Font = nil,  -- Holds the massive 200% font for downscaling
    is_initialized = false
}

function UI.InitFontAtlas(ctx)
    if UI.ScaleRegistry.is_initialized then return end

    local base_size = 14
    local font_name = 'sans-serif'

    -- 1. Bake the Fixed-Step Fonts for the Device Lane & IDE
    for i, scale in ipairs(UI.ScaleRegistry.steps) do
        local size = math.floor((base_size * scale) + 0.5)
        local f = reaper.ImGui_CreateFont(font_name, size)
        reaper.ImGui_Attach(ctx, f)
        UI.ScaleRegistry.Fonts[i] = f
    end

    -- 2. Bake the Massive Font for Canvas Oversampling (Using 200% = 28px)
    local oversample_size = math.floor((base_size * 2.0) + 0.5)
    UI.ScaleRegistry.Canvas_Font = reaper.ImGui_CreateFont(font_name, oversample_size)
    reaper.ImGui_Attach(ctx, UI.ScaleRegistry.Canvas_Font)

    UI.ScaleRegistry.is_initialized = true
end
-- ==============================================================================

local function LoadOSConfig()
    local fpath = (debug.getinfo(1, "S").source:match("@?(.*[\\/])") or "") .. "OMM_Config.lua"
    local chunk = loadfile(fpath)
    if chunk then 
        local ok, dat = pcall(chunk)
        if ok and dat then UI.config = dat return end
    end
    UI.config = { defaults = {} }
end
LoadOSConfig()

UI.PaletteEngine = dofile((debug.getinfo(1, "S").source:match("@?(.*[\\/])") or "") .. "OMM_Palette.lua")

function UI.WriteOSConfig()
    local fpath = (debug.getinfo(1, "S").source:match("@?(.*[\\/])") or "") .. "OMM_Config.lua"
    local f = io.open(fpath, "w")
    if f then
        f:write("return {\n  defaults = {\n")
        for k, v in pairs(UI.config.defaults) do f:write(string.format("    [%d] = '%s',\n", k, v)) end
        f:write("  }\n}\n")
        f:close()
    end
end

function UI.DeepCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do copy[UI.DeepCopy(orig_key)] = UI.DeepCopy(orig_value) end
        setmetatable(copy, UI.DeepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

function UI.PushUndoState()
    if not UI.wb_schema_buffer then return end
    table.insert(UI.undo_stack, UI.DeepCopy(UI.wb_schema_buffer))
    UI.redo_stack = {}
end

function UI.Lerp(a, b, t) return a + (b - a) * t end
function UI.ApplyAlpha(col, alpha) return (col & 0xFFFFFF00) | math.floor((col & 0xFF) * (tonumber(alpha) or 1.0)) end
function UI.LerpColor(c1, c2, t)
    local r1, g1, b1, a1 = (c1>>24)&0xFF, (c1>>16)&0xFF, (c1>>8)&0xFF, c1&0xFF
    local r2, g2, b2, a2 = (c2>>24)&0xFF, (c2>>16)&0xFF, (c2>>8)&0xFF, c2&0xFF
    return (math.floor(r1+(r2-r1)*t)<<24) | (math.floor(g1+(g2-g1)*t)<<16) | (math.floor(b1+(b2-b1)*t)<<8) | math.floor(a1+(a2-a1)*t)
end

function UI.SpringDamp(current, target, velocity, tension, friction, dt)
    local force = -tension * (current - target) - friction * velocity
    velocity = velocity + force * dt
    current = current + velocity * dt
    return current, velocity
end

function UI.PushNotification(msg, color)
    table.insert(UI.notifications, { id = UI.notif_counter, text = msg, time = 0.0, alpha = 0.0, color = color or 0x00E5FFFF })
    UI.notif_counter = UI.notif_counter + 1
    if #UI.notifications > 3 then table.remove(UI.notifications, 1) end
end

function UI.DrawNotifications(ctx, dl, center_x, start_y, dt)
    local ny = start_y
    for i = #UI.notifications, 1, -1 do
        local n = UI.notifications[i]
        n.time = n.time + dt
        local target_alpha = (n.time < 2.0) and 1.0 or 0.0
        n.alpha = UI.SpringDamp(n.alpha, target_alpha, n.vel or 0, 200, 15, dt)
        if n.alpha < 0.01 and n.time >= 2.0 then table.remove(UI.notifications, i) else
            local _, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, n.text)
            tw = tonumber(tw) or 100; th = tonumber(th) or 20
            local pill_w, pill_h = tw + 40, th + 16
            local px = center_x - (pill_w / 2)
            reaper.ImGui_DrawList_AddRectFilled(dl, px, ny - pill_h, px + pill_w, ny, 0x11111100 | math.floor(0xEE * n.alpha), 16.0)
            reaper.ImGui_DrawList_AddRect(dl, px, ny - pill_h, px + pill_w, ny, 0xFFFFFF00 | math.floor(0x22 * n.alpha), 16.0, 0, 1.0)
            reaper.ImGui_DrawList_AddCircleFilled(dl, px + 16, ny - (pill_h/2), 4, n.color & 0xFFFFFF00 | math.floor(0xFF * n.alpha))
            UI.DrawStandardText(dl, px + 28, ny - (pill_h/2) - (th/2), n.text, 0xFFFFFFFF, n.alpha)
            ny = ny - ((pill_h + 10) * n.alpha)
        end
    end
end

function UI.IsComponentSelected(id)
    if not id then return false end
    for _, s_id in ipairs(UI.selected_comp_ids) do
        if s_id == id then return true end
    end
    return false
end

function UI.SelectComponent(id, keep_existing)
    if not keep_existing then UI.selected_comp_ids = {} end
    if id and not UI.IsComponentSelected(id) then
        table.insert(UI.selected_comp_ids, id)
    end
end

function UI.Safe_InvisibleButton(ctx, id, w, h) 
    local ok = reaper.ImGui_InvisibleButton(ctx, tostring(id), math.max(1.0, w), math.max(1.0, h)) 
    
    -- THE HOVER GUARD: If ANY component is hovered or actively being dragged, lock the chassis.
    if reaper.ImGui_IsItemHovered(ctx) or reaper.ImGui_IsItemActive(ctx) then
        UI.hovered_component = id
    end
    
    -- THE SELECTION BRIDGE: Interacting in Play Mode selects it for the Property Pane
    if not UI.edit_mode and ok and select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then
        local base_id = tostring(id)
        base_id = base_id:gsub("_knob$", "")
        base_id = base_id:gsub("_fader$", "")
        base_id = base_id:gsub("_drop$", "")
        base_id = base_id:gsub("_seg_%d+$", "")
        
        local is_comp = false
        if UI.wb_schema_buffer then
            for _, comp in ipairs(UI.wb_schema_buffer) do
                if comp.id == base_id then is_comp = true; break end
            end
        end
        if is_comp then
            UI.selected_comp_ids = {base_id}
        end
    end
    
    return ok
end

function UI.DrawModeToggle(ctx, dl, x, y, act_a)
    local w, h = 100, 30
    local a = tonumber(act_a) or 1.0
    pcall(reaper.ImGui_SetCursorScreenPos, ctx, x, y)
    local ok = UI.Safe_InvisibleButton(ctx, "mode_toggle", w, h)
    local hovered = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
    if hovered and select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then 
        UI.edit_mode = not UI.edit_mode
    end
    
    local bg_col = UI.edit_mode and 0x222222FF or 0x111111FF
    pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x, y, x + w, y + h, bg_col & 0xFFFFFF00 | math.floor(0xFF*a), 4.0)
    
    local tx = UI.edit_mode and "DESIGN MODE" or "PLAY MODE"
    local t_col = UI.edit_mode and 0x00A5FFFF or 0x00FF88FF
    if hovered then t_col = 0xFFFFFFFF end
    
    local _, tw = pcall(reaper.ImGui_CalcTextSize, ctx, tx)
    UI.DrawStandardText(dl, x + (w/2) - ((tonumber(tw) or 0)/2), y + 8, tx, t_col, a)
    
    return ok
end

-- ==========================================================
-- PRO CODE: KINEMATIC TEXT RENDERER (IDE Legacy Safe)
-- ==========================================================
function UI.DrawStandardText(draw_list, x, y, text, col, alpha_mult, opt_font, opt_size)
    local a = tonumber(alpha_mult) or 1.0
    
    -- PRO FIX: Subpixel Immune Floor Anchor
    local fx = math.floor(x + 0.5)
    local fy = math.floor(y + 0.5)
    
    if opt_font and opt_size then
        -- 1. ZOOMED CANVAS ROUTE: Uses AddTextEx for absolute 200% oversampled clarity.
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx+1, fy+1, 0x00000000 | math.floor(0xFF*a), tostring(text))
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx, fy, (col & 0xFFFFFF00) | math.floor((col & 0xFF)*a), tostring(text))
    else
        -- 2. STATIC UI ROUTE: Safely falls back to native AddText for sidebars and toolbars.
        reaper.ImGui_DrawList_AddText(draw_list, fx+1, fy+1, 0x00000000 | math.floor(0xFF*a), tostring(text))
        reaper.ImGui_DrawList_AddText(draw_list, fx, fy, (col & 0xFFFFFF00) | math.floor((col & 0xFF)*a), tostring(text))
    end
end

function UI.DrawAnimatedDisclosure(ctx, dl, id, label, is_open, dt, w)
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_InvisibleButton(ctx, id, math.max(1.0, w), 24)
    local clicked = reaper.ImGui_IsItemClicked(ctx); if clicked then is_open = not is_open end
    if not UI.toggle_anim_states[id] then UI.toggle_anim_states[id] = { val = is_open and 1.0 or 0.0, vel = 0.0 } end
    local state = UI.toggle_anim_states[id]
    state.val, state.vel = UI.SpringDamp(state.val, is_open and 1.0 or 0.0, state.vel, 250.0, 18.0, dt)
    local t = state.val; local col = reaper.ImGui_IsItemHovered(ctx) and 0xFFFFFFFF or 0x8E8E93FF
    local rad = 5.0; local angle = t * (math.pi / 2)
    local p1x, p1y = cx + 10 + math.cos(angle - math.pi/2) * rad, cy + 12 + math.sin(angle - math.pi/2) * rad
    local p2x, p2y = cx + 10 + math.cos(angle + math.pi*0.8) * rad, cy + 12 + math.sin(angle + math.pi*0.8) * rad
    local p3x, p3y = cx + 10 + math.cos(angle + math.pi*0.2) * rad, cy + 12 + math.sin(angle + math.pi*0.2) * rad
    reaper.ImGui_DrawList_AddTriangleFilled(dl, p1x, p1y, p2x, p2y, p3x, p3y, col)
    UI.DrawStandardText(dl, cx + 24, cy + 5, label, col, 1.0)
    return clicked, is_open, math.max(0.001, t)
end

function UI.DrawAnimatedPlus(ctx, dl, id, is_active, dt, cx, cy)
    reaper.ImGui_SetCursorScreenPos(ctx, cx, cy)
    reaper.ImGui_InvisibleButton(ctx, id, 24, 24)
    local clicked = reaper.ImGui_IsItemClicked(ctx); if clicked then is_active = not is_active end
    if not UI.toggle_anim_states[id] then UI.toggle_anim_states[id] = { val = is_active and 1.0 or 0.0, vel = 0.0 } end
    local state = UI.toggle_anim_states[id]
    state.val, state.vel = UI.SpringDamp(state.val, is_active and 1.0 or 0.0, state.vel, 250.0, 15.0, dt)
    local t = state.val; local hov = reaper.ImGui_IsItemHovered(ctx)
    local col = hov and 0xFFFFFFFF or 0xAAAAAAFF; local bg_col = hov and 0xFFFFFF22 or 0xFFFFFF0A
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx + 12, cy + 12, 12, bg_col)
    local rad = 6.0; local angle = t * (math.pi / 4) 
    local c = math.cos(angle); local s = math.sin(angle)
    local l1_dx = c * rad; local l1_dy = s * rad; local l2_dx = -s * rad; local l2_dy = c * rad
    reaper.ImGui_DrawList_AddLine(dl, cx + 12 - l1_dx, cy + 12 - l1_dy, cx + 12 + l1_dx, cy + 12 + l1_dy, col, 2.0)
    reaper.ImGui_DrawList_AddLine(dl, cx + 12 - l2_dx, cy + 12 - l2_dy, cx + 12 + l2_dx, cy + 12 + l2_dy, col, 2.0)
    if hov then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand()) end
    return clicked, is_active, t
end

function UI.DrawVectorIcon(ctx, dl, id, icon_type, is_active)
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    UI.Safe_InvisibleButton(ctx, id, 28, 28)
    local hov = reaper.ImGui_IsItemHovered(ctx)
    local clicked = reaper.ImGui_IsItemClicked(ctx)
    local col = (is_active or hov) and 0x00E5FFFF or 0x888888FF
    if hov then reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx+28, cy+28, 0xFFFFFF11, 4.0) end
    
    if icon_type == "ALIGN_L" then
        reaper.ImGui_DrawList_AddLine(dl, cx+6, cy+4, cx+6, cy+24, col, 2.0)
        reaper.ImGui_DrawList_AddRectFilled(dl, cx+8, cy+6, cx+20, cy+10, col)
        reaper.ImGui_DrawList_AddRectFilled(dl, cx+8, cy+14, cx+16, cy+18, col)
    elseif icon_type == "ALIGN_C" then
        reaper.ImGui_DrawList_AddLine(dl, cx+14, cy+4, cx+14, cy+24, col & 0xFFFFFF88, 1.0)
        reaper.ImGui_DrawList_AddRectFilled(dl, cx+8, cy+6, cx+20, cy+10, col)
        reaper.ImGui_DrawList_AddRectFilled(dl, cx+10, cy+14, cx+18, cy+18, col)
    elseif icon_type == "ALIGN_R" then
        reaper.ImGui_DrawList_AddLine(dl, cx+22, cy+4, cx+22, cy+24, col, 2.0)
        reaper.ImGui_DrawList_AddRectFilled(dl, cx+8, cy+6, cx+20, cy+10, col)
        reaper.ImGui_DrawList_AddRectFilled(dl, cx+12, cy+14, cx+20, cy+18, col)
    elseif icon_type == "SEARCH" then
        reaper.ImGui_DrawList_AddCircle(dl, cx+12, cy+12, 6, col, 0, 2.0)
        reaper.ImGui_DrawList_AddLine(dl, cx+16, cy+16, cx+22, cy+22, col, 2.0)
    end
    return clicked
end

-- ==========================================
-- SMART GUIDES & HYSTERESIS ENGINE (DUAL-CURSOR)
-- ==========================================
local function GetBounds(c)
    if c.type == "AuraKnob" then local r = c.radius or 16; return c.x, c.y, r*2, r*2
    else return c.x, c.y, c.w or 60, c.h or 20 end
end

local function ProcessSmartGuides(c, intended_x, intended_y, components, dl, cx, cy, mouse_x, mouse_y)
    local SNAP, BREAK = UI.snap_radius, UI.break_tension
    local bx, by, bw, bh = GetBounds(c)

    if not UI.drag_mem.is_snapped_x then
        local best_dist, lock_val, line_pos = SNAP, nil, nil
        local i_cx, i_left, i_right = intended_x + bw/2, intended_x, intended_x + bw
        for _, p in ipairs(components) do
            if p.id ~= c.id then
                local px, py, pw, ph = GetBounds(p); local p_cx, p_left, p_right = px + pw/2, px, px + pw
                if math.abs(i_cx - p_cx) < best_dist then best_dist = math.abs(i_cx - p_cx); lock_val = p_cx - bw/2; line_pos = p_cx end
                if math.abs(i_left - p_left) < best_dist then best_dist = math.abs(i_left - p_left); lock_val = p_left; line_pos = p_left end
                if math.abs(i_right - p_right) < best_dist then best_dist = math.abs(i_right - p_right); lock_val = p_right - bw; line_pos = p_right end
                if math.abs(i_left - p_right) < best_dist then best_dist = math.abs(i_left - p_right); lock_val = p_right; line_pos = p_right end
                if math.abs(i_right - p_left) < best_dist then best_dist = math.abs(i_right - p_left); lock_val = p_left - bw; line_pos = p_left end
            end
        end
        if lock_val then UI.drag_mem.is_snapped_x = true; UI.drag_mem.locked_x = lock_val; UI.drag_mem.anchor_mouse_x = mouse_x; UI.drag_mem.line_x = line_pos else c.x = intended_x end
    end

    if UI.drag_mem.is_snapped_x then
        if math.abs(mouse_x - UI.drag_mem.anchor_mouse_x) > BREAK then UI.drag_mem.is_snapped_x = false; c.x = intended_x
        else c.x = UI.drag_mem.locked_x; reaper.ImGui_DrawList_AddLine(dl, cx + UI.drag_mem.line_x, cy - 1000, cx + UI.drag_mem.line_x, cy + 1000, 0x00E5FFFF, 1.0) end
    end

    if not UI.drag_mem.is_snapped_y then
        local best_dist, lock_val, line_pos = SNAP, nil, nil
        local i_cy, i_top, i_bot = intended_y + bh/2, intended_y, intended_y + bh
        for _, p in ipairs(components) do
            if p.id ~= c.id then
                local px, py, pw, ph = GetBounds(p); local p_cy, p_top, p_bot = py + ph/2, py, py + ph
                if math.abs(i_cy - p_cy) < best_dist then best_dist = math.abs(i_cy - p_cy); lock_val = p_cy - bh/2; line_pos = p_cy end
                if math.abs(i_top - p_top) < best_dist then best_dist = math.abs(i_top - p_top); lock_val = p_top; line_pos = p_top end
                if math.abs(i_bot - p_bot) < best_dist then best_dist = math.abs(i_bot - p_bot); lock_val = p_bot - bh; line_pos = p_bot end
                if math.abs(i_top - p_bot) < best_dist then best_dist = math.abs(i_top - p_bot); lock_val = p_bot; line_pos = p_bot end
                if math.abs(i_bot - p_top) < best_dist then best_dist = math.abs(i_bot - p_top); lock_val = p_top - bh; line_pos = p_top end
            end
        end
        if lock_val then UI.drag_mem.is_snapped_y = true; UI.drag_mem.locked_y = lock_val; UI.drag_mem.anchor_mouse_y = mouse_y; UI.drag_mem.line_y = line_pos else c.y = intended_y end
    end

    if UI.drag_mem.is_snapped_y then
        if math.abs(mouse_y - UI.drag_mem.anchor_mouse_y) > BREAK then UI.drag_mem.is_snapped_y = false; c.y = intended_y
        else c.y = UI.drag_mem.locked_y; reaper.ImGui_DrawList_AddLine(dl, cx - 1000, cy + UI.drag_mem.line_y, cx + 1000, cy + UI.drag_mem.line_y, 0x00E5FFFF, 1.0) end
    end

    if UI.drag_mem.is_snapped_x or UI.drag_mem.is_snapped_y then
        local ghost_cx, ghost_cy = cx + intended_x + bw/2, cy + intended_y + bh/2
        local real_cx, real_cy = cx + c.x + bw/2, cy + c.y + bh/2
        reaper.ImGui_DrawList_AddLine(dl, real_cx, real_cy, ghost_cx, ghost_cy, 0x00E5FF88, 2.0)
        reaper.ImGui_DrawList_AddCircleFilled(dl, ghost_cx, ghost_cy, 4.0, 0x00E5FFFF)
        if c.type == "AuraKnob" then reaper.ImGui_DrawList_AddCircle(dl, ghost_cx, ghost_cy, bw/2, 0xFFFFFF44, 0, 1.0)
        else reaper.ImGui_DrawList_AddRect(dl, cx + intended_x, cy + intended_y, cx + intended_x + bw, cy + intended_y + bh, 0xFFFFFF44, 4.0, 0, 1.0) end
    end
end

-- ==========================================
-- THE COMPILER & HARD DRIVE SCANNER
-- ==========================================
function UI.CompileFaceplate(module, theme_name)
    local algo = module.algo or 0
    local safe_theme = theme_name == "" and "Default" or theme_name
    local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
    local filepath = script_path .. "OMM_Schema_Algo_" .. tostring(algo) .. "_" .. safe_theme .. ".lua"
    
    local f = io.open(filepath, "w")
    if not f then return false end
    f:write("-- AUTO-GENERATED BY OMM VISUAL COMPILER\n")
    f:write("-- ALGO: " .. tostring(algo) .. " | THEME: " .. safe_theme .. "\n\n")
    f:write("return {\n")
    f:write(string.format("  grid_cols = %d,\n", module.grid_cols or 12))
    f:write(string.format("  grid_rows = %d,\n", module.grid_rows or 6))
    f:write(string.format("  seed_hex = %d,\n", module.seed_hex or 0x00A5FFFF))
    if UI.active_palette then
        f:write("  active_palette = {\n")
        for _, p in ipairs(UI.active_palette) do
            f:write(string.format("    { id=%d, hex=%d, token='%s', gen_index=%d, hue_drift=%f },\n", p.id, p.hex, p.token, p.gen_index or 0, p.hue_drift or 0.0))
        end
        f:write("  },\n")
    end
    f:write("  components = {\n")
    for _, c in ipairs(module.components) do
        f:write("    {\n")
        f:write(string.format("      id = '%s', type = '%s',\n", c.id, c.type))
        f:write(string.format("      x = %d, y = %d, w = %d, h = %d, radius = %d, align = %d,\n", math.floor(c.x or 0), math.floor(c.y or 0), math.floor(c.w or 60), math.floor(c.h or 20), math.floor(c.radius or 16), c.align or 1))
        f:write(string.format("      param_key = '%s', default_val = %f, color_token = '%s', is_bipolar = %s,\n", c.param_key or "unmapped", c.default_val or 0.0, c.color_token or "Teal", c.is_bipolar and "true" or "false"))
        if type(c.label) == "string" then f:write(string.format("      label = '%s',\n", c.label)) end
        -- MACRO MULTIPLEXING: Serialize routes array
        if c.routes and #c.routes > 0 then
            f:write("      routes = {\n")
            for _, r in ipairs(c.routes) do
                local safe_label = (r.label or ""):gsub('"', '\\"'):gsub("\n", " ")
                if r.type == "INTERNAL" then
                    local safe_tgt = (r.target or ""):gsub('"', '\\"')
                    f:write(string.format('        { type = "INTERNAL", target = "%s", depth = %.4f, label = "%s" },\n', safe_tgt, r.depth or 1.0, safe_label))
                elseif r.type == "EXTERNAL" then
                    f:write(string.format('        { type = "EXTERNAL", fx_idx = %d, param_idx = %d, depth = %.4f, label = "%s" },\n', r.fx_idx, r.param_idx, r.depth or 1.0, safe_label))
                end
            end
            f:write("      },\n")
        else
            f:write("      routes = {},\n")
        end
        f:write("      get_format = function(s, v) return string.format('%.1f', v) end,\n")
        f:write("      norm_to_real = function(n) return n end,\n      real_to_norm = function(r) return r end\n")
        f:write("    },\n")
    end
    f:write("  }\n}\n")
    f:close()
    return true, safe_theme
end

local function ScanThemesForAlgo(algo_id)
    local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
    local themes = {}
    local i = 0
    while true do
        local f = reaper.EnumerateFiles(script_path, i)
        if not f then break end
        local match = f:match("^OMM_Schema_Algo_" .. tostring(algo_id) .. "_(.+)\\.lua$")
        if match then table.insert(themes, match) end
        i = i + 1
    end
    if #themes == 0 then table.insert(themes, "Default") end
    return themes
end

local function LoadThemeIntoBuffer(algo_id, theme_name, env)
    local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
    local filepath = script_path .. "OMM_Schema_Algo_" .. tostring(algo_id) .. "_" .. theme_name .. ".lua"
    local chunk = loadfile(filepath)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then
            UI.wb_grid_cols = data.grid_cols or 12
            UI.wb_grid_rows = data.grid_rows or 6
            UI.theme_seed_hex = data.seed_hex or 0x00A5FFFF
            if data.active_palette then
                UI.active_palette = UI.DeepCopy(data.active_palette)
            else
                UI.active_palette = { 
                    { id=1, hex = 0x00E5FFFF, token = "Primary", gen_index=0, hue_drift=0.0 }, 
                    { id=2, hex = 0xFF6B35FF, token = "Accent", gen_index=0, hue_drift=0.0 },
                    { id=3, hex = 0xF5F5F7FF, token = "Text", gen_index=0, hue_drift=0.0 },
                    { id=4, hex = 0x8E8E93FF, token = "Neutral", gen_index=0, hue_drift=0.0 },
                    { id=5, hex = 0x1C1C1EFF, token = "Base", gen_index=0, hue_drift=0.0 }
                }
            end
            UI.wb_schema_buffer = data.components or {}
            for _, comp in ipairs(UI.wb_schema_buffer) do
                if comp.param_key and not comp.routes then
                    if comp.param_key ~= "unmapped" and comp.param_key ~= "" then
                        comp.routes = { { type = "INTERNAL", target = comp.param_key, depth = 1.0, label = comp.param_key } }
                    else
                        comp.routes = {}
                    end
                end
            end
            UI.selected_comp_ids = {}
            return true
        end
    end
    
    -- MEMORY FETCH: If no physical file exists, pull the extracted memory fallback from NodeUI
    UI.wb_grid_cols = 12; UI.wb_grid_rows = 6; UI.theme_seed_hex = 0x00A5FFFF; UI.selected_comp_ids = {}
    local fallback_schema = env and env.NodeUI and env.NodeUI.GetSchema(algo_id)
    if fallback_schema and fallback_schema.components then
        -- Deep Copy to prevent altering the global fallback registry
        UI.wb_schema_buffer = UI.DeepCopy(fallback_schema.components)
    else
        UI.wb_schema_buffer = {}
    end
    
    return false
end

function UI.DrawLayerToolbar(ctx, draw_list, canvas_x, canvas_y, canvas_w, canvas_h)
    -- 1. Self-Contained Physics Timer
    local now = reaper.time_precise()
    UI.layer_last_time = UI.layer_last_time or now
    local dt = math.min(0.05, now - UI.layer_last_time)
    UI.layer_last_time = now

    -- 2. Dimensions & Grid
    local pad = 40
    local bar_w = 40 
    local cell_h = 32
    
    -- 3. Spring State Initialization
    UI.layer_anim_h = UI.layer_anim_h or cell_h
    UI.layer_anim_a = UI.layer_anim_a or (UI.layer_toolbar_collapsed and 0.0 or 1.0)
    UI.layer_anim_t = UI.layer_anim_t or (UI.layer_toolbar_collapsed and 0.0 or 1.0)
    
    local target_h = UI.layer_toolbar_collapsed and cell_h or (cell_h * 8)
    local target_a = UI.layer_toolbar_collapsed and 0.0 or 1.0
    local target_t = UI.layer_toolbar_collapsed and 0.0 or 1.0
    
    -- 4. The Spring Engine (Exponential Decay)
    local speed = 18.0
    UI.layer_anim_h = UI.layer_anim_h + (target_h - UI.layer_anim_h) * math.min(1.0, dt * speed)
    UI.layer_anim_a = UI.layer_anim_a + (target_a - UI.layer_anim_a) * math.min(1.0, dt * (speed * 1.5))
    UI.layer_anim_t = UI.layer_anim_t + (target_t - UI.layer_anim_t) * math.min(1.0, dt * speed)
    
    -- 5. Dynamic Centering Anchor
    local bar_h = UI.layer_anim_h
    local x = canvas_x + canvas_w - bar_w - pad
    local y = canvas_y + (canvas_h - bar_h) / 2 
    
    -- Solid Dark Theme
    pcall(reaper.ImGui_DrawList_AddRectFilled, draw_list, x, y, x + bar_w, y + bar_h, 0x111111CC, 12.0)
    pcall(reaper.ImGui_DrawList_AddRect, draw_list, x, y, x + bar_w, y + bar_h, 0xFFFFFF22, 12.0)

    pcall(reaper.ImGui_SetCursorScreenPos, ctx, x, y)
    
    -- CRITICAL FIX: Unconditional Begin/End wrapper to protect ImGui Stack
    local is_vis = select(2, pcall(reaper.ImGui_BeginChild, ctx, "layer_stack", bar_w, bar_h, 0, reaper.ImGui_WindowFlags_NoBackground() | reaper.ImGui_WindowFlags_NoScrollbar()))
    if is_vis then
        -- ==========================================
        -- CELL 0: THE MECHANICAL HINGE
        -- ==========================================
        local cursor_y = y
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, x, cursor_y)
        pcall(reaper.ImGui_InvisibleButton, ctx, "btn_lyr_collapse", bar_w, cell_h)
        local hinge_hov = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
        
        if hinge_hov then 
            pcall(reaper.ImGui_DrawList_AddRectFilled, draw_list, x, cursor_y, x + bar_w, cursor_y + cell_h, 0xFFFFFF11, 12.0, reaper.ImGui_DrawFlags_RoundCornersTop())
            if select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then
                UI.layer_toolbar_collapsed = not UI.layer_toolbar_collapsed
            end
        end
        
        -- Crossfade Icon Morphing
        local cx, cy = x + (bar_w/2), cursor_y + (cell_h/2)
        local icon_base = hinge_hov and 0xFFFFFFFF or 0x888888FF
        local alpha_hamb = math.floor((1.0 - UI.layer_anim_t) * 255)
        local alpha_arrow = math.floor(UI.layer_anim_t * 255)
        
        if alpha_hamb > 0 then
            local col_h = (icon_base & 0xFFFFFF00) | alpha_hamb
            pcall(reaper.ImGui_DrawList_AddLine, draw_list, cx-6, cy-4, cx+6, cy-4, col_h, 2.0)
            pcall(reaper.ImGui_DrawList_AddLine, draw_list, cx-6, cy,   cx+6, cy,   col_h, 2.0)
            pcall(reaper.ImGui_DrawList_AddLine, draw_list, cx-6, cy+4, cx+6, cy+4, col_h, 2.0)
        end
        if alpha_arrow > 0 then
            local col_a = (icon_base & 0xFFFFFF00) | alpha_arrow
            pcall(reaper.ImGui_DrawList_AddLine, draw_list, cx-2, cy-6, cx-2, cy+6, col_a, 2.0)
            pcall(reaper.ImGui_DrawList_AddTriangleFilled, draw_list, cx+1, cy-5, cx+1, cy+5, cx+6, cy, col_a)
        end
        
        -- ==========================================
        -- THE LAYER CELLS
        -- ==========================================
        if UI.layer_anim_a > 0.01 then
            -- The Separator Line
            local sep_alpha = math.floor(UI.layer_anim_a * 34)
            pcall(reaper.ImGui_DrawList_AddLine, draw_list, x, cursor_y + cell_h, x + bar_w, cursor_y + cell_h, 0xFFFFFF00 | sep_alpha, 1.0)
            
            -- Push Clip Rect so closing animation doesn't bleed out of the box
            pcall(reaper.ImGui_DrawList_PushClipRect, draw_list, x, y, x + bar_w, y + bar_h, true)
            
            local layers = {"ALL", 5, 4, 3, 2, 1, 0}
            local anim_a_byte = math.floor(UI.layer_anim_a * 255)
            local hover_a_byte = math.floor(UI.layer_anim_a * 17)
            
            for _, lyr in ipairs(layers) do
                cursor_y = cursor_y + cell_h
                local label = tostring(lyr)
                
                pcall(reaper.ImGui_SetCursorScreenPos, ctx, x, cursor_y)
                pcall(reaper.ImGui_InvisibleButton, ctx, "btn_lyr_"..label, bar_w, cell_h)
                pcall(reaper.ImGui_SetItemAllowOverlap, ctx)
                
                local is_hov = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
                
                -- Input Engine (Guard: Only click if fully open)
                if is_hov and UI.layer_anim_a > 0.9 then
                    if select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then 
                        if lyr == "ALL" then UI.filter_layer, UI.locked_layer = nil, nil
                        else UI.filter_layer, UI.locked_layer = lyr, nil end
                    elseif select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 1)) then 
                        if lyr == "ALL" then UI.filter_layer, UI.locked_layer = nil, nil
                        else UI.locked_layer, UI.filter_layer = lyr, nil end
                    end
                end
                
                local state = 0
                if lyr == "ALL" then
                    if UI.filter_layer == nil and UI.locked_layer == nil then state = 1 end
                else
                    if UI.filter_layer == lyr then state = 1 
                    elseif UI.locked_layer == lyr then state = 2 end
                end
                
                -- Optical Centering & Box Geometry
                local pad_x, pad_y = 4, 5
                local bx1, by1 = x + pad_x, cursor_y + pad_y
                local bx2, by2 = x + bar_w - pad_x, cursor_y + cell_h - pad_y
                local text_col = 0x88888800 | anim_a_byte
                local cyan_solid = 0x00E5FF00 | anim_a_byte
                
                if state == 1 then
                    pcall(reaper.ImGui_DrawList_AddRectFilled, draw_list, bx1, by1, bx2, by2, cyan_solid, 4.0)
                    text_col = 0x11111100 | anim_a_byte
                elseif state == 2 then
                    pcall(reaper.ImGui_DrawList_AddRect, draw_list, bx1, by1, bx2, by2, cyan_solid, 4.0, 0, 2.0)
                    text_col = cyan_solid
                else
                    if is_hov and UI.layer_anim_a > 0.9 then 
                        pcall(reaper.ImGui_DrawList_AddRectFilled, draw_list, bx1, by1, bx2, by2, 0xFFFFFF00 | hover_a_byte, 4.0) 
                    end
                end
                
                -- The Nudge Fix
                local ok, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, label)
                tw = tonumber(tw) or 10; th = tonumber(th) or 14
                local font_y_nudge = 0
                local tx = x + (bar_w / 2) - (tw / 2)
                local ty = cursor_y + (cell_h / 2) - (th / 2) + font_y_nudge
                
                pcall(reaper.ImGui_DrawList_AddText, draw_list, tx, ty, text_col, label)
            end
            
            pcall(reaper.ImGui_DrawList_PopClipRect, draw_list)
        end
    end
    
    -- CRITICAL FIX: Unconditional EndChild prevents stack corruption!
    pcall(reaper.ImGui_EndChild, ctx)
end

-- ==========================================
-- THE STANDALONE CAD FACTORY
-- ==========================================

function UI.PushIDEStyle(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x14141AFF) -- The crisp Charcoal
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 0)
end

function UI.PopIDEStyle(ctx)
    pcall(reaper.ImGui_PopStyleColor, ctx, 1)
    pcall(reaper.ImGui_PopStyleVar, ctx, 2)
end
function UI.DrawWorkbenchWindow(ctx, env)
    if not env.DEV_MODE then return end

    -- Generate active IDE Palette dynamically based on current seed hex
    env.palette = UI.PaletteEngine.Generate(UI.theme_seed_hex)

    -- Temporal Engine Interceptor
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()) then
        if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()) then
            if #UI.redo_stack > 0 then
                table.insert(UI.undo_stack, UI.DeepCopy(UI.wb_schema_buffer))
                UI.wb_schema_buffer = table.remove(UI.redo_stack); UI.selected_comp_ids = {}
            end
        else
            if #UI.undo_stack > 0 then
                table.insert(UI.redo_stack, UI.DeepCopy(UI.wb_schema_buffer))
                UI.wb_schema_buffer = table.remove(UI.undo_stack); UI.selected_comp_ids = {}
            end
        end
    end

    UI.open_blueprints = UI.open_blueprints == nil and true or UI.open_blueprints
    UI.open_cat_knobs = UI.open_cat_knobs == nil and true or UI.open_cat_knobs
    UI.open_cat_meters = UI.open_cat_meters == nil and true or UI.open_cat_meters
    UI.open_cat_switches = UI.open_cat_switches == nil and true or UI.open_cat_switches
    UI.open_cat_displays = UI.open_cat_displays == nil and false or UI.open_cat_displays
    UI.open_cat_panels = UI.open_cat_panels == nil and false or UI.open_cat_panels

    -- Deferred Window Drag Protocol (Seatbelt logic to prevent cross-monitor nil crash)
    if UI.drag_mem.next_win_x and UI.drag_mem.next_win_y then
        pcall(reaper.ImGui_SetNextWindowPos, ctx, UI.drag_mem.next_win_x, UI.drag_mem.next_win_y)
        UI.drag_mem.next_win_x, UI.drag_mem.next_win_y = nil, nil
    end

    local flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoMove()
    reaper.ImGui_SetNextWindowSize(ctx, 1200, 700, reaper.ImGui_Cond_FirstUseEver())
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x08080AFF) 
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x14141AFF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 14.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 12.0)

    local visible, open = reaper.ImGui_Begin(ctx, "OMM_WORKBENCH_FACTORY", true, flags)
    
    if visible then
        local dl_main = reaper.ImGui_GetWindowDrawList(ctx)
        local ok_pos, top_wx, top_wy = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
        top_wx, top_wy = tonumber(top_wx) or 0, tonumber(top_wy) or 0
        local ok_avail, drag_w, avail_main_h = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
        drag_w, avail_main_h = tonumber(drag_w) or 0, tonumber(avail_main_h) or 0
        
        -- ==========================================================
        -- 1. THE 3-ZONE HEADER ARCHITECTURE (Absolute 26px)
        -- ==========================================================
        local header_h = 26
        local btn_w = 80
        local btn_h = 20
        local total_btn_w = btn_w * 2
        local win_w = select(2, pcall(reaper.ImGui_GetWindowWidth, ctx)) or 400
        
        local ok_pos, win_x, win_y = pcall(reaper.ImGui_GetWindowPos, ctx)
        win_x = ok_pos and win_x or 0; win_y = ok_pos and win_y or 0
        
        local left_drag_w = (win_w - total_btn_w) / 2
        local right_drag_w = win_w - left_drag_w - total_btn_w

        -- Helper Engine: Keeps the hover/drag logic clean for both sides
        local function HandleHeaderDrag(w, h)
            if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
                local ok_min, ix, iy = pcall(reaper.ImGui_GetItemRectMin, ctx)
                if ok_min then pcall(reaper.ImGui_DrawList_AddRectFilled, dl_main, ix, iy, ix + w, iy + h, 0xFFFFFF0A, 4.0) end
            end
            if select(2, pcall(reaper.ImGui_IsItemActive, ctx)) and select(2, pcall(reaper.ImGui_IsMouseDragging, ctx, 0)) then
                local ok_delta, dx, dy = pcall(reaper.ImGui_GetMouseDelta, ctx)
                if ok_delta and (dx ~= 0 or dy ~= 0) then
                    UI.drag_mem.next_win_x = win_x + dx
                    UI.drag_mem.next_win_y = win_y + dy
                end
            end
        end

        -- ZONE 1: Left Drag (Forces Cursor to 0,0 to override ImGui padding)
        pcall(reaper.ImGui_SetCursorPos, ctx, 0, 0)
        UI.Safe_InvisibleButton(ctx, "drag_left", math.max(1, left_drag_w), header_h)
        HandleHeaderDrag(left_drag_w, header_h)
        
        pcall(reaper.ImGui_SameLine, ctx, 0, 0)
        
        -- ZONE 2: Design & Play (Math: 26 - 20 / 2 = 3px vertical padding)
        pcall(reaper.ImGui_SetCursorPosY, ctx, (header_h - btn_h) / 2)
        local active_col = UI.edit_mode and 0xFF6B35FF or 0x00E5FFFF
        pcall(reaper.ImGui_PushStyleVar, ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
        
        -- DESIGN (â– )
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), UI.edit_mode and active_col or 0x2A2A2CFF)
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Text(), UI.edit_mode and 0x1C1C1EFF or 0x888888FF)
        if select(2, pcall(reaper.ImGui_Button, ctx, "â–  DESIGN", btn_w, btn_h)) then 
            if not UI.edit_mode and UI.wb_schema_buffer then
                -- SNAP-BACK ENGINE: Reset all components to their Default Value
                for _, comp in ipairs(UI.wb_schema_buffer) do
                    if comp.default_val then comp.val = comp.default_val end
                end
            end
            UI.edit_mode = true 
        end
        pcall(reaper.ImGui_PopStyleColor, ctx, 2)
        
        pcall(reaper.ImGui_SameLine, ctx, 0, 0)
        pcall(reaper.ImGui_SetCursorPosY, ctx, (header_h - btn_h) / 2)
        
        -- PLAY (â–¶)
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), not UI.edit_mode and active_col or 0x2A2A2CFF)
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Text(), not UI.edit_mode and 0x1C1C1EFF or 0x888888FF)
        if select(2, pcall(reaper.ImGui_Button, ctx, "â–¶ PLAY", btn_w, btn_h)) then UI.edit_mode = false end
        pcall(reaper.ImGui_PopStyleColor, ctx, 2)
        
        pcall(reaper.ImGui_PopStyleVar, ctx, 1)
        
        pcall(reaper.ImGui_SameLine, ctx, 0, 0)
        
        -- ZONE 3: Right Drag
        pcall(reaper.ImGui_SetCursorPosY, ctx, 0)
        UI.Safe_InvisibleButton(ctx, "drag_right", math.max(1, right_drag_w), header_h)
        HandleHeaderDrag(right_drag_w, header_h)
        
        -- ==========================================================
        -- RESTORE CONTENT CURSOR: Force everything below to start at Y = 26
        -- ==========================================================
        pcall(reaper.ImGui_SetCursorPosY, ctx, header_h)

        if not UI.wb_targets then
            UI.wb_targets = {
                -- DYNAMICS & COMPRESSORS (Authentic Registry)
                { label = "Processor: ReaComp", id = 0, type = "COMPRESSOR", algo_variant = 0 },
                { label = "Processor: 1175", id = 1, type = "COMPRESSOR", algo_variant = 1 },
                { label = "Processor: Bus SSL", id = 2, type = "COMPRESSOR", algo_variant = 2 },
                { label = "Processor: FairlyChild", id = 3, type = "COMPRESSOR", algo_variant = 3 },
                { label = "Processor: EventHorizon", id = 4, type = "COMPRESSOR", algo_variant = 4 },
                { label = "Processor: Peak Limiter", id = 5, type = "COMPRESSOR", algo_variant = 5 },
                { label = "Processor: Opto", id = 6, type = "COMPRESSOR", algo_variant = 6 },
                
                -- MODULATORS
                { label = "Modulator: LFO Core", id = 100, type = "LFO" },
                { label = "Modulator: Transfer Shaper", id = 300, type = "TRANSFER_CURVE" },
                
                -- UTILITIES & CONTROLLERS
                { label = "Controller: Macro Hub", id = 400, type = "MACRO_HUB" },
                { label = "Utility: Gain Stage", id = 200, type = "GAIN" },
                { label = "Utility: Beta Sandbox", id = 999, type = "BETA_LAB" },
                
                -- PRO CODE: Expose Routing Nodes to IDE
                { label = "Routing: Target Node", id = 500, type = "TARGET" },
                { label = "Routing: MIDI Input", id = 600, type = "MIDI_IN" }
            }
            -- BACKWARD COMPATIBILITY SHIM (Protocol Zero Safe Transition)
            for _, t in ipairs(UI.wb_targets) do
                t.algo = t.id
                t.name = t.label
                t.algo_name = t.type
            end
            UI.wb_target_idx = 1
            UI.theme_manager.list = ScanThemesForAlgo(UI.wb_targets[UI.wb_target_idx].algo)
            UI.theme_manager.current_theme = UI.config.defaults[UI.wb_targets[UI.wb_target_idx].algo] or "Default"
            LoadThemeIntoBuffer(UI.wb_targets[UI.wb_target_idx].algo, UI.theme_manager.current_theme, env)
        end
        local active_target = UI.wb_targets[UI.wb_target_idx]

        -- ==========================================================
        -- PRO CODE: HARD-AXIS LAYOUT FRAME
        -- ==========================================================

        -- 1. LOCK GEOMETRY (Before rendering)
        local p1_w = 240
        local p3_w = math.max(280, math.min(360, UI.prop_pane_width or 280))
        local p2_w = math.max(10, win_w - p1_w - p3_w - 32) -- 32 = gap + 2 borders

        -- 2. APPLY GLOBAL STYLE
        UI.PushIDEStyle(ctx)

        -- 3. RENDER PANE 1 (TOOLBOX)
        reaper.ImGui_BeginChild(ctx, "omm_left_pane", p1_w, 0, 0, 0)
        local dl_left = reaper.ImGui_GetWindowDrawList(ctx)
        
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12.0)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0xFFFFFF1A)
        reaper.ImGui_SetNextItemWidth(ctx, 240)
        local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
        local search_changed, search_txt = reaper.ImGui_InputTextWithHint(ctx, "##search", "       Search components...", UI.search_filter)
        if search_changed then UI.search_filter = search_txt:lower() end
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_PopStyleVar(ctx, 1)
        
        reaper.ImGui_DrawList_AddCircle(dl_left, cx + 16, cy + 12, 5.0, 0x8E8E93FF, 0, 1.5)
        reaper.ImGui_DrawList_AddLine(dl_left, cx + 20, cy + 16, cx + 24, cy + 20, 0x8E8E93FF, 2.0)
        reaper.ImGui_Spacing(ctx); reaper.ImGui_Spacing(ctx)

        local clk_bp, open_bp, t_bp = UI.DrawAnimatedDisclosure(ctx, dl_left, "bp_disc", "BLUEPRINTS", UI.open_blueprints, env.app_dt, 240)
        UI.open_blueprints = open_bp
        
        if t_bp > 0.01 then
            reaper.ImGui_BeginChild(ctx, "omm_bp_list", 240, 140 * t_bp, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_bp)
            for i, tgt in ipairs(UI.wb_targets) do
                if reaper.ImGui_Selectable(ctx, tgt.name, UI.wb_target_idx == i) then
                    UI.wb_target_idx = i
                    UI.theme_manager.list = ScanThemesForAlgo(tgt.algo)
                    UI.theme_manager.current_theme = UI.config.defaults[tgt.algo] or "Default"
                    LoadThemeIntoBuffer(tgt.algo, UI.theme_manager.current_theme, env)
                end
            end
            reaper.ImGui_PopStyleVar(ctx, 1)
            reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, 0x8E8E93FF, "TOOLBOX")
        reaper.ImGui_Spacing(ctx)

        -- CATEGORY: CONTROLS (Knobs & Faders)
        local clk_tk, open_tk, t_tk = UI.DrawAnimatedDisclosure(ctx, dl_left, "cat_knobs", "CONTROLS", UI.open_cat_knobs, env.app_dt, 240)
        UI.open_cat_knobs = open_tk
        if t_tk > 0.01 and (UI.search_filter == "" or string.find("auraknob fader", UI.search_filter, 1, true)) then
            reaper.ImGui_BeginChild(ctx, "omm_tk_list", 240, 140 * t_tk, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_tk)
            
            -- AuraKnob
            local bx, by = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_AuraKnob", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx, by, bx+220, by+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddCircleFilled(dl_left, bx + 30, by + 30, 16, 0x666666FF)
            reaper.ImGui_DrawList_AddCircleFilled(dl_left, bx + 30, by + 30, 14, 0x444444FF)
            reaper.ImGui_DrawList_PathArcTo(dl_left, bx+30, by+30, 14, math.pi*0.75, math.pi*1.75)
            reaper.ImGui_DrawList_PathStroke(dl_left, 0x00E5FFFF, 0, 3.0)
            UI.DrawStandardText(dl_left, bx + 60, by + 16, "AuraKnob", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bx + 60, by + 33, "Rotary encoder", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "AuraKnob"); reaper.ImGui_Text(ctx, "Instantiate AuraKnob"); reaper.ImGui_EndDragDropSource(ctx) end

            -- Fader
            reaper.ImGui_Dummy(ctx, 10, 5)
            local bxf, byf = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_Fader", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bxf, byf, bxf+220, byf+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bxf+18, byf+8, bxf+28, byf+52, 0x0A0D0FFF, 3.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bxf+20, byf+30, bxf+26, byf+50, 0x00E5FF66, 3.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bxf+17, byf+26, bxf+29, byf+34, 0xDDDDDDFF, 2.0)
            UI.DrawStandardText(dl_left, bxf + 60, byf + 16, "Fader (VCA)", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bxf + 60, byf + 33, "Vertical slider w/ dB", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "Fader"); reaper.ImGui_Text(ctx, "Instantiate Fader"); reaper.ImGui_EndDragDropSource(ctx) end

            reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_EndChild(ctx)
        end

        -- CATEGORY: METERS
        local clk_tm, open_tm, t_tm = UI.DrawAnimatedDisclosure(ctx, dl_left, "cat_meters", "METERS & SLIDERS", UI.open_cat_meters, env.app_dt, 240)
        UI.open_cat_meters = open_tm
        if t_tm > 0.01 and (UI.search_filter == "" or string.find("peakmeter vumeter inlinedrag", UI.search_filter, 1, true)) then
            reaper.ImGui_BeginChild(ctx, "omm_tm_list", 240, 210 * t_tm, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_tm)
            
            local bx2, by2 = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_PeakMeter", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx2, by2, bx2+220, by2+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx2 + 10, by2 + 10, bx2 + 20, by2 + 50, 0x111111FF, 4.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx2 + 12, by2 + 30, bx2 + 18, by2 + 48, 0x00E5FFFF, 4.0)
            UI.DrawStandardText(dl_left, bx2 + 60, by2 + 22, "PeakMeter (Liquid)", 0xFFFFFFFF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "PeakMeter"); reaper.ImGui_Text(ctx, "PeakMeter"); reaper.ImGui_EndDragDropSource(ctx) end

            reaper.ImGui_Dummy(ctx, 10, 5)
            local bx3, by3 = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_VuMeter", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx3, by3, bx3+220, by3+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_PathArcTo(dl_left, bx3 + 25, by3 + 45, 20, math.pi * 1.25, math.pi * 1.75, 0); reaper.ImGui_DrawList_PathStroke(dl_left, 0x888888FF, 0, 2.0)
            reaper.ImGui_DrawList_AddLine(dl_left, bx3 + 25, by3 + 45, bx3 + 35, by3 + 25, 0xFF3333FF, 2.0)
            UI.DrawStandardText(dl_left, bx3 + 60, by3 + 22, "VuMeter (Analog)", 0xFFFFFFFF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "VuMeter"); reaper.ImGui_Text(ctx, "VuMeter"); reaper.ImGui_EndDragDropSource(ctx) end
            
            reaper.ImGui_Dummy(ctx, 10, 5)
            local bx4, by4 = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_InlineDrag", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx4, by4, bx4+220, by4+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx4 + 10, by4 + 20, bx4 + 50, by4 + 40, 0x666666FF, 4.0)
            UI.DrawStandardText(dl_left, bx4 + 60, by4 + 22, "InlineDrag Text", 0xFFFFFFFF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "InlineDrag"); reaper.ImGui_Text(ctx, "InlineDrag"); reaper.ImGui_EndDragDropSource(ctx) end
            
            reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_EndChild(ctx)
        end

        -- CATEGORY: SWITCHES & SELECTORS
        local clk_sw, open_sw, t_sw = UI.DrawAnimatedDisclosure(ctx, dl_left, "cat_switches", "SWITCHES", UI.open_cat_switches, env.app_dt, 240)
        UI.open_cat_switches = open_sw
        if t_sw > 0.01 and (UI.search_filter == "" or string.find("togglepill togglelever dropdown radiostrip", UI.search_filter, 1, true)) then
            reaper.ImGui_BeginChild(ctx, "omm_sw_list", 240, 280 * t_sw, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_sw)
            
            local bx5, by5 = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_TogglePill", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx5, by5, bx5+220, by5+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx5+10, by5+20, bx5+40, by5+40, 0x00E5FFFF, 10.0)
            reaper.ImGui_DrawList_AddCircleFilled(dl_left, bx5+30, by5+30, 8, 0xFFFFFFFF)
            UI.DrawStandardText(dl_left, bx5 + 60, by5 + 16, "TogglePill (Squarcle)", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bx5 + 60, by5 + 33, "iOS-style switch", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "TogglePill"); reaper.ImGui_Text(ctx, "TogglePill"); reaper.ImGui_EndDragDropSource(ctx) end

            reaper.ImGui_Dummy(ctx, 10, 5)
            local bx6, by6 = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_ToggleLever", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx6, by6, bx6+220, by6+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx6+15, by6+10, bx6+35, by6+50, 0x111111FF, 4.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx6+18, by6+12, bx6+32, by6+30, 0xDDDDDDFF, 2.0)
            UI.DrawStandardText(dl_left, bx6 + 60, by6 + 16, "ToggleLever (Metal)", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bx6 + 60, by6 + 33, "Hardware flip switch", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "ToggleLever"); reaper.ImGui_Text(ctx, "ToggleLever"); reaper.ImGui_EndDragDropSource(ctx) end

            reaper.ImGui_Dummy(ctx, 10, 5)
            local bx7, by7 = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_Dropdown", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx7, by7, bx7+220, by7+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx7+10, by7+20, bx7+45, by7+40, 0x1C1C1EFF, 4.0)
            reaper.ImGui_DrawList_AddRect(dl_left, bx7+10, by7+20, bx7+45, by7+40, 0x333333FF, 4.0, 0, 1.0)
            reaper.ImGui_DrawList_AddTriangleFilled(dl_left, bx7+36, by7+27, bx7+44, by7+27, bx7+40, by7+35, 0x888888FF)
            UI.DrawStandardText(dl_left, bx7 + 60, by7 + 16, "Dropdown", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bx7 + 60, by7 + 33, "Frosted glass selector", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "Dropdown"); reaper.ImGui_Text(ctx, "Dropdown"); reaper.ImGui_EndDragDropSource(ctx) end
            
            reaper.ImGui_Dummy(ctx, 10, 5)
            local bx8, by8 = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_RadioStrip", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx8, by8, bx8+220, by8+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx8+10, by8+20, bx8+24, by8+40, 0x111111FF, 2.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx8+12, by8+22, bx8+22, by8+38, 0x00E5FFFF, 2.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx8+30, by8+20, bx8+44, by8+40, 0x111111FF, 2.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bx8+32, by8+22, bx8+42, by8+38, 0x444444FF, 2.0)
            UI.DrawStandardText(dl_left, bx8 + 60, by8 + 16, "RadioStrip", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bx8 + 60, by8 + 33, "Claymorphism selector", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "RadioStrip"); reaper.ImGui_Text(ctx, "RadioStrip"); reaper.ImGui_EndDragDropSource(ctx) end

            reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_EndChild(ctx)
        end

        -- CATEGORY: DISPLAYS
        local clk_dp, open_dp, t_dp = UI.DrawAnimatedDisclosure(ctx, dl_left, "cat_displays", "DISPLAYS", UI.open_cat_displays, env.app_dt, 240)
        UI.open_cat_displays = open_dp
        if t_dp > 0.01 and (UI.search_filter == "" or string.find("vfdscreen", UI.search_filter, 1, true)) then
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_dp)
            local is_visible = reaper.ImGui_BeginChild(ctx, "omm_disp_block_v2", 240, 70 * t_dp, 0, reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
            if is_visible then
                local bxv, byv = reaper.ImGui_GetCursorScreenPos(ctx)
                reaper.ImGui_InvisibleButton(ctx, "drag_VFDScreen", 220, 60)
                reaper.ImGui_DrawList_AddRectFilled(dl_left, bxv, byv, bxv+220, byv+60, 0x2A2A2AFF, 12.0)
                reaper.ImGui_DrawList_AddRectFilled(dl_left, bxv+10, byv+12, bxv+48, byv+48, 0x0A0A0AFF, 4.0)
                reaper.ImGui_DrawList_AddRect(dl_left, bxv+10, byv+12, bxv+48, byv+48, 0x1A1A1FFF, 4.0, 0, 1.0)
                UI.DrawStandardText(dl_left, bxv + 16, byv + 22, "8.8", 0x00E5FFFF, 1.0)
                UI.DrawStandardText(dl_left, bxv + 60, byv + 16, "VFD Screen", 0xFFFFFFFF, 1.0)
                UI.DrawStandardText(dl_left, bxv + 60, byv + 33, "Vacuum fluorescent", 0x888888FF, 1.0)
                if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "VFDScreen"); reaper.ImGui_Text(ctx, "VFDScreen"); reaper.ImGui_EndDragDropSource(ctx) end
            end
            reaper.ImGui_EndChild(ctx)
            reaper.ImGui_PopStyleVar(ctx, 1)
        end

        -- CATEGORY: PANELS & DECOR
        local clk_pn, open_pn, t_pn = UI.DrawAnimatedDisclosure(ctx, dl_left, "cat_panels", "PANELS", UI.open_cat_panels, env.app_dt, 240)
        UI.open_cat_panels = open_pn
        if t_pn > 0.01 and (UI.search_filter == "" or string.find("backpanel screwdecal", UI.search_filter, 1, true)) then
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_pn)
            local is_visible = reaper.ImGui_BeginChild(ctx, "omm_pnl_block_v2", 240, 140 * t_pn, 0, reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
            if is_visible then
                local bxp, byp = reaper.ImGui_GetCursorScreenPos(ctx)
                reaper.ImGui_InvisibleButton(ctx, "drag_BackPanel", 220, 60)
                reaper.ImGui_DrawList_AddRectFilled(dl_left, bxp, byp, bxp+220, byp+60, 0x2A2A2AFF, 12.0)
                reaper.ImGui_DrawList_AddRectFilledMultiColor(dl_left, bxp+10, byp+12, bxp+48, byp+48, 0xE5E5EAFF, 0xE5E5EAFF, 0xB5B5BAFF, 0xB5B5BAFF)
                reaper.ImGui_DrawList_AddLine(dl_left, bxp+10, byp+12, bxp+48, byp+12, 0xFFFFFF33, 2.0)
                UI.DrawStandardText(dl_left, bxp + 60, byp + 16, "BackPanel", 0xFFFFFFFF, 1.0)
                UI.DrawStandardText(dl_left, bxp + 60, byp + 33, "Gradient chassis", 0x888888FF, 1.0)
                if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "BackPanel"); reaper.ImGui_Text(ctx, "BackPanel"); reaper.ImGui_EndDragDropSource(ctx) end
                
                reaper.ImGui_Dummy(ctx, 10, 5)
                local bxs, bys = reaper.ImGui_GetCursorScreenPos(ctx)
                reaper.ImGui_InvisibleButton(ctx, "drag_ScrewDecal", 220, 60)
                reaper.ImGui_DrawList_AddRectFilled(dl_left, bxs, bys, bxs+220, bys+60, 0x2A2A2AFF, 12.0)
                reaper.ImGui_DrawList_AddCircleFilled(dl_left, bxs+25, bys+30, 7, 0x0A0A0AFF)
                reaper.ImGui_DrawList_AddCircleFilled(dl_left, bxs+25, bys+30, 5, 0x888888FF)
                UI.DrawStandardText(dl_left, bxs + 60, bys + 16, "ScrewDecal", 0xFFFFFFFF, 1.0)
                if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "ScrewDecal"); reaper.ImGui_Text(ctx, "ScrewDecal"); reaper.ImGui_EndDragDropSource(ctx) end
            end
            reaper.ImGui_EndChild(ctx)
            reaper.ImGui_PopStyleVar(ctx, 1)
        end

        reaper.ImGui_EndChild(ctx)
        reaper.ImGui_SameLine(ctx, 0, 8)

        -- 4. RENDER PANE 2 (CANVAS)
        local ok_aw, raw_aw, raw_ah = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
        local canvas_w = p2_w
        local total_h = tonumber(raw_ah) or 0
        local canvas_h = total_h

        reaper.ImGui_BeginChild(ctx, "canvas_pane", p2_w, 0, 0, 0)

        -- KINEMATIC PALETTE SPRING (Smooth Roll-Down/Up)
        UI.pal_anim_t = UI.pal_anim_t or (UI.palette_open and 1.0 or 0.0)
        UI.pal_anim_v = UI.pal_anim_v or 0.0
        local target_pal = UI.palette_open and 1.0 or 0.0
        UI.pal_anim_t, UI.pal_anim_v = UI.SpringDamp(UI.pal_anim_t, target_pal, UI.pal_anim_v, 200.0, 16.0, env.app_dt)
        UI.is_interactable = UI.palette_open

        if UI.pal_anim_t > 0.01 then
            UI.palette_height = math.max(150, math.min(total_h - 100, UI.palette_height))
            local current_h = UI.palette_height * UI.pal_anim_t
            
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), UI.pal_anim_t)
            local flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
            if not UI.is_interactable then flags = flags | reaper.ImGui_WindowFlags_NoInputs() end
            local is_vis = reaper.ImGui_BeginChild(ctx, "pal_pane_v2", canvas_w, current_h, 0, flags)
            
            if is_vis then
                local dl_pal = reaper.ImGui_GetWindowDrawList(ctx)
                local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
                local mx, my = reaper.ImGui_GetMousePos(ctx)
                
                -- FLUID COLUMN MATH & DRAG/DROP
                local col_count = 0; for _, c in ipairs(UI.active_palette) do if not c.is_deleting then col_count = col_count + 1 end end
                local base_target_w = canvas_w / math.max(1, col_count)
                local cur_x = px
                
                for i, p_col in ipairs(UI.active_palette) do
                    local c_id = "pal_col_"..p_col.id
                    if not UI.physics_states[c_id] then UI.physics_states[c_id] = { w = 0, x = cur_x, vel_w=0, vel_x=0 } end
                    local p_st = UI.physics_states[c_id]
                    
                    local target_w = p_col.is_deleting and 0 or base_target_w
                    p_st.w, p_st.vel_w = UI.SpringDamp(p_st.w, target_w, p_st.vel_w, 250.0, 18.0, env.app_dt)
                    
                    -- GRIP ZONE LOGIC
                    local grip_zone_h = 90
                    reaper.ImGui_SetCursorScreenPos(ctx, p_st.x, py + current_h - grip_zone_h)
                    UI.Safe_InvisibleButton(ctx, "grip_"..c_id, p_st.w, grip_zone_h)
                    
                    if reaper.ImGui_IsItemActivated(ctx) then 
                        UI.drag_col_idx = i
                        UI.drag_mem.pal_off_x = mx - p_st.x 
                    end
                    if reaper.ImGui_IsItemDeactivated(ctx) and UI.drag_col_idx == i then UI.drag_col_idx = nil end
                    
                    local is_dragged = (UI.drag_col_idx == i) and select(2, pcall(reaper.ImGui_IsItemActive, ctx))
                    
                    if is_dragged then 
                        p_st.x = mx - UI.drag_mem.pal_off_x
                        p_st.vel_x = 0
                    else 
                        p_st.x, p_st.vel_x = UI.SpringDamp(p_st.x, cur_x, p_st.vel_x, 250.0, 18.0, env.app_dt) 
                    end
                    
                    if p_col.is_deleting and p_st.w < 2 then table.remove(UI.active_palette, i) else
                        if is_dragged then
                            reaper.ImGui_DrawList_AddRectFilled(dl_pal, p_st.x + 4, py + 4, p_st.x + p_st.w + 4, py + current_h + 4, 0x00000044)
                            reaper.ImGui_DrawList_AddRectFilled(dl_pal, p_st.x, py, p_st.x + p_st.w, py + current_h, p_col.hex & 0xFFFFFF00 | 0xEE)
                        else
                            reaper.ImGui_DrawList_AddRectFilled(dl_pal, p_st.x, py, p_st.x + p_st.w, py + current_h, p_col.hex)
                        end
                        
                        local txt_col = env.palette_engine and env.palette_engine.GetBestTextColor(p_col.hex) or 0xFFFFFFFF
                        local name = env.palette_engine and env.palette_engine.GetColorName(p_col.hex) or p_col.token
                        local hex_str = string.format("#%06X", (p_col.hex >> 8) & 0xFFFFFF)
                        
                        local nw, nh = reaper.ImGui_CalcTextSize(ctx, name)
                        reaper.ImGui_DrawList_AddText(dl_pal, p_st.x + (p_st.w/2) - (nw/2), py + current_h - 70, txt_col, name)
                        local hw = reaper.ImGui_CalcTextSize(ctx, hex_str)
                        reaper.ImGui_DrawList_AddText(dl_pal, p_st.x + (p_st.w/2) - (hw/2), py + current_h - 50, txt_col & 0xFFFFFF88, hex_str)
                        
                        local gx, gy = p_st.x + (p_st.w/2), py + current_h - 20
                        local grip_col = txt_col & 0xFFFFFF00 | (is_dragged and 0xFF or 0x44)
                        reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx - 8, gy, 2, grip_col)
                        reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx,     gy, 2, grip_col)
                        reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx + 8, gy, 2, grip_col)
                        if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW()) end
                        
                        local is_upper_hov = (mx >= p_st.x and mx <= p_st.x + p_st.w and my >= py and my < py + current_h - grip_zone_h)
                        if is_upper_hov and not is_dragged and not UI.hover_states.picker_active then
                            local kx, ky = p_st.x + (p_st.w/2) - 16, py + (current_h/2) - 30
                            reaper.ImGui_SetCursorScreenPos(ctx, kx, ky)
                            UI.Safe_InvisibleButton(ctx, "kill_"..p_col.id, 32, 32)
                            local kill_hov = reaper.ImGui_IsItemHovered(ctx)
                            local k_alpha = kill_hov and 1.0 or 0.3
                            local k_col = txt_col & 0xFFFFFF00 | math.floor(0xFF * k_alpha)
                            if kill_hov then reaper.ImGui_DrawList_AddCircleFilled(dl_pal, kx+16, ky+16, 20, txt_col & 0xFFFFFF00 | 0x22) end
                            reaper.ImGui_DrawList_AddLine(dl_pal, kx+8, ky+8, kx+24, ky+24, k_col, 3.0)
                            reaper.ImGui_DrawList_AddLine(dl_pal, kx+24, ky+8, kx+8, ky+24, k_col, 3.0)
                            if reaper.ImGui_IsItemClicked(ctx) then p_col.is_deleting = true; UI.PushNotification("Deleted " .. name, txt_col) end
                        end
                    end
                    if not p_col.is_deleting then cur_x = cur_x + target_w end
                end

                if UI.drag_col_idx and select(2, pcall(reaper.ImGui_IsMouseDragging, ctx, 0)) then
                    local dragged_col = UI.active_palette[UI.drag_col_idx]
                    local d_center = UI.physics_states["pal_col_"..dragged_col.id].x + (base_target_w / 2)
                    
                    if d_center > px + (UI.drag_col_idx * base_target_w) and UI.drag_col_idx < #UI.active_palette then
                        UI.active_palette[UI.drag_col_idx] = UI.active_palette[UI.drag_col_idx + 1]
                        UI.active_palette[UI.drag_col_idx + 1] = dragged_col
                        UI.drag_col_idx = UI.drag_col_idx + 1
                    elseif d_center < px + ((UI.drag_col_idx - 1) * base_target_w) and UI.drag_col_idx > 1 then
                        UI.active_palette[UI.drag_col_idx] = UI.active_palette[UI.drag_col_idx - 1]
                        UI.active_palette[UI.drag_col_idx - 1] = dragged_col
                        UI.drag_col_idx = UI.drag_col_idx - 1
                    end
                end

                if not UI.hover_states.picker_active then
                    local gap_x = px
                    for i = 1, col_count + 1 do
                        if i > 1 then gap_x = gap_x + base_target_w end
                        local gx_center = (i == 1) and px or ((i > col_count) and px + canvas_w or gap_x)
                        reaper.ImGui_SetCursorScreenPos(ctx, gx_center - 15, py)
                        UI.Safe_InvisibleButton(ctx, "gap_"..i, 30, current_h)
                        
                        if reaper.ImGui_IsItemHovered(ctx) and not UI.drag_col_idx then
                            reaper.ImGui_SetTooltip(ctx, "Click: Generate Harmonic Variant\nShift+Click: Force Contrast Variant")
                            
                            -- Draw Gap Highlight
                            local is_l_down = reaper.ImGui_IsMouseDown(ctx, 0)
                            local is_r_down = reaper.ImGui_IsMouseDown(ctx, 1)
                            local ring_col = (is_l_down or is_r_down) and 0x00E5FFFF or 0xFFFFFFCC
                            reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx_center, py + (current_h/2), 16, ring_col)
                            reaper.ImGui_DrawList_AddLine(dl_pal, gx_center-6, py + (current_h/2), gx_center+6, py + (current_h/2), 0x111111FF, 3.0)
                            reaper.ImGui_DrawList_AddLine(dl_pal, gx_center, py + (current_h/2)-6, gx_center, py + (current_h/2)+6, 0x111111FF, 3.0)

                            if reaper.ImGui_IsItemClicked(ctx, 0) or reaper.ImGui_IsItemClicked(ctx, 1) then
                                local neighbor = UI.active_palette[i - 1] or UI.active_palette[1]
                                local is_shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()) or reaper.ImGui_IsItemClicked(ctx, 1)
                                
                                local history_id = neighbor.last_row_id or 0

                                local new_hex, new_token, n_gen, n_drift, winning_row_id = UI.PaletteEngine.GetHarmoniousVariant(
                                    neighbor.hex, neighbor.token, neighbor.gen_index, neighbor.hue_drift, is_shift, history_id
                                )

                                -- CRITICAL UX FIX: Update the neighbor's DNA. 
                                -- This forces the algorithm forward if you spam-click the same '+' button.
                                neighbor.gen_index = n_gen
                                neighbor.hue_drift = n_drift
                                neighbor.last_row_id = winning_row_id

                                table.insert(UI.active_palette, i, { 
                                    id = math.random(10000,99999), 
                                    hex = new_hex, 
                                    token = new_token, 
                                    gen_index = n_gen, 
                                    hue_drift = n_drift,
                                    last_row_id = winning_row_id
                                })
                                UI.PushNotification("Added " .. new_token, new_hex)
                            end
                        end
                    end
                end

                local bar_w = 40; local bar_x = px + (canvas_w/2) - (bar_w/2); local bar_y = py + 16
                reaper.ImGui_DrawList_AddRectFilled(dl_pal, bar_x, bar_y, bar_x + bar_w, bar_y + 40, 0x111111CC, 20.0)
                reaper.ImGui_DrawList_AddRect(dl_pal, bar_x, bar_y, bar_x + bar_w, bar_y + 40, 0xFFFFFF22, 20.0, 0, 1.0)
                
                reaper.ImGui_SetCursorScreenPos(ctx, bar_x + 6, bar_y + 6)
                if UI.DrawVectorIcon(ctx, dl_pal, "pal_search_btn", "SEARCH", UI.hover_states.picker_active) then
                    UI.hover_states.picker_active = true
                    pcall(reaper.ImGui_OpenPopup, ctx, "ColorPickerPopup")
                end
                
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x1A1A1EFF)
                reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding(), 12.0)
                if select(2, pcall(reaper.ImGui_BeginPopup, ctx, "ColorPickerPopup")) then
                    if not UI.picker_color then UI.picker_color = 0x00E5FFFF; UI.picker_search = "" end
                    reaper.ImGui_PushItemWidth(ctx, 220)
                    local ok_txt, changed_txt, new_str = pcall(reaper.ImGui_InputTextWithHint, ctx, "##cp_search", "Type HEX...", UI.picker_search)
                    if ok_txt and changed_txt then
                        UI.picker_search = new_str
                        local hex_str = type(new_str) == "string" and new_str:match("#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])") or nil
                        if hex_str then UI.picker_color = (tonumber(hex_str, 16) << 8) | 0xFF end
                    end
                    reaper.ImGui_Spacing(ctx)
                    local flags = reaper.ImGui_ColorEditFlags_NoSidePreview() | reaper.ImGui_ColorEditFlags_NoAlpha() | reaper.ImGui_ColorEditFlags_PickerHueWheel()
                    local ok_col, changed_col, new_col = pcall(reaper.ImGui_ColorPicker4, ctx, "##cp_picker", UI.picker_color, flags)
                    if ok_col and changed_col and type(new_col) == "number" then
                        UI.picker_color = new_col
                        UI.picker_search = string.format("#%06X", (new_col >> 8) & 0xFFFFFF)
                    end
                    reaper.ImGui_Spacing(ctx)
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFFFFFF22)
                    if select(2, pcall(reaper.ImGui_Button, ctx, "+ ADD TO PALETTE", 220, 30)) then
                        local t_name = env.palette_engine and env.palette_engine.GetColorName(UI.picker_color) or "Custom"
                        table.insert(UI.active_palette, { id=math.random(10000,99999), hex=UI.picker_color, token=t_name })
                        UI.PushNotification("Added " .. t_name, UI.picker_color)
                        pcall(reaper.ImGui_CloseCurrentPopup, ctx)
                    end
                    reaper.ImGui_PopStyleColor(ctx, 1); reaper.ImGui_PopItemWidth(ctx)
                    pcall(reaper.ImGui_EndPopup, ctx)
                else
                    UI.hover_states.picker_active = false
                end
                reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_PopStyleColor(ctx, 1)

                -- DIVIDER HITBOX (Controls final height)
                reaper.ImGui_SetCursorScreenPos(ctx, px, py + current_h - 3)
                UI.Safe_InvisibleButton(ctx, "pal_divider", canvas_w, 6)
                if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS()) end
                if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
                    local _, dy = reaper.ImGui_GetMouseDelta(ctx); UI.palette_height = UI.palette_height + dy
                end
            end
            reaper.ImGui_EndChild(ctx)
            reaper.ImGui_PopStyleVar(ctx, 1)
            canvas_h = total_h - current_h
        end

        local raw_cx, raw_cy = reaper.ImGui_GetCursorScreenPos(ctx)
        
        -- CRITICAL FIX: BeginGroup anchors the coordinates. PushClipRect contains the drawing.
        reaper.ImGui_BeginGroup(ctx)
        local dl_ide = reaper.ImGui_GetWindowDrawList(ctx)
        pcall(reaper.ImGui_DrawList_PushClipRect, dl_ide, raw_cx, raw_cy, raw_cx + canvas_w, raw_cy + canvas_h, true)
        
        -- Force ImGui to respect the canvas dimensions in the layout engine
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, raw_cx, raw_cy)
        reaper.ImGui_Dummy(ctx, canvas_w, canvas_h)
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, raw_cx, raw_cy)

        -- ==========================================================
        -- PRO CODE: ISOLATED IDE SCALING (Device Lane Method)
        -- ==========================================================
        local reg = UI.ScaleRegistry
        if not reg.IDE_Idx then reg.IDE_Idx = 4 end -- 4 is the default 1.0x scale

        local mw = select(2, pcall(reaper.ImGui_GetMouseWheel, ctx)) or 0
        local mx, my = select(2, pcall(reaper.ImGui_GetMousePos, ctx))
        mx, my = tonumber(mx) or 0, tonumber(my) or 0
        
        -- PRO FIX: Native ImGui Hover (Respects Window Z-Order, Tabs, and Occlusion!)
        local is_ide_hovered = select(2, pcall(reaper.ImGui_IsWindowHovered, ctx))

        -- 1. ISOLATED MOUSE WHEEL ZOOM (Stepped)
        local ctrl_held = false
        if pcall(reaper.ImGui_Mod_Ctrl) then
            if select(2, pcall(reaper.ImGui_IsKeyDown, ctx, reaper.ImGui_Mod_Ctrl())) then ctrl_held = true end
        elseif pcall(reaper.ImGui_ModFlags_Ctrl) then
            local ok_mods, mods = pcall(reaper.ImGui_GetKeyMods, ctx)
            local ok_flag, ctrl_flag = pcall(reaper.ImGui_ModFlags_Ctrl)
            if ok_mods and ok_flag and (mods & ctrl_flag) ~= 0 then ctrl_held = true end
        end

        if is_ide_hovered and ctrl_held and mw ~= 0 then
            if mw > 0 then 
                reg.IDE_Idx = math.min(#reg.steps, reg.IDE_Idx + 1)
            else 
                reg.IDE_Idx = math.max(1, reg.IDE_Idx - 1)
            end
        end

        local ide_z = reg.steps[reg.IDE_Idx] or 1.0

        -- 2. ISOLATED PANNING LOGIC
        local is_panning = (reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_Space()) or select(2, pcall(reaper.ImGui_IsMouseDown, ctx, 2)) or UI.active_tool == "PAN")
        if is_panning and is_ide_hovered then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
            local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
            UI.ide_camera.pan_x = UI.ide_camera.pan_x + dx
            UI.ide_camera.pan_y = UI.ide_camera.pan_y + dy
        end

        -- 3. PERFECT FONT PUSH (Pulls pre-baked font, no Canvas variables)
        UI.ide_pushed_font = false
        if reg.Fonts and reg.Fonts[reg.IDE_Idx] then
            local ide_font_sz = math.floor((14 * ide_z) + 0.5)
            local ok = pcall(reaper.ImGui_PushFont, ctx, reg.Fonts[reg.IDE_Idx], ide_font_sz)
            if not ok then ok = pcall(reaper.ImGui_PushFont, ctx, reg.Fonts[reg.IDE_Idx]) end
            if ok then UI.ide_pushed_font = true end
        end

        -- ==========================================================
        -- THE IDE GRID (Slaved exclusively to ide_z)
        -- ==========================================================
        local avail_w, avail_h = canvas_w, canvas_h
        local cell_size = 40; local grid_w = UI.wb_grid_cols * cell_size; local grid_h = UI.wb_grid_rows * cell_size
        
        local offset_x = math.max(0, (avail_w - grid_w * ide_z) / 2)
        local offset_y = math.max(0, (avail_h - grid_h * ide_z) / 2)
        local cx = raw_cx + offset_x + UI.ide_camera.pan_x 
        local cy = raw_cy + offset_y + UI.ide_camera.pan_y 

        reaper.ImGui_DrawList_AddRectFilled(dl_ide, cx, cy, cx + grid_w * ide_z, cy + grid_h * ide_z, 0x0A0A0DFF, 12.0 * ide_z)
        if UI.edit_mode then
            for y = 0, UI.wb_grid_rows do 
                for x = 0, UI.wb_grid_cols do 
                    reaper.ImGui_DrawList_AddCircleFilled(dl_ide, cx + (x * cell_size * ide_z), cy + (y * cell_size * ide_z), 1.5 * ide_z, 0xFFFFFF1A) 
                end 
            end
        end

        local sel_comp = nil
        for render_pass = 0, 1 do
            pcall(reaper.ImGui_DrawList_ChannelsSplit, dl_ide, 6)
            pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl_ide, 0) -- Force background to Layer 0
            for idx, c in ipairs(UI.wb_schema_buffer) do
                local is_sel = UI.IsComponentSelected(c.id)
                if (render_pass == 0 and not is_sel) or (render_pass == 1 and is_sel) then
                    if is_sel and not sel_comp then sel_comp = c end
                    local bx, by, bw, bh = GetBounds(c)
                    local comp_x, comp_y = cx + bx * ide_z, cy + by * ide_z
                    local comp_col = is_sel and 0x00E5FFFF or 0x444444FF
                    
                    -- ==========================================================
                    -- THE SELECTION BRIDGE (Universal Coordinate Hit-Test for Play Mode)
                    -- ==========================================================
                    if not UI.edit_mode then
                        if select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then
                            local mx, my = reaper.ImGui_GetMousePos(ctx)
                            if mx >= comp_x and mx <= comp_x + (bw * ide_z) and my >= comp_y and my <= comp_y + (bh * ide_z) then
                                UI.selected_comp_ids = {c.id}
                            end
                        end
                    end

                    -- ==========================================================
                    -- LAYOUT DRAG HITBOX / BOUNDING BOX INTERACTION: ONLY ACTIVE IN DESIGN MODE
                    -- ==========================================================
                    if UI.edit_mode then
                        reaper.ImGui_SetCursorScreenPos(ctx, comp_x, comp_y)
                        reaper.ImGui_InvisibleButton(ctx, "ide_hit_"..c.id, bw * ide_z, bh * ide_z)
                        
                        if reaper.ImGui_IsItemClicked(ctx) then
                            UI.drag_mem.pending_push = true
                            local keep = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
                            if not UI.IsComponentSelected(c.id) then UI.SelectComponent(c.id, keep) end
                            local mx, my = reaper.ImGui_GetMousePos(ctx)
                            UI.drag_mem.mouse_start_x = mx; UI.drag_mem.mouse_start_y = my
                            UI.drag_mem.group_starts = {}
                            for _, sc in ipairs(UI.wb_schema_buffer) do
                                if UI.IsComponentSelected(sc.id) then UI.drag_mem.group_starts[sc.id] = {x = sc.x, y = sc.y} end
                            end
                            UI.drag_mem.is_snapped_x = false; UI.drag_mem.is_snapped_y = false
                        end
                        if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
                            local mx, my = reaper.ImGui_GetMousePos(ctx)
                            
                            -- ALT-DRAG DUPLICATION
                            if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt()) and not UI.drag_mem.alt_cloned then
                                UI.drag_mem.alt_cloned = true
                                local clone = {}; for k,v in pairs(c) do clone[k] = v end
                                -- Append a microsecond timestamp to the ID to guarantee it never collides
                                clone.id = c.id .. "_" .. tostring(math.floor(reaper.time_precise() * 100000))
                                table.insert(UI.wb_schema_buffer, clone)
                                UI.SelectComponent(clone.id, false)
                                UI.drag_mem.group_starts = { [clone.id] = { x = c.x, y = c.y } }
                                c = clone 
                            end

                            if UI.drag_mem.pending_push then UI.PushUndoState(); UI.drag_mem.pending_push = false end
                            local my_start = UI.drag_mem.group_starts[c.id]
                            if my_start then
                                local dx = (mx - UI.drag_mem.mouse_start_x) / ide_z
                                local dy = (my - UI.drag_mem.mouse_start_y) / ide_z
                                
                                -- Build unified bounding box for the selection group
                                local g_min_x, g_min_y, g_max_x, g_max_y = 99999, 99999, -99999, -99999
                                local unselected = {}
                                for _, sc in ipairs(UI.wb_schema_buffer) do
                                    if UI.IsComponentSelected(sc.id) then
                                        local st = UI.drag_mem.group_starts[sc.id]
                                        local s_bw, s_bh = sc.w or 60, sc.h or 20
                                        if sc.type == "AuraKnob" then s_bw, s_bh = (sc.radius or 16)*2, (sc.radius or 16)*2 end
                                        if st then
                                            g_min_x = math.min(g_min_x, st.x)
                                            g_min_y = math.min(g_min_y, st.y)
                                            g_max_x = math.max(g_max_x, st.x + s_bw)
                                            g_max_y = math.max(g_max_y, st.y + s_bh)
                                        end
                                    else
                                        table.insert(unselected, sc)
                                    end
                                end
                                
                                -- Create a dummy component representing the entire group for snapping
                                local g_w, g_h = g_max_x - g_min_x, g_max_y - g_min_y
                                local group_c = { id = "GROUP", x = g_min_x, y = g_min_y, w = g_w, h = g_h, type = "GROUP" }
                                local intended_g_x = g_min_x + dx
                                local intended_g_y = g_min_y + dy
                                
                                -- Snap the entire group against unselected components
                                if UI.snap_enabled and not reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()) then
                                    ProcessSmartGuides(group_c, intended_g_x, intended_g_y, unselected, dl_ide, cx, cy, mx, my)
                                else
                                    group_c.x = intended_g_x; group_c.y = intended_g_y
                                end
                                
                                -- Calculate snapped delta
                                local snapped_dx = group_c.x - g_min_x
                                local snapped_dy = group_c.y - g_min_y
                                
                                -- Apply to all selected components
                                for _, sc in ipairs(UI.wb_schema_buffer) do
                                    local st = UI.drag_mem.group_starts[sc.id]
                                    if st then
                                        local s_bw, s_bh = sc.w or 60, sc.h or 20
                                        if sc.type == "AuraKnob" then s_bw, s_bh = (sc.radius or 16)*2, (sc.radius or 16)*2 end
                                        -- FLOOR THE VALUES TO PREVENT CRASHES
                                        sc.x = math.max(0, math.floor(math.min(grid_w - s_bw, st.x + snapped_dx)))
                                        sc.y = math.max(0, math.floor(math.min(grid_h - s_bh, st.y + snapped_dy)))
                                    end
                                end
                            end
                        elseif reaper.ImGui_IsItemDeactivated(ctx) then
                            UI.drag_mem.alt_cloned = false
                        end
                    end
                    
                    env.p_min_x = cx; env.p_min_y = cy; env.scroll_x = 0; env.scroll_y = 0
                    local live_val = c.val or c.default_val or 0.5
                    local c_mock = { 
                        id = c.id, 
                        z = ide_z, -- INJECT THE FIXED IDE SCALE
                        x = c.x,   -- KEEP RAW. Scaling happens inside the component.
                        y = c.y, 
                        w = c.w or 60, 
                        h = c.h or 20, 
                        radius = c.radius or 16, 
                        align = c.align, label = c.label, color_token = c.color_token or "Teal", 
                        default_val = live_val,
                        routes = c.routes,
                        is_bipolar = c.is_bipolar,
                        steps = c.steps, axis = c.axis, wrap_at = c.wrap_at, 
                        btn_w = c.btn_w, 
                        btn_h = c.btn_h, 
                        labels = c.labels
                    }
                    
                    -- Initialize/fetch physics state for this component
                    if not UI.physics_states[c.id] then
                        UI.physics_states[c.id] = {
                            disp_val = live_val,
                            vel_val = 0.0,
                            flash = 0.0
                        }
                    end
                    local pst = UI.physics_states[c.id]
                    
                    -- Smoothly interpolate disp_val towards live_val
                    pst.disp_val, pst.vel_val = UI.SpringDamp(pst.disp_val, live_val, pst.vel_val, 250.0, 18.0, env.app_dt or 0.016)
                    
                    -- Decelerate flash time
                    if pst.flash > 0 then
                        pst.flash = math.max(0, pst.flash - (env.app_dt or 0.016) * 3.0)
                    end

                    local disp_str = ""
                    if type(c.get_format) == "function" then
                        disp_str = c:get_format(live_val)
                    elseif type(c.get_format) == "string" then
                        local success, res = pcall(function() return c.get_format(c, live_val) end)
                        if success then
                            disp_str = res
                        else
                            disp_str = string.format("%.2f", live_val)
                        end
                    else
                        disp_str = string.format("%.2f", live_val)
                    end
                    
                    -- 1. Z-Override Fallback
                    local target_layer = c.z_override
                    if not target_layer then
                        if c.type == "Text" or c.type == "BackPanel" then target_layer = 3
                        elseif c.type == "Dropdown" or c.type == "Tooltip" then target_layer = 5
                        else target_layer = 4 end
                    end
                    
                    -- 2. THE FILTER LOGIC (Early Exit)
                    if env.filter_layer and target_layer ~= env.filter_layer then
                        goto skip_component
                    end

                    -- 3. THE LOCK LOGIC (Disable Interaction)
                    local is_locked = (env.locked_layer and target_layer ~= env.locked_layer)
                    if is_locked then pcall(reaper.ImGui_BeginDisabled, ctx) end

                    pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl_ide, target_layer)

                    -- Replace your massive IDE if/elseif block with this updated block:
                    -- PRO CODE: Unified Factory Dispatcher
                    local changed, new_norm = false, live_val
                    local ox, oy = env.p_min_x, env.p_min_y 
                    
                    if env.NodeUI and env.NodeUI.Registry then
                        local renderer = env.NodeUI.Registry[c.type]
                        if renderer then
                            -- Both IDE and Canvas now pass the EXACT same footprint
                            changed, new_norm = renderer(ctx, dl_ide, c_mock, ox, oy, env, nil, false, live_val, disp_str, pst, UI)
                        else
                            reaper.ShowConsoleMsg("OMM OS Error: Missing Renderer in NodeUI Registry for -> " .. tostring(c.type) .. "\n")
                        end
                    end
                    
                    if not UI.edit_mode and changed and new_norm then
                        c.val = new_norm
                    end
                    
                    if is_locked then pcall(reaper.ImGui_EndDisabled, ctx) end
                    
                    ::skip_component::
                end
            end
            pcall(reaper.ImGui_DrawList_ChannelsMerge, dl_ide)
        end

        if #UI.selected_comp_ids > 0 then
            local g_min_x, g_min_y, g_max_x, g_max_y = 99999, 99999, -99999, -99999
            for _, c in ipairs(UI.wb_schema_buffer) do
                if UI.IsComponentSelected(c.id) then
                    local bx, by, bw, bh = GetBounds(c)
                    local comp_x, comp_y = cx + bx * ide_z, cy + by * ide_z
                    g_min_x = math.min(g_min_x, comp_x)
                    g_min_y = math.min(g_min_y, comp_y)
                    g_max_x = math.max(g_max_x, comp_x + bw * ide_z)
                    g_max_y = math.max(g_max_y, comp_y + bh * ide_z)
                end
            end
            if g_min_x < 99999 and UI.edit_mode then
                reaper.ImGui_DrawList_AddRect(dl_ide, g_min_x-4, g_min_y-4, g_max_x+4, g_max_y+4, 0xFFFFFF66, 4.0, 0, 1.0)
                -- RESIZE HANDLE LOCK: ONLY ACTIVE IN DESIGN MODE
                if UI.edit_mode and #UI.selected_comp_ids == 1 and sel_comp then
                    local hw, hh = 12, 12; local hx, hy = g_max_x + 4 - hw, g_max_y + 4 - hh
                    reaper.ImGui_SetCursorScreenPos(ctx, hx, hy)
                    reaper.ImGui_InvisibleButton(ctx, "sz_"..sel_comp.id, hw, hh)
                    local is_hov = reaper.ImGui_IsItemHovered(ctx)
                    if is_hov then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNWSE()) end
                    reaper.ImGui_DrawList_AddTriangleFilled(dl_ide, hx+hw, hy, hx+hw, hy+hh, hx, hy+hh, is_hov and 0xFFFFFFFF or 0xFFFFFF88)
                    if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
                        local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
                        dx = dx / ide_z
                        dy = dy / ide_z
                        if sel_comp.type == "AuraKnob" then sel_comp.radius = math.floor(math.max(10, (sel_comp.radius or 16) + math.max(dx, dy)*0.5))
                        else sel_comp.w = math.floor(math.max(20, (sel_comp.w or 60) + dx)); sel_comp.h = math.floor(math.max(10, (sel_comp.h or 20) + dy)) end
                    end
                end
            end
        end

        -- BACKDROP / DROP ZONE / MARQUEE: ONLY ACTIVE IN DESIGN MODE
        if UI.edit_mode then
            reaper.ImGui_SetCursorScreenPos(ctx, cx, cy)
            reaper.ImGui_InvisibleButton(ctx, "canvas_drop_zone", grid_w * ide_z, grid_h * ide_z)
            
            local bg_clicked = reaper.ImGui_IsItemClicked(ctx, 0)
            if bg_clicked then
                local mx, my = reaper.ImGui_GetMousePos(ctx)
                if not (reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())) then UI.selected_comp_ids = {} end
                UI.drag_mem.marquee_start_x = mx; UI.drag_mem.marquee_start_y = my; UI.drag_mem.is_marquee = true
            end
            if UI.drag_mem.is_marquee and reaper.ImGui_IsMouseDragging(ctx, 0) then
                local mx, my = reaper.ImGui_GetMousePos(ctx)
                local rx = math.min(UI.drag_mem.marquee_start_x, mx)
                local ry = math.min(UI.drag_mem.marquee_start_y, my)
                local rw = math.abs(mx - UI.drag_mem.marquee_start_x)
                local rh = math.abs(my - UI.drag_mem.marquee_start_y)
                reaper.ImGui_DrawList_AddRectFilled(dl_ide, rx, ry, rx + rw, ry + rh, 0x00E5FF22)
                reaper.ImGui_DrawList_AddRect(dl_ide, rx, ry, rx + rw, ry + rh, 0x00E5FFFF, 0, 0, 1.0)
                
                for _, c in ipairs(UI.wb_schema_buffer) do
                    local bx, by, bw, bh = GetBounds(c)
                    local comp_screen_x, comp_screen_y = cx + bx * ide_z, cy + by * ide_z
                    local comp_w, comp_h = bw * ide_z, bh * ide_z
                    if comp_screen_x < rx + rw and comp_screen_x + comp_w > rx and comp_screen_y < ry + rh and comp_screen_y + comp_h > ry then
                        UI.SelectComponent(c.id, true)
                    end
                end
            end
            if UI.drag_mem.is_marquee and reaper.ImGui_IsMouseReleased(ctx, 0) then UI.drag_mem.is_marquee = false end

            if reaper.ImGui_BeginDragDropTarget(ctx) then
                local accepted, payload = reaper.ImGui_AcceptDragDropPayload(ctx, 'NEW_COMP')
                if accepted and payload then
                    local mx, my = reaper.ImGui_GetMousePos(ctx)
                    local world_drop_x = (mx - cx) / ide_z
                    local world_drop_y = (my - cy) / ide_z
                    local drop_x = math.max(0, math.floor(world_drop_x / 10) * 10)
                    local drop_y = math.max(0, math.floor(world_drop_y / 10) * 10)
                    local blueprint_prefix = active_target.name:match("([^%s:]+)$") or "MOD"
                    local new_id = string.format("%s_%s_%d", blueprint_prefix, payload, math.random(1000, 9999))
                    local nw, nh, nr = 60, 20, 16
                    if payload == "PeakMeter" then nw, nh = 20, 100
                    elseif payload == "VuMeter" then nw, nh = 100, 80
                    elseif payload == "TogglePill" then nw, nh = 50, 24
                    elseif payload == "ToggleLever" then nw, nh = 24, 50
                    elseif payload == "AuraKnob" then nr = 16; nw, nh = 32, 32
                    elseif payload == "Fader" then nw, nh = 30, 120
                    elseif payload == "VFDScreen" then nw, nh = 140, 50
                    elseif payload == "Dropdown" then nw, nh = 140, 28
                    elseif payload == "BackPanel" then nw, nh = 200, 160
                    elseif payload == "ScrewDecal" then nr = 5; nw, nh = 10, 10
                    elseif payload == "RadioStrip" then nw, nh = 240, 36 end
                    local new_comp = { id = new_id, type = payload, x = drop_x, y = drop_y, radius = nr, w = nw, h = nh, align = 1, label = payload:upper(), color_token = "Teal", param_key = "unmapped", default_val = 0.0, routes = {} }
                    if payload == "RadioStrip" then
                        new_comp.steps = 6
                        new_comp.axis = "H"
                        new_comp.wrap_at = 6
                        new_comp.btn_w = 32
                        new_comp.btn_h = 24
                        new_comp.labels = {"1", "2", "3", "4", "5", "6"}
                    end
                    UI.PushUndoState()
                    table.insert(UI.wb_schema_buffer, new_comp); UI.SelectComponent(new_id, false)
                end
                reaper.ImGui_EndDragDropTarget(ctx)
            end
        end
        pcall(reaper.ImGui_SetWindowFontScale, ctx, 1.0)
        if UI.ide_pushed_font then pcall(reaper.ImGui_PopFont, ctx); UI.ide_pushed_font = false end
        
        -- TOP-RIGHT ZOOM HUD (Isolated Registry Hook)
        local hud_w, hud_h = 130, 32
        local hud_x, hud_y = raw_cx + avail_w - hud_w - 20, raw_cy + 20
        reaper.ImGui_DrawList_AddRectFilled(dl_ide, hud_x, hud_y, hud_x + hud_w, hud_y + hud_h, 0x11111199, 16.0)
        reaper.ImGui_DrawList_AddRect(dl_ide, hud_x, hud_y, hud_x + hud_w, hud_y + hud_h, 0xFFFFFF22, 16.0, 0, 1.0)
        
        reaper.ImGui_SetCursorScreenPos(ctx, hud_x + 8, hud_y + 4)
        if reaper.ImGui_Button(ctx, "-##zo", 24, 24) then UI.ScaleRegistry.IDE_Idx = math.max(1, UI.ScaleRegistry.IDE_Idx - 1) end
        reaper.ImGui_SameLine(ctx)
        
        local z_str = string.format("%d%%", math.floor((UI.ScaleRegistry.steps[UI.ScaleRegistry.IDE_Idx] or 1.0) * 100))
        local zw = reaper.ImGui_CalcTextSize(ctx, z_str)
        reaper.ImGui_SetCursorScreenPos(ctx, hud_x + (hud_w/2) - (zw/2), hud_y + 8)
        reaper.ImGui_Text(ctx, z_str)
        if reaper.ImGui_IsItemClicked(ctx) then UI.ScaleRegistry.IDE_Idx = 4; UI.ide_camera.pan_x = 0; UI.ide_camera.pan_y = 0 end
        
        reaper.ImGui_SetCursorScreenPos(ctx, hud_x + hud_w - 32, hud_y + 4)
        if reaper.ImGui_Button(ctx, "+##zi", 24, 24) then UI.ScaleRegistry.IDE_Idx = math.min(#UI.ScaleRegistry.steps, UI.ScaleRegistry.IDE_Idx + 1) end

        -- LEFT-EDGE ACTION HUB (ABSOLUTE VERTICAL CENTER)
        local tb_w, tb_h = 44, 170
        local tb_x = raw_cx + 20
        local tb_y = top_wy + 16 + (avail_main_h / 2) - (tb_h / 2) -- Locks independently of Palette!
        
        reaper.ImGui_DrawList_AddRectFilled(dl_ide, tb_x, tb_y, tb_x + tb_w, tb_y + tb_h, 0x111111CC, 12.0)
        reaper.ImGui_DrawList_AddRect(dl_ide, tb_x, tb_y, tb_x + tb_w, tb_y + tb_h, 0xFFFFFF22, 12.0, 0, 1.0)
        
        local function DrawHubIcon(id, tx, ty, icon_type, is_active)
            reaper.ImGui_SetCursorScreenPos(ctx, tx, ty)
            UI.Safe_InvisibleButton(ctx, id, 36, 36)
            local hov = reaper.ImGui_IsItemHovered(ctx)
            local col = (is_active or hov) and 0x00E5FFFF or 0x888888FF
            if hov then reaper.ImGui_DrawList_AddRectFilled(dl_ide, tx, ty, tx+36, ty+36, 0xFFFFFF11, 8.0) end

            if icon_type == "SEL" then
                reaper.ImGui_DrawList_AddTriangleFilled(dl_ide, tx+12, ty+10, tx+12, ty+22, tx+20, ty+17, col)
                reaper.ImGui_DrawList_AddLine(dl_ide, tx+15, ty+19, tx+18, ty+26, col, 2.0)
            elseif icon_type == "PAN" then
                reaper.ImGui_DrawList_AddRect(dl_ide, tx+13, ty+14, tx+23, ty+22, col, 3.0, 0, 2.0)
                reaper.ImGui_DrawList_AddLine(dl_ide, tx+15, ty+14, tx+15, ty+10, col, 2.0)
                reaper.ImGui_DrawList_AddLine(dl_ide, tx+18, ty+14, tx+18, ty+8, col, 2.0)
                reaper.ImGui_DrawList_AddLine(dl_ide, tx+21, ty+14, tx+21, ty+11, col, 2.0)
            elseif icon_type == "MAG" then
                reaper.ImGui_DrawList_PathArcTo(dl_ide, tx+18, ty+15, 5, math.pi, math.pi*2, 0)
                reaper.ImGui_DrawList_PathStroke(dl_ide, col, 0, 2.0)
                reaper.ImGui_DrawList_AddLine(dl_ide, tx+13, ty+15, tx+13, ty+22, col, 2.0)
                reaper.ImGui_DrawList_AddLine(dl_ide, tx+23, ty+15, tx+23, ty+22, col, 2.0)
                reaper.ImGui_DrawList_AddRectFilled(dl_ide, tx+11, ty+22, tx+15, ty+24, col)
                reaper.ImGui_DrawList_AddRectFilled(dl_ide, tx+21, ty+22, tx+25, ty+24, col)
            elseif icon_type == "PAL" then
                reaper.ImGui_DrawList_AddCircle(dl_ide, tx+18, ty+18, 7, col, 0, 2.0)
                reaper.ImGui_DrawList_AddCircleFilled(dl_ide, tx+15, ty+20, 2, col)
                reaper.ImGui_DrawList_AddCircleFilled(dl_ide, tx+16, ty+14, 1.5, col)
                reaper.ImGui_DrawList_AddCircleFilled(dl_ide, tx+21, ty+15, 1.5, col)
            end
            return reaper.ImGui_IsItemClicked(ctx)
        end

        if DrawHubIcon("t_sel", tb_x + 4, tb_y + 8, "SEL", UI.active_tool == "SELECT") then UI.active_tool = "SELECT" end
        if DrawHubIcon("t_pan", tb_x + 4, tb_y + 48, "PAN", UI.active_tool == "PAN") then UI.active_tool = "PAN" end
        if DrawHubIcon("t_snp", tb_x + 4, tb_y + 88, "MAG", UI.snap_enabled) then UI.snap_enabled = not UI.snap_enabled end
        if DrawHubIcon("t_pal", tb_x + 4, tb_y + 128, "PAL", UI.palette_open) then UI.palette_open = not UI.palette_open end

        -- DRAW TOAST NOTIFICATIONS
        UI.DrawNotifications(ctx, dl_ide, raw_cx + (canvas_w/2), raw_cy + canvas_h - 20, env.app_dt)

        pcall(reaper.ImGui_DrawList_PopClipRect, dl_ide)
        reaper.ImGui_EndGroup(ctx) -- Ends canvas internal group
        reaper.ImGui_EndChild(ctx) -- ENDS PANE 2 WRAPPER
        reaper.ImGui_SameLine(ctx, 0, 8)

        -- 5. RENDER PANE 3 (PROPERTIES)
        reaper.ImGui_BeginChild(ctx, "omm_props_pane", p3_w, 0, 0, 0)
        local dl_right = reaper.ImGui_GetWindowDrawList(ctx)
        
        -- 1. Create a scrolling child window that stops 40 pixels before the bottom
        reaper.ImGui_BeginChild(ctx, "omm_prop_scroll", 0, -40)
        
        reaper.ImGui_TextColored(ctx, 0x00A5FFFF, "THEME MANAGER")
            reaper.ImGui_Spacing(ctx)
        
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0xFFFFFF1A)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0xFFFFFF22)
        reaper.ImGui_PushItemWidth(ctx, 220)
        if reaper.ImGui_BeginCombo(ctx, "##theme_sel", UI.theme_manager.current_theme) then
            for _, t in ipairs(UI.theme_manager.list) do
                if reaper.ImGui_Selectable(ctx, t, UI.theme_manager.current_theme == t) then
                    UI.theme_manager.current_theme = t; LoadThemeIntoBuffer(active_target.algo, t, env)
                end
            end
            reaper.ImGui_EndCombo(ctx)
        end
        reaper.ImGui_PopItemWidth(ctx)
        reaper.ImGui_PopStyleColor(ctx, 2)
        
        reaper.ImGui_SameLine(ctx, 0, 10)
        local px, py = reaper.ImGui_GetCursorScreenPos(ctx)
        local clk_plus, is_plus_active, t_plus = UI.DrawAnimatedPlus(ctx, dl_right, "plus_theme", UI.theme_manager.is_creating, env.app_dt, px, py - 4)
        UI.theme_manager.is_creating = is_plus_active
        
        if t_plus > 0.01 then
            reaper.ImGui_BeginChild(ctx, "new_theme_box", 0, 60 * t_plus, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_plus)
            reaper.ImGui_PushItemWidth(ctx, 190)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x000000FF)
            local changed_t, new_t = reaper.ImGui_InputText(ctx, "##newtheme", UI.theme_manager.new_theme_name)
            if changed_t then UI.theme_manager.new_theme_name = new_t end
            reaper.ImGui_PopStyleColor(ctx, 1); reaper.ImGui_PopItemWidth(ctx)
            
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF6B35FF)
            if reaper.ImGui_Button(ctx, "CREATE") and UI.theme_manager.new_theme_name ~= "" then
                local compile_data = { algo = active_target.algo, grid_cols = UI.wb_grid_cols, grid_rows = UI.wb_grid_rows, components = UI.wb_schema_buffer }
                UI.CompileFaceplate(compile_data, UI.theme_manager.new_theme_name)
                UI.theme_manager.list = ScanThemesForAlgo(active_target.algo)
                UI.theme_manager.current_theme = UI.theme_manager.new_theme_name
                UI.theme_manager.new_theme_name = ""; UI.theme_manager.is_creating = false
            end
            reaper.ImGui_PopStyleColor(ctx, 1); reaper.ImGui_PopStyleVar(ctx, 1)
            reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00A5FFFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x33D5FFFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x000000FF)
        if reaper.ImGui_Button(ctx, "SET AS DEFAULT MODULE THEME", -1, 30) then
            UI.config.defaults[active_target.algo] = UI.theme_manager.current_theme
            UI.WriteOSConfig()
            if env.NodeUI then env.NodeUI.HotReload(active_target.algo, UI) end
            reaper.ShowConsoleMsg("OMM OS: Assigned Theme '" .. UI.theme_manager.current_theme .. "' to Algo " .. tostring(active_target.algo) .. " Registry.\n")
        end
        reaper.ImGui_PopStyleColor(ctx, 3)

        reaper.ImGui_Spacing(ctx); reaper.ImGui_Spacing(ctx); reaper.ImGui_Separator(ctx)
        
        UI.open_palette = UI.open_palette == nil and true or UI.open_palette
        local clk_pal, open_pal, t_pal = UI.DrawAnimatedDisclosure(ctx, dl_right, "pal_disc", "MODULE PALETTE", UI.open_palette, env.app_dt, 280)
        UI.open_palette = open_pal
        if t_pal > 0.01 then
            reaper.ImGui_BeginChild(ctx, "omm_pal_list", 0, 160 * t_pal, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_pal)
            
            reaper.ImGui_PushItemWidth(ctx, 220)
            local c_chg, new_col = reaper.ImGui_ColorEdit4(ctx, "##SeedColor", UI.theme_seed_hex, reaper.ImGui_ColorEditFlags_NoInputs() | reaper.ImGui_ColorEditFlags_NoLabel())
            if c_chg then UI.theme_seed_hex = new_col end
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_Spacing(ctx)
            
            local keys = {"Base", "Secondary", "TextDim", "TextBright", "Accent_A", "Accent_B", "Teal", "Tangerine"}
            local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
            local swatch_size, gap = 26, 12
            for i, k in ipairs(keys) do
                local row, col = math.floor((i-1)/4), (i-1)%4
                local sx, sy = cx + col*(swatch_size+gap), cy + row*(swatch_size+gap)
                
                reaper.ImGui_SetCursorScreenPos(ctx, sx, sy)
                reaper.ImGui_InvisibleButton(ctx, "swatch_"..k, swatch_size, swatch_size)
                local is_hov = reaper.ImGui_IsItemHovered(ctx)
                if is_hov then reaper.ImGui_SetTooltip(ctx, k) end
                
                local ht = UI.hover_states["swatch_"..k] or 0.0
                ht = UI.SpringDamp(ht, is_hov and 1.0 or 0.0, 0.0, 300, 20, env.app_dt)
                UI.hover_states["swatch_"..k] = ht
                
                local inflated, ix, iy = swatch_size + (ht * 6.0), sx - (ht * 3.0), sy - (ht * 3.0)
                reaper.ImGui_DrawList_AddRectFilled(dl_right, ix, iy, ix+inflated, iy+inflated, env.palette[k], 12.0)
                reaper.ImGui_DrawList_AddRect(dl_right, ix, iy, ix+inflated, iy+inflated, 0xFFFFFF33, 12.0, 0, 1.0)
                
                if reaper.ImGui_IsItemClicked(ctx) then
                    if not (reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())) then UI.selected_comp_ids = {} end
                    for _, c in ipairs(UI.wb_schema_buffer) do if c.color_token == k then UI.SelectComponent(c.id, true) end end
                end
            end
            
            reaper.ImGui_PopStyleVar(ctx, 1)
            reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_Spacing(ctx); reaper.ImGui_Spacing(ctx); reaper.ImGui_Separator(ctx)
        
        UI.open_settings = UI.open_settings == nil and true or UI.open_settings
        local clk_set, open_set, t_set = UI.DrawAnimatedDisclosure(ctx, dl_right, "set_disc", "CANVAS SETTINGS", UI.open_settings, env.app_dt, 200)
        UI.open_settings = open_set
        if t_set > 0.01 then
            reaper.ImGui_BeginChild(ctx, "omm_set_list", 0, 40 * t_set, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_set)
            reaper.ImGui_PushItemWidth(ctx, 80)
            local c_chg, n_cols = reaper.ImGui_DragInt(ctx, "Cols##chas", UI.wb_grid_cols, 1, 4, 64)
            if c_chg then UI.wb_grid_cols = math.floor(n_cols) end
            reaper.ImGui_SameLine(ctx, 0, 20)
            local r_chg, n_rows = reaper.ImGui_DragInt(ctx, "Rows##chas", UI.wb_grid_rows, 1, 2, 32)
            if r_chg then UI.wb_grid_rows = math.floor(n_rows) end
            reaper.ImGui_PopItemWidth(ctx); reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_EndChild(ctx)
        end
        
        reaper.ImGui_Spacing(ctx); reaper.ImGui_TextColored(ctx, 0x8E8E93FF, "DATA BINDING")

        if #UI.selected_comp_ids > 1 then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0xFFFFFF0A)
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12.0)
            reaper.ImGui_TextColored(ctx, 0x00E5FFFF, "MULTIPLE COMPONENTS SELECTED (" .. tostring(#UI.selected_comp_ids) .. ")"); reaper.ImGui_Spacing(ctx)
            
            reaper.ImGui_TextColored(ctx, 0x888888FF, "Color Token (Group)")
            if reaper.ImGui_BeginCombo(ctx, "##coltok_grp", "Select Token...") then
                for _, k in ipairs({"Accent_A", "Accent_B", "Teal", "Tangerine", "Base", "Secondary", "TextBright"}) do
                    if reaper.ImGui_Selectable(ctx, k, false) then
                        UI.PushUndoState()
                        for _, c in ipairs(UI.wb_schema_buffer) do
                            if UI.IsComponentSelected(c.id) then c.color_token = k end
                        end
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            
            reaper.ImGui_Spacing(ctx); reaper.ImGui_TextColored(ctx, 0x888888FF, "ALIGNMENT TOOLS")
            if reaper.ImGui_Button(ctx, "Align Left", -1, 28) then
                UI.PushUndoState()
                local min_x = 99999
                for _, c in ipairs(UI.wb_schema_buffer) do
                    if UI.IsComponentSelected(c.id) then min_x = math.min(min_x, c.x) end
                end
                for _, c in ipairs(UI.wb_schema_buffer) do
                    if UI.IsComponentSelected(c.id) then c.x = min_x end
                end
            end
            if reaper.ImGui_Button(ctx, "Align Center (H)", -1, 28) then
                UI.PushUndoState()
                local min_x, max_x = 99999, -99999
                for _, c in ipairs(UI.wb_schema_buffer) do
                    if UI.IsComponentSelected(c.id) then
                        local bx, by, bw, bh = GetBounds(c)
                        min_x = math.min(min_x, c.x)
                        max_x = math.max(max_x, c.x + bw)
                    end
                end
                local center_x = min_x + (max_x - min_x) / 2
                for _, c in ipairs(UI.wb_schema_buffer) do
                    if UI.IsComponentSelected(c.id) then
                        local bx, by, bw, bh = GetBounds(c)
                        c.x = center_x - (bw / 2)
                    end
                end
            end
            if reaper.ImGui_Button(ctx, "Distribute Horizontal", -1, 28) then
                UI.PushUndoState()
                local sel_nodes = {}
                for _, c in ipairs(UI.wb_schema_buffer) do
                    if UI.IsComponentSelected(c.id) then table.insert(sel_nodes, c) end
                end
                table.sort(sel_nodes, function(a, b) return a.x < b.x end)
                if #sel_nodes > 2 then
                    local first, last = sel_nodes[1], sel_nodes[#sel_nodes]
                    local total_w = 0
                    for i = 2, #sel_nodes - 1 do
                        local bx, by, bw, bh = GetBounds(sel_nodes[i]); total_w = total_w + bw
                    end
                    local f_bx, f_by, f_bw, f_bh = GetBounds(first)
                    local available_space = last.x - (first.x + f_bw)
                    local gap = (available_space - total_w) / (#sel_nodes - 1)
                    local current_x = first.x + f_bw + gap
                    for i = 2, #sel_nodes - 1 do
                        local c = sel_nodes[i]
                        c.x = current_x
                        local bx, by, bw, bh = GetBounds(c)
                        current_x = current_x + bw + gap
                    end
                end
            end
            
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x441111FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x661111FF)
            if reaper.ImGui_Button(ctx, "DELETE COMPONENTS", -1, 36) then
                UI.PushUndoState()
                for i = #UI.wb_schema_buffer, 1, -1 do
                    if UI.IsComponentSelected(UI.wb_schema_buffer[i].id) then table.remove(UI.wb_schema_buffer, i) end
                end
                UI.selected_comp_ids = {}
            end
            reaper.ImGui_PopStyleColor(ctx, 2)
            
            reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_PopStyleColor(ctx, 1); reaper.ImGui_Spacing(ctx)
        elseif #UI.selected_comp_ids == 1 and sel_comp then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0xFFFFFF0A)
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12.0)
            reaper.ImGui_Text(ctx, "ID: " .. sel_comp.id)
            
            -- VECTOR ALIGNMENT & Z-INDEX TOOLBAR
            reaper.ImGui_Spacing(ctx)
            if UI.DrawVectorIcon(ctx, dl_right, "aln_l", "ALIGN_L", sel_comp.align == 0) then UI.PushUndoState(); sel_comp.align = 0 end
            reaper.ImGui_SameLine(ctx, 0, 4)
            if UI.DrawVectorIcon(ctx, dl_right, "aln_c", "ALIGN_C", sel_comp.align == 1) then UI.PushUndoState(); sel_comp.align = 1 end
            reaper.ImGui_SameLine(ctx, 0, 4)
            if UI.DrawVectorIcon(ctx, dl_right, "aln_r", "ALIGN_R", sel_comp.align == 2) then UI.PushUndoState(); sel_comp.align = 2 end
            
            reaper.ImGui_SameLine(ctx, 0, 16)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFFFFFF11)
            if reaper.ImGui_Button(ctx, "Send to Back", 0, 28) then
                UI.PushUndoState()
                for i, c in ipairs(UI.wb_schema_buffer) do
                    if c.id == sel_comp.id then table.remove(UI.wb_schema_buffer, i); table.insert(UI.wb_schema_buffer, 1, c); break end
                end
            end
            reaper.ImGui_SameLine(ctx, 0, 4)
            if reaper.ImGui_Button(ctx, "Bring to Front", 0, 28) then
                UI.PushUndoState()
                for i, c in ipairs(UI.wb_schema_buffer) do
                    if c.id == sel_comp.id then table.remove(UI.wb_schema_buffer, i); table.insert(UI.wb_schema_buffer, c); break end
                end
            end
            reaper.ImGui_PopStyleColor(ctx, 1)
            reaper.ImGui_Spacing(ctx)
            
            reaper.ImGui_TextColored(ctx, 0x888888FF, "Z-Override (Render Layer)")
            reaper.ImGui_PushItemWidth(ctx, 120)
            local current_z = sel_comp.z_override or "Auto"
            if select(2, pcall(reaper.ImGui_BeginCombo, ctx, "##z_over", tostring(current_z))) then
                for _, z_val in ipairs({"Auto", "0", "1", "2", "3", "4", "5"}) do
                    if select(2, pcall(reaper.ImGui_Selectable, ctx, z_val, z_val == current_z)) then
                        UI.PushUndoState()
                        sel_comp.z_override = (z_val == "Auto") and nil or z_val
                    end
                end
                pcall(reaper.ImGui_EndCombo, ctx)
            end
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_Spacing(ctx)

            reaper.ImGui_PushItemWidth(ctx, -1)
            
            reaper.ImGui_TextColored(ctx, 0x888888FF, "Label Name")
            local l_chg, new_l = reaper.ImGui_InputText(ctx, "##lbl", sel_comp.label or "")
            if l_chg then sel_comp.label = new_l end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
            
            reaper.ImGui_TextColored(ctx, 0x888888FF, "Visual State Binding (Required)")
            local k_chg, new_k = reaper.ImGui_InputText(ctx, "##pkey", sel_comp.param_key or "")
            if k_chg then sel_comp.param_key = new_k end
            if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end

            local comp = sel_comp
            if comp.type == "Knob" or comp.type == "Slider" or comp.type == "AuraKnob" or comp.type == "Fader" or comp.type == "InlineDrag" or comp.type == "TogglePill" or comp.type == "ToggleLever" then
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_TextColored(ctx, 0x888888FF, "Default Value")
                local def_val = comp.default_val or comp.val or 0.0
                local ok_def, new_def = pcall(reaper.ImGui_DragDouble, ctx, "##DefaultValue", def_val, 0.01, comp.min or 0.0, comp.max or 1.0, "%.2f")
                if ok_def and select(2, pcall(reaper.ImGui_IsItemEdited, ctx)) then
                    comp.default_val = new_def
                end
                if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
            end

            -- ==========================================
            -- MACRO MULTIPLEXING: ROUTING MATRIX
            -- ==========================================
            reaper.ImGui_Spacing(ctx); reaper.ImGui_Separator(ctx); reaper.ImGui_Spacing(ctx)
            reaper.ImGui_TextColored(ctx, 0x00E5FFFF, "ROUTING MATRIX")
            reaper.ImGui_Spacing(ctx)
            
            if not sel_comp.routes then sel_comp.routes = {} end
            
            -- Draw existing routes with depth sliders
            local route_to_delete = nil
            for ri, route in ipairs(sel_comp.routes) do
                reaper.ImGui_PushID(ctx, "route_" .. ri)
                local r_label = route.label or (route.type == "INTERNAL" and route.target or ("FX" .. (route.fx_idx or 0) .. ":P" .. (route.param_idx or 0)))
                local type_icon = route.type == "INTERNAL" and "[INT]" or "[EXT]"
                reaper.ImGui_TextColored(ctx, route.type == "INTERNAL" and 0x00E5FFFF or 0xFF6B35FF, type_icon)
                reaper.ImGui_SameLine(ctx, 0, 6)
                reaper.ImGui_Text(ctx, r_label)
                reaper.ImGui_SameLine(ctx, 0, 6)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x44111188)
                if reaper.ImGui_SmallButton(ctx, "X##del_route") then route_to_delete = ri end
                reaper.ImGui_PopStyleColor(ctx, 1)
                
                reaper.ImGui_PushItemWidth(ctx, -1)
                local d_chg, new_d = reaper.ImGui_SliderDouble(ctx, "Depth##" .. ri, route.depth or 1.0, -1.0, 1.0, "%.2f")
                if d_chg then route.depth = new_d end
                if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
                reaper.ImGui_PopItemWidth(ctx)
                reaper.ImGui_PopID(ctx)
                reaper.ImGui_Spacing(ctx)
            end
            if route_to_delete then UI.PushUndoState(); table.remove(sel_comp.routes, route_to_delete) end
            
            -- ADD ROUTING TARGET button
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFFFFFF11)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00E5FF44)
            if reaper.ImGui_Button(ctx, "+ Add Routing Target", -1, 30) then
                reaper.ImGui_OpenPopup(ctx, "RoutingMenu")
            end
            reaper.ImGui_PopStyleColor(ctx, 2)
            
            if reaper.ImGui_BeginPopup(ctx, "RoutingMenu") then
                -- Category 1: Internal Module Parameters
                local node_type = active_target and active_target.type or "COMPRESSOR"
                local algo_id = active_target and active_target.algo or 0
                local internal_dict = env.NodeUI and env.NodeUI.Router and env.NodeUI.Router.INTERNAL_PARAMS[node_type]
                
                if internal_dict and reaper.ImGui_BeginMenu(ctx, "Internal Parameters") then
                    for _, p in ipairs(internal_dict) do
                        -- Check if already connected
                        local already = false
                        for _, r in ipairs(sel_comp.routes) do
                            if r.type == "INTERNAL" and r.target == p.key then already = true; break end
                        end
                        if already then
                            reaper.ImGui_TextDisabled(ctx, p.label .. " (Connected)")
                        else
                            if reaper.ImGui_MenuItem(ctx, p.label) then
                                UI.PushUndoState()
                                table.insert(sel_comp.routes, { type = "INTERNAL", target = p.key, depth = 1.0, label = p.label })
                            end
                        end
                    end
                    reaper.ImGui_EndMenu(ctx)
                end
                
                -- Category 2: Track VST Parameters (Scraped from linked track)
                local lane_track = active_target and active_target.lane_guid and env.NodeUI and env.NodeUI.Router and env.NodeUI.Router.GetTrackByGUID(active_target.lane_guid)
                if not lane_track then lane_track = reaper.GetSelectedTrack(0, 0) end
                
                if lane_track and env.NodeUI and env.NodeUI.Router then
                    local scraped = env.NodeUI.Router.ScrapeTrackParams(lane_track)
                    if #scraped > 0 and reaper.ImGui_BeginMenu(ctx, "Track VST Parameters") then
                        for _, fx in ipairs(scraped) do
                            if reaper.ImGui_BeginMenu(ctx, fx.fx_name) then
                                for _, p in ipairs(fx.params) do
                                    local already = false
                                    for _, r in ipairs(sel_comp.routes) do
                                        if r.type == "EXTERNAL" and r.fx_idx == fx.fx_idx and r.param_idx == p.idx then already = true; break end
                                    end
                                    if already then
                                        reaper.ImGui_TextDisabled(ctx, p.name .. " (Connected)")
                                    else
                                        if reaper.ImGui_MenuItem(ctx, p.name) then
                                            UI.PushUndoState()
                                            table.insert(sel_comp.routes, { type = "EXTERNAL", fx_idx = fx.fx_idx, param_idx = p.idx, depth = 1.0, label = fx.fx_name .. ": " .. p.name })
                                        end
                                    end
                                end
                                reaper.ImGui_EndMenu(ctx)
                            end
                        end
                        reaper.ImGui_EndMenu(ctx)
                    end
                end
                
                reaper.ImGui_EndPopup(ctx)
            end
            
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_TextColored(ctx, 0x888888FF, "Color Token")
            if reaper.ImGui_BeginCombo(ctx, "##coltok_single", sel_comp.color_token or "Teal") then
                for _, k in ipairs({"Accent_A", "Accent_B", "Teal", "Tangerine", "Base", "Secondary", "TextBright"}) do
                    if reaper.ImGui_Selectable(ctx, k, sel_comp.color_token == k) then UI.PushUndoState(); sel_comp.color_token = k end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            
            if sel_comp.type == "InlineDrag" then
                reaper.ImGui_Spacing(ctx); reaper.ImGui_TextColored(ctx, 0x888888FF, "Text Alignment")
                local al = sel_comp.align or 1
                if reaper.ImGui_RadioButton(ctx, "L##al", al == 0) then sel_comp.align = 0 end
                reaper.ImGui_SameLine(ctx); if reaper.ImGui_RadioButton(ctx, "C##al", al == 1) then sel_comp.align = 1 end
                reaper.ImGui_SameLine(ctx); if reaper.ImGui_RadioButton(ctx, "R##al", al == 2) then sel_comp.align = 2 end
            end
            reaper.ImGui_PopItemWidth(ctx); reaper.ImGui_Spacing(ctx); reaper.ImGui_Spacing(ctx)
            
            local px2, py2 = reaper.ImGui_GetCursorScreenPos(ctx)
            local clk_sp, open_sp, t_sp = UI.DrawAnimatedDisclosure(ctx, dl_right, "sp_disc", "SPATIAL COORDINATES", UI.open_spatial, env.app_dt, 200)
            UI.open_spatial = open_sp; reaper.ImGui_SetCursorScreenPos(ctx, px2, py2 + 28)
            
            if t_sp > 0.01 then
                reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_sp)
                local is_visible = reaper.ImGui_BeginChild(ctx, "omm_spat_block_v2", 0, 100 * t_sp, 0, reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
                if is_visible then
                    reaper.ImGui_PushItemWidth(ctx, 80)
                    
                    local x_chg, new_x = reaper.ImGui_DragInt(ctx, "X##cx", math.floor(sel_comp.x or 0), 1, 0, 2000)
                    if x_chg then sel_comp.x = new_x end
                    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
                    
                    reaper.ImGui_SameLine(ctx, 0, 20)
                    local y_chg, new_y = reaper.ImGui_DragInt(ctx, "Y##cy", math.floor(sel_comp.y or 0), 1, 0, 2000)
                    if y_chg then sel_comp.y = new_y end
                    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
                    
                    if sel_comp.type == "AuraKnob" then
                        reaper.ImGui_Spacing(ctx); local r_chg, new_r = reaper.ImGui_DragInt(ctx, "Rad##crad", math.floor(sel_comp.radius or 16), 1, 5, 100)
                        if r_chg then sel_comp.radius = new_r end
                        if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
                    else
                        reaper.ImGui_Spacing(ctx); local w_chg, new_w = reaper.ImGui_DragInt(ctx, "W##cw", math.floor(sel_comp.w or 60), 1, 10, 500)
                        if w_chg then sel_comp.w = new_w end
                        if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
                        
                        reaper.ImGui_SameLine(ctx, 0, 20); local h_chg, new_h = reaper.ImGui_DragInt(ctx, "H##ch", math.floor(sel_comp.h or 20), 1, 10, 500)
                        if h_chg then sel_comp.h = new_h end
                        if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then UI.PushUndoState() end
                    end
                    
                    reaper.ImGui_PopItemWidth(ctx)
                end
                reaper.ImGui_EndChild(ctx)
                reaper.ImGui_PopStyleVar(ctx, 1)
            end
            reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_PopStyleColor(ctx, 1); reaper.ImGui_Spacing(ctx)
            
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x441111FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x661111FF)
            if reaper.ImGui_Button(ctx, "DELETE COMPONENT", -1, 36) then
                UI.PushUndoState()
                for i = #UI.wb_schema_buffer, 1, -1 do
                    if UI.wb_schema_buffer[i].id == sel_comp.id then table.remove(UI.wb_schema_buffer, i); break end
                end
                UI.selected_comp_ids = {}
            end
            reaper.ImGui_PopStyleColor(ctx, 2)
        else
            reaper.ImGui_TextDisabled(ctx, "Select a widget to bind parameters.")
        end

        -- This guarantees the stack closes perfectly every single frame
        reaper.ImGui_EndChild(ctx)

        -- 2. The Isolated Save Button (Locked to the bottom)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFF6B35FF) 
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x1C1C1EFF)
        
        if reaper.ImGui_Button(ctx, "SAVE AS CURRENT THEME", -1, 30) then
            local compile_data = { algo = active_target.algo, grid_cols = UI.wb_grid_cols, grid_rows = UI.wb_grid_rows, components = UI.wb_schema_buffer }
            UI.CompileFaceplate(compile_data, UI.theme_manager.current_theme)
            if env.NodeUI then env.NodeUI.HotReload(active_target.algo, UI) end
            reaper.ShowConsoleMsg("OMM Compiler: Overwritten Theme -> " .. UI.theme_manager.current_theme .. ".\n")
        end
        
        reaper.ImGui_PopStyleColor(ctx, 2)
        
        -- CRITICAL FIX: Close the main "props_pane" child window!
        reaper.ImGui_EndChild(ctx)

        -- 6. PANE 3 RESIZE HANDLE (Invisible Handle + Cursor change)
        -- PRO CODE FIX: Draw the handle exactly inside the 8px gap (between p2_w + 8 and p2_w + 16).
        -- If it starts at +16, it overlaps Pane 3's child window, which will eat the hit-test priority.
        reaper.ImGui_SetCursorScreenPos(ctx, top_wx + p1_w + p2_w + 8, top_wy + 26)
        UI.Safe_InvisibleButton(ctx, "resize_pane3", 8, avail_main_h)
        if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW()) end
        if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
            local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
            local current_w = UI.prop_pane_width or 280
            UI.prop_pane_width = math.max(280, math.min(360, current_w - dx))
        end

        -- 7. FOREGROUND BORDERS
        local fg_dl = reaper.ImGui_GetForegroundDrawList(ctx)
        -- Divider 1 (After Pane 1)
        reaper.ImGui_DrawList_AddLine(fg_dl, top_wx + p1_w + 4, top_wy + 26, top_wx + p1_w + 4, top_wy + avail_main_h, 0x333333FF, 1.0)
        -- Divider 2 (After Pane 2)
        reaper.ImGui_DrawList_AddLine(fg_dl, top_wx + p1_w + p2_w + 12, top_wy + 26, top_wx + p1_w + p2_w + 12, top_wy + avail_main_h, 0x333333FF, 1.0)

        -- Clean up from Style Uniformity
        UI.PopIDEStyle(ctx)

        -- CRITICAL FIX 2: Move the Toolbar Anchor INSIDE the visibility block 
        -- and use the Single Source of Truth (top_wx, top_wy) established at frame start.
        local ok_size, ww, wh = pcall(reaper.ImGui_GetWindowSize, ctx)
        if ok_size then
            local right_pane_w = p3_w
            local c_x = top_wx
            local c_y = top_wy + header_h
            local c_w = math.max(10, ww - right_pane_w)
            local c_h = math.max(10, wh - header_h)
            
            UI.DrawLayerToolbar(ctx, dl_main, c_x, c_y, c_w, c_h)
        end
    end

    reaper.ImGui_End(ctx) 
    pcall(reaper.ImGui_PopStyleVar, ctx, 2); pcall(reaper.ImGui_PopStyleColor, ctx, 2)
end

-- ==============================================================================
-- LEGACY WIDGET API (Raw Native Drawing, No Protected Wrappers)
-- ==============================================================================
function UI.DrawSharpGlowingText(draw_list, x, y, text, col, alpha_mult, opt_font, opt_size)
    local a = tonumber(alpha_mult) or 1.0; local bg = math.floor(0x66*a); local drop = math.floor(0xFF*a); local c_bg = (col & 0xFFFFFF00) | bg
    
    -- PRO FIX: Subpixel Immune Floor Anchor
    local fx = math.floor(x + 0.5)
    local fy = math.floor(y + 0.5)
    
    if opt_font and opt_size then
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx-1, fy, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx+1, fy, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx, fy-1, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx, fy+1, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx+1, fy+1, 0x00000000 | drop, tostring(text))
        reaper.ImGui_DrawList_AddTextEx(draw_list, opt_font, opt_size, fx, fy, (0xFFFFFF00) | drop, tostring(text))
    else
        reaper.ImGui_DrawList_AddText(draw_list, fx-1, fy, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddText(draw_list, fx+1, fy, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddText(draw_list, fx, fy-1, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddText(draw_list, fx, fy+1, c_bg, tostring(text))
        reaper.ImGui_DrawList_AddText(draw_list, fx+1, fy+1, 0x00000000 | drop, tostring(text))
        reaper.ImGui_DrawList_AddText(draw_list, fx, fy, (0xFFFFFF00) | drop, tostring(text))
    end
end

function UI.DrawFixedTextToggleNoBorder(ctx, id_str, text, active, x, y, fixed_w, h, draw_list, alpha_mult, dt)
    x = tonumber(x) or 0; y = tonumber(y) or 0; fixed_w = tonumber(fixed_w) or 20; h = tonumber(h) or 20
    reaper.ImGui_SetCursorScreenPos(ctx, x, y); UI.Safe_InvisibleButton(ctx, id_str, fixed_w, h)
    local clicked = reaper.ImGui_IsItemClicked(ctx); if clicked then active = not active end; local is_pressed = reaper.ImGui_IsItemActive(ctx)
    UI.toggle_anim_states[id_str] = UI.toggle_anim_states[id_str] or (active and 1.0 or 0.0)
    UI.toggle_anim_states[id_str] = UI.Lerp(UI.toggle_anim_states[id_str], active and 1.0 or 0.0, dt * 12.0)
    local anim_a = UI.toggle_anim_states[id_str]; local scale_mod = is_pressed and 2 or 0
    if is_pressed then reaper.ImGui_DrawList_AddRectFilled(draw_list, x + scale_mod, y + scale_mod, x+fixed_w - scale_mod, y+h - scale_mod, 0x050505FF | math.floor(0xFF * alpha_mult), 4.0) end
    local tw, th = reaper.ImGui_CalcTextSize(ctx, text)
    if anim_a > 0.01 then UI.DrawSharpGlowingText(draw_list, x + fixed_w/2 - tw/2, y + h/2 - th/2, text, 0x00E5FFFF, alpha_mult * anim_a) end
    if anim_a < 0.99 then UI.DrawStandardText(draw_list, x + fixed_w/2 - tw/2, y + h/2 - th/2, text, 0xAAAAAAFF, alpha_mult * (1.0 - anim_a)) end
    return clicked, active
end

function UI.DrawAttenuverterSlider(ctx, label, val, x, y, w, h, col_track, col_handle, draw_list, alpha_mult)
    local safe_w = math.max(10, tonumber(w) or 20); val = tonumber(val) or 0.5
    reaper.ImGui_SetCursorScreenPos(ctx, x, y); UI.Safe_InvisibleButton(ctx, label, safe_w, h); local changed = false
    if not UI.edit_mode and reaper.ImGui_IsItemActive(ctx) then local mx, my = reaper.ImGui_GetMousePos(ctx); val = math.max(0.0, math.min(1.0, (mx - x) / safe_w)); changed = true end
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y+h/2-2, x+safe_w, y+h/2+2, col_track & 0xFFFFFF00 | math.floor((col_track & 0xFF) * alpha_mult), 2.0)
    local cx, hx = x + (safe_w / 2), x + (val * safe_w)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, math.min(cx, hx), y+h/2-2, math.max(cx, hx), y+h/2+2, (col_handle & 0xFFFFFF00) | math.floor(0x55 * alpha_mult), 2.0)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, cx - 1, y+h/2-4, cx + 1, y+h/2+4, 0x88888800 | math.floor(0xFF * alpha_mult), 1.0)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, hx, y+h/2, h/2-2, (col_handle & 0xFFFFFF00) | math.floor(0xFF * alpha_mult))
    return changed, val
end

function UI.DrawAuraKnob(ctx, label, base_val, mod_sum, vis_pos_mod, vis_neg_mod, shift_held, is_bipolar, x, y, radius, main_col, is_target, flash_time, force_glow, draw_list, alpha_mult, ignore_internal_drag, app_time, is_depth_active, shockwave_time)
    base_val = tonumber(base_val) or 0.0; mod_sum = tonumber(mod_sum) or 0.0
    vis_pos_mod = tonumber(vis_pos_mod) or 0.0; vis_neg_mod = tonumber(vis_neg_mod) or 0.0
    x = tonumber(x) or 0; y = tonumber(y) or 0; radius = tonumber(radius) or 10
    main_col = math.floor(tonumber(main_col) or 0xFFFFFFFF)
    local a_mult = tonumber(alpha_mult) or 1.0
    
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, label.."_knob", radius*2, radius*2)
    local changed = false; local dy_out = 0; local is_active = reaper.ImGui_IsItemActive(ctx)
    if not UI.edit_mode and is_active then
        local dx, m_dy = reaper.ImGui_GetMouseDelta(ctx)
        dy_out = m_dy
        if not ignore_internal_drag and m_dy ~= 0 then
            local speed = shift_held and 0.0005 or 0.003 
            base_val = math.max(0.0, math.min(1.0, base_val - (m_dy * speed)))
            changed = true
        end
    end
    
    local cx, cy = x + radius, y + radius
    
    -- Volumetric Shadows
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy + 4, radius, 0x00000044 | math.floor(0xFF * a_mult))
    
    local arc_min = 0.75 * math.pi; local arc_max = 2.25 * math.pi; local a_base = arc_min + (base_val * 1.5 * math.pi)
    reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy, radius, arc_min, arc_max, 0)
    reaper.ImGui_DrawList_PathStroke(draw_list, 0x05050500 | math.floor(0xFF * a_mult), 0, 4.0)
    
    if force_glow or math.abs(vis_pos_mod) > 0.001 or math.abs(vis_neg_mod) > 0.001 then
        local t_max = math.max(0.0, math.min(1.0, base_val + vis_pos_mod))
        local t_min = math.max(0.0, math.min(1.0, base_val + vis_neg_mod))
        if is_bipolar then
            local swing = math.max(math.abs(vis_pos_mod), math.abs(vis_neg_mod))
            t_max = math.max(0.0, math.min(1.0, base_val + swing)); t_min = math.max(0.0, math.min(1.0, base_val - swing))
        end
        local a_lim_max = arc_min + (t_max * 1.5 * math.pi); local a_lim_min = arc_min + (t_min * 1.5 * math.pi)
        local draw_min, draw_max = math.min(a_lim_min, a_lim_max), math.max(a_lim_min, a_lim_max)
        if draw_max - draw_min > 0.01 then
            reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy, radius, draw_min, draw_max, 0)
            reaper.ImGui_DrawList_PathStroke(draw_list, (main_col & 0xFFFFFF00) | math.floor(255 * 0.35 * a_mult), 0, 4.0)
        end
    end
    
    if math.abs(mod_sum) > 0.001 then
        local cur_val = math.max(0.0, math.min(1.0, base_val + mod_sum))
        local cur_a = arc_min + (cur_val * 1.5 * math.pi)
        if is_target then
            local draw_min, draw_max = math.min(a_base, cur_a), math.max(a_base, cur_a)
            if draw_max - draw_min > 0.01 then
                reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy, radius, draw_min, draw_max, 0)
                reaper.ImGui_DrawList_PathStroke(draw_list, (main_col & 0xFFFFFF00) | math.floor(0xAA * a_mult), 0, 4.0)
            end
        else
            local draw_min, draw_max = math.min(a_base, cur_a), math.max(a_base, cur_a)
            if draw_max - draw_min > 0.01 then
                reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy, radius, draw_min, draw_max, 0)
                reaper.ImGui_DrawList_PathStroke(draw_list, (main_col & 0xFFFFFF00) | math.floor(0x88 * a_mult), 0, 4.0)
                reaper.ImGui_DrawList_PathArcTo(draw_list, cx, cy, radius, draw_min, draw_max, 0)
                reaper.ImGui_DrawList_PathStroke(draw_list, (main_col & 0xFFFFFF00) | math.floor(0xFF * a_mult), 0, 2.0)
            end
        end
    end
    
    local cap_bg = is_active and 0x08080800 or 0x1A1A1E00
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, radius-4, cap_bg | math.floor(0xFF * a_mult))
    reaper.ImGui_DrawList_PathArcTo(draw_list, cx - 0.5, cy - 0.5, radius - 4, math.pi * 1.0, math.pi * 1.5, 0)
    reaper.ImGui_DrawList_PathStroke(draw_list, 0xFFFFFF00 | math.floor(0x1F * a_mult), 0, 1.5)
    reaper.ImGui_DrawList_PathArcTo(draw_list, cx + 1, cy + 1, radius - 4, 0, math.pi * 0.5, 0)
    reaper.ImGui_DrawList_PathStroke(draw_list, 0x00000000 | math.floor(0xAA * a_mult), 0, 2.0)
    
    local ex, ey = cx + math.cos(a_base) * (radius-4), cy + math.sin(a_base) * (radius-4)
    reaper.ImGui_DrawList_AddLine(draw_list, cx, cy, ex, ey, 0x1C1C1EFF & 0xFFFFFF00 | math.floor(0xFF * a_mult), 2.0)
    return changed, base_val, dy_out, is_active
end

function UI.DrawEditableText(ctx, id_str, val, format_str, x, y, w, h, v_min, v_max, draw_list, alpha_mult)
    val = tonumber(val) or 0; x = tonumber(x) or 0; y = tonumber(y) or 0; w = tonumber(w) or 20; h = tonumber(h) or 20
    local display_text = string.format(format_str, val)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, display_text)
    local center_x = x + w/2 - tw/2
    
    if UI.active_edit_id == id_str then
        reaper.ImGui_SetCursorScreenPos(ctx, center_x - 5, y + h/2 - th/2 - 2)
        reaper.ImGui_PushItemWidth(ctx, math.max(40, tw + 10))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x000000FF)
        local changed, new_str = reaper.ImGui_InputText(ctx, "##"..id_str, UI.edit_buffer, reaper.ImGui_InputTextFlags_EnterReturnsTrue() | reaper.ImGui_InputTextFlags_AutoSelectAll())
        reaper.ImGui_PopStyleColor(ctx, 1); reaper.ImGui_PopItemWidth(ctx)
        
        if changed then 
            local num = tonumber(new_str)
            if num then val = math.max(v_min, math.min(v_max, num)) end
            UI.active_edit_id = nil
            return true, val 
        end
        if not reaper.ImGui_IsItemActive(ctx) and (reaper.ImGui_IsMouseClicked(ctx, 0) or reaper.ImGui_IsMouseClicked(ctx, 1)) then UI.active_edit_id = nil end
        UI.edit_buffer = new_str; return false, val
    else
        reaper.ImGui_SetCursorScreenPos(ctx, center_x, y + h/2 - th/2)
        UI.Safe_InvisibleButton(ctx, "btn_"..id_str, tw, th)
        if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then 
            UI.active_edit_id = id_str; UI.edit_buffer = string.format("%.1f", val) 
        end
        UI.DrawSharpGlowingText(draw_list, center_x, y + h/2 - th/2, display_text, 0x00E5FFFF, alpha_mult)
        return false, val
    end
end

function UI.DrawVerticalDragBox(ctx, id_string, display_label, val, v_min, v_max, shift_held, x, y, w, h, draw_list, alpha_mult)
    reaper.ImGui_SetCursorScreenPos(ctx, x, y); UI.Safe_InvisibleButton(ctx, id_string, w, h); local changed = false
    if reaper.ImGui_IsItemActive(ctx) then 
        local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
        if dy ~= 0 and not UI.edit_mode then val = math.max(v_min, math.min(v_max, val - (dy * (shift_held and ((v_max-v_min)/2000) or ((v_max-v_min)/200))))); changed = true end
        reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x+w, y+h, 0x050505FF | math.floor(0xFF * alpha_mult), 4.0) 
    end
    local txt = display_label .. " " .. math.floor(val)
    local tw, th = reaper.ImGui_CalcTextSize(ctx, txt)
    if reaper.ImGui_IsItemHovered(ctx) then 
        UI.DrawSharpGlowingText(draw_list, x + w/2 - tw/2, y + h/2 - th/2, txt, 0x00E5FFFF, alpha_mult)
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS()) 
    else 
        UI.DrawStandardText(draw_list, x + w/2 - tw/2, y + h/2 - th/2, txt, 0xAAAAAAFF, alpha_mult) 
    end
    return changed, val
end

-- ==========================================================
-- PRO CODE: STRICT GARBAGE COLLECTION PROTOCOL
-- ==========================================================
function UI.DestroyNode(env, node_id)
    if not env.nodes then return end
    
    -- 1. Identify the Target
    local target_node, n_idx
    for i, n in ipairs(env.nodes) do
        if n.id == node_id then target_node = n; n_idx = i; break end
    end
    if not target_node then return end
    
    -- 2. Purge the Reaper JSFX (The Backend)
    if target_node.lane_guid and env.Router then
        local track = env.Router.GetTrackByGUID(target_node.lane_guid)
        if track then
            -- Iterate backward to prevent index shifting during deletion
            for i = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
                local _, fn = reaper.TrackFX_GetFXName(track, i)
                if fn:match("OMM") then
                    local ok, param_val = pcall(reaper.TrackFX_GetParam, track, i, 0)
                    if ok then
                        local p_val = math.floor(param_val + 0.5)
                        -- Match against either the ID or the assigned gmem slot
                        if p_val == target_node.id or p_val == target_node.gmem_slot then
                            reaper.TrackFX_Delete(track, i)
                        end
                    end
                end
            end
        end
    end
    
    -- 3. Purge the Connections (The Cables)
    if env.connections then
        for i = #env.connections, 1, -1 do
            local c = env.connections[i]
            if c.source_id == node_id or c.target_id == node_id then
                table.remove(env.connections, i)
            end
        end
    end
    
    -- 4. Purge the UI State
    table.remove(env.nodes, n_idx)
    return true
end

-- Trash Hub State Machine
UI.trash_state = { is_open = false, anim_z = 0.0, confirm_clear = false, scroll_offset = 0.0, del_anim = {} }

-- PRO CODE: Sub-Island Geometry & Dual-Clip Scrolling
function UI.DrawTrashHub(ctx, env, avail_w, center_y, is_matrix_tab)
    -- 1. TAB LOCK: Instantly abort if we are not in the Matrix tab
    if not is_matrix_tab then return end

    local fg_dl = reaper.ImGui_GetForegroundDrawList(ctx)

    -- 2. SUB-ISLAND GEOMETRY (The sleek, small pill)
    local btn_size = 20
    local padding = 6
    local island_w = btn_size + (padding * 2)
    local island_h = btn_size + (padding * 2) -- 32px total height

    -- Anchor 16px from right edge, mathematically centered to the Main Island
    local island_x = (env.p_min_x or 0) + avail_w - island_w - 16
    local island_y = center_y - (island_h / 2)

    -- Physics
    local target_z = UI.trash_state.is_open and 1.0 or 0.0
    UI.trash_state.anim_z = UI.trash_state.anim_z + (target_z - UI.trash_state.anim_z) * (env.app_dt * 15.0)
    local anim_z = UI.trash_state.anim_z

    -- Draw Sub-Island Base
    local base_col = UI.trash_state.is_open and 0x2A2A33FF or 0x1C1C1EFF
    reaper.ImGui_DrawList_AddRectFilled(fg_dl, island_x, island_y, island_x + island_w, island_y + island_h, base_col, island_h / 2)
    reaper.ImGui_DrawList_AddRect(fg_dl, island_x, island_y, island_x + island_w, island_y + island_h, 0x333333FF, island_h / 2, 0, 1.0)

    -- Sleek Trash/List Icon
    local bx, by = island_x + padding, island_y + padding
    reaper.ImGui_DrawList_AddLine(fg_dl, bx + 3, by + 5, bx + 17, by + 5, 0xAAAAAAFF, 2.0)
    reaper.ImGui_DrawList_AddLine(fg_dl, bx + 5, by + 10, bx + 15, by + 10, 0xAAAAAAFF, 2.0)
    reaper.ImGui_DrawList_AddLine(fg_dl, bx + 7, by + 15, bx + 13, by + 15, 0xAAAAAAFF, 2.0)

    -- Button Interaction
    reaper.ImGui_SetCursorScreenPos(ctx, island_x, island_y)
    UI.Safe_InvisibleButton(ctx, "trash_island_btn", island_w, island_h)
    if reaper.ImGui_IsItemClicked(ctx) then
        UI.trash_state.is_open = not UI.trash_state.is_open
        UI.trash_state.confirm_clear = false
    end

    -- 3. THE DROPDOWN PANEL
    if anim_z > 0.01 then
        local panel_w = 240
        local item_h = 24 -- DENSE SPACING
        local node_count = env.nodes and #env.nodes or 0
        
        -- Layout Constraints
        local header_h = 8
        local footer_h = 32
        local list_max_h = 168 -- Allows exactly 7 dense modules before scrolling
        
        local total_list_h = node_count * item_h
        local view_list_h = math.min(total_list_h, list_max_h)
        if node_count == 0 then view_list_h = item_h end -- Force space for "No Modules" text
        
        local max_panel_h = header_h + view_list_h + footer_h
        local cur_panel_h = max_panel_h * anim_z

        local px = island_x + island_w - panel_w
        local py = island_y + island_h + 8

        -- CREATE A FOREGROUND CHILD TO STEAL MOUSE FROM MATRIX
        reaper.ImGui_SetCursorScreenPos(ctx, px, py)
        local child_flags = reaper.ImGui_WindowFlags_NoBackground() | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoDecoration()
        local ok_c, vis_c = pcall(reaper.ImGui_BeginChild, ctx, "trash_dropdown_layer", panel_w, cur_panel_h, 0, child_flags)
        
        if vis_c then
            -- OUTER CLIP RECT: Solves the "Leak" during Unroll Animation
            reaper.ImGui_PushClipRect(ctx, px, py, px + panel_w, py + cur_panel_h, true)
    
            -- Panel Background
            reaper.ImGui_DrawList_AddRectFilled(fg_dl, px, py, px + panel_w, py + cur_panel_h, 0x0F0F12F5, 8.0)
            reaper.ImGui_DrawList_AddRect(fg_dl, px, py, px + panel_w, py + cur_panel_h, 0x333333FF, 8.0, 0, 1.0)
    
            -- MOUSE TRACKING
            local ok, mx, my = pcall(reaper.ImGui_GetMousePos, ctx)
            local mouse_in_panel = ok and (mx >= px and mx <= px + panel_w and my >= py and my <= py + cur_panel_h)
    
            -- SCROLL LOGIC
            if mouse_in_panel and total_list_h > view_list_h then
                local mw = select(2, pcall(reaper.ImGui_GetMouseWheel, ctx))
                if mw and mw ~= 0 then
                    UI.trash_state.scroll_offset = UI.trash_state.scroll_offset - (mw * item_h * 1.5)
                end
            end
            
            -- Clamp Scroll to precise bounds
            local max_scroll = math.max(0, total_list_h - view_list_h)
            UI.trash_state.scroll_offset = math.max(0, math.min(max_scroll, UI.trash_state.scroll_offset))
    
            local draw_y = py + header_h
    
            if node_count == 0 then
                reaper.ImGui_DrawList_AddText(fg_dl, px + (panel_w/2) - 35, draw_y + 4, 0x555555FF, "No Modules")
                draw_y = draw_y + view_list_h
            else
                -- INNER CLIP RECT: Restricts the scrolling list from bleeding into Header/Footer
                reaper.ImGui_PushClipRect(ctx, px, draw_y, px + panel_w, draw_y + view_list_h, true)
                
                for i = node_count, 1, -1 do
                    local n = env.nodes[i]
                    -- Apply scroll offset to mathematical position
                    local row_y = draw_y + ((node_count - i) * item_h) - UI.trash_state.scroll_offset
                    
                    -- Only Draw/Interact if physically visible in the viewport
                    if row_y + item_h > draw_y and row_y < draw_y + view_list_h then
                        local is_hovered = mouse_in_panel and my >= row_y and my <= row_y + item_h
                        if is_hovered then
                            reaper.ImGui_DrawList_AddRectFilled(fg_dl, px + 4, row_y, px + panel_w - 4, row_y + item_h, 0xFFFFFF11, 4.0)
                        end
                        
                        local name = (n.type or "MODULE") .. " " .. (n.id or "")
                        reaper.ImGui_DrawList_AddText(fg_dl, px + 12, row_y + 5, 0xE5E5EAFF, name)
                        
                        local del_w = 20
                        local del_x = px + panel_w - del_w - 8
                        local del_hover = is_hovered and mx >= del_x and mx <= del_x + del_w
                        local x_col = del_hover and 0xFF4040FF or 0x666666FF
                        
                        reaper.ImGui_DrawList_AddText(fg_dl, del_x + 6, row_y + 5, x_col, "X")
                        
                        reaper.ImGui_SetCursorScreenPos(ctx, del_x, row_y + 2)
                        UI.Safe_InvisibleButton(ctx, "del_btn_"..n.id, del_w, item_h - 4)
                        if reaper.ImGui_IsItemClicked(ctx) then
                            UI.DestroyNode(env, n.id)
                            env.needs_save = true
                        end
                    end
                end
                
                reaper.ImGui_PopClipRect(ctx) -- Close Inner Clip
                draw_y = draw_y + view_list_h
            end
    
            -- Footer Divider
            reaper.ImGui_DrawList_AddLine(fg_dl, px + 8, draw_y + 4, px + panel_w - 8, draw_y + 4, 0x222222FF, 1.0)
            
            -- ========================================================
            -- FOOTER LAYOUT (You can adjust these numbers)
            -- ========================================================
            local footer_y = draw_y + 8 -- Master Y anchor for the buttons
            local btn_h = 20            -- Height of the YES/NO buttons
            local btn_w = 55            -- Width of the YES/NO buttons
            local text_y_offset = 1.5    -- Pushes text down inside the buttons
            -- ========================================================
            
            -- CLEAR ALL LOGIC
            if not UI.trash_state.confirm_clear then
                reaper.ImGui_DrawList_AddText(fg_dl, px + (panel_w/2) - 42, footer_y + text_y_offset, 0xFF4040FF, "CLEAR CANVAS")
                reaper.ImGui_SetCursorScreenPos(ctx, px, footer_y)
                UI.Safe_InvisibleButton(ctx, "clear_all_btn", panel_w, 24)
                if reaper.ImGui_IsItemClicked(ctx) and node_count > 0 then
                    UI.trash_state.confirm_clear = true
                end
            else
                -- NO Button (Left)
                local no_x = px + 12 -- Adjust this to move NO button left/right
                reaper.ImGui_DrawList_AddRectFilled(fg_dl, no_x, footer_y, no_x + btn_w, footer_y + btn_h, 0x333333FF, 4.0)
                reaper.ImGui_DrawList_AddText(fg_dl, no_x + 19, footer_y + text_y_offset, 0xEEEEEEFF, "NO")
                reaper.ImGui_SetCursorScreenPos(ctx, no_x, footer_y)
                UI.Safe_InvisibleButton(ctx, "confirm_no", btn_w, btn_h)
                if reaper.ImGui_IsItemClicked(ctx) then
                    UI.trash_state.confirm_clear = false
                end
                
                -- Centered "Are you sure?" text
                reaper.ImGui_DrawList_AddText(fg_dl, px + (panel_w/2) - 37, footer_y + text_y_offset, 0xAAAAAAFF, "Are you sure?")
                
                -- YES Button (Right)
                local yes_x = px + panel_w - btn_w - 12 -- Adjust the '- 12' to move YES button left/right
                reaper.ImGui_DrawList_AddRectFilled(fg_dl, yes_x, footer_y, yes_x + btn_w, footer_y + btn_h, 0x550000FF, 4.0)
                reaper.ImGui_DrawList_AddText(fg_dl, yes_x + 17, footer_y + text_y_offset, 0xFF4040FF, "YES")
                reaper.ImGui_SetCursorScreenPos(ctx, yes_x, footer_y)
                UI.Safe_InvisibleButton(ctx, "confirm_yes", btn_w, btn_h)
                if reaper.ImGui_IsItemClicked(ctx) then
                    for i = node_count, 1, -1 do UI.DestroyNode(env, env.nodes[i].id) end
                    env.needs_save = true
                    UI.trash_state.is_open = false
                    UI.trash_state.confirm_clear = false
                end
            end
    
            -- OUTER CLIP RECT POP
            reaper.ImGui_PopClipRect(ctx)
            reaper.ImGui_EndChild(ctx)
        end

        -- Auto-close if clicked outside both the island and the panel
        if select(2, pcall(reaper.ImGui_IsMouseClicked, ctx, 0)) then
            if ok and not mouse_in_panel and not (mx >= island_x and mx <= island_x + island_w and my >= island_y and my <= island_y + island_h) then
                UI.trash_state.is_open = false
                UI.trash_state.confirm_clear = false
            end
        end
    end
end

return UI
