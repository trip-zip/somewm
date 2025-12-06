---------------------------------------------------------------------------
--- Bitwise operations for Lua 5.1 compatibility.
---
--- Lua 5.1 doesn't have built-in bitwise operators, so we provide
--- pure Lua implementations here.
---
--- @module gears.bitwise
---------------------------------------------------------------------------

local bitwise = {}

--- Left shift operation
-- @tparam number x Value to shift
-- @tparam number n Number of positions to shift
-- @treturn number Shifted value
function bitwise.lshift(x, n)
  return x * (2 ^ n)
end

--- Bitwise AND operation
-- @tparam number a First operand
-- @tparam number b Second operand
-- @treturn number Result of a & b
function bitwise.band(a, b)
  local result = 0
  local bit = 1
  while a > 0 or b > 0 do
    if a % 2 == 1 and b % 2 == 1 then
      result = result + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return result
end

--- Bitwise OR operation
-- @tparam number a First operand
-- @tparam number b Second operand
-- @treturn number Result of a | b
function bitwise.bor(a, b)
  local result = 0
  local bit = 1
  while a > 0 or b > 0 do
    if a % 2 == 1 or b % 2 == 1 then
      result = result + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return result
end

return bitwise

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
