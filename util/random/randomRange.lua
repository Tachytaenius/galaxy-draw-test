local util = require("util")

return function(a, b)
	return util.lerp(a, b, love.math.random())
end
