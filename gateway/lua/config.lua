local _M = {
    DISCOVERY_INTERVAL = tonumber(os.getenv("DISCOVERY_INTERVAL")) or 2,
    NETWORK_NAME       = os.getenv("NETWORK_NAME") or "gateway_net",
    UPSTREAMS          = {},
}

-- UPSTREAMS: comma-separated list, e.g. "app-web,app-api"
local raw = os.getenv("UPSTREAMS") or "app-web,app-api"
for name in raw:gmatch("[^,]+") do
    name = name:match("^%s*(.-)%s*$")
    if name ~= "" then
        _M.UPSTREAMS[#_M.UPSTREAMS + 1] = name
    end
end

return _M
