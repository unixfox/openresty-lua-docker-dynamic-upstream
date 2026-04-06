local http = require("resty.http")
local cjson = require("cjson.safe")

local _M = {}

function _M.request(path)
    local httpc = http.new()
    httpc:set_timeout(5000)

    local ok, err = httpc:connect("unix:/var/run/docker.sock")
    if not ok then
        return nil, "docker connect: " .. (err or "unknown")
    end

    local res, err = httpc:request({
        method = "GET",
        path   = path,
        headers = { Host = "localhost" },
    })
    if not res then
        return nil, "docker request: " .. (err or "unknown")
    end

    local body, err = res:read_body()
    if not body then
        return nil, "docker read body: " .. (err or "unknown")
    end

    httpc:close()

    local data, decode_err = cjson.decode(body)
    if not data then
        return nil, "docker json decode: " .. (decode_err or "unknown")
    end

    return data
end

--- List running containers that have upstream.enable=true.
function _M.list_containers()
    local filters = cjson.encode({
        label  = { "upstream.enable=true" },
        status = { "running" },
    })
    local path = "/containers/json?filters=" .. ngx.escape_uri(filters)
    return _M.request(path)
end

return _M
