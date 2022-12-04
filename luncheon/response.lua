local Headers = require 'luncheon.headers'
local statuses = require 'luncheon.status'
local utils = require 'luncheon.utils'
local shared = require 'luncheon.shared'

---@class Response
---
---An HTTP Response
---
---@field public headers Headers The HTTP headers for this response
---@field public body string the contents of the response body
---@field public status number The HTTP status 3 digit number
---@filed public status_msg string The HTTP status message
---@field public http_version string
---@field public socket table The socket to send/receive on
---@field private _source fun(pat:string|nil):string ltn12 source
---@field private _parsed_headers boolean
---@field private _received_body boolean
local Response = {}
Response.__index = Response

--#endregion
--#region Parser


---Create a request parser from an ltn12 source function
---@param source fun():string
---@return Response
---@return string @if return 1 is nil the error string
function Response.source(source)
    local ret = setmetatable({
        headers = Headers.new(),
        _source = source,
        _parsed_headers = false,
    }, Response)
    local line, err = ret:next_line()
    if not line then
        return nil, err
    end
    local pre, err = Response._parse_preamble(line)
    if not pre then
        return nil, err
    end
    ret.status = pre.status
    ret.status_msg = pre.status_msg
    ret.http_version = pre.http_version
    return ret
end

---Create a response from a lua socket tcp socket
---@param socket table tcp socket
---@return Response
function Response.tcp_source(socket)
    local utils = require 'luncheon.utils'
    local ret, err = Response.source(
        utils.tcp_socket_source(socket)
    )
    if not ret then
        return nil, err
    end
    ret.socket = socket
    return ret
end

---Create a response from a lua socket udp socket
---@param socket table udp socket
---@return Response
function Response.udp_source(socket)
    local utils = require 'luncheon.utils'
    local ret, err =  Response.source(
        utils.udp_socket_source(socket)
    )
    if not ret then
        return nil, err
    end
    ret.socket = socket
    return ret
end

---Parse the first line of an incoming response
---@param line string
---@return nil|table @`{http_version: number, status: number, status_msg: string}`
---@return nil|string @Error message if populated
function Response._parse_preamble(line)
    local version, status, msg = string.match(line, 'HTTP/([0-9.]+) ([^%s]+) (.+)')
    if not version then
        return nil, string.format('invalid preamble: %q', line)
    end
    return {
        http_version = tonumber(version),
        status = math.tointeger(status),
        status_msg = msg,
    }
end

function Response:get_headers()
    return shared.SharedLogic.get_headers(self)
end

---Attempt to get the value from Content-Length header
---@return number|nil @when not `nil` the Content-Length
---@return string|nil @when not `nil` the error message
function Response:get_content_length()
    return shared.SharedLogic.get_content_length(self)
end

---Get the next line from an incoming request, checking first
---if we have reached the end of the content
---@return string|nil
---@return string|nil
function Response:next_line()
    if not self._source then
        return nil, 'nil source'
    end
    return self:_next_line()
end

function Response:get_body()
    return shared.SharedLogic.get_body(self)
end

---Receive the next line from an incoming request w/o checking
---the content-length header
---@return string|nil
---@return string|nil
function Response:_next_line()
    local line, err = self._source()
    self._recvd = (self._recvd or 0) + #(line or '')
    return line, err
end

--#region builder

---Create a new response for building in memory
---@param status_code number|nil if not provided 200
---@param socket table|nil luasocket for sending (not required)
function Response.new(status_code, socket)
    if status_code == nil then
        status_code = 200
    end
    if ({string = true, number = true})[type(status_code)] then
        status_code = math.tointeger(status_code)
    else
        return nil, string.format('Invalid status code %s', type(status_code))
    end

    return setmetatable(
        {
            status = status_code or 200,
            status_msg = statuses[status_code] or 'Unknown',
            http_version = 1.1,
            headers = Headers.new(),
            body = '',
            _parsed_headers = true,
            socket = socket,
            _send_state = {
                stage = 'none',
            },
            mode = shared.Mode.Outgoing,
        },
        Response
    )
end

---Append a header to the internal headers map
---
---note: this is additive, though the _last_ value is used during
---serialization
---@param key string
---@param value any If not a string will call tostring
---@return Response
function Response:add_header(key, value)
    if type(value) ~= 'string' then
        value = tostring(value)
    end
    self.headers:append(key, value)
    return self
end

