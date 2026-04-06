local http = require("resty.http")
local cjson = require("cjson.safe")

local _M = {}

local docker_host = os.getenv("DOCKER_HOST") or "unix:/var/run/docker.sock"

function _M.request(path)
    local httpc = http.new()
    httpc:set_timeout(5000)

    local ok, err

    if docker_host:sub(1, 7) == "unix://" then
        ok, err = httpc:connect(docker_host)
    elseif docker_host:sub(1, 5) == "unix:" then
        ok, err = httpc:connect(docker_host)
    elseif docker_host:sub(1, 6) == "tcp://" then
        local host_port = docker_host:sub(7)
        local host, port = host_port:match("^(.+):(%d+)$")
        if not host then
            host = host_port
            port = 2375
        end
        ok, err = httpc:connect(host, tonumber(port))
    else
        ok, err = httpc:connect(docker_host)
    end

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

function _M.list_containers()
    local filters = cjson.encode({
        label  = { "upstream.enable=true" },
        status = { "running" },
    })
    local path = "/containers/json?filters=" .. ngx.escape_uri(filters)
    return _M.request(path)
end

return _M
