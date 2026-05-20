-- ==============================================================================
-- OMM_UI.lua (The Complete Luxury Graphics Engine + Standalone CAD Factory)
-- Protocol Zero: Seatbelt Drag Logic, Safe Stack Pops & Premium Toolbox
-- ==============================================================================
local UI = { 
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
    camera = { pan_x = 0, pan_y = 0, zoom = 1.0 }, active_tool = "SELECT",
    palette_open = false, palette_height = 250, drag_col_idx = nil,
    notifications = {}, notif_counter = 0, palette_search = "",
    active_palette = { 
        { id=1, hex = 0x00E5FFFF, token = "Primary" }, 
        { id=2, hex = 0xFF6B35FF, token = "Accent" },
        { id=3, hex = 0xF5F5F7FF, token = "Text" },
        { id=4, hex = 0x8E8E93FF, token = "Neutral" },
        { id=5, hex = 0x1C1C1EFF, token = "Base" }
    }
}

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

function UI.DrawStandardText(draw_list, x, y, text, col, alpha_mult)
    local a = tonumber(alpha_mult) or 1.0
    reaper.ImGui_DrawList_AddText(draw_list, x+1, y+1, 0x00000000 | math.floor(0xFF*a), tostring(text))
    reaper.ImGui_DrawList_AddText(draw_list, x, y, (col & 0xFFFFFF00) | math.floor((col & 0xFF)*a), tostring(text))
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

-- ==============================================================================
-- PREMIUM COMPONENT RENDERERS
-- ==============================================================================
function UI.DrawComponent_AuraKnob(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state)
    local x, y, rad = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y, comp.radius or 16
    local active_col = UI.LerpColor(env.palette and env.palette[comp.color_token] or 0x00A5FFFF, 0xFFFFFFFF, p_state.flash)
    local cx, cy = x + rad, y + rad
    local a_min, a_max = math.pi * 0.75, math.pi * 2.25
    local a_val = a_min + (a_max - a_min) * p_state.disp_val
    
    -- Extract Macro Depth (Targets Route #1 if available)
    local has_depth = comp.routes and comp.routes[1]
    local depth_val = has_depth and comp.routes[1].depth or 0.0
    local is_bipolar = comp.is_bipolar or false

    -- Dual-Zone Interaction Engine
    reaper.ImGui_SetCursorScreenPos(ctx, x, y)
    UI.Safe_InvisibleButton(ctx, comp.id.."_knob", rad*2, rad*2)
    local changed, new_norm = false, val_norm
    local hov = reaper.ImGui_IsItemHovered(ctx)
    local is_active = reaper.ImGui_IsItemActive(ctx)
    
    -- Double Click Bipolar Toggle
    if hov and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        comp.is_bipolar = not comp.is_bipolar
        changed = true; p_state.flash = 1.0
    end

    if is_active and not is_disabled then
        local _, dx, dy = reaper.ImGui_GetMouseDelta(ctx)
        if dy and dy ~= 0 then
            local mx, my = reaper.ImGui_GetMousePos(ctx)
            local dist = math.sqrt((mx - cx)^2 + (my - cy)^2)
            local ok_mods, mods = pcall(reaper.ImGui_GetKeyMods, ctx)
            local shift = ok_mods and (mods & (reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 1)) ~= 0
            local speed = shift and 0.0005 or 0.003
            
            -- If grabbed outside the inner radius, adjust Depth instead of Value!
            if dist > (rad * 0.6) and has_depth then
                comp.routes[1].depth = math.max(-1.0, math.min(1.0, depth_val - (dy * speed * 2.0)))
                changed = true; p_state.flash = 1.0
            else
                new_norm = math.max(0.0, math.min(1.0, val_norm - (dy * speed)))
                changed = true
            end
        end
    end

    -- Volumetric Shadow
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy + 4, rad, 0x00000044 | math.floor(0xFF * env.act_a))
    
    -- Base Track
    reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, rad, a_min, a_max, 0); reaper.ImGui_DrawList_PathStroke(dl, 0x05050500 | math.floor(0xFF * env.act_a), 0, 4.0)
    
    -- Depth Ring Visualization (The Pro Feature)
    if has_depth and math.abs(depth_val) > 0.01 then
        local t_max, t_min = p_state.disp_val + depth_val, p_state.disp_val
        if is_bipolar then
            t_max = p_state.disp_val + math.abs(depth_val)
            t_min = p_state.disp_val - math.abs(depth_val)
        elseif depth_val < 0 then
            t_max, t_min = p_state.disp_val, p_state.disp_val + depth_val
        end
        t_max, t_min = math.max(0.0, math.min(1.0, t_max)), math.max(0.0, math.min(1.0, t_min))
        
        local a_lim_max = a_min + (t_max * 1.5 * math.pi)
        local a_lim_min = a_min + (t_min * 1.5 * math.pi)
        if math.abs(a_lim_max - a_lim_min) > 0.01 then
            reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, rad, math.min(a_lim_min, a_lim_max), math.max(a_lim_min, a_lim_max), 0)
            reaper.ImGui_DrawList_PathStroke(dl, (active_col & 0xFFFFFF00) | math.floor(255 * 0.35 * env.act_a), 0, 4.0)
        end
    end
    
    -- Value Core Arc
    local draw_st, draw_en = a_min, a_val
    if draw_en - draw_st > 0.01 then
        reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, rad, draw_st, draw_en, 0)
        reaper.ImGui_DrawList_PathStroke(dl, active_col & 0xFFFFFF00 | math.floor(0xAA * env.act_a), 0, 3.0)
    end
    
    -- Inner Cap
    local cap_bg = is_active and 0x08080800 or 0x1A1A1E00
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, rad-4, cap_bg | math.floor(0xFF * env.act_a))
    
    -- Needle
    local lx, ly = cx + math.cos(a_val) * (rad - 1), cy + math.sin(a_val) * (rad - 1)
    reaper.ImGui_DrawList_AddLine(dl, cx, cy, lx, ly, 0x1C1C1EFF & 0xFFFFFF00 | math.floor(0xFF * env.act_a), 2.0)
    
    -- Labels
    local tw, th = reaper.ImGui_CalcTextSize(ctx, comp.label); reaper.ImGui_DrawList_AddText(dl, cx - tw/2, cy - rad - 20, 0x8E8E93FF & 0xFFFFFF00 | math.floor(0xFF * env.act_a), comp.label)
    local vw, vh = reaper.ImGui_CalcTextSize(ctx, disp_str); reaper.ImGui_DrawList_AddText(dl, cx - vw/2, cy + rad + 6, active_col & 0xFFFFFF00 | math.floor(0xFF * env.act_a), disp_str)
    
    return changed, new_norm
