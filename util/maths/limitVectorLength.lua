local vec3 = require("lib.mathsies").vec3

local util = require("util")

return function(v, m)
	local l = #v
	if l > m then
		return util.normaliseOrZero(v) * m
	end
	return vec3.clone(v)
end
