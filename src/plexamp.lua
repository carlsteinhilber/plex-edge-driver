--- plexamp.lua
--- Controls a headless PlexAmp instance via the Plex Player HTTP API.
--- Uses raw cosock TCP sockets for HTTP — socket.http / ltn12 are not
--- reliably available in the SmartThings Edge Driver runtime.

local log    = require('log')
local cosock = require('cosock')

local plex_api = require('plex_api')

local M = {}

-- ─────────────────────────────────────────────
-- Internal state
-- ─────────────────────────────────────────────

local _cmd_id = 0
local function next_cmd_id()
  _cmd_id = _cmd_id + 1
  return _cmd_id
end

-- ─────────────────────────────────────────────
-- Raw TCP HTTP client
-- ─────────────────────────────────────────────

--- Send a GET to PlexAmp using a raw cosock TCP socket.
--- path: e.g. '/player/playback/pause'
--- extra_params: additional query parameters (optional table)
--- Returns: body string, error string
local function amp_get(amp_ip, amp_port, path, extra_params)
  local params = { commandID = next_cmd_id() }
  for k, v in pairs(extra_params or {}) do
    params[k] = v
  end

  local query    = plex_api.build_query(params)
  local full_path = path .. '?' .. query

  local client, err = cosock.socket.tcp()
  if not client then
    return nil, 'tcp() failed: ' .. tostring(err)
  end

  client:settimeout(5)
  local ok, connect_err = client:connect(amp_ip, amp_port)
  if not ok then
    client:close()
    return nil, 'connect ' .. amp_ip .. ':' .. tostring(amp_port) .. ' failed: ' .. tostring(connect_err)
  end

  local request = table.concat({
    'GET ' .. full_path .. ' HTTP/1.1',
    'Host: ' .. amp_ip .. ':' .. tostring(amp_port),
    'X-Plex-Client-Identifier: smartthings-plex-edge-driver',
    'X-Plex-Product: SmartThings Edge Driver',
    'X-Plex-Version: 1.0',
    'Connection: close',
    '', '',
  }, '\r\n')

  client:send(request)

  -- Read until we have a complete HTTP response (don't wait for connection close)
  local response = ''
  local hdr_end  = nil
  local clen     = nil
  while true do
    local chunk, _, partial = client:receive(4096)
    local data = chunk or (partial ~= '' and partial) or nil
    if data then
      response = response .. data
      if not hdr_end then
        hdr_end = response:find('\r\n\r\n')
        if hdr_end then
          clen = tonumber(response:match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
        end
      end
      if hdr_end and clen ~= nil then
        if #response - (hdr_end + 3) >= clen then break end
      end
    end
    if not chunk then break end
  end
  client:close()

  local status = tonumber(response:match('^HTTP/%S+ (%d+)'))

  if not status or (status ~= 200 and status ~= 204) then
    return nil, 'PlexAmp HTTP status ' .. tostring(status or 'unknown')
  end

  local body = response:match('\r\n\r\n(.*)') or ''
  return body, nil
end

-- ─────────────────────────────────────────────
-- Playback commands
-- ─────────────────────────────────────────────

--- Start playing a playlist on PlexAmp immediately.
function M.play_playlist(amp_ip, amp_port, server_ip, server_port, machine_id, rating_key, token)
  local key = '/playlists/' .. rating_key .. '/items'
  local uri = string.format(
    'server://%s/com.plexapp.plugins.library/playlists/%s/items',
    machine_id, rating_key
  )

  return amp_get(amp_ip, amp_port, '/player/playback/playMedia', {
    type              = 'music',
    shuffle           = '1',
    ['repeat']        = '0',
    key               = key,
    containerKey      = key,
    machineIdentifier = machine_id,
    address           = server_ip,
    port              = tostring(server_port),
    protocol          = 'http',
    uri               = uri,
    ['X-Plex-Token']  = token,
  })
end

function M.play(amp_ip, amp_port)
  return amp_get(amp_ip, amp_port, '/player/playback/play')
end

function M.pause(amp_ip, amp_port)
  return amp_get(amp_ip, amp_port, '/player/playback/pause')
end

function M.stop(amp_ip, amp_port)
  return amp_get(amp_ip, amp_port, '/player/playback/stop')
end

function M.next_track(amp_ip, amp_port)
  return amp_get(amp_ip, amp_port, '/player/playback/skipNext')
end

function M.previous_track(amp_ip, amp_port)
  return amp_get(amp_ip, amp_port, '/player/playback/skipPrevious')
end

function M.set_volume(amp_ip, amp_port, volume)
  local v = math.max(0, math.min(100, math.floor(tonumber(volume) or 50)))
  return amp_get(amp_ip, amp_port, '/player/playback/setParameters', {
    volume = tostring(v),
  })
end

-- ─────────────────────────────────────────────
-- Now-playing state
-- ─────────────────────────────────────────────

--- Poll PlexAmp for current playback state.
--- Returns: info table, error
function M.get_now_playing(amp_ip, amp_port)
  local body, err = amp_get(amp_ip, amp_port, '/player/timeline/poll', {
    wait            = '0',
    includeMetadata = '1',
  })

  if err then
    return nil, err
  end

  local info = { state = 'stopped' }

  -- Timeline tag holds state/volume/position; Track child holds title/artist/album
  for attrs in body:gmatch('<Timeline%s+([^>]+)') do
    if plex_api.parse_attr(attrs, 'type') == 'music' then
      info.state    = plex_api.parse_attr(attrs, 'state') or 'stopped'
      info.time     = tonumber(plex_api.parse_attr(attrs, 'time'))
      info.duration = tonumber(plex_api.parse_attr(attrs, 'duration'))
      info.volume   = plex_api.parse_attr(attrs, 'volume')
      break
    end
  end

  -- Track metadata is on the nested <Track> element
  local track_attrs = body:match('<Track%s+([^>]+)')
  if track_attrs then
    info.title  = plex_api.xml_unescape(plex_api.parse_attr(track_attrs, 'title'))
    info.artist = plex_api.xml_unescape(plex_api.parse_attr(track_attrs, 'grandparentTitle'))
    info.album  = plex_api.xml_unescape(plex_api.parse_attr(track_attrs, 'parentTitle'))
  end

  return info, nil
end

return M