end

function UI.DrawComponent_InlineDrag(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h, align = comp.w or 60, comp.h or 20, comp.align or 1 
    local full_str = (type(comp.label) == "function" and comp.label(state) or comp.label) .. " " .. disp_str
    local tw, th = reaper.ImGui_CalcTextSize(ctx, full_str)
    local tx = (align == 0) and x + 4 or ((align == 1) and x + (w/2) - (tw/2) or x + w - tw - 4)
    reaper.ImGui_DrawList_AddText(dl, tx, y + (h/2) - (th/2), UI.LerpColor(0x005F73FF, 0xFFFFFFFF, p_state.flash) & 0xFFFFFF00 | math.floor(0xFF * env.act_a), full_str)
    return false, val_norm
end

function UI.DrawComponent_PeakMeter(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 20, comp.h or 100
    local active_a = math.floor(0xFF * env.act_a)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x050508FF, 12.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x1A1A1FFF & 0xFFFFFF00 | active_a, 12.0, 0, 1.5)
    local fill_h = h * p_state.disp_val
    if fill_h > 2 then
        local c_fill = UI.LerpColor(0x00E5FFFF, 0xFF3333FF, p_state.disp_val)
        reaper.ImGui_DrawList_AddRectFilled(dl, x+2, y + h - fill_h + 2, x+w-2, y+h-2, c_fill & 0xFFFFFF00 | active_a, 6.0)
        if p_state.disp_val > 0.8 then reaper.ImGui_DrawList_AddCircleFilled(dl, x+w/2, y + h - fill_h, w, c_fill & 0xFFFFFF00 | math.floor(0x44 * env.act_a)) end
    end
    return false, val_norm
end

function UI.DrawComponent_VuMeter(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 100, comp.h or 80
    local active_a = math.floor(0xFF * env.act_a)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x161619FF, 6.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x2A2A33FF, 6.0, 0, 1.0)
    
    local pivot_x, pivot_y = x + w/2, y + h * 1.15
    local radius = h * 0.9
    local a_min, a_max = math.pi * 1.25, math.pi * 1.75
    
    reaper.ImGui_DrawList_PathArcTo(dl, pivot_x, pivot_y, radius, a_min, a_max, 0)
    reaper.ImGui_DrawList_PathStroke(dl, 0x8E8E93FF & 0xFFFFFF00 | active_a, 0, 2.0)
    
    for i = 0, 5 do
        local t_a = a_min + (a_max - a_min) * (i / 5.0)
        local tx1, ty1 = pivot_x + math.cos(t_a) * radius, pivot_y + math.sin(t_a) * radius
        local tx2, ty2 = pivot_x + math.cos(t_a) * (radius - 8), pivot_y + math.sin(t_a) * (radius - 8)
        reaper.ImGui_DrawList_AddLine(dl, tx1, ty1, tx2, ty2, 0x8E8E93FF & 0xFFFFFF00 | active_a, 1.5)
    end
    
    local a_val = a_min + (a_max - a_min) * p_state.disp_val
    local n_x, n_y = pivot_x + math.cos(a_val) * (radius + 4), pivot_y + math.sin(a_val) * (radius + 4)
    reaper.ImGui_DrawList_AddLine(dl, pivot_x, pivot_y, n_x, n_y, 0xFF3333FF & 0xFFFFFF00 | active_a, 2.0)
    
    if p_state.disp_val > 0.8 then reaper.ImGui_DrawList_AddCircleFilled(dl, n_x, n_y, 12, 0xFF333300 | math.floor(0x44 * env.act_a)) end
    return false, val_norm
end

function UI.DrawComponent_TogglePill(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 50, comp.h or 24
    local r = math.min(w,h)/2
    local is_active = val_norm > 0.5
    reaper.ImGui_SetCursorScreenPos(ctx, x, y); UI.Safe_InvisibleButton(ctx, comp.id, w, h)
    local changed, new_norm = false, val_norm
    if reaper.ImGui_IsItemClicked(ctx) then new_norm = is_active and 0.0 or 1.0; changed = true end
    p_state.ghost_norm = new_norm
    local c_bg = is_active and 0x00E5FFFF or 0x2A2A33FF
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, c_bg & 0xFFFFFF00 | math.floor(0xFF * env.act_a), r)
    
    local t_size = r * 1.5
    local t_x, t_y = x + 3, y + h/2 - t_size/2
    if w > h then t_x = x + 3 + (w - t_size - 6) * p_state.disp_val
    else t_x = x + w/2 - t_size/2; t_y = y + 3 + (h - t_size - 6) * (1.0 - p_state.disp_val) end
    
    reaper.ImGui_DrawList_AddCircleFilled(dl, t_x + t_size/2, t_y + t_size/2, t_size/2, 0xFFFFFFFF & 0xFFFFFF00 | math.floor(0xFF * env.act_a))
    return changed, new_norm
end

function UI.DrawComponent_ToggleLever(ctx, dl, comp, env, state, is_disabled, val_norm, disp_str, p_state)
    local x, y = env.p_min_x + env.scroll_x + comp.x, env.p_min_y + env.scroll_y + comp.y
    local w, h = comp.w or 24, comp.h or 50
    local is_active = val_norm > 0.5
    reaper.ImGui_SetCursorScreenPos(ctx, x, y); UI.Safe_InvisibleButton(ctx, comp.id, w, h)
    local changed, new_norm = false, val_norm
    if reaper.ImGui_IsItemClicked(ctx) then new_norm = is_active and 0.0 or 1.0; changed = true end
    p_state.ghost_norm = new_norm
    local a = math.floor(0xFF * env.act_a)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x+w, y+h, 0x1A1A1CFF & 0xFFFFFF00 | a, 4.0)
    reaper.ImGui_DrawList_AddRect(dl, x, y, x+w, y+h, 0x08080AFF & 0xFFFFFF00 | a, 4.0, 0, 2.0)
    local l_y = y + 4 + (h - 24 - 8) * (1.0 - p_state.disp_val)
    reaper.ImGui_DrawList_AddRectFilled(dl, x+4, l_y+4, x+w-4, l_y+24+4, 0x00000088 & 0xFFFFFF00 | a, 2.0)
    reaper.ImGui_DrawList_AddRectFilled(dl, x+2, l_y, x+w-2, l_y+24, 0xDDDDDDFF & 0xFFFFFF00 | a, 2.0)
    reaper.ImGui_DrawList_AddLine(dl, x+4, l_y+12, x+w-4, l_y+12, 0x888888FF & 0xFFFFFF00 | a, 2.0)
    return changed, new_norm
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
    if env and env.NodeUI and env.NodeUI.SCHEMAS[algo_id] then
        -- Deep Copy to prevent altering the global fallback registry
        UI.wb_schema_buffer = UI.DeepCopy(env.NodeUI.SCHEMAS[algo_id])
    else
        UI.wb_schema_buffer = {}
    end
    
    return false
