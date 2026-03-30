return function(clay)
    local function max_build(clients, wa, t)
        return clay.client(clients[1])
    end

    clay.max = clay.layout("clay.max", max_build, {
        skip_gap = function() return true end,
        no_gap = true,
    })
end
