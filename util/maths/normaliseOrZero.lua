local vec3 = require("lib.mathsies").vec3

return function(v)
	local zeroVector = vec3()
	return v == zeroVector and zeroVector or vec3.normalise(v)
end
