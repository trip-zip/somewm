-- Attachment policy shared by popup, tooltip, menu and launcher front ends.
-- Clay's point enum is column-major (left/center/right, top/center/bottom).
local M = { points={top_left=0,left=1,bottom_left=2,top=3,centered=4,
    bottom=5,top_right=6,right=7,bottom_right=8} }
function M.next_to(w, target, positions, anchors, offset, kind)
    local position = type(positions)=='table' and positions[1] or positions or 'bottom'
    local anchor = type(anchors)=='table' and anchors[1] or anchors or 'middle'
    local cross = anchor=='front' and 0 or anchor=='back' and 2 or 1
    local parent, own
    if position=='top' then parent,own=cross*3,cross*3+2
    elseif position=='bottom' then parent,own=cross*3+2,cross*3
    elseif position=='left' then parent,own=cross,6+cross
    else parent,own=6+cross,cross end
    local widget = target and (target.is_widget and target or target.widget)
    -- Widget objects expose emit_signal, while explicit point input does not.
    if target and not widget and target.emit_signal and not target.geometry then widget=target end
    local occurrence = target and target.occurrence
    local host
    if widget then
        -- Keep the event's drawable: a widget can occur on multiple outputs.
        -- Programmatic show while hovered can use the same previous-frame hit.
        -- Wibox objects keep the Lua host under _drawable; their public
        -- drawable is the C object. A widget hit already names the Lua host.
        host = target._drawable or target.drawable
        if not occurrence then
            for _, hit in ipairs(mouse.current_widget_geometries or {}) do
                if hit.widget == widget and (not host or host == hit.drawable) then
                    occurrence, host = hit.occurrence, hit.drawable
                end
            end
        end
        if not occurrence then
            host = require('wibox.drawable')._clay_target(widget, host) or host
        end
        if host then w.screen = host:get_screen() end
    end
    local a = {kind=kind or 1, parent=parent, own=own,
        target=widget and require('wibox.clay').identity(widget) or 0,
        occurrence=occurrence or 0,
        host=host and host.drawable,
        x=offset and offset.x or 0, y=offset and offset.y or 0}
    if not widget then
        local point = target or mouse.coords()
        a.parent=0
        local origin=w.screen.geometry
        a.x=a.x+(point.x or 0)-origin.x; a.y=a.y+(point.y or 0)-origin.y
    end
    w.drawin.attachment=a
    return position,anchor
end
function M.corner(w, name, offset, kind)
    local point=assert(M.points[name], 'unknown attachment point: '..tostring(name))
    local launcher = name=='centered'
    local override = require('beautiful').launcher_width
    w.drawin.attachment={kind=kind or (launcher and 3 or 1),parent=point,own=point,
        width=launcher and (override or w.minimum_width or 600) or 0,
        lua_width=launcher and not override and w._private and w._private.size_source == "workarea",
        x=offset and offset.x or 0,y=offset and offset.y or 0}
end
return M
