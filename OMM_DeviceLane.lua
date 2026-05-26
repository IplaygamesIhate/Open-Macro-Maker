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

function DeviceLane.Draw(ctx, state, UI)
    local needs_save = false
    local trigger_add_menu = false

    pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_WindowBg(), PALETTE.ASH)
    local l_flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    local ok, lane_visible, is_open = pcall(reaper.ImGui_Begin, ctx, 'OMM Device Lane', true, l_flags)
    
    if ok and lane_visible then
        local dl_lane = select(2, pcall(reaper.ImGui_GetWindowDrawList, ctx))
        local _, l_x, l_y = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
        local _, l_w, l_h = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
        l_x = tonumber(l_x) or 0; l_y = tonumber(l_y) or 0; l_w = tonumber(l_w) or 0; l_h = tonumber(l_h) or 0
        
        -- THE MASTER SPLIT-TOGGLE
        local btn_w = 34
        local half_h = l_h / 2
        pcall(reaper.ImGui_Dummy, ctx, btn_w, l_h)
        
        local canv_col = state.show_canvas and PALETTE.TANGERINE or (PALETTE.TANGERINE & 0xFFFFFF00 | 0x55)
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y, l_x + btn_w, l_y + half_h, canv_col, 0)
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, l_x, l_y)
        if UI.Safe_InvisibleButton(ctx, "canvas_toggle_btn", btn_w, half_h) then state.show_canvas = not state.show_canvas; needs_save = true end
        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y, l_x + btn_w, l_y + half_h, 0xFFFFFF33, 0)
            pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) 
        end
        local _, tw1 = pcall(reaper.ImGui_CalcTextSize, ctx, "UI")
        pcall(reaper.ImGui_DrawList_AddText, dl_lane, l_x + (btn_w/2) - ((tonumber(tw1) or 0)/2), l_y + (half_h/2) - 6, 0xFFFFFFFF, "UI")

        local dev_col = state.env.DEV_MODE and 0xFF0000FF or 0x444444FF
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y + half_h, l_x + btn_w, l_y + l_h, dev_col, 0)
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, l_x, l_y + half_h)
        if UI.Safe_InvisibleButton(ctx, "dev_toggle_btn", btn_w, half_h) then 
            state.env.DEV_MODE = not state.env.DEV_MODE
            if not state.env.DEV_MODE then state.env.active_dev_module = nil end
        end
        if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
            pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, l_x, l_y + half_h, l_x + btn_w, l_y + l_h, 0xFFFFFF33, 0)
            pcall(reaper.ImGui_SetMouseCursor, ctx, reaper.ImGui_MouseCursor_Hand()) 
        end
        local _, tw2 = pcall(reaper.ImGui_CalcTextSize, ctx, "DEV")
        pcall(reaper.ImGui_DrawList_AddText, dl_lane, l_x + (btn_w/2) - ((tonumber(tw2) or 0)/2), l_y + half_h + (half_h/2) - 6, 0xFFFFFFFF, "DEV")
        pcall(reaper.ImGui_DrawList_AddLine, dl_lane, l_x, l_y + half_h, l_x + btn_w, l_y + half_h, 0x00000066, 2.0)

        -- DEVICE LANE SCROLL AREA
        pcall(reaper.ImGui_SetCursorScreenPos, ctx, l_x + btn_w + 10, l_y)
        local child_w = math.max(1.0, l_w - btn_w - 10.0) 
        local child_h = math.max(1.0, l_h)
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
                    
                    local dev_w, dev_h = 160, 240 -- Default Fallback
                    if n and n.algo then
                        -- Pro Code: Query the Source of Truth directly
                        local schema = state.NodeUI.GetSchema(n.algo)
                        if schema then
                            dev_w = (schema.grid_cols or 4) * UI.BASE_GRID
                            dev_h = (schema.grid_rows or 4) * UI.BASE_GRID
                        end
                    end
                    
                    if is_col then
                        dev_w = 40
                    end
                    local y_offset = 10
                    local dim_factor = is_bypassed and 0.4 or 1.0
                    
                    pcall(reaper.ImGui_Dummy, ctx, dev_w, dev_h + y_offset)
                    local _, dev_x, dev_y = pcall(reaper.ImGui_GetItemRectMin, ctx)
                    dev_x = tonumber(dev_x) or 0; dev_y = tonumber(dev_y) or 0
                    local box_y = dev_y + y_offset
                    
                    if is_col or not n then
                        local chassis_col = PALETTE.TITANIUM & 0xFFFFFF00 | math.floor(0xFF * dim_factor)
                        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, chassis_col, 8.0)
                        pcall(reaper.ImGui_DrawList_AddRect, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, 0x00000033, 8.0, 0, 1.0)
                    end
                    
                    if not is_col then
                        if n then
                            local orig_alpha = state.env.act_a
                            state.env.act_a = orig_alpha * dim_factor
                            state.env.current_fx_idx = f_i
                            
                            -- PROTOCOL ZERO SEATBELT: Strict pcall wrapper. If module logic fails, the IDE survives.
                            local ok_draw, ns = pcall(state.NodeUI.DrawNodeBlock, ctx, dl_lane, n, matched_node.idx, state.nodes, state.connections, state.env, UI, state.DSP, dev_x, box_y, true)
                            if ok_draw then
                                if ns then needs_save = true end
                                pcall(reaper.ImGui_DrawList_AddRect, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, 0xFFFFFF1A, 8.0, 0, 1.0)
                            else
                                pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + dev_h, 0xFF000033, 8.0)
                                pcall(reaper.ImGui_DrawList_AddText, dl_lane, dev_x + 10, box_y + 10, 0xFF0000FF, "RENDER ERROR")
                            end
                            
                            state.env.act_a = orig_alpha
                        else
                            pcall(reaper.ImGui_SetCursorScreenPos, ctx, dev_x, box_y + 28)
                            UI.Safe_InvisibleButton(ctx, "launch_"..f_i, dev_w, dev_h - 28)
                            if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then reaper.TrackFX_Show(state.sel_track, f_i, 3) end
                            if select(2, pcall(reaper.ImGui_IsItemHovered, ctx)) then 
                                local r_bot = reaper.ImGui_DrawFlags_RoundCornersBottom and reaper.ImGui_DrawFlags_RoundCornersBottom() or 12
                                pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y + 28, dev_x + dev_w, box_y + dev_h, 0xFFFFFF44, 8.0, r_bot)
                            end
                        end
                    end
                    
                    local r_all = reaper.ImGui_DrawFlags_RoundCornersAll and reaper.ImGui_DrawFlags_RoundCornersAll() or 15
                    local r_top = reaper.ImGui_DrawFlags_RoundCornersTop and reaper.ImGui_DrawFlags_RoundCornersTop() or 3
                    local head_flags = is_col and r_all or r_top
                    if is_col or not n then
                        pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, dev_x, box_y, dev_x + dev_w, box_y + (is_col and dev_h or 28), head_col, 8.0, head_flags)
                    end
                    
                    local led_col = is_bypassed and 0x777777FF or PALETTE.TANGERINE
                    pcall(reaper.ImGui_DrawList_AddCircleFilled, dl_lane, dev_x + (is_col and 20 or 14), box_y + 14, 5, led_col)
                    pcall(reaper.ImGui_SetCursorScreenPos, ctx, dev_x + (is_col and 10 or 4), box_y + 4)
                    UI.Safe_InvisibleButton(ctx, "byp_"..f_i, 20, 20)
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
                        local text_y = box_y + 35
                        for c_i = 1, #short_name do
                            local char = short_name:sub(c_i, c_i)
                            local _, cw, ch = pcall(reaper.ImGui_CalcTextSize, ctx, char)
                            pcall(reaper.ImGui_DrawList_AddText, dl_lane, dev_x + 20 - (tonumber(cw) or 0)/2, text_y, PALETTE.ONYX, char)
                            text_y = text_y + (tonumber(ch) or 0) + 2
                        end
                    else
                        local t_col = n and 0xAAAAAAFF or PALETTE.ONYX
                        pcall(reaper.ImGui_DrawList_AddText, dl_lane, dev_x + 28, box_y + 6, t_col, string.sub(clean_name, 1, 16))
                        local x_btn_x = dev_x + dev_w - 24
                        pcall(reaper.ImGui_DrawList_AddText, dl_lane, x_btn_x + 5, box_y + 6, t_col, "X")
                        pcall(reaper.ImGui_SetCursorScreenPos, ctx, x_btn_x, box_y + 4)
                        UI.Safe_InvisibleButton(ctx, "del_"..f_i, 20, 20)
                        if select(2, pcall(reaper.ImGui_IsItemClicked, ctx)) then 
                            if n then n.lane_guid = nil else reaper.TrackFX_Delete(state.sel_track, f_i) end
                            needs_save = true 
                        end
                    end

                    pcall(reaper.ImGui_SetCursorScreenPos, ctx, dev_x + (is_col and 0 or 28), box_y)
                    local drag_w = is_col and 40 or (dev_w - 60)
                    local drag_h = is_col and dev_h or 28
                    
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
                
                local dev_w, dev_h, y_offset = 160, 240, 10
                pcall(reaper.ImGui_Dummy, ctx, dev_w, dev_h + y_offset)
                local _, add_x, add_y = pcall(reaper.ImGui_GetItemRectMin, ctx)
                add_x = tonumber(add_x) or 0; add_y = tonumber(add_y) or 0
                local box_y = add_y + y_offset
                
                local is_add_hovered = select(2, pcall(reaper.ImGui_IsItemHovered, ctx))
                if is_add_hovered then pcall(reaper.ImGui_DrawList_AddRectFilled, dl_lane, add_x, box_y, add_x + dev_w, box_y + dev_h, 0xFFFFFF11, 8.0) end
                pcall(reaper.ImGui_DrawList_AddRect, dl_lane, add_x, box_y, add_x + dev_w, box_y + dev_h, is_add_hovered and PALETTE.TANGERINE or 0x00000033, 8.0, 0, 2.0)
                
                local cx, cy = add_x + (dev_w/2), box_y + (dev_h/2)
                local rad, thick = 15, 4.0
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
    
    pcall(reaper.ImGui_End, ctx)
    pcall(reaper.ImGui_PopStyleColor, ctx, 1)
    
    return needs_save, state.show_canvas, is_open
end

return DeviceLane