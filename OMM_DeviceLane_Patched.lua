-- ==============================================================================
-- OMM_DeviceLane.lua (The 3rd-Party Wrapper Engine)
-- Protocol Zero: Strict Two-Way Sync & Seatbelt Rendering
-- ==============================================================================

local DeviceLane = {}
DeviceLane.collapsed_vst = DeviceLane.collapsed_vst or {}

local PALETTE = {
    ASH       = 0xC7C7CCFF,
    TITANIUM  = 0xE5E5EAFF,
    ONYX      = 0x1C1C1EFF,
    TANGERINE = 0xFF6B35FF,
    SCREEN_BG = 0x0A0A0AFF
}

local function DrawSmartMenu(ctx, label, type_name, state)
    if select(2, pcall(reaper.ImGui_BeginMenu, ctx, label)) then
        if select(2, pcall(reaper.ImGui_MenuItem, ctx, "+ Create New " .. type_name)) then state.AddNode(type_name) end
        pcall(reaper.ImGui_Separator, ctx)
        local has_any = false
        if state.nodes then
            for _, n in ipairs(state.nodes) do
                if n.type == type_name then
                    has_any = true
                    local is_linked = (n.lane_guid == state.sel_track_guid)
                    if is_linked then
                        pcall(reaper.ImGui_TextDisabled, ctx, type_name .. " " .. n.id .. " (Linked Here)")
                    else
                        if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Link Existing " .. type_name .. " " .. n.id)) then state.LinkNode(n.id) end
                    end
                end
            end
        end
        if not has_any then pcall(reaper.ImGui_TextDisabled, ctx, "(No " .. type_name .. "s on Canvas)") end
        pcall(reaper.ImGui_EndMenu, ctx)
    end
end

-- ==========================================================
-- PRO CODE: PREMIUM SETTINGS ENGINE (Light Gradient + 20/80)
-- ==========================================================
local function DrawKinematicGear(dl, cx, cy, rad, teeth, col, thickness)
    -- Inner Ring & Hub
    pcall(reaper.ImGui_DrawList_AddCircle, dl, cx, cy, rad * 0.35, col, 0, thickness)
    pcall(reaper.ImGui_DrawList_AddCircle, dl, cx, cy, rad * 0.70, col, 0, thickness)
    -- The Teeth
    for i = 0, teeth - 1 do
        local angle = (i / teeth) * math.pi * 2
        local x1, y1 = cx + math.cos(angle) * (rad * 0.70), cy + math.sin(angle) * (rad * 0.70)
        local x2, y2 = cx + math.cos(angle) * rad, cy + math.sin(angle) * rad
        pcall(reaper.ImGui_DrawList_AddLine, dl, x1, y1, x2, y2, col, thickness * 1.5)
    end
end