end

-- ==========================================
-- THE STANDALONE CAD FACTORY
-- ==========================================
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
        
        UI.Safe_InvisibleButton(ctx, "top_drag_bar", math.max(1.0, drag_w), 16)
        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl_main, top_wx, top_wy, top_wx + drag_w, top_wy + 16, 0xFFFFFF0A, 4.0) 
        end
        if select(2, pcall(reaper.ImGui_IsItemActive, ctx)) and select(2, pcall(reaper.ImGui_IsMouseDragging, ctx, 0)) then
            local ok, dx, dy = pcall(reaper.ImGui_GetMouseDelta, ctx)
            if ok and tonumber(dx) and tonumber(dy) and (dx ~= 0 or dy ~= 0) then
                local wok, wx, wy = pcall(reaper.ImGui_GetWindowPos, ctx)
                if wok and tonumber(wx) and tonumber(wy) then
                    UI.drag_mem.next_win_x = wx + dx
                    UI.drag_mem.next_win_y = wy + dy
                end
            end
        end
        -- ==========================================================
        -- THE FLOATING DESIGN/PLAY TOGGLE (Top Center)
        -- ==========================================================
        local win_w = reaper.ImGui_GetWindowWidth(ctx)
        -- Lowered by 15px (to Y=25) to clear ImGui's invisible window-drag bar
        pcall(reaper.ImGui_SetCursorPos, ctx, (win_w - 160) / 2, 25) 
        
        local active_col = UI.edit_mode and 0xFF6B35FF or 0x00E5FFFF
        pcall(reaper.ImGui_PushStyleVar, ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
        
        -- DESIGN MODE (■)
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), UI.edit_mode and active_col or 0x2A2A2CFF)
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Text(), UI.edit_mode and 0x1C1C1EFF or 0x888888FF)
        if select(2, pcall(reaper.ImGui_Button, ctx, "■ DESIGN", 80, 24)) then UI.edit_mode = true end
        pcall(reaper.ImGui_PopStyleColor, ctx, 2)
        
        pcall(reaper.ImGui_SameLine, ctx)
        
        -- PLAY MODE (▶)
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), not UI.edit_mode and active_col or 0x2A2A2CFF)
        pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Text(), not UI.edit_mode and 0x1C1C1EFF or 0x888888FF)
        if select(2, pcall(reaper.ImGui_Button, ctx, "▶ PLAY", 80, 24)) then UI.edit_mode = false end
        pcall(reaper.ImGui_PopStyleColor, ctx, 2)
        
        pcall(reaper.ImGui_PopStyleVar, ctx, 1)
        -- ==========================================================
        reaper.ImGui_Spacing(ctx)

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
                { label = "Utility: Beta Sandbox", id = 999, type = "BETA_LAB" }
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

        -- ==========================================
        -- PANE 1: BLUEPRINTS & TOOLBOX (GOLDEN RATIO 240px)
        -- ==========================================
        reaper.ImGui_BeginChild(ctx, "left_pane", 240, 0, 0, 0)
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
            reaper.ImGui_BeginChild(ctx, "bp_list", 240, 140 * t_bp, 0, reaper.ImGui_WindowFlags_NoScrollbar())
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
            reaper.ImGui_BeginChild(ctx, "tk_list", 240, 140 * t_tk, 0, reaper.ImGui_WindowFlags_NoScrollbar())
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
            reaper.ImGui_BeginChild(ctx, "tm_list", 240, 210 * t_tm, 0, reaper.ImGui_WindowFlags_NoScrollbar())
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
            reaper.ImGui_BeginChild(ctx, "sw_list", 240, 280 * t_sw, 0, reaper.ImGui_WindowFlags_NoScrollbar())
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
            reaper.ImGui_BeginChild(ctx, "dp_list", 240, 70 * t_dp, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_dp)
            
            local bxv, byv = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_InvisibleButton(ctx, "drag_VFDScreen", 220, 60)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bxv, byv, bxv+220, byv+60, 0x2A2A2AFF, 12.0)
            reaper.ImGui_DrawList_AddRectFilled(dl_left, bxv+10, byv+12, bxv+48, byv+48, 0x0A0A0AFF, 4.0)
            reaper.ImGui_DrawList_AddRect(dl_left, bxv+10, byv+12, bxv+48, byv+48, 0x1A1A1FFF, 4.0, 0, 1.0)
            UI.DrawStandardText(dl_left, bxv + 16, byv + 22, "8.8", 0x00E5FFFF, 1.0)
            UI.DrawStandardText(dl_left, bxv + 60, byv + 16, "VFD Screen", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bxv + 60, byv + 33, "Vacuum fluorescent", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "VFDScreen"); reaper.ImGui_Text(ctx, "VFDScreen"); reaper.ImGui_EndDragDropSource(ctx) end
            
            reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_EndChild(ctx)
        end

        -- CATEGORY: PANELS & DECOR
        local clk_pn, open_pn, t_pn = UI.DrawAnimatedDisclosure(ctx, dl_left, "cat_panels", "PANELS", UI.open_cat_panels, env.app_dt, 240)
        UI.open_cat_panels = open_pn
        if t_pn > 0.01 and (UI.search_filter == "" or string.find("backpanel screwdecal", UI.search_filter, 1, true)) then
            reaper.ImGui_BeginChild(ctx, "pn_list", 240, 140 * t_pn, 0, reaper.ImGui_WindowFlags_NoScrollbar())
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_pn)
            
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
            reaper.ImGui_DrawList_AddLine(dl_left, bxs+22, bys+30, bxs+28, bys+30, 0x555555FF, 1.5)
            reaper.ImGui_DrawList_AddLine(dl_left, bxs+25, bys+27, bxs+25, bys+33, 0x555555FF, 1.5)
            UI.DrawStandardText(dl_left, bxs + 60, bys + 16, "ScrewDecal", 0xFFFFFFFF, 1.0)
            UI.DrawStandardText(dl_left, bxs + 60, bys + 33, "Decorative hardware", 0x888888FF, 1.0)
            if reaper.ImGui_BeginDragDropSource(ctx) then reaper.ImGui_SetDragDropPayload(ctx, 'NEW_COMP', "ScrewDecal"); reaper.ImGui_Text(ctx, "ScrewDecal"); reaper.ImGui_EndDragDropSource(ctx) end
            
            reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_EndChild(ctx)
        reaper.ImGui_SameLine(ctx, 0, 16)

        -- ==========================================
        -- PANE 2: THE INFINITE CENTERED CANVAS
        -- ==========================================
        local ok_aw, raw_aw, raw_ah = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
        local canvas_w = math.max(10.0, (tonumber(raw_aw) or 0) - 280 - 16)
        local total_h = tonumber(raw_ah) or 0
        local canvas_h = total_h

        reaper.ImGui_BeginGroup(ctx) -- PROTECTS PANE 3 FROM ALIGNMENT BUGS

        if UI.palette_open then
            UI.palette_height = math.max(150, math.min(total_h - 100, UI.palette_height))
            reaper.ImGui_BeginChild(ctx, "pal_pane", canvas_w, UI.palette_height, 0, reaper.ImGui_WindowFlags_NoScrollbar())
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
                
                -- GRIP ZONE LOGIC (Must come first to calculate drag state)
                local grip_zone_h = 90
                reaper.ImGui_SetCursorScreenPos(ctx, p_st.x, py + UI.palette_height - grip_zone_h)
                UI.Safe_InvisibleButton(ctx, "grip_"..c_id, p_st.w, grip_zone_h)
                
                if reaper.ImGui_IsItemActivated(ctx) then 
                    UI.drag_col_idx = i
                    UI.drag_mem.pal_off_x = mx - p_st.x -- Capture the exact grab pixel!
                end
                if reaper.ImGui_IsItemDeactivated(ctx) and UI.drag_col_idx == i then UI.drag_col_idx = nil end
                
                local is_dragged = (UI.drag_col_idx == i) and select(2, pcall(reaper.ImGui_IsItemActive, ctx))
                
                -- PERFECT 1:1 X-COORDINATE PHYSICS
                if is_dragged then 
                    p_st.x = mx - UI.drag_mem.pal_off_x
                    p_st.vel_x = 0
                else 
                    p_st.x, p_st.vel_x = UI.SpringDamp(p_st.x, cur_x, p_st.vel_x, 250.0, 18.0, env.app_dt) 
                end
                
                if p_col.is_deleting and p_st.w < 2 then table.remove(UI.active_palette, i) else
                    
                    if is_dragged then
                        reaper.ImGui_DrawList_AddRectFilled(dl_pal, p_st.x + 4, py + 4, p_st.x + p_st.w + 4, py + UI.palette_height + 4, 0x00000044)
                        reaper.ImGui_DrawList_AddRectFilled(dl_pal, p_st.x, py, p_st.x + p_st.w, py + UI.palette_height, p_col.hex & 0xFFFFFF00 | 0xEE)
                    else
                        reaper.ImGui_DrawList_AddRectFilled(dl_pal, p_st.x, py, p_st.x + p_st.w, py + UI.palette_height, p_col.hex)
                    end
                    
                    local txt_col = env.palette_engine and env.palette_engine.GetBestTextColor(p_col.hex) or 0xFFFFFFFF
                    local name = env.palette_engine and env.palette_engine.GetColorName(p_col.hex) or p_col.token
                    local hex_str = string.format("#%06X", (p_col.hex >> 8) & 0xFFFFFF)
                    
                    local nw, nh = reaper.ImGui_CalcTextSize(ctx, name)
                    reaper.ImGui_DrawList_AddText(dl_pal, p_st.x + (p_st.w/2) - (nw/2), py + UI.palette_height - 70, txt_col, name)
                    local hw = reaper.ImGui_CalcTextSize(ctx, hex_str)
                    reaper.ImGui_DrawList_AddText(dl_pal, p_st.x + (p_st.w/2) - (hw/2), py + UI.palette_height - 50, txt_col & 0xFFFFFF88, hex_str)
                    
                    -- GRIP HINT
                    local gx = p_st.x + (p_st.w/2)
                    local gy = py + UI.palette_height - 20
                    local grip_col = txt_col & 0xFFFFFF00 | (is_dragged and 0xFF or 0x44)
                    reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx - 8, gy, 2, grip_col)
                    reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx,     gy, 2, grip_col)
                    reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx + 8, gy, 2, grip_col)
                    if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW()) end
                    
                    -- PREMIUM KILL SWITCH (Math based hover, no blocking invisible buttons)
                    local is_upper_hov = (mx >= p_st.x and mx <= p_st.x + p_st.w and my >= py and my < py + UI.palette_height - grip_zone_h)
                    if is_upper_hov and not is_dragged and not UI.hover_states.picker_active then
                        local kx, ky = p_st.x + (p_st.w/2) - 16, py + (UI.palette_height/2) - 30
                        reaper.ImGui_SetCursorScreenPos(ctx, kx, ky)
                        UI.Safe_InvisibleButton(ctx, "kill_"..p_col.id, 32, 32)
                        local kill_hov = reaper.ImGui_IsItemHovered(ctx)
                        
                        -- Adapts to the smart text color (White or Dark) with smooth alphas
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

            -- FLAWLESS DRAG SWAP MATH
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

            -- GAP INSERTERS (+) - Only active if the search popup is closed
            if not UI.hover_states.picker_active then
                local gap_x = px
                for i = 1, col_count + 1 do
                    if i > 1 then gap_x = gap_x + base_target_w end
                    local gx_center = (i == 1) and px or ((i > col_count) and px + canvas_w or gap_x)
                    reaper.ImGui_SetCursorScreenPos(ctx, gx_center - 15, py)
                    UI.Safe_InvisibleButton(ctx, "gap_"..i, 30, UI.palette_height)
                    if reaper.ImGui_IsItemHovered(ctx) and not UI.drag_col_idx then
                        reaper.ImGui_DrawList_AddCircleFilled(dl_pal, gx_center, py + (UI.palette_height/2), 16, 0xFFFFFFCC)
                        reaper.ImGui_DrawList_AddLine(dl_pal, gx_center-6, py + (UI.palette_height/2), gx_center+6, py + (UI.palette_height/2), 0x111111FF, 3.0)
                        reaper.ImGui_DrawList_AddLine(dl_pal, gx_center, py + (UI.palette_height/2)-6, gx_center, py + (UI.palette_height/2)+6, 0x111111FF, 3.0)
                        if reaper.ImGui_IsItemClicked(ctx) then
                            local new_hex = 0x00E5FFFF -- Default fallback
                            table.insert(UI.active_palette, i, { id=math.random(10000,99999), hex=new_hex, token="New Color" })
                            UI.PushNotification("Added New Color", new_hex)
                        end
                    end
                end
            end

            -- THE SEARCH & PICKER POPUP ICON
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
                
                -- PROPER PCALL UNPACKING: (success, is_changed, string_value)
                local ok_txt, changed_txt, new_str = pcall(reaper.ImGui_InputTextWithHint, ctx, "##cp_search", "Type HEX...", UI.picker_search)
                if ok_txt and changed_txt then
                    UI.picker_search = new_str
                    local hex_str = type(new_str) == "string" and new_str:match("#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])") or nil
                    if hex_str then UI.picker_color = (tonumber(hex_str, 16) << 8) | 0xFF end
                end
                
                reaper.ImGui_Spacing(ctx)
                
                local flags = reaper.ImGui_ColorEditFlags_NoSidePreview() | reaper.ImGui_ColorEditFlags_NoAlpha() | reaper.ImGui_ColorEditFlags_PickerHueWheel()
                -- PROPER PCALL UNPACKING: (success, is_changed, color_number)
                local ok_col, changed_col, new_col = pcall(reaper.ImGui_ColorPicker4, ctx, "##cp_picker", UI.picker_color, flags)
                if ok_col and changed_col and type(new_col) == "number" then
                    UI.picker_color = new_col
                    UI.picker_search = string.format("#%06X", (new_col >> 8) & 0xFFFFFF)
                end
                
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFFFFFF22)
                
                -- Button protection
                if select(2, pcall(reaper.ImGui_Button, ctx, "+ ADD TO PALETTE", 220, 30)) then
                    local t_name = env.palette_engine and env.palette_engine.GetColorName(UI.picker_color) or "Custom"
                    table.insert(UI.active_palette, { id=math.random(10000,99999), hex=UI.picker_color, token=t_name })
                    UI.PushNotification("Added " .. t_name, UI.picker_color)
                    pcall(reaper.ImGui_CloseCurrentPopup, ctx)
                end
                
                reaper.ImGui_PopStyleColor(ctx, 1)
                reaper.ImGui_PopItemWidth(ctx)
                pcall(reaper.ImGui_EndPopup, ctx)
            else
                UI.hover_states.picker_active = false
            end
            reaper.ImGui_PopStyleVar(ctx, 1)
            reaper.ImGui_PopStyleColor(ctx, 1)
            
            reaper.ImGui_EndChild(ctx)
            
            -- DIVIDER HITBOX
            reaper.ImGui_SetCursorScreenPos(ctx, px, py + UI.palette_height - 3)
            UI.Safe_InvisibleButton(ctx, "pal_divider", canvas_w, 6)
            if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS()) end
            if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
                local _, dy = reaper.ImGui_GetMouseDelta(ctx); UI.palette_height = UI.palette_height + dy
            end
            canvas_h = total_h - UI.palette_height
        end

        reaper.ImGui_BeginChild(ctx, "canvas_pane", canvas_w, canvas_h, 0, reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
        local dl_ide = reaper.ImGui_GetWindowDrawList(ctx)

        local raw_cx, raw_cy = reaper.ImGui_GetCursorScreenPos(ctx)
        local is_canvas_hovered = reaper.ImGui_IsWindowHovered(ctx)

        -- FREE-WHEEL RELATIVE ZOOM MATRIX
        if is_canvas_hovered then
            local wheel = select(2, pcall(reaper.ImGui_GetMouseWheel, ctx)) or 0
            if wheel ~= 0 then
                local mx, my = reaper.ImGui_GetMousePos(ctx)
                local mouse_world_x = (mx - raw_cx - UI.camera.pan_x) / UI.camera.zoom
                local mouse_world_y = (my - raw_cy - UI.camera.pan_y) / UI.camera.zoom
                
                UI.camera.zoom = math.max(0.2, math.min(5.0, UI.camera.zoom + (wheel * 0.1 * UI.camera.zoom)))
                
                UI.camera.pan_x = (mx - raw_cx) - (mouse_world_x * UI.camera.zoom)
                UI.camera.pan_y = (my - raw_cy) - (mouse_world_y * UI.camera.zoom)
            end
        end

        -- PAN MATRIX (Spacebar OR Middle Mouse OR Action Hub Tool)
        local is_panning = (reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_Space()) or select(2, pcall(reaper.ImGui_IsMouseDown, ctx, 2)) or UI.active_tool == "PAN")
        if is_panning then
            if is_canvas_hovered then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll()) end
            if is_canvas_hovered and (reaper.ImGui_IsMouseDown(ctx, 0) or select(2, pcall(reaper.ImGui_IsMouseDown, ctx, 2))) then
                local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
                UI.camera.pan_x = UI.camera.pan_x + dx
                UI.camera.pan_y = UI.camera.pan_y + dy
            end
        end
        
        pcall(reaper.ImGui_SetWindowFontScale, ctx, UI.camera.zoom)

        local ok_av, raw_w, raw_h = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
        local avail_w, avail_h = tonumber(raw_w) or 0, tonumber(raw_h) or 0
        local cell_size = 40; local grid_w = UI.wb_grid_cols * cell_size; local grid_h = UI.wb_grid_rows * cell_size
        
        local offset_x = math.max(0, (avail_w - grid_w * UI.camera.zoom) / 2)
        local offset_y = math.max(0, (avail_h - grid_h * UI.camera.zoom) / 2)
        local cx = raw_cx + offset_x + UI.camera.pan_x
        local cy = raw_cy + offset_y + UI.camera.pan_y

        reaper.ImGui_DrawList_AddRectFilled(dl_ide, cx, cy, cx + grid_w * UI.camera.zoom, cy + grid_h * UI.camera.zoom, 0x0A0A0DFF, 12.0 * UI.camera.zoom)
        for y = 0, UI.wb_grid_rows do 
            for x = 0, UI.wb_grid_cols do 
                reaper.ImGui_DrawList_AddCircleFilled(dl_ide, cx + (x * cell_size * UI.camera.zoom), cy + (y * cell_size * UI.camera.zoom), 1.5 * UI.camera.zoom, 0xFFFFFF1A) 
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
                    local comp_x, comp_y = cx + bx * UI.camera.zoom, cy + by * UI.camera.zoom
                    local comp_col = is_sel and 0x00E5FFFF or 0x444444FF
                    reaper.ImGui_SetCursorScreenPos(ctx, comp_x, comp_y)
                    reaper.ImGui_InvisibleButton(ctx, "ide_hit_"..c.id, bw * UI.camera.zoom, bh * UI.camera.zoom)
                    
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
                            local dx = (mx - UI.drag_mem.mouse_start_x) / UI.camera.zoom
                            local dy = (my - UI.drag_mem.mouse_start_y) / UI.camera.zoom
                            
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
                    
                    env.p_min_x = cx; env.p_min_y = cy; env.scroll_x = 0; env.scroll_y = 0
                    local c_mock = { 
                        id = c.id, 
                        x = c.x * UI.camera.zoom, 
                        y = c.y * UI.camera.zoom, 
                        w = (c.w or 60) * UI.camera.zoom, 
                        h = (c.h or 20) * UI.camera.zoom, 
                        radius = (c.radius or 16) * UI.camera.zoom, 
                        align = c.align, label = c.label, color_token = c.color_token or "Teal", default_val=0.5,
                        steps = c.steps, axis = c.axis, wrap_at = c.wrap_at, btn_w = c.btn_w and (c.btn_w * UI.camera.zoom) or nil, btn_h = c.btn_h and (c.btn_h * UI.camera.zoom) or nil, labels = c.labels
                    }
                    local pst = { disp_val = 0.5, flash = 0.0 }
                    
                    -- DEFAULT LAYER FALLBACK
                    local target_layer = c.z_override
                    if not target_layer then
                        if c.type == "Text" or c.type == "BackPanel" then target_layer = 3
                        elseif c.type == "Dropdown" or c.type == "Tooltip" then target_layer = 5
                        else target_layer = 4 end
                    end
                    pcall(reaper.ImGui_DrawList_ChannelsSetCurrent, dl_ide, tonumber(target_layer) or target_layer)

                    if c.type == "AuraKnob" then UI.DrawComponent_AuraKnob(ctx, dl_ide, c_mock, env, nil, false, 0.5, "0.5", pst)
                    elseif c.type == "InlineDrag" then UI.DrawComponent_InlineDrag(ctx, dl_ide, c_mock, env, nil, false, 0.5, "0.5", pst)
                    elseif c.type == "PeakMeter" then UI.DrawComponent_PeakMeter(ctx, dl_ide, c_mock, env, nil, false, 0.5, "", pst)
                    elseif c.type == "VuMeter" then UI.DrawComponent_VuMeter(ctx, dl_ide, c_mock, env, nil, false, 0.5, "", pst)
                    elseif c.type == "TogglePill" then UI.DrawComponent_TogglePill(ctx, dl_ide, c_mock, env, nil, false, 0.5, "", pst)
                    elseif c.type == "ToggleLever" then UI.DrawComponent_ToggleLever(ctx, dl_ide, c_mock, env, nil, false, 0.5, "", pst)
                    elseif env.NodeUI then -- Safely call the extracted NodeUI renderers
                        if c.type == "Fader" then env.NodeUI.DrawComponent_Fader(ctx, dl_ide, c_mock, env, nil, false, 0.5, "0.0", pst, UI)
                        elseif c.type == "VFDScreen" then env.NodeUI.DrawComponent_VFDScreen(ctx, dl_ide, c_mock, env, nil, false, 0.5, "8.8", pst, UI)
                        elseif c.type == "Dropdown" then env.NodeUI.DrawComponent_Dropdown(ctx, dl_ide, c_mock, env, nil, false, 0.5, "Option 1", pst, UI)
                        elseif c.type == "BackPanel" then env.NodeUI.DrawComponent_BackPanel(ctx, dl_ide, c_mock, env, nil, false, 0.5, "", pst, UI)
                        elseif c.type == "ScrewDecal" then env.NodeUI.DrawComponent_ScrewDecal(ctx, dl_ide, c_mock, env, nil, false, 0.5, "", pst, UI)
                        elseif c.type == "RadioStrip" then env.NodeUI.DrawComponent_RadioStrip(ctx, dl_ide, c_mock, env, nil, false, 0.5, "", pst, UI)
                        end
                    end
                end
            end
            pcall(reaper.ImGui_DrawList_ChannelsMerge, dl_ide)
        end

        if #UI.selected_comp_ids > 0 then
            local g_min_x, g_min_y, g_max_x, g_max_y = 99999, 99999, -99999, -99999
            for _, c in ipairs(UI.wb_schema_buffer) do
                if UI.IsComponentSelected(c.id) then
                    local bx, by, bw, bh = GetBounds(c)
                    local comp_x, comp_y = cx + bx * UI.camera.zoom, cy + by * UI.camera.zoom
                    g_min_x = math.min(g_min_x, comp_x)
                    g_min_y = math.min(g_min_y, comp_y)
                    g_max_x = math.max(g_max_x, comp_x + bw * UI.camera.zoom)
                    g_max_y = math.max(g_max_y, comp_y + bh * UI.camera.zoom)
                end
            end
            if g_min_x < 99999 then
                reaper.ImGui_DrawList_AddRect(dl_ide, g_min_x-4, g_min_y-4, g_max_x+4, g_max_y+4, 0xFFFFFF66, 4.0, 0, 1.0)
                if #UI.selected_comp_ids == 1 and sel_comp then
                    local hw, hh = 12, 12; local hx, hy = g_max_x + 4 - hw, g_max_y + 4 - hh
                    reaper.ImGui_SetCursorScreenPos(ctx, hx, hy)
                    reaper.ImGui_InvisibleButton(ctx, "sz_"..sel_comp.id, hw, hh)
                    local is_hov = reaper.ImGui_IsItemHovered(ctx)
                    if is_hov then reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNWSE()) end
                    reaper.ImGui_DrawList_AddTriangleFilled(dl_ide, hx+hw, hy, hx+hw, hy+hh, hx, hy+hh, is_hov and 0xFFFFFFFF or 0xFFFFFF88)
                    if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0) then
                        local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
                        dx = dx / UI.camera.zoom
                        dy = dy / UI.camera.zoom
                        if sel_comp.type == "AuraKnob" then sel_comp.radius = math.floor(math.max(10, (sel_comp.radius or 16) + math.max(dx, dy)*0.5))
                        else sel_comp.w = math.floor(math.max(20, (sel_comp.w or 60) + dx)); sel_comp.h = math.floor(math.max(10, (sel_comp.h or 20) + dy)) end
                    end
                end
            end
        end

        reaper.ImGui_SetCursorScreenPos(ctx, cx, cy)
        reaper.ImGui_InvisibleButton(ctx, "canvas_drop_zone", grid_w * UI.camera.zoom, grid_h * UI.camera.zoom)
        
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
                local comp_screen_x, comp_screen_y = cx + bx * UI.camera.zoom, cy + by * UI.camera.zoom
                local comp_w, comp_h = bw * UI.camera.zoom, bh * UI.camera.zoom
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
                local world_drop_x = (mx - cx) / UI.camera.zoom
                local world_drop_y = (my - cy) / UI.camera.zoom
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
        pcall(reaper.ImGui_SetWindowFontScale, ctx, 1.0)
        
        -- TOP-RIGHT ZOOM HUD
        local hud_w, hud_h = 130, 32
        local hud_x, hud_y = raw_cx + avail_w - hud_w - 20, raw_cy + 20
        reaper.ImGui_DrawList_AddRectFilled(dl_ide, hud_x, hud_y, hud_x + hud_w, hud_y + hud_h, 0x11111199, 16.0)
        reaper.ImGui_DrawList_AddRect(dl_ide, hud_x, hud_y, hud_x + hud_w, hud_y + hud_h, 0xFFFFFF22, 16.0, 0, 1.0)
        
        reaper.ImGui_SetCursorScreenPos(ctx, hud_x + 8, hud_y + 4)
        if reaper.ImGui_Button(ctx, "-##zo", 24, 24) then UI.camera.zoom = math.max(0.2, UI.camera.zoom - 0.1) end
        reaper.ImGui_SameLine(ctx)
        
        local z_str = string.format("%d%%", math.floor(UI.camera.zoom * 100))
        local zw = reaper.ImGui_CalcTextSize(ctx, z_str)
        reaper.ImGui_SetCursorScreenPos(ctx, hud_x + (hud_w/2) - (zw/2), hud_y + 8)
        reaper.ImGui_Text(ctx, z_str)
        if reaper.ImGui_IsItemClicked(ctx) then UI.camera.zoom = 1.0; UI.camera.pan_x = 0; UI.camera.pan_y = 0 end
        
        reaper.ImGui_SetCursorScreenPos(ctx, hud_x + hud_w - 32, hud_y + 4)
        if reaper.ImGui_Button(ctx, "+##zi", 24, 24) then UI.camera.zoom = math.min(5.0, UI.camera.zoom + 0.1) end

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

        reaper.ImGui_EndChild(ctx)
        reaper.ImGui_EndGroup(ctx) -- ENDS PANE 2 WRAPPER
        reaper.ImGui_SameLine(ctx, 0, 16)

        -- ==========================================
        -- PANE 3: THEME MANAGER & DATA BINDING (GOLDEN RATIO 280px)
        -- ==========================================
        reaper.ImGui_BeginChild(ctx, "props_pane", 280, 0, 0, 0)
        local dl_right = reaper.ImGui_GetWindowDrawList(ctx)
        
        -- 1. Create a scrolling child window that stops 40 pixels before the bottom
        reaper.ImGui_BeginChild(ctx, "PropertyScrollArea", 0, -40)
        
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
            reaper.ImGui_BeginChild(ctx, "pal_list", 0, 160 * t_pal, 0, reaper.ImGui_WindowFlags_NoScrollbar())
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
            reaper.ImGui_BeginChild(ctx, "set_list", 0, 40 * t_set, 0, reaper.ImGui_WindowFlags_NoScrollbar())
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
                reaper.ImGui_BeginChild(ctx, "sp_list", 0, 100 * t_sp, 0, reaper.ImGui_WindowFlags_NoScrollbar())
                reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), t_sp); reaper.ImGui_PushItemWidth(ctx, 80)
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
                reaper.ImGui_PopItemWidth(ctx); reaper.ImGui_PopStyleVar(ctx, 1); reaper.ImGui_EndChild(ctx)
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
    end
    
    reaper.ImGui_End(ctx) 
    reaper.ImGui_PopStyleVar(ctx, 2); reaper.ImGui_PopStyleColor(ctx, 2)
