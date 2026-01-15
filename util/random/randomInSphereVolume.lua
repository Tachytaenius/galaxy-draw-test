local vec3 = require("lib.mathsies").vec3

local consts = require("consts")

return function(radius)
	local phi = love.math.random() * consts.tau
	local cosTheta = love.math.random() * 2 - 1
	local theta = math.acos(cosTheta)

	local u = love.math.random()
	local r = radius * u ^ (1 / 3)

	return r * vec3.fromAngles(theta, phi)
end