function DeviceLane.DrawSettingsPane(ctx, dl, x, y, w, h, state, UI, lane_z)
    DeviceLane.active_settings_tab = DeviceLane.active_settings_tab or "UI"
    local left_w = math.max(120 * lane_z, w * 0.2)
    local right_w = w - left_w
    
    local base_f_sz = tonumber(reaper.ImGui_GetFontSize(ctx)) or 14
    local scaled_f_sz = base_f_sz * lane_z
    local f_sz = scaled_f_sz
    local draw_font = (UI and UI.ScaleRegistry and UI.ScaleRegistry.Canvas_Font) or nil
    
    local c1, c2, c3, c4, c5 = 0xF4F5F8FF, 0xEBECEFFF, 0xE2E4ECFF, 0xE3DFE8FF, 0xEBE2E1FF
    local seg_w = w / 4
    pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl, x, y, x + seg_w, y + h, c1, c2, c2, c1)
    pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl, x + seg_w, y, x + (seg_w*2), y + h, c2, c3, c3, c2)
    pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl, x + (seg_w*2), y, x + (seg_w*3), y + h, c3, c4, c4, c3)
    pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl, x + (seg_w*3), y, x + w, y + h, c4, c5, c5, c4)
    pcall(reaper.ImGui_DrawList_AddRect, dl, x, y, x + w, y + h, 0xFFFFFF88, 4.0, 0, 1.0)

    pcall(reaper.ImGui_SetCursorScreenPos, ctx, x, y)
    pcall(reaper.ImGui_BeginChild, ctx, "set_tabs", left_w, h, 0)
    
    local tabs = {"UI", "JSFX"}
    local tab_y = y + (20 * lane_z)
    
    for _, tab in ipairs(tabs) do
        local is_active = (DeviceLane.active_settings_tab == tab)
        local col = is_active and 0x1A1A1CFF or 0x888899FF 
        
        if is_active then
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x + (10*lane_z), tab_y - (6*lane_z), x + left_w - (10*lane_z), tab_y + (20*lane_z), 0x0000000D, 6.0)
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x + (2*lane_z), tab_y - (4*lane_z), x + (5*lane_z), tab_y + (18*lane_z), PALETTE.TANGERINE, 2.0)
        end
        
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, scaled_f_sz, x + (18*lane_z), tab_y, col, tab)
        
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, x, tab_y - (6*lane_z))
        if UI.Safe_InvisibleButton(ctx, "tab_"..tab, left_w, 26 * lane_z) then DeviceLane.active_settings_tab = tab end
        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) end
        
        tab_y = tab_y + (36 * lane_z)
    end
    pcall(reaper.ImGui_EndChild, ctx)
    
    pcall(reaper.ImGui_DrawList_AddLine, dl, x + left_w, y + (20*lane_z), x + left_w, y + h - (20*lane_z), 0x00000015, 1.0)
    
    pcall(reaper.ImGui_SetCursorScreenPos, ctx, x + left_w + 1, y)
    pcall(reaper.ImGui_BeginChild, ctx, "set_content", right_w - 1, h, 0)
    
    local cx = x + left_w + (40 * lane_z)
    local cy = y + (30 * lane_z)
    local txt_col = 0x2A2A33FF
    
    if DeviceLane.active_settings_tab == "UI" then
        local head_sz = base_f_sz * math.max(0.85, lane_z * 0.85)
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, head_sz, cx, cy, 0x888899FF, "ZOOM & SCALING")
        pcall(reaper.ImGui_DrawList_AddLine, dl, cx, cy + (20*lane_z), cx + right_w - (80*lane_z), cy + (20*lane_z), 0x00000011, 1.0)
        cy = cy + (40 * lane_z)
        
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, scaled_f_sz, cx, cy + (4*lane_z), txt_col, "Device Lane Zoom Level")
        
        local p_w, p_h = 135 * lane_z, 26 * lane_z
        local p_x = cx + right_w - (80*lane_z) - p_w
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl, p_x, cy, p_x + p_w, cy + p_h, 0x0000000C, p_h/2)
        pcall(reaper.ImGui_DrawList_AddRect, dl, p_x, cy, p_x + p_w, cy + p_h, 0x0000001A, p_h/2, 0, 1.0)
        
        local seg_w = p_w / 3
        
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, p_x, cy)
        local min_clk = UI.Safe_InvisibleButton(ctx, "z_min", seg_w, p_h)
        local min_hov = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
        local min_act = select(2, pcall(reaper.ImGui_IsItemActive, ctx))
        if min_hov then pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()); pcall(reaper.ImGui_DrawList_AddRectFilled, dl, p_x, cy, p_x + seg_w, cy + p_h, 0x0000000F, p_h/2, reaper.ImGui_DrawFlags_RoundCornersLeft()) end
        if min_clk then DeviceLane.zoom = math.max(0.5, DeviceLane.zoom - 0.25) end
        
        local _, tw_min = pcall(reaper.ImGui_CalcTextSize, ctx, "-")
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, f_sz, p_x + (seg_w/2) - ((tonumber(tw_min) or 0)*lane_z)/2, cy + (4*lane_z) + (min_act and 1 or 0), min_hov and PALETTE.TANGERINE or txt_col, "-")
        
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, p_x + seg_w, cy)
        local rst_clk = UI.Safe_InvisibleButton(ctx, "z_rst", seg_w, p_h)
        local rst_hov = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
        local rst_act = select(2, pcall(reaper.ImGui_IsItemActive, ctx))
        if rst_hov then pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()); pcall(reaper.ImGui_DrawList_AddRectFilled, dl, p_x + seg_w, cy, p_x + (seg_w*2), cy + p_h, 0x0000000A, 0) end
        if rst_clk then DeviceLane.zoom = 1.0 end
        
        local cur_z_str = math.floor((DeviceLane.zoom * 100) + 0.5) .. "%"
        local _, zw = pcall(reaper.ImGui_CalcTextSize, ctx, cur_z_str)
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, f_sz, p_x + seg_w + (seg_w/2) - ((tonumber(zw) or 0)*lane_z)/2, cy + (4*lane_z) + (rst_act and 1 or 0), rst_hov and PALETTE.TANGERINE or txt_col, cur_z_str)
        
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, p_x + (seg_w*2), cy)
        local plu_clk = UI.Safe_InvisibleButton(ctx, "z_plu", seg_w, p_h)
        local plu_hov = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
        local plu_act = select(2, pcall(reaper.ImGui_IsItemActive, ctx))
        if plu_hov then pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()); pcall(reaper.ImGui_DrawList_AddRectFilled, dl, p_x + (seg_w*2), cy, p_x + p_w, cy + p_h, 0x0000000F, p_h/2, reaper.ImGui_DrawFlags_RoundCornersRight()) end
        if plu_clk then DeviceLane.zoom = math.min(2.0, DeviceLane.zoom + 0.25) end
        
        local _, tw_plus = pcall(reaper.ImGui_CalcTextSize, ctx, "+")
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, f_sz, p_x + (seg_w*2) + (seg_w/2) - ((tonumber(tw_plus) or 0)*lane_z)/2, cy + (4*lane_z) + (plu_act and 1 or 0), plu_hov and PALETTE.TANGERINE or txt_col, "+")
        
    elseif DeviceLane.active_settings_tab == "JSFX" then
        local head_sz = base_f_sz * math.max(0.85, lane_z * 0.85)
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, head_sz, cx, cy, 0x888899FF, "PERFORMANCE & DSP")
        pcall(reaper.ImGui_DrawList_AddLine, dl, cx, cy + (20*lane_z), cx + right_w - (80*lane_z), cy + (20*lane_z), 0x00000011, 1.0)
        cy = cy + (40 * lane_z)
        
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, scaled_f_sz, cx, cy, txt_col, "DSP Auto-Bypass (CPU Saver)")
        pcall(reaper.ImGui_DrawList_AddTextEx, dl, draw_font, head_sz, cx, cy + (18*lane_z), 0x888899FF, "Automatically suspends JSFX processing on silent channels.")
        
        local t_w, t_h = 40 * lane_z, 22 * lane_z
        local t_x = cx + right_w - (80*lane_z) - t_w
        
        state.dsp_auto_bypass = state.dsp_auto_bypass or false
        local is_on = state.dsp_auto_bypass
        
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl, t_x, cy, t_x + t_w, cy + t_h, is_on and PALETTE.TANGERINE or 0x00000022, t_h/2)
        pcall(reaper.ImGui_DrawList_AddRect, dl, t_x, cy, t_x + t_w, cy + t_h, 0x00000033, t_h/2, 0, 1.0)
        pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, t_x + (is_on and (t_w - t_h/2) or (t_h/2)), cy + t_h/2, (t_h/2) - (2*lane_z), 0xFFFFFFFF)
        
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, t_x, cy)
        if UI.Safe_InvisibleButton(ctx, "byp_tog", t_w, t_h) then state.dsp_auto_bypass = not is_on end
        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) end
    end
    
    pcall(reaper.ImGui_EndChild, ctx)
