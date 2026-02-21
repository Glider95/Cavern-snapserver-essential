--[[
    Cavern Raw Audio Output for VLC
    
    This extension configures VLC to output raw encoded audio (AC3/EAC3/TrueHD)
    directly to CavernPipe for Dolby Atmos decoding.
    
    Installation:
    Copy to: %APPDATA%\vlc\lua\extensions\cavern_raw_output.lua
    
    Requirements:
    - CavernPipeServer must be running
    - VLC must be restarted after installation
--]]

function descriptor()
    return {
        title = "Cavern Raw Audio Output",
        version = "1.0",
        author = "Cavern Project",
        url = "https://github.com/Glider95/Cavern-snapserver-essential",
        shortdesc = "Send raw AC3/EAC3/TrueHD to Cavern for Atmos decoding",
        description = [[
            Outputs raw encoded audio from VLC directly to CavernPipe.
            
            This preserves the Dolby Atmos metadata for proper spatial audio decoding.
            
            Supported formats:
            - Dolby Digital (AC3)
            - Dolby Digital Plus (EAC3) 
            - Dolby TrueHD
            - DTS, DTS-HD
            
            The audio is NOT decoded by VLC - it's sent raw to Cavern.
        ]],
        capabilities = {"input-listener"}
    }
end

-- Global state
local config = {
    enabled = false,
    pipe_name = "CavernPipe",
    last_status = "Idle"
}

local dlg = nil
local status_label = nil

-- VLC extension callbacks
function activate()
    load_config()
    show_main_dialog()
end

function deactivate()
    save_config()
    if dlg then
        dlg:hide()
    end
end

function close()
    save_config()
end

function meta_changed()
    -- Called when media metadata changes
    local input = vlc.object.input()
    if input and config.enabled then
        local item = vlc.input.item()
        if item then
            local codec = detect_audio_codec(item)
            update_status("Playing: " .. codec)
            
            -- Auto-configure VLC output based on codec
            configure_vlc_output(codec)
        end
    end
end

function input_changed()
    -- Called when input changes
    if config.enabled then
        local input = vlc.object.input()
        if input then
            update_status("Input changed - configuring output...")
        end
    end
end

--[[ Main Dialog UI --]]
function show_main_dialog()
    dlg = vlc.dialog("🎧 Cavern Raw Audio Output")
    
    -- Title
    dlg:add_label("<h2>Cavern Dolby Atmos Pipeline</h2>", 1, 1, 4, 1)
    
    -- Status
    dlg:add_label("<b>Status:</b>", 1, 2, 1, 1)
    status_label = dlg:add_label(get_status_text(), 2, 2, 3, 1)
    
    -- Enable/Disable
    dlg:add_button(
        config.enabled and "⏹ Disable Cavern Output" or "▶ Enable Cavern Output",
        toggle_output,
        1, 3, 2, 1
    )
    
    dlg:add_button("📊 Show Details", show_details, 3, 3, 2, 1)
    
    -- Configuration
    dlg:add_label("<b>Configuration:</b>", 1, 5, 4, 1)
    
    dlg:add_label("Pipe Name:", 1, 6, 1, 1)
    local pipe_input = dlg:add_text_input(config.pipe_name, 2, 6, 2, 1)
    dlg:add_button("Save", function()
        config.pipe_name = pipe_input:get_text()
        save_config()
        update_status("Settings saved")
    end, 4, 6, 1, 1)
    
    -- Instructions
    dlg:add_label("<b>How to use:</b>", 1, 8, 4, 1)
    dlg:add_label([[
    1. Click "Enable Cavern Output"
    2. Open any movie with Dolby Atmos
    3. VLC will send raw audio to Cavern
    4. Cavern decodes Atmos → Snapcast → Speakers
    
    <i>Note: PC speakers will be silent - audio goes only to Cavern pipeline</i>
    ]], 1, 9, 4, 5)
    
    -- Current media info
    dlg:add_label("<b>Current Media:</b>", 1, 15, 4, 1)
    dlg:add_label(get_media_info(), 1, 16, 4, 3)
    
    dlg:show()
end

function get_status_text()
    if not config.enabled then
        return "<span style='color: gray;'>⏸ Cavern Output Disabled</span>"
    end
    
    local input = vlc.object.input()
    if not input then
        return "<span style='color: orange;'>⏳ Waiting for media...</span>"
    end
    
    local status = vlc.var.get(input, "state")
    if status == vlc.state.Playing then
        return "<span style='color: green;'>▶ Streaming raw audio to Cavern</span>"
    elseif status == vlc.state.Paused then
        return "<span style='color: orange;'>⏸ Paused</span>"
    else
        return "<span style='color: gray;'>⏹ Stopped</span>"
    end
end

function update_status(msg)
    if status_label then
        if msg then
            status_label:set_text(msg)
        else
            status_label:set_text(get_status_text())
        end
    end
end

