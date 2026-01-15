local util = {}

local function recurse(path)
	for _, itemName in ipairs(love.filesystem.getDirectoryItems(path)) do
		local itemPath = path .. itemName
		if itemPath ~= "util/init.lua" then
			if love.filesystem.getInfo(itemPath, "directory") then
				recurse(itemPath .. "/")
			elseif love.filesystem.getInfo(itemPath, "file") then
				if itemName:match("%.lua$") then
					local key = itemName:gsub("%.lua$", "")
					if key == "load" then
						error("Can't call a util module reserved name \"load\"")
					elseif util[key] then
						error("Duplicate util module name \"" .. key .. "\"")
					end
					util[key] = require(itemPath:gsub("%.lua", ""):gsub("/", "."))
				end
			end
		end
	end
end

function util.load()
	recurse("util/")
end

return util
