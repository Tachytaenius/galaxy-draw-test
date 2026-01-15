local consts = require("consts")

return function(segments, noFade)
	local vertices = {
		{
			-- No z
			0, 0, -- 0,
			0 -- This is VertexFade
		}
	}
	for i = 0, segments do
		local angle = consts.tau * i / segments
		vertices[#vertices + 1] = {
			math.cos(angle), math.sin(angle), -- 0,
			noFade and 0 or 1
		}
	end
	return love.graphics.newMesh(consts.blurredPointVertexFormat, vertices, "fan")
end