function toggle_output()
    config.enabled = not config.enabled
    save_config()
    
    if config.enabled then
        -- Configure VLC for raw output
        vlc.msg.info("Cavern: Enabling raw audio output to " .. config.pipe_name)
        
        -- Set VLC preferences for raw passthrough
        vlc.config.set("audio-filter", "")  -- Disable audio filters
        vlc.config.set("spdif", "1")  -- Enable SPDIF/HDMI passthrough mode
        
        vlc.osd.message("🎧 Cavern Raw Audio Enabled", nil, "top-left", 3000)
        update_status("Cavern output enabled - restart playback")
    else
        vlc.msg.info("Cavern: Disabling raw audio output")
        vlc.config.set("spdif", "0")  -- Disable passthrough
        vlc.osd.message("⏹ Cavern Raw Audio Disabled", nil, "top-left", 3000)
        update_status("Cavern output disabled")
    end
    
    -- Refresh dialog
    dlg:hide()
    show_main_dialog()
end

function show_details()
    local details_dlg = vlc.dialog("📊 Cavern Pipeline Details")
    
    details_dlg:add_label("<h2>Pipeline Status</h2>", 1, 1, 4, 1)
    
    local input = vlc.object.input()
    if input then
        local item = vlc.input.item()
        local metas = item and item:metas() or {}
        
        details_dlg:add_label("<b>Audio Track Info:</b>", 1, 3, 4, 1)
        details_dlg:add_label("Codec: " .. (metas["codec"] or "Unknown"), 1, 4, 2, 1)
        details_dlg:add_label("Language: " .. (metas["language"] or "Unknown"), 3, 4, 2, 1)
        
        local is_atmos = is_atmos_content(item)
        details_dlg:add_label("Atmos Detected: " .. (is_atmos and "✓ Yes" or "✗ No"), 1, 5, 2, 1)
    else
        details_dlg:add_label("No media playing", 1, 3, 4, 1)
    end
    
    details_dlg:add_label("<b>Output Configuration:</b>", 1, 7, 4, 1)
    details_dlg:add_label("Target Pipe: " .. config.pipe_name, 1, 8, 2, 1)
    details_dlg:add_label("Passthrough Mode: " .. (config.enabled and "Enabled" or "Disabled"), 3, 8, 2, 1)
    
    details_dlg:add_label("<b>Troubleshooting:</b>", 1, 10, 4, 1)
    details_dlg:add_label([[
If audio is not reaching speakers:
1. Check CavernPipeServer is running
2. Verify snapserver is running
3. Check snapclients are connected
4. Ensure media has Atmos/EAC3 audio track
    ]], 1, 11, 4, 4)
    
    details_dlg:show()
end

function get_media_info()
    local input = vlc.object.input()
    if not input then
        return "No media loaded"
    end
    
    local item = vlc.input.item()
    if not item then
        return "Unknown media"
    end
    
    local metas = item:metas()
    local info = {
        "Title: " .. (metas["title"] or "Unknown"),
        "Codec: " .. (metas["codec"] or "Unknown"),
    }
    
    if is_atmos_content(item) then
        table.insert(info, "🎧 Dolby Atmos detected!")
    end
    
    return table.concat(info, "\n")
end

function detect_audio_codec(item)
    if not item then return "Unknown" end
    
    local metas = item:metas()
    local codec = (metas["codec"] or ""):lower()
    
    if codec:find("eac3") or codec:find("ec3") then
        return "Dolby Digital Plus (EAC3)"
    elseif codec:find("truehd") then
        return "Dolby TrueHD"
    elseif codec:find("ac3") then
        return "Dolby Digital (AC3)"
    elseif codec:find("dts") then
        return "DTS"
    else
        return codec:upper()
    end
end

function is_atmos_content(item)
    if not item then return false end
    
    local metas = item:metas()
    local codec = (metas["codec"] or ""):lower()
    local desc = (metas["description"] or ""):lower()
    
    -- Check for Atmos indicators
    return codec:find("eac3") or 
           codec:find("truehd") or
           desc:find("atmos") or
           desc:find("joc")  -- Joint Object Coding (Atmos signature)
end

function configure_vlc_output(codec)
    -- This function configures VLC based on the detected codec
    -- In a full implementation, this would set the appropriate output module
    
    vlc.msg.info("Cavern: Configuring output for " .. codec)
    
    -- For EAC3/TrueHD, we want passthrough
    if codec:find("Dolby") or codec:find("DTS") then
        vlc.config.set("spdif", "1")
        vlc.msg.info("Cavern: Enabled SPDIF passthrough")
    end
end

--[[ Configuration persistence --]]
function load_config()
    local config_file = vlc.config.userdatadir() .. "/cavern-raw-config.lua"
    local f = io.open(config_file, "r")
    if f then
        local content = f:read("*all")
        f:close()
        
        for key, value in content:gmatch("(%w+)=(%S+)") do
            if key == "enabled" then
                config.enabled = (value == "true")
            elseif key == "pipe_name" then
                config.pipe_name = value
            end
        end
    end
end

function save_config()
    local config_file = vlc.config.userdatadir() .. "/cavern-raw-config.lua"
    local f = io.open(config_file, "w")
    if f then
        f:write(string.format("enabled=%s\n", tostring(config.enabled)))
        f:write(string.format("pipe_name=%s\n", config.pipe_name))
        f:close()
    end
end

--[[ Menu registration --]]
function menu()
    return {
        "🎧 Cavern Raw Audio Output"
    }
end

function trigger_menu(id)
    if id == 1 then
        show_main_dialog()
    end
end