end

-- ==============================================================================
-- LEGACY WIDGET API (Raw Native Drawing, No Protected Wrappers)
-- ==============================================================================
function UI.DrawSharpGlowingText(draw_list, x, y, text, col, alpha_mult)
    local a = tonumber(alpha_mult) or 1.0; local bg = math.floor(0x66*a); local drop = math.floor(0xFF*a); local c_bg = (col & 0xFFFFFF00) | bg
    reaper.ImGui_DrawList_AddText(draw_list, x-1, y, c_bg, tostring(text))
    reaper.ImGui_DrawList_AddText(draw_list, x+1, y, c_bg, tostring(text))
    reaper.ImGui_DrawList_AddText(draw_list, x, y-1, c_bg, tostring(text))
    reaper.ImGui_DrawList_AddText(draw_list, x, y+1, c_bg, tostring(text))
    reaper.ImGui_DrawList_AddText(draw_list, x+1, y+1, 0x00000000 | drop, tostring(text))
    reaper.ImGui_DrawList_AddText(draw_list, x, y, (0xFFFFFF00) | drop, tostring(text))
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
    if reaper.ImGui_IsItemActive(ctx) then local mx, my = reaper.ImGui_GetMousePos(ctx); val = math.max(0.0, math.min(1.0, (mx - x) / safe_w)); changed = true end
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
    if is_active then
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
        if dy ~= 0 then val = math.max(v_min, math.min(v_max, val - (dy * (shift_held and ((v_max-v_min)/2000) or ((v_max-v_min)/200))))); changed = true end
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

return UI