---Set the Content-Type of the outbound request
---@param s string the mime type for this request
---@return Response
function Response:set_content_type(s)
    if type(s) ~= 'string' then
        return nil, string.format('mime type must be a string, found %s', type(s))
    end
    return self:add_header('content_type', s)
end

---Set the Content-Length header of the outbound response
---@param len number The length of the content that will be sent
---@return Response
function Response:set_content_length(len)
    if type(len) ~= 'number' then
        return nil, string.format('content length must be a number, found %s', type(len))
    end
    return self:add_header('content_length', string.format('%i', len))
end

---Serialize this full response into a string
---@return string
function Response:serialize()
    return shared.SharedLogic.serialize(self)
end

---Generate the first line of this response without the trailing \r\n
---@return string|nil
function Response:_serialize_preamble()
    return string.format('HTTP/%s %s %s',
        self.http_version,
        self.status,
        statuses[self.status] or ''
    )
end

---Create the string representing the pre-body entries for
---this request. including the 2 trailing \r\n
---@return string
function Response:_generate_prebody()
    return self:_generate_preamble() .. '\r\n'
        .. self.headers:serialize() .. '\r\n'
end

---Append text to the body
---@param s string the text to append
---@return Response
function Response:append_body(s)
    self.body = (self.body or '') .. s
    self:set_content_length(#self.body)
    return self
end

---Set the status for this outgoing request
---@param n number the 3 digit status
---@return Response
function Response:set_status(n)
    if type(n) == 'string' then
        n = math.tointeger(n)
    end
    if type(n) ~= 'number' then
        return nil, string.format('http status must be a number, found %s', type(n))
    end
    self.status = n
    return self
end

---Creates a lua iterator returning a line (with new line characters)
---for this Response
---@return function
function Response:iter()
    return shared.SharedLogic.iter(self)
end

--#endregion

--#region sink

---Serialize and pass the first line of this Request into the sink
---@return integer if not nil, success
---@return string if not nil and error message
function Response:send_preamble()
    if self._send_state.stage ~= 'none' then
        return 1 --already sent
    end
    local line = self:_serialize_preamble() .. '\r\n'
    local s, err = utils.send_all(self.socket, line)
    if not s then
        return nil, err
    end
    self._send_state.stage = 'header'
    return 1
end

---Pass a single header line into the sink functions
---@return integer|nil If not nil, then successfully "sent"
---@return string If not nil, the error message
function Response:send_header()
    if self._send_state.stage == 'none' then
        return self:send_preamble()
    end
    if self._send_state.stage == 'body' then
        return nil, 'cannot send headers after body'
    end
    local key, value = next(self.headers._inner, self._send_state.last_header)
    if not key then
        local s, e = utils.send_all(self.socket, '\r\n')
        if not s then
            return nil, e
        end
        self._send_state = {
            stage = 'body',
            sent = 0,
        }
        return 1
    end
    local line = Headers.serialize_header(key, value) .. '\r\n'
    local s, e = utils.send_all(self.socket, line)
    if not s then
        return nil, e
    end
    self._send_state.last_header = key
    return 1
end

---Slice a chunk of at most 1024 bytes from `self.body` and pass it to
---the sink
---@return integer|nil if not nil, success
---@return string if not nil and error message
function Response:send_body_chunk()
    if self._send_state.stage ~= 'body' then
        return self:send_header()
    end
    local start_idx = self._send_state.sent + 1
    local end_idx = start_idx + 1024
    local chunk = self.body:sub(start_idx, end_idx)
    local s, e = utils.send_all(self.socket, chunk)
    if not s then
        return nil, e
    end
    self._send_state.sent = self._send_state.sent + #chunk
    return 1
end

---Serialize and pass the request chunks into the sink
---@param bytes string|nil the final bytes to append to the body
---@return integer|nil If not nil sent successfully
---@return string if not nil the error message
function Response:send(bytes, skip_length)
    if bytes then
        self.body = self.body .. bytes
    end
    if self._send_state.stage ~= 'body' and not skip_length then
        self:set_content_length(#self.body)
    end
    while not self:_sending_body() or (self._send_state.sent or 0) < #self.body do
        local s, e = self:send_body_chunk()
        if not s then
            return nil, e
        end
    end
    return 1
end

function Response:has_sent()
    return self._send_state.stage ~= 'none'
end

function Response:_sending_body()
    return self._send_state.stage == 'body'
end

--#endregion

return Response
