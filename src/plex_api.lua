--- plex_api.lua
--- Handles all communication with the Plex Media Server REST API.
--- Uses raw cosock TCP sockets for HTTP — socket.http / ltn12 are not
--- reliably available in the SmartThings Edge Driver runtime.

local log    = require('log')
local cosock = require('cosock')

local M = {}

-- ─────────────────────────────────────────────
-- Shared utilities
-- ─────────────────────────────────────────────

--- Percent-encode a string for use in a URL.
local function url_encode(str)
  if not str then return '' end
  str = tostring(str)
  return str:gsub('[^%w%-%.%_%~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
end
M.url_encode = url_encode

--- Build a query string from a key→value table.
local function build_query(params)
  local parts = {}
  for k, v in pairs(params) do
    table.insert(parts, url_encode(tostring(k)) .. '=' .. url_encode(tostring(v)))
  end
  return table.concat(parts, '&')
end
M.build_query = build_query

--- Unescape the five basic XML character entities.
local function xml_unescape(s)
  if not s then return s end
  return (s:gsub('&amp;',  '&')
           :gsub('&lt;',   '<')
           :gsub('&gt;',   '>')
           :gsub('&quot;', '"')
           :gsub('&apos;', "'"))
end
M.xml_unescape = xml_unescape

--- Extract a named attribute value from an XML attribute string.
local function parse_attr(attrs, name)
  return attrs:match(name .. '="([^"]*)"')
      or attrs:match(name .. "='([^']*)'")
end
M.parse_attr = parse_attr

-- ─────────────────────────────────────────────
-- Raw TCP HTTP client
-- ─────────────────────────────────────────────

--- Perform an HTTP GET using a raw cosock TCP socket.
--- host: IP address string
--- port: integer
--- path: URL path + query string, e.g. "/playlists/all?X-Plex-Token=xxx"
--- Returns: body string, error string (one will be nil)
local function http_get(host, port, path)
  local client, err = cosock.socket.tcp()
  if not client then
    return nil, 'tcp() failed: ' .. tostring(err)
  end

  client:settimeout(10)

  local ok, connect_err = client:connect(host, port)
  if not ok then
    client:close()
    return nil, 'connect ' .. host .. ':' .. tostring(port) .. ' failed: ' .. tostring(connect_err)
  end

  local request = table.concat({
    'GET ' .. path .. ' HTTP/1.1',
    'Host: ' .. host .. ':' .. tostring(port),
    'Accept: application/xml',
    'X-Plex-Client-Identifier: smartthings-plex-edge-driver',
    'X-Plex-Product: SmartThings Edge Driver',
    'X-Plex-Version: 1.0',
    'Connection: close',
    '', '',          -- blank line terminates headers
  }, '\r\n')

  client:send(request)

  -- Read until the connection closes
  local chunks = {}
  while true do
    local chunk, recv_err, partial = client:receive(4096)
    if chunk then
      table.insert(chunks, chunk)
    else
      if partial and #partial > 0 then
        table.insert(chunks, partial)
      end
      break
    end
  end
  client:close()

  local response = table.concat(chunks)

  -- Check HTTP status
  local status = tonumber(response:match('^HTTP/%S+ (%d+)'))
  if not status or (status ~= 200 and status ~= 204) then
    return nil, 'HTTP status ' .. tostring(status or 'unknown')
  end

  -- Return body (everything after the blank header line)
  local body = response:match('\r\n\r\n(.*)') or ''
  return body, nil
end
M.http_get = http_get

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

--- Fetch all audio playlists from the Plex server.
--- Returns: list of {title, rating_key, key, leaf_count}, error
function M.get_playlists(server_ip, server_port, token)
  local path = '/playlists/all?playlistType=audio&X-Plex-Token=' .. url_encode(token)
  local body, err = http_get(server_ip, server_port, path)
  if err then
    return nil, 'get_playlists: ' .. err
  end

  local playlists = {}
  for attrs in body:gmatch('<Playlist%s+([^>]+)') do
    local playlist_type = parse_attr(attrs, 'playlistType')
    if playlist_type == 'audio' then
      local title      = xml_unescape(parse_attr(attrs, 'title'))
      local rating_key = parse_attr(attrs, 'ratingKey')
      local key        = parse_attr(attrs, 'key')
      local leaf_count = tonumber(parse_attr(attrs, 'leafCount')) or 0
      if title and rating_key then
        table.insert(playlists, {
          title      = title,
          rating_key = rating_key,
          key        = key or ('/playlists/' .. rating_key .. '/items'),
          leaf_count = leaf_count,
        })
      end
    end
  end

  log.info(string.format('[plex_api] Found %d audio playlists', #playlists))
  return playlists, nil
end

--- Retrieve the Plex Media Server's machineIdentifier.
--- Returns: machine_id string or nil on error.
function M.get_machine_id(server_ip, server_port, token)
  local path = '/?X-Plex-Token=' .. url_encode(token)
  local body, err = http_get(server_ip, server_port, path)
  if err then
    log.error('[plex_api] get_machine_id failed: ' .. err)
    return nil
  end

  local machine_id = body:match('machineIdentifier="([^"]*)"')
  if machine_id then
    log.info('[plex_api] Server machine ID: ' .. machine_id)
  else
    log.warn('[plex_api] machineIdentifier not found in server response')
  end
  return machine_id
end

return M
