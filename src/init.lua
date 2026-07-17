local Driver = require('st.driver')
local log    = require('log')
local cosock = require('cosock')
local caps   = require('st.capabilities')

local plex_api = require('plex_api')
local plexamp  = require('plexamp')

-- ─── Preferences ────────────────────────────────────────

local function get_prefs(device)
  local p = device.preferences
  if not p then return nil end  -- device being deleted or uninitialized
  return {
    server_ip   = p.plexServerIp  or '',
    server_port = tonumber(p.plexServerPort) or 32400,
    token       = p.plexToken     or '',
    amp_ip      = p.plexAmpIp    or '',
    amp_port    = tonumber(p.plexAmpPort)   or 32500,
    poll_secs   = tonumber(p.pollInterval)  or 30,
  }
end

local function prefs_valid(p)
  if not p then return false end
  return p.server_ip ~= '' and p.token ~= '' and p.amp_ip ~= ''
end

-- ─── Source name sanitization ────────────────────────────

local function sanitize_name(s)
  s = s:gsub('&#39;',   "'")
  s = s:gsub('&amp;',   '&')
  s = s:gsub('&lt;',    '<')
  s = s:gsub('&gt;',    '>')
  s = s:gsub('&quot;',  '"')
  s = s:gsub('&#%d+;',  '')
  s = s:gsub('&#x%x+;', '')
  s = s:gsub('&%w+;',   '')
  s = s:gsub('[^\32-\126]', '')
  s = s:match('^%s*(.-)%s*$')
  return s
end

-- ─── State updates ──────────────────────────────────────

local function update_now_playing(device)
  local p = get_prefs(device)
  if not prefs_valid(p) then return end

  local info, err = plexamp.get_now_playing(p.amp_ip, p.amp_port)
  if err then
    log.warn('[plexamp] get_now_playing: ' .. err)
    return
  end

  local state = info.state or 'stopped'
  if state == 'playing' then
    device:emit_event(caps.mediaPlayback.playbackStatus.playing())
  elseif state == 'paused' then
    device:emit_event(caps.mediaPlayback.playbackStatus.paused())
  else
    device:emit_event(caps.mediaPlayback.playbackStatus.stopped())
  end

  local track_data = {}
  if info.title  then track_data.title  = info.title  end
  if info.artist then track_data.artist = info.artist end
  if info.album  then track_data.album  = info.album  end
  local playlist_name = device:get_field('current_playlist')
  if playlist_name then track_data.mediaSource = playlist_name end
  if not next(track_data) then
    local state = info.state or 'stopped'
    track_data.title = state == 'paused' and 'Paused' or 'Not playing'
  end
  device:emit_event(caps.audioTrackData.audioTrackData({value = track_data}))

  if info.volume then
    local vol = tonumber(info.volume)
    if vol then
      device:emit_event(caps.audioVolume.volume({value = math.floor(vol)}))
    end
  end
end

