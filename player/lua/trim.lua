local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    ffmpeg = "ffmpeg",
    ffprobe = "ffprobe",
}
options.read_options(o, "trim")

local in_mark
local out_mark
local active_scan
local generation = 0

local function osd(text)
    mp.osd_message(text, 3000)
end

local function brief_error(text)
    text = tostring(text or "unknown error"):gsub("%s+$", "")
    if #text > 400 then
        text = text:sub(1, 400) .. "…"
    end
    return text
end

local function get_source()
    local path = mp.get_property("path")
    if not path or path == "" or path == "-" or path:find("://", 1, true) then
        osd("Trim supports local files only")
        return nil
    end

    if mp.get_property_native("demuxer-via-network") then
        osd("Trim supports local files only")
        return nil
    end

    local tracks = mp.get_property_native("track-list") or {}
    for _, track in ipairs(tracks) do
        if track.type == "video" and track.selected and track["ff-index"] ~= nil then
            if path:sub(1, 1) == "-" then
                path = "./" .. path
            end
            return path, track["ff-index"], track.codec
        end
    end

    osd("Trim requires a selected video track")
    return nil
end

local function choose_keyframe(frames, time)
    local nearest
    local distance
    for _, frame_time in ipairs(frames) do
        local current_distance = math.abs(frame_time - time)
        if not distance or current_distance < distance then
            nearest = frame_time
            distance = current_distance
        end
    end
    return nearest
end

local function scan_keyframes(path, stream_index, callback)
    local cached = active_scan
    if cached and cached.path == path and cached.stream_index == stream_index then
        if cached.frames then
            callback(cached.frames)
        else
            table.insert(cached.callbacks, callback)
        end
        return
    end

    local scan = {
        path = path,
        stream_index = stream_index,
        callbacks = {callback},
    }
    active_scan = scan

    osd("Finding video keyframes…")
    mp.command_native_async({
        _name = "subprocess",
        args = {
            o.ffprobe,
            "-v", "error",
            "-select_streams", tostring(stream_index),
            "-skip_frame", "nokey",
            "-show_frames",
            "-show_format",
            "-show_entries", "frame=best_effort_timestamp_time:format=start_time",
            "-of", "json",
            path,
        },
        capture_stdout = true,
        capture_stderr = true,
        capture_size = 64 * 1024 * 1024,
    }, function(success, result, err)
        if active_scan ~= scan then
            return
        end

        if not success or not result or result.status ~= 0 then
            local detail = result and result.stderr or err or "ffprobe failed"
            msg.error("Could not read keyframes: " .. brief_error(detail))
            osd("Could not read keyframes; see the log")
            active_scan = nil
            return
        end

        local data, parse_error = utils.parse_json(result.stdout or "")
        if not data or type(data.frames) ~= "table" then
            msg.error("Could not parse ffprobe keyframe output: " .. tostring(parse_error))
            osd("Could not parse keyframes; see the log")
            active_scan = nil
            return
        end

        local origin = tonumber(data.format and data.format.start_time)
        local raw_times = {}
        for _, frame in ipairs(data.frames) do
            local timestamp = tonumber(frame.best_effort_timestamp_time)
            if timestamp then
                table.insert(raw_times, timestamp)
                if not origin then
                    origin = timestamp
                end
            end
        end

        if #raw_times == 0 then
            msg.error("ffprobe found no video keyframes in " .. path)
            osd("No video keyframes found")
            active_scan = nil
            return
        end

        origin = origin or 0
        scan.frames = {}
        for _, timestamp in ipairs(raw_times) do
            table.insert(scan.frames, timestamp - origin)
        end

        local callbacks = scan.callbacks
        scan.callbacks = {}
        for _, queued_callback in ipairs(callbacks) do
            queued_callback(scan.frames)
        end
    end)
end

local function seek_to(time)
    mp.commandv("seek", string.format("%.6f", time), "absolute+exact")
end

local function mark(which)
    local source, stream_index, codec = get_source()
    local time = mp.get_property_number("time-pos")
    if not source or not time then
        return
    end

    local mark_generation = generation
    scan_keyframes(source, stream_index, function(frames)
        if mark_generation ~= generation then
            return
        end

        local snapped = choose_keyframe(frames, time)
        if not snapped then
            osd("No video keyframes found")
            return
        end

        seek_to(snapped)
        if which == "start" then
            in_mark = snapped
            out_mark = nil
            osd(string.format("Trim start: %.3f s (keyframe)", snapped))
            return
        end

        if not in_mark then
            osd("Mark the trim start first with Ctrl+I")
            return
        end
        if snapped <= in_mark then
            osd("Trim end must be after the start")
            return
        end

        out_mark = snapped
        local start_time = in_mark
        local end_time = out_mark
        osd(string.format("Trim: %.3f–%.3f s; saving…", start_time, end_time))

        -- Write to the temp directory; the source's directory may be read-only.
        local directory = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
        if not directory:find("[/\\]$") then
            directory = directory .. "/"
        end
        local filename = source:match("([^/\\]+)$") or source
        local stem, extension = filename:match("^(.*)(%.[^%.]+)$")
        if not stem then
            stem = filename
            extension = ".mkv"
        end

        local function stamp(value)
            return string.format("%.3f", value):gsub("%.", "p"):gsub("%-", "m")
        end
        local output = directory .. stem .. "-trim-" .. stamp(start_time) .. "-" ..
                       stamp(end_time) .. extension
        if output:sub(1, 1) == "-" then
            output = "./" .. output
        end

        local args = {
            o.ffmpeg,
            "-nostdin", "-hide_banner", "-loglevel", "error", "-n",
            "-ss", string.format("%.6f", start_time),
            "-i", source,
            "-t", string.format("%.6f", end_time - start_time),
            "-map", "0", "-c", "copy",
            "-map_metadata", "0", "-map_chapters", "-1",
            "-avoid_negative_ts", "make_zero",
        }
        -- Apple software (Finder, QuickLook) only recognizes HEVC in MP4/MOV
        -- when the sample entry is hvc1; ffmpeg keeps hev1 when copying from
        -- e.g. MKV, which leaves the file without a thumbnail.
        local lower = extension:lower()
        if codec == "hevc" and (lower == ".mp4" or lower == ".m4v" or lower == ".mov") then
            table.insert(args, "-tag:" .. stream_index)
            table.insert(args, "hvc1")
        end
        table.insert(args, output)

        local trim_generation = generation
        mp.command_native_async({
            _name = "subprocess",
            args = args,
            capture_stderr = true,
            capture_size = 1024 * 1024,
            playback_only = false,
        }, function(success, result, err)
            if trim_generation ~= generation then
                return
            end
            if success and result and result.status == 0 then
                msg.info("Saved stream-copy trim to " .. output)
                osd("Trim saved: " .. output)
            else
                local detail = result and result.stderr or err or "ffmpeg failed"
                msg.error("Trim failed: " .. brief_error(detail))
                osd("Trim failed; see the log")
            end
        end)
    end)
end

local function clear_marks()
    in_mark = nil
    out_mark = nil
    osd("Trim marks cleared")
end

mp.register_event("start-file", function()
    generation = generation + 1
    in_mark = nil
    out_mark = nil
    active_scan = nil
end)

mp.add_key_binding("Ctrl+i", "mark-start", function() mark("start") end)
mp.add_key_binding("Ctrl+o", "mark-end", function() mark("end") end)
mp.add_key_binding("Ctrl+Shift+x", "clear-marks", clear_marks)
