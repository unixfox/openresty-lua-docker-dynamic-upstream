local config = require("config")

local _M = {}

function _M.start()
    -- Only run timers in worker 0 to avoid duplicated work.
    if ngx.worker.id() ~= 0 then
        return
    end

    -- Run initial discovery via a 0-delay timer (cosockets not allowed
    -- directly in init_worker_by_lua, but work inside timer callbacks).
    ngx.timer.at(0, function()
        local discovery = require("discovery")
        discovery.refresh()
    end)

    -- Periodic discovery timer.
    local ok, err = ngx.timer.every(config.DISCOVERY_INTERVAL, function(premature)
        if premature then return end
        local discovery = require("discovery")
        discovery.refresh()
    end)
    if not ok then
        ngx.log(ngx.ERR, "init: failed to start discovery timer: ", err)
    end

    ngx.log(ngx.NOTICE, "init: discovery timer started (every ", config.DISCOVERY_INTERVAL, "s)")
end

return _M