end

function DeviceLane.Draw(ctx, state, UI)
    local needs_save = false
    local trigger_add_menu = false

    -- ==========================================================
    -- PRO FIX: INDEPENDENT ZOOM & BASE FONT DISCOVERY
    -- ==========================================================
    DeviceLane.zoom = DeviceLane.zoom or 1.0
    local lane_z = DeviceLane.zoom
    
    local target_h = 250
    -- Clamped Padding: 12px min, 20px max
    local pad = math.max(12, math.min(20, 16 * lane_z))
    -- PRO FIX: IDE Parity. 6 Grids (6 * 40 = 240px) + Top/Bottom Padding
    target_h = math.floor((240 * lane_z) + (pad * 2))

    -- PHYSICAL LOCK: Cannot resize smaller than target_h 
    pcall(reaper.ImGui_SetNextWindowSizeConstraints, ctx, 100, target_h, 99999, 99999)

    pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_WindowBg(), PALETTE.ASH)
    local l_flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    local ok, lane_visible, is_open = pcall(reaper.ImGui_Begin, ctx, 'OMM Device Lane', true, l_flags)
    
    -- ANCHOR THE TRUE BASE FONT SIZE
    local base_f_sz = tonumber(reaper.ImGui_GetFontSize(ctx)) or 14
    local scaled_f_sz = base_f_sz * lane_z
    
    -- PRO FIX: GRAB THE OVERSAMPLED CANVAS FONT (Avoids nil fallback to unscalable bitmap)
    local draw_font = (UI and UI.ScaleRegistry and UI.ScaleRegistry.Canvas_Font) or nil
    
    if ok and lane_visible then
        local dl_lane = select(2, pcall(reaper.ImGui_GetWindowDrawList, ctx))
        local _, l_x, l_y = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
        local _, l_w, l_h = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
        l_x = tonumber(l_x) or 0; l_y = tonumber(l_y) or 0; l_w = tonumber(l_w) or 0; l_h = tonumber(l_h) or 0
        
        -- PRO FIX: If the font scales, the column MUST scale!
        local btn_w = math.floor(34 * lane_z)
        local third_h = l_h / 3
        pcall(reaper.ImGui_Dummy, ctx, btn_w, l_h)
        
        -- SLOT 1: UI / CANVAS TOGGLE
        local canv_col = state.show_canvas and PALETTE.TANGERINE or (PALETTE.TANGERINE & 0xFFFFFF00 | 0x55)
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y, l_x + btn_w, l_y + third_h, canv_col, 0)
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, l_x, l_y)
        if UI.Safe_InvisibleButton(ctx, "canvas_toggle_btn", btn_w, third_h) then state.show_canvas = not state.show_canvas; needs_save = true end
        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y, l_x + btn_w, l_y + third_h, 0xFFFFFF33, 0)
            pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) 
        end
        local _, tw1 = pcall(reaper.ImGui_CalcTextSize, ctx, "UI")
        pcall(reaper.ImGui_DrawList_AddTextEx, dl_lane, draw_font, scaled_f_sz, l_x + (btn_w/2) - ((tonumber(tw1) or 0)*lane_z)/2, l_y + (third_h/2) - (scaled_f_sz/2), 0xFFFFFFFF, "UI")

        -- SLOT 2: DEV MODE TOGGLE
        local dev_y = l_y + third_h
        local dev_col = state.env.DEV_MODE and 0xFF0000FF or 0x444444FF
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, dev_y, l_x + btn_w, dev_y + third_h, dev_col, 0)
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, l_x, dev_y)
        if UI.Safe_InvisibleButton(ctx, "dev_toggle_btn", btn_w, third_h) then 
            state.env.DEV_MODE = not state.env.DEV_MODE
            if not state.env.DEV_MODE then state.env.active_dev_module = nil end
        end
        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, dev_y, l_x + btn_w, dev_y + third_h, 0xFFFFFF33, 0)
            pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) 
        end
        local _, tw2 = pcall(reaper.ImGui_CalcTextSize, ctx, "DEV")
        pcall(reaper.ImGui_DrawList_AddTextEx, dl_lane, draw_font, scaled_f_sz, l_x + (btn_w/2) - ((tonumber(tw2) or 0)*lane_z)/2, dev_y + (third_h/2) - (scaled_f_sz/2), 0xFFFFFFFF, "DEV")
        pcall(reaper.ImGui_DrawList_AddLine, dl_lane, l_x, dev_y, l_x + btn_w, dev_y, 0x00000066, 2.0 * lane_z)

        -- SLOT 3: SETTINGS GEAR (Kinematic Geometry Gear)
        -- PRO FIX: Revert to the exact legacy module state variable
        DeviceLane.show_lane_settings = DeviceLane.show_lane_settings or false
        local set_col = DeviceLane.show_lane_settings and PALETTE.TANGERINE or 0x2A2A2EFF
        
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y + (third_h*2), l_x + btn_w, l_y + l_h, set_col, 0)
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, l_x, l_y + (third_h*2))
        
        -- EXACT LEGACY EXTRACTION: Same ID, silent boolean toggle, NO needs_save trigger.
        if UI.Safe_InvisibleButton(ctx, "settings_toggle_btn", btn_w, third_h) then 
            DeviceLane.show_lane_settings = not DeviceLane.show_lane_settings 
        end
        
        local set_hov = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
        if set_hov then 
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y + (third_h*2), l_x + btn_w, l_y + l_h, 0xFFFFFF33, 0)
            pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) 
        end
        
        -- Premium Geometry Gear (Preserved)
        local gear_col = DeviceLane.show_lane_settings and 0xFFFFFFFF or (set_hov and 0xDDDDDDFF or 0x888888FF)
        DrawKinematicGear(dl_lane, l_x + (btn_w/2), l_y + (third_h*2) + (third_h/2), 7.0 * lane_z, 8, gear_col, 2.0 * lane_z)
        pcall(reaper.ImGui_DrawList_AddLine, dl_lane, l_x, l_y + (third_h*2), l_x + btn_w, l_y + (third_h*2), 0x00000066, 2.0)


        -- 2. THE MASTER CONTENT ROUTER (Scroll vs Settings)
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, l_x + btn_w + 10, l_y)
        local child_w = math.max(1.0, l_w - btn_w - 10.0) 
        local child_h = math.max(1.0, l_h)
        
        -- PRO FIX: Match the exact legacy module state variable
        if DeviceLane.show_lane_settings then
            DeviceLane.DrawSettingsPane(ctx, dl_lane, l_x + btn_w, l_y, child_w + 10, child_h, state, UI, lane_z)
        else
            -- Otherwise, render the standard Device Scroll
            local c_ok, child_visible = pcall(reaper.ImGui_BeginChild, ctx, "devices_scroll", child_w, child_h, 0, reaper.ImGui_WindowFlags_HorizontalScrollbar())
        
        if c_ok and child_visible then
            local _, bg_x, bg_y = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
            local _, vis_w, vis_h = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
            bg_x = tonumber(bg_x) or 0; bg_y = tonumber(bg_y) or 0; vis_w = tonumber(vis_w) or 0; vis_h = tonumber(vis_h) or 0
            
            if reaper.ImGui_SetNextItemAllowOverlap then pcall(reaper.ImGui_SetNextItemAllowOverlap, ctx) end
            UI.Safe_InvisibleButton(ctx, "lane_bg_catcher", math.max(1, vis_w), math.max(1, vis_h))
            if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) and select(2, pcall(reaper.ImGui_IsMouseReleased, ctx, 1)) then trigger_add_menu = true end
            pcall(reaper.ImGui_SetCursorScreenPos, ctx, bg_x, bg_y)

            if state.sel_track then
                local fx_count = reaper.TrackFX_GetCount(state.sel_track)
                local current_guid = state.sel_track_guid
                
                local available_nodes = {}
                if state.nodes and current_guid then
                    for i, n in ipairs(state.nodes) do
                        if n.lane_guid == current_guid then table.insert(available_nodes, {node = n, idx = i}) end
                    end
                end
                
                for f_i = 0, fx_count - 1 do
                    local _, fx_name = reaper.TrackFX_GetFXName(state.sel_track, f_i)
                    local fx_guid = reaper.TrackFX_GetFXGUID(state.sel_track, f_i)
                    local is_bypassed = not reaper.TrackFX_GetEnabled(state.sel_track, f_i)
                    
                    if string.find(fx_name, "OMM Track Hub") then goto skip_fx end
                    
                    pcall(reaper.ImGui_PushID, ctx, "fx_block_"..f_i)
                    pcall(reaper.ImGui_BeginGroup, ctx)
                    
                    local matched_node = nil
                    if string.find(fx_name, "OMM") or string.find(fx_name, "MacroMaker") then
                        local ok_param, param_val = pcall(reaper.TrackFX_GetParam, state.sel_track, f_i, 0)
                        local target_val = math.floor((tonumber(param_val) or 0) + 0.5)
                        
                        if ok_param and target_val > 0 then
                            local found = false
                            for _, n in ipairs(state.nodes) do
                                if string.find(fx_name, "Compressor") then
                                    if n.gmem_slot == target_val then found = true; break end
                                else
                                    if n.id == target_val then found = true; break end
                                end
                            end

                            if not found then
                                reaper.TrackFX_Delete(state.sel_track, f_i)
                                needs_save = true
                                pcall(reaper.ImGui_EndGroup, ctx)
                                pcall(reaper.ImGui_PopID, ctx)
                                goto skip_fx
                            end
                            
                            for j, an in ipairs(available_nodes) do
                                if string.find(fx_name, "Compressor") then
                                    if an.node.gmem_slot == target_val then matched_node = an; table.remove(available_nodes, j); break end
                                else
                                    if an.node.id == target_val then matched_node = an; table.remove(available_nodes, j); break end
                                end
                            end
                        end
                        if not matched_node then pcall(reaper.ImGui_EndGroup, ctx); pcall(reaper.ImGui_PopID, ctx); goto skip_fx end
                    end
                    
                    local is_col = false
                    local n = nil
                    local display_name = ""
                    local head_col = 0x00000022
                    
                    if matched_node then
                        n = matched_node.node
                        is_col = n.is_collapsed
                        display_name = (n.type == "TRANSFER_CURVE" and "ATTEN" or n.type) .. " " .. n.id
                        head_col = n.col and (n.col & 0xFFFFFF99) or 0x00000022
                        if n.type == "COMPRESSOR" then head_col = PALETTE.TITANIUM end
                    else
                        is_col = DeviceLane.collapsed_vst[fx_guid]
                        local clean_name = fx_name:gsub("^VST%d?i?:%s*", ""):gsub("^JS:%s*", ""):gsub("^AUi?:%s*", "")
                        display_name = clean_name:match("^%s*(.-)%s*$")
                        head_col = PALETTE.TITANIUM
                    end
                    
                    -- PRO CODE: Grid-Locked Module Dimensions
                    -- PRO FIX: IDE-Synchronized Grid Dimensions (40px)
                    local dev_w, dev_h = 160, 240
                    if n and n.algo then
                        local schema = state.NodeUI.GetSchema(n.algo)
                        if schema then
                            dev_w = (schema.grid_cols or 4) * 40
                            dev_h = (schema.grid_rows or 6) * 40 
                        end
                    end
                    if is_col then dev_w = 40 end
                    
                    dev_w = math.floor(dev_w * lane_z)
                    dev_h = math.floor(dev_h * lane_z)
                    
                    -- CLAMPED PADDING (12px to 20px max)
                    local y_pad = math.floor(math.max(12, math.min(20, 16 * lane_z)))
                    local dim_factor = is_bypassed and 0.4 or 1.0
                    
                    -- Dummy reserves space for both top and bottom padding
                    pcall(reaper.ImGui_Dummy, ctx, dev_w, dev_h + (y_pad * 2))
                    local _, dev_x, dev_y = pcall(reaper.ImGui_GetItemRectMin, ctx)
                    dev_x = tonumber(dev_x) or 0; dev_y = tonumber(dev_y) or 0
                    local box_y = dev_y + y_pad
                    
                    if is_col or not n then
                        local chassis_col = PALETTE.TITANIUM & 0xFFFFFF00 | math.floor(0xFF * dim_factor)
                        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, chassis_col, 8.0 * lane_z)
                        pcall(reaper.ImGui_DrawList_AddRect, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, 0x00000033, 8.0 * lane_z, 0, 1.0 * lane_z)
                    end
                    
                    if not is_col then
                        if n then
                            local orig_alpha = state.env.act_a
                            state.env.act_a = orig_alpha * dim_factor
                            state.env.current_fx_idx = f_i
                            
                            n.z = lane_z -- INJECT ZOOM TO CANVAS COMPONENTS
                            local ok_draw, ns = pcall(state.NodeUI.DrawNodeBlock, ctx, dl_lane, n, matched_node.idx, state.nodes, state.connections, state.env, UI, state.DSP, dev_x, box_y, true)
                            if ok_draw then
                                if ns then needs_save = true end
                                pcall(reaper.ImGui_DrawList_AddRect, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, 0xFFFFFF1A, 8.0 * lane_z, 0, 1.0 * lane_z)
                            else
                                pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, 0xFF000033, 8.0 * lane_z)
                                pcall(reaper.ImGui_DrawList_AddTextEx, dl_lane, nil, 14 * lane_z, dev_x + (10*lane_z), box_y + (10*lane_z), 0xFF0000FF, "RENDER ERROR")
                            end
                            
                            state.env.act_a = orig_alpha
                        else
                            pcall(reaper.ImGui_SetCursorScreenPos, ctx, dev_x, box_y + (28 * lane_z))
                            UI.Safe_InvisibleButton(ctx, "launch_"..f_i, dev_w, dev_h - (28 * lane_z))
                            if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then reaper.TrackFX_Show(state.sel_track, f_i, 3) end
                            if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
                                local r_bot = reaper.ImGui_DrawFlags_RoundCornersBottom and reaper.ImGui_DrawFlags_RoundCornersBottom() or 12
                                pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y + (28 * lane_z), dev_x + dev_w, box_y + dev_h, 0xFFFFFF44, 8.0 * lane_z, r_bot)
                            end
                        end
                    end
                    
                    local r_all = reaper.ImGui_DrawFlags_RoundCornersAll and reaper.ImGui_DrawFlags_RoundCornersAll() or 15
                    local r_top = reaper.ImGui_DrawFlags_RoundCornersTop and reaper.ImGui_DrawFlags_RoundCornersTop() or 3
                    local head_flags = is_col and r_all or r_top
                    if is_col or not n then
                        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + (is_col and dev_h or (28 * lane_z)), head_col, 8.0 * lane_z, head_flags)
                    end
                    
                    local led_col = is_bypassed and 0x777777FF or PALETTE.TANGERINE
                    pcall(reaper.ImGui_DrawList_AddCircleFilled, dl_lane, dev_x + (is_col and (20*lane_z) or (14*lane_z)), box_y + (14*lane_z), 5*lane_z, led_col)
                    pcall(reaper.ImGui_SetCursorScreenPos, ctx, dev_x + (is_col and (10*lane_z) or (4*lane_z)), box_y + (4*lane_z))
                    UI.Safe_InvisibleButton(ctx, "byp_"..f_i, 20*lane_z, 20*lane_z)
                    if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then 
                        local new_byp = not is_bypassed
                        reaper.TrackFX_SetEnabled(state.sel_track, f_i, not new_byp)
                        if n then n.bypass = new_byp end
                        needs_save = true 
                    end

                    local clean_name = display_name:gsub("^VST%d?i?:%s*", ""):gsub("^JS:%s*", ""):gsub("^AUi?:%s*", "")
                    clean_name = clean_name:match("^%s*(.-)%s*$")
                    
                    if is_col then
                        local short_name = string.sub(clean_name, 1, 10):upper()
                        local text_y = box_y + (35 * lane_z)
                        for c_i = 1, #short_name do
                            local char = short_name:sub(c_i, c_i)
                            local _, cw, ch = pcall(reaper.ImGui_CalcTextSize, ctx, char)
                            pcall(reaper.ImGui_DrawList_AddTextEx, dl_lane, draw_font, scaled_f_sz, dev_x + (20 * lane_z) - ((tonumber(cw) or 0)*lane_z)/2, text_y, PALETTE.ONYX, char)
                            text_y = text_y + ((tonumber(ch) or 0)*lane_z) + (2 * lane_z)
                        end
                    else
                    -- Expanded Header and X Button
                        local t_col = n and 0xAAAAAAFF or PALETTE.ONYX
                        pcall(reaper.ImGui_DrawList_AddTextEx, dl_lane, draw_font, scaled_f_sz, dev_x + (28 * lane_z), box_y + (6 * lane_z), t_col, string.sub(clean_name, 1, 16))
                        
                        local x_btn_x = dev_x + dev_w - (24 * lane_z)
                        pcall(reaper.ImGui_DrawList_AddTextEx, dl_lane, draw_font, scaled_f_sz, x_btn_x + (5 * lane_z), box_y + (6 * lane_z), t_col, "X")
                        
                        pcall(reaper.ImGui_SetCursorScreenPos, ctx, x_btn_x, box_y + (4 * lane_z))
                        UI.Safe_InvisibleButton(ctx, "del_"..f_i, 20 * lane_z, 20 * lane_z)
                        if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then 
                            if n then n.lane_guid = nil else reaper.TrackFX_Delete(state.sel_track, f_i) end
                            needs_save = true 
                        end
                    end

                    pcall(reaper.ImGui_SetCursorScreenPos, ctx, dev_x + (is_col and 0 or (28*lane_z)), box_y)
                    local drag_w = is_col and (40*lane_z) or (dev_w - (60*lane_z))
                    local drag_h = is_col and dev_h or (28*lane_z)
                    
                    pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), 0)
                    pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_ButtonHovered(), 0)
                    pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_ButtonActive(), 0)
                    pcall(reaper.ImGui_Button, ctx, "##dh_"..f_i, drag_w, drag_h)
                    pcall(reaper.ImGui_PopStyleColor, ctx, 3)

                    if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) and select(2, pcall(reaper.ImGui_IsMouseDoubleClicked, ctx, 0)) then 
                        if n then n.is_collapsed = not is_col else DeviceLane.collapsed_vst[fx_guid] = not is_col end
                        needs_save = true 
                    end
                    
                    if select(2, pcall(reaper.ImGui_BeginDragDropSource, ctx, reaper.ImGui_DragDropFlags_SourceAllowNullID())) then
                        pcall(reaper.ImGui_SetDragDropPayload, ctx, 'FX_LANE', tostring(f_i))
                        pcall(reaper.ImGui_Text, ctx, "Move " .. clean_name)
                        pcall(reaper.ImGui_EndDragDropSource, ctx)
                    end

                    if select(2, pcall(reaper.ImGui_BeginDragDropTarget, ctx)) then
                        local ok_p, rv_p, payload = pcall(reaper.ImGui_AcceptDragDropPayload, ctx, 'FX_LANE')
                        if ok_p and rv_p and payload then
                            local src_idx = tonumber(payload)
                            if src_idx and src_idx ~= f_i then state.pending_fx_move = {from = src_idx, to = f_i} end
                        end
                        pcall(reaper.ImGui_EndDragDropTarget, ctx)
                    end

                    pcall(reaper.ImGui_EndGroup, ctx)
                    pcall(reaper.ImGui_PopID, ctx)
                    pcall(reaper.ImGui_SameLine, ctx, 0, 10)
                    
                    ::skip_fx::
                end
                
                for _, an in ipairs(available_nodes) do
                    state.DeleteNode(an.node.id)
                    needs_save = true
                end
                
                pcall(reaper.ImGui_PushID, ctx, "add_fx_btn")
                pcall(reaper.ImGui_BeginGroup, ctx)
                
                -- PRO FIX: Add Button Math (Synchronized to 40px grid)
                local dev_w = math.floor(160 * lane_z)
                local dev_h = math.floor(240 * lane_z)
                local y_pad = math.floor(math.max(12, math.min(20, 16 * lane_z)))
                
                pcall(reaper.ImGui_Dummy, ctx, dev_w, dev_h + (y_pad * 2))
                local _, add_x, add_y = pcall(reaper.ImGui_GetItemRectMin, ctx)
                add_x = tonumber(add_x) or 0; add_y = tonumber(add_y) or 0
                local box_y = add_y + y_pad
                
                local is_add_hovered = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
                if is_add_hovered then pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, add_x, box_y, add_x + dev_w, box_y + dev_h, 0xFFFFFF11, 8.0 * lane_z) end
                pcall(reaper.ImGui_DrawList_AddRect, dl_lane, add_x, box_y, add_x + dev_w, box_y + dev_h, is_add_hovered and PALETTE.TANGERINE or 0x00000033, 8.0 * lane_z, 0, 2.0 * lane_z)
                
                local cx, cy = add_x + (dev_w/2), box_y + (dev_h/2)
                local rad, thick = 15 * lane_z, 4.0 * lane_z
                local plus_col = is_add_hovered and PALETTE.TANGERINE or 0x888888FF
                pcall(reaper.ImGui_DrawList_AddLine, dl_lane, cx - rad, cy, cx + rad, cy, plus_col, thick)
                pcall(reaper.ImGui_DrawList_AddLine, dl_lane, cx, cy - rad, cx, cy + rad, plus_col, thick)
                
                pcall(reaper.ImGui_SetCursorScreenPos, ctx, add_x, box_y)
                UI.Safe_InvisibleButton(ctx, "plus_btn_hitbox", dev_w, dev_h)
                if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then trigger_add_menu = true end
                
                pcall(reaper.ImGui_EndGroup, ctx)
                pcall(reaper.ImGui_PopID, ctx)
            end

            if trigger_add_menu then pcall(reaper.ImGui_OpenPopup, ctx, "lane_add_menu") end

            if select(2, pcall(reaper.ImGui_BeginPopup, ctx, "lane_add_menu")) then
                pcall(reaper.ImGui_TextColored, ctx, 0x888888FF, "Add Device")
                pcall(reaper.ImGui_Separator, ctx)
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "Native Reaper FX...")) and state.sel_track then 
                    local fxc = reaper.TrackFX_GetCount(state.sel_track)
                    if fxc > 0 then reaper.TrackFX_Show(state.sel_track, fxc - 1, 1) end
                    reaper.Main_OnCommand(40208, 0) 
                end
                pcall(reaper.ImGui_Separator, ctx)
                DrawSmartMenu(ctx, "OMM LFO", "LFO", state)
                DrawSmartMenu(ctx, "OMM Attenuator", "TRANSFER_CURVE", state)
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "OMM Compressor")) then state.AddNode("COMPRESSOR") end
                DrawSmartMenu(ctx, "OMM Gain", "GAIN", state)
                if select(2, pcall(reaper.ImGui_MenuItem, ctx, "OMM Beta Lab (Sandbox)")) then state.AddNode("BETA_LAB") end
                pcall(reaper.ImGui_EndPopup, ctx)
            end
        end
        if c_ok then pcall(reaper.ImGui_EndChild, ctx) end
        end

        -- PRO FIX: ATOMIC CLEANUP
        pcall(reaper.ImGui_SetWindowFontScale, ctx, 1.0)
        if pushed_lane_font then pcall(reaper.ImGui_PopFont, ctx) end
    end
    
    pcall(reaper.ImGui_End, ctx)
    pcall(reaper.ImGui_PopStyleColor, ctx, 1)
    
    return needs_save, state.show_canvas, is_open
end

return DeviceLane
