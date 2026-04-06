local cjson = require("cjson.safe")
local docker = require("docker")
local config = require("config")
local dynamic_upstream = require("ngx.dynamic_upstream")

local _M = {}

-- NOTE: ngx_dynamic_upstream does not support IPv6 peers.
-- Only IPv4 addresses are used.

--- Pick IPv4 address from a Docker network entry.
local function pick_ip(net)
    local ipv4 = net.IPAddress
    if ipv4 and ipv4 ~= "" then
        return ipv4
    end
    return nil
end

local function format_peer(ip, port)
    return ip .. ":" .. port
end

--- Get current primary peers as a set of "ip:port" -> true.
local function current_peers(upstream_name)
    local ok, peers, err = dynamic_upstream.get_primary_peers(upstream_name)
    if not ok then
        return nil, err
    end
    local set = {}
    for _, p in ipairs(peers) do
        if p.name ~= "0.0.0.1:80" then
            set[p.name] = true
        end
    end
    return set
end

--- Refresh backends from Docker and sync into native upstreams.
function _M.refresh()
    local containers, err = docker.list_containers()
    if not containers then
        ngx.log(ngx.ERR, "discovery: failed to list containers: ", err)
        return
    end

    -- Build desired state: service -> set of "ip:port".
    local desired = {}

    for _, c in ipairs(containers) do
        local labels = c.Labels or {}
        local svc    = labels["upstream.name"]
        local port   = tonumber(labels["upstream.port"])

        if svc and port then
            local status = c.Status or ""
            if string.find(status, "%(unhealthy%)") then
                goto continue
            end

            local ip
            local nets = c.NetworkSettings and c.NetworkSettings.Networks
            if nets then
                local net = nets[config.NETWORK_NAME]
                if net then
                    ip = pick_ip(net)
                end
                if not ip then
                    for _, n in pairs(nets) do
                        ip = pick_ip(n)
                        if ip then break end
                    end
                end
            end

            if ip then
                if not desired[svc] then
                    desired[svc] = {}
                end
                desired[svc][format_peer(ip, port)] = true
            end

            ::continue::
        end
    end

    -- Sync each upstream.
    for _, upstream_name in ipairs(config.UPSTREAMS) do
        local want = desired[upstream_name] or {}
        local have, err = current_peers(upstream_name)
        if not have then
            ngx.log(ngx.ERR, "discovery: get peers(", upstream_name, "): ", err)
            goto next
        end

        -- Add missing peers.
        for addr in pairs(want) do
            if not have[addr] then
                local ok, _, err = dynamic_upstream.add_primary_peer(upstream_name, addr)
                if ok then
                    ngx.log(ngx.NOTICE, "discovery: added ", addr, " to ", upstream_name)
                else
                    ngx.log(ngx.ERR, "discovery: add ", addr, " to ", upstream_name, ": ", err)
                end
            end
        end

        -- Remove stale peers.
        for addr in pairs(have) do
            if not want[addr] then
                local ok, _, err = dynamic_upstream.remove_peer(upstream_name, addr)
                if ok then
                    ngx.log(ngx.NOTICE, "discovery: removed ", addr, " from ", upstream_name)
                else
                    ngx.log(ngx.ERR, "discovery: remove ", addr, " from ", upstream_name, ": ", err)
                end
            end
        end

        ::next::
    end
end

--- Status endpoint.
function _M.status()
    local result = { services = {} }

    for _, name in ipairs(config.UPSTREAMS) do
        local ok, peers, err = dynamic_upstream.get_primary_peers(name)
        if ok then
            local list = {}
            for _, p in ipairs(peers) do
                if p.name ~= "0.0.0.1:80" then
                    list[#list + 1] = {
                        name       = p.name,
                        weight     = p.weight,
                        max_fails  = p.max_fails,
                        down       = p.down,
                    }
                end
            end
            result.services[name] = list
        else
            result.services[name] = { error = err }
        end
    end

    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(result))
    ngx.exit(ngx.HTTP_OK)
end

return _M