local function load_playlists(device)
  local p = get_prefs(device)
  if not prefs_valid(p) then
    log.warn('[plexamp] Preferences not yet configured — skipping playlist load')
    return
  end

  local playlists, err = plex_api.get_playlists(p.server_ip, p.server_port, p.token)
  if err then
    log.error('[plexamp] get_playlists: ' .. err)
    return
  end

  -- Build preset list: {id = rating_key, name = display_name}
  -- id is used by playPreset command; name is shown in the app
  local preset_list  = {}
  local playlist_map = {}  -- keyed by rating_key string
  local seen_names   = {}

  for _, pl in ipairs(playlists) do
    local name = sanitize_name(pl.title)
    if name == '' then name = 'Playlist' end
    -- deduplicate display names
    if seen_names[name] then
      local i = 2
      while seen_names[name .. ' ' .. i] do i = i + 1 end
      name = name .. ' ' .. i
    end
    seen_names[name] = true

    local id = tostring(pl.rating_key)
    table.insert(preset_list, {id = id, name = name})
    playlist_map[id] = pl
  end

  if #preset_list > 0 then
    device:emit_event(caps.mediaPresets.presets({value = preset_list}))
  end
  device:set_field('playlists', playlist_map, {persist = true})
  log.info('[plexamp] Loaded ' .. #preset_list .. ' playlists as presets')

  if not device:get_field('machine_id') then
    local mid = plex_api.get_machine_id(p.server_ip, p.server_port, p.token)
    if mid then device:set_field('machine_id', mid, {persist = true}) end
  end
end

-- ─── Polling ────────────────────────────────────────────

local function start_polling(driver, device)
  cosock.spawn(function()
    cosock.socket.sleep(2)
    load_playlists(device)
    update_now_playing(device)
    while true do
      local p = get_prefs(device)
      if not p then
        log.info('[plexamp] polling stopped — device no longer valid')
        return
      end
      cosock.socket.sleep(p.poll_secs)
      update_now_playing(device)
    end
  end, 'poll-' .. device.id)
end

-- ─── Capability handlers ─────────────────────────────────

local function cmd_play(driver, device, cmd)
  local p = get_prefs(device)
  local _, err = plexamp.play(p.amp_ip, p.amp_port)
  if err then log.error('[plexamp] play: ' .. err); return end
  device:emit_event(caps.mediaPlayback.playbackStatus.playing())
end

local function cmd_pause(driver, device, cmd)
  local p = get_prefs(device)
  local _, err = plexamp.pause(p.amp_ip, p.amp_port)
  if err then log.error('[plexamp] pause: ' .. err); return end
  device:emit_event(caps.mediaPlayback.playbackStatus.paused())
end

local function cmd_stop(driver, device, cmd)
  local p = get_prefs(device)
  local _, err = plexamp.stop(p.amp_ip, p.amp_port)
  if err then log.error('[plexamp] stop: ' .. err); return end
  device:emit_event(caps.mediaPlayback.playbackStatus.stopped())
end

local function cmd_next(driver, device, cmd)
  local p = get_prefs(device)
  local _, err = plexamp.next_track(p.amp_ip, p.amp_port)
  if err then log.error('[plexamp] next: ' .. err); return end
  cosock.socket.sleep(1)
  update_now_playing(device)
end

local function cmd_prev(driver, device, cmd)
  local p = get_prefs(device)
  local _, err = plexamp.previous_track(p.amp_ip, p.amp_port)
  if err then log.error('[plexamp] prev: ' .. err); return end
  cosock.socket.sleep(1)
  update_now_playing(device)
end

local function cmd_volume(driver, device, cmd)
  local p = get_prefs(device)
  local vol = cmd.args.volume or cmd.args.level or 50
  local _, err = plexamp.set_volume(p.amp_ip, p.amp_port, vol)
  if err then log.error('[plexamp] volume: ' .. err); return end
  device:emit_event(caps.audioVolume.volume({value = vol}))
end

local function cmd_play_preset(driver, device, cmd)
  local p = get_prefs(device)
  local rating_key = cmd.args.presetId

  local playlists = device:get_field('playlists') or {}
  local playlist  = playlists[rating_key]
  if not playlist then
    log.error('[plexamp] Unknown preset id: ' .. tostring(rating_key))
    return
  end

  local machine_id = device:get_field('machine_id')
  if not machine_id then
    machine_id = plex_api.get_machine_id(p.server_ip, p.server_port, p.token)
    if machine_id then
      device:set_field('machine_id', machine_id, {persist = true})
    else
      log.error('[plexamp] Could not get machine ID')
      return
    end
  end

  log.info('[plexamp] Starting playlist: ' .. tostring(playlist.title))
  local _, err = plexamp.play_playlist(
    p.amp_ip, p.amp_port,
    p.server_ip, p.server_port,
    machine_id, playlist.rating_key, p.token
  )
  if err then log.error('[plexamp] play_playlist: ' .. err); return end

  device:set_field('current_playlist', sanitize_name(playlist.title))
  cosock.socket.sleep(3)
  update_now_playing(device)
end

local function cmd_refresh(driver, device, cmd)
  load_playlists(device)
  update_now_playing(device)
end

-- ─── Lifecycle ──────────────────────────────────────────

local function device_added(driver, device)
  log.info('[plexamp] added: ' .. device.label)
  device:emit_event(caps.mediaPlayback.playbackStatus.stopped())
  device:emit_event(caps.audioTrackData.audioTrackData({value = {title = 'Not playing'}}))
  device:emit_event(caps.audioVolume.volume({value = 50}))
  device:emit_event(caps.mediaPresets.presets({value = {}}))
end

local function device_init(driver, device)
  log.info('[plexamp] init: ' .. device.label)
  device:online()
  start_polling(driver, device)
end

local function device_removed(driver, device)
  log.info('[plexamp] removed: ' .. device.label)
end

local function device_info_changed(driver, device, event)
  log.info('[plexamp] preferences changed — reloading playlists')
  load_playlists(device)
end

-- ─── Discovery ──────────────────────────────────────────

local function handle_discovery(driver, _opts, should_continue)
  log.info('[plexamp] discovery')
  local ok, err = driver:try_create_device({
    type              = 'LAN',
    device_network_id = 'plexamp-player',
    label             = 'PlexAmp Player',
    profile           = 'plexamp-player',
    manufacturer      = 'Plex',
    model             = 'PlexAmp Headless',
  })
  if not ok then
    local msg = tostring(err)
    if msg:find('DNI already exists') then
      log.info('[plexamp] device already registered — skipping creation')
    else
      log.error('[plexamp] try_create_device: ' .. msg)
    end
  end
end

-- ─── Driver ─────────────────────────────────────────────

local driver = Driver('PlexAmp Player', {
  discovery = handle_discovery,
  lifecycle_handlers = {
    init        = device_init,
    added       = device_added,
    removed     = device_removed,
    infoChanged = device_info_changed,
  },
  capability_handlers = {
    [caps.mediaPlayback.ID] = {
      [caps.mediaPlayback.commands.play.NAME]  = cmd_play,
      [caps.mediaPlayback.commands.pause.NAME] = cmd_pause,
      [caps.mediaPlayback.commands.stop.NAME]  = cmd_stop,
    },
    [caps.mediaTrackControl.ID] = {
      [caps.mediaTrackControl.commands.nextTrack.NAME]     = cmd_next,
      [caps.mediaTrackControl.commands.previousTrack.NAME] = cmd_prev,
    },
    [caps.audioVolume.ID] = {
      [caps.audioVolume.commands.setVolume.NAME] = cmd_volume,
    },
    [caps.mediaPresets.ID] = {
      [caps.mediaPresets.commands.playPreset.NAME] = cmd_play_preset,
    },
    [caps.refresh.ID] = {
      [caps.refresh.commands.refresh.NAME] = cmd_refresh,
    },
  },
})

driver:run()
