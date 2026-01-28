local ffi = require("ffi")

local util = require("util")
util.load()

local mathsies = require("lib.mathsies")
local vec2 = mathsies.vec2
local vec3 = mathsies.vec3
local quat = mathsies.quat
local mat4 = mathsies.mat4

local consts = require("consts")

local outputCanvas
local starCanvas
local cloudCanvas

local dummyTexture

local cloudShader
-- local cloudTextureViews

local nebulaeTexture
local createNebulaShader
local nebulae
local nebulaeBuffer

local blurredPointPreparationShader
local blurredPointInstanceShader
local diskMesh
local blurredPointBuffer
local lightSourceBuffer
local starAttenuationTexture
local starAttenuationShader
local pointIndirectDrawArgsBuffer

local chunks
local chunkStarCountBuffer
local chunkStarCountData
local chunkStarCountDataFFI

local lightSourceData
local lightSourceDataFFI

local camera

local mode

local starRNG

-- TODO: Move all to consts...
local squashAmount = 0.03
local nebulaSquashAmount = 0.03
local galaxyRadius = 900
local haloProportion = 0.0005
local galaxyForwards = vec3(0, 1, 0)
local galaxyUp = vec3(0, 0, 1)
local galaxyRight = vec3.cross(galaxyForwards, galaxyUp)
local intensityPerStar = consts.intensityPerPoint
local stellarDensityMultiplier = consts.stellarDensityMultiplier
local stellarDensityCurvePower = 1
local swirlAngleAtRadius = 2
local coreProportion = 0.2
local coreFullProportion = 0.05
local armCount = 6
local attenuationMultiplier = 0

local function getGalaxyBoundingBoxChunks()
	local originX, originY, originZ = 0, 0, 0
	local minX, maxX = math.floor((originX - galaxyRadius) / consts.chunkSize.x), math.floor((originX + galaxyRadius) / consts.chunkSize.x)
	local minY, maxY = math.floor((originY - galaxyRadius) / consts.chunkSize.y), math.floor((originY + galaxyRadius) / consts.chunkSize.y)
	local minZ, maxZ = math.floor((originZ - galaxyRadius) / consts.chunkSize.z), math.floor((originZ + galaxyRadius) / consts.chunkSize.z)
	return minX, maxX, minY, maxY, minZ, maxZ
end

local function getDensity(x, y, z)
	local samplePosition = vec3(x, y, z)

	local samplePositionElevation = vec3.dot(galaxyForwards, samplePosition)
	local samplePosition2D = vec2(
		vec3.dot(galaxyRight, samplePosition),
		vec3.dot(galaxyUp, samplePosition)
	)
	local samplePosition2DSwirled = vec2.rotate(samplePosition2D, swirlAngleAtRadius * vec2.length(samplePosition2D) / galaxyRadius)
	local samplePositionSwirled =
		galaxyRight * samplePosition2D.x +
		galaxyUp * samplePosition2D.y +
		galaxyForwards * samplePositionElevation

	local galaxyCoreFactor = math.min(1, math.max(0, 1.0 - (vec2.length(samplePosition2D) - galaxyRadius * coreFullProportion) / (galaxyRadius * (coreProportion - coreFullProportion)) + 0.25))
	local armFactor =
		util.lerp( -- Mix between spiral arms and core with no arms
			(math.sin(math.atan2(samplePosition2DSwirled.y, samplePosition2DSwirled.x) * armCount) * 0.5 + 0.5) ^ (3.3 * vec2.length(samplePosition2D) / galaxyRadius),
			1,
			galaxyCoreFactor
		)
	local diskDensityMultiplier =
		armFactor * math.max(0.0, 1.0 - vec3.length(
			galaxyRight * samplePosition2D.x +
			galaxyUp * samplePosition2D.y +
			galaxyForwards * samplePositionElevation / squashAmount
		) / galaxyRadius)

	local haloDensityMultiplier = math.max(0.0, 1.0 - vec3.length(samplePosition) / galaxyRadius)

	local densityMultiplier = util.lerp(diskDensityMultiplier, haloDensityMultiplier, haloProportion)
	densityMultiplier = math.max(0, math.min(1, densityMultiplier))
	local stellarDensity = stellarDensityMultiplier * densityMultiplier ^ stellarDensityCurvePower
	return stellarDensity
end

local function safeSend(shader, uniform, ...)
	if shader:hasUniform(uniform) then
		shader:send(uniform, ...)
	end
end

local function sendGalaxyUniforms(shader)
	safeSend(shader, "squashAmount", squashAmount)
	safeSend(shader, "galaxyRadius", galaxyRadius)
	safeSend(shader, "haloProportion", haloProportion)
	safeSend(shader, "galaxyForwards", {vec3.components(galaxyForwards)})
	safeSend(shader, "galaxyUp", {vec3.components(galaxyUp)})
	safeSend(shader, "galaxyRight", {vec3.components(galaxyRight)})
	safeSend(shader, "intensityPerStar", intensityPerStar)
	safeSend(shader, "stellarDensityMultiplier", stellarDensityMultiplier)
	safeSend(shader, "stellarDensityCurvePower", stellarDensityCurvePower)
	safeSend(shader, "swirlAngleAtRadius", swirlAngleAtRadius)
	safeSend(shader, "coreProportion", coreProportion)
	safeSend(shader, "coreFullProportion", coreFullProportion)
	safeSend(shader, "armCount", armCount)
	safeSend(shader, "attenuationMultiplier", attenuationMultiplier)

	safeSend(shader, "nebulaCount", #nebulae)
	safeSend(shader, "nebulaeTexture", nebulaeTexture)
	safeSend(shader, "Nebulae", nebulaeBuffer)
end

local function getStarCount(average, variance, rng) -- Average can be a float! This function is uniform-ish. It returns numbers with the desired average
	local ret = math.floor(util.randomRange(1 - variance, (1 + variance)) * average)
	if rng:random() < average % 1 then -- Use fractional part of average as a probability
		ret = ret + 1
	end
	return ret
end

local function setStarData(index, ...)
	assert(index >= 0 and index < consts.maxPoints, "Bad index " .. index .. " given to setLightSourceData, must be an int within [0, " .. consts.maxPoints .. ")")

	local floatCount = select("#", ...)
	assert(floatCount == consts.floatsPerLightSource, "Wrong argument count to setLightSourceData")
	local bytesPerFloat = 4
	local curAddr = index * lightSourceBuffer:getElementStride() / bytesPerFloat
	for i = 1, floatCount do
		local property = select(i, ...)
		lightSourceDataFFI[curAddr] = property -- Casts from double to float
		curAddr = curAddr + 1
	end
end

local function generateChunk(chunkX, chunkY, chunkZ, chunkId, chunkBufferX, chunkBufferY, chunkBufferZ, chunkBufferIndex)
	local pointIdStart = chunkBufferIndex * consts.maxStarsPerChunk

	starRNG:setSeed(chunkId)

	local chunkCoord = vec3(chunkX, chunkY, chunkZ)
	local chunkPosition = chunkCoord * consts.chunkSize
	local samplePosition = chunkPosition + 0.5 * consts.chunkSize

	local sample = getDensity(vec3.components(samplePosition))
	local count = getStarCount(sample * consts.chunkVolume, consts.starCountVariance, starRNG)
	local chunkShaderDistanceScale = 1 / math.max( -- used in drawing too
		consts.chunkSize.x,
		consts.chunkSize.y,
		consts.chunkSize.z
	)
	for i = 0, count - 1 do
		local chunkLocalPosX = starRNG:random()
		local chunkLocalPosY = starRNG:random()
		local chunkLocalPosZ = starRNG:random()

		-- Colour is dimensionless (under this model). Will learn more another time
		local r = starRNG:random() * 0.9 + 0.1
		local g = starRNG:random() * 0.9 + 0.1
		local b = starRNG:random() * 0.9 + 0.1
		-- Make sure the highest is 1
		local max = math.max(r, g, b)
		r = r / max
		g = g / max
		b = b / max

		local intensityMultiplier = (starRNG:random() * 2 - 1) * 0.4 + 1
		intensityMultiplier = intensityMultiplier * chunkShaderDistanceScale ^ 2
		local intensity = consts.intensityPerPoint * intensityMultiplier

		setStarData(
			pointIdStart + i,

			chunkLocalPosX,
			chunkLocalPosY,
			chunkLocalPosZ,
			intensity,
			r,
			g,
			b
		)
	end
	if count > 0 then
		lightSourceBuffer:setArrayData(lightSourceData, pointIdStart + 1, pointIdStart + 1, count)
	end
	return count
end

local function getBlockRanges(size, position, viewRadiusMultiplier)
	viewRadiusMultiplier = viewRadiusMultiplier or 1
	local viewRadius = consts.cloudFadeRadius * viewRadiusMultiplier
	local minX, maxX = math.floor((position.x - viewRadius) / size.x), math.floor((position.x + viewRadius) / size.x)
	local minY, maxY = math.floor((position.y - viewRadius) / size.y), math.floor((position.y + viewRadius) / size.y)
	local minZ, maxZ = math.floor((position.z - viewRadius) / size.z), math.floor((position.z + viewRadius) / size.z)
	return minX, maxX, minY, maxY, minZ, maxZ
end

local function iterateInRangeBlocks(size, position, func, viewRadiusMultiplier)
	local minX, maxX, minY, maxY, minZ, maxZ = getBlockRanges(size, position, viewRadiusMultiplier)
	for x = minX, maxX do
		for y = minY, maxY do
			for z = minZ, maxZ do
				func(x, y, z)
			end
		end
	end
end

local function handleChunkGeneration()
	local generatedChunks = 0
	local updateChunkStarCountBuffer = false

	local minX, maxX, minY, maxY, minZ, maxZ = getGalaxyBoundingBoxChunks()
	local widthChunks = maxX - minX + 1
	local heightChunks = maxY - minY + 1
	local depthChunks = maxZ - minZ + 1

	local chunkBufferStartRealX = math.floor((camera.position.x / consts.chunkSize.x - consts.chunkRange.x / 2) / consts.chunkRange.x) * consts.chunkRange.x
	local chunkBufferStartRealY = math.floor((camera.position.y / consts.chunkSize.y - consts.chunkRange.y / 2) / consts.chunkRange.y) * consts.chunkRange.y
	local chunkBufferStartRealZ = math.floor((camera.position.z / consts.chunkSize.z - consts.chunkRange.z / 2) / consts.chunkRange.z) * consts.chunkRange.z
	local viewMinXInChunkBuffer = (camera.position.x / consts.chunkSize.x - consts.chunkRange.x / 2) % consts.chunkRange.x
	local viewMinYInChunkBuffer = (camera.position.y / consts.chunkSize.y - consts.chunkRange.y / 2) % consts.chunkRange.y
	local viewMinZInChunkBuffer = (camera.position.z / consts.chunkSize.z - consts.chunkRange.z / 2) % consts.chunkRange.z
	for x = 0, consts.chunkRange.x - 1 do
		for y = 0, consts.chunkRange.y - 1 do
			for z = 0, consts.chunkRange.z - 1 do
				local realX = x + chunkBufferStartRealX + (x < viewMinXInChunkBuffer and consts.chunkRange.x or 0)
				local realY = y + chunkBufferStartRealY + (y < viewMinYInChunkBuffer and consts.chunkRange.y or 0)
				local realZ = z + chunkBufferStartRealZ + (z < viewMinZInChunkBuffer and consts.chunkRange.z or 0)

				local chunkBufferIndex = x + y * consts.chunkRange.x + z * consts.chunkRange.y * consts.chunkRange.x

				if
					minX <= realX and realX <= maxX and
					minY <= realY and realY <= maxY and
					minZ <= realZ and realZ <= maxZ
				then
					local currentChunk = chunks[x][y][z]
					if
						currentChunk.x ~= realX or
						currentChunk.y ~= realY or
						currentChunk.z ~= realZ
					then
						local x2, y2, z2 = realX - minX, realY - minY, realZ - minZ
						local chunkId = x2 + y2 * widthChunks + z2 * heightChunks * depthChunks

						local chunkCount = generateChunk(realX, realY, realZ, chunkId, x, y, z, chunkBufferIndex)
						generatedChunks = generatedChunks + 1
						local chunk = chunks[x][y][z]
						chunk.x = realX
						chunk.y = realY
						chunk.z = realZ
						chunkStarCountDataFFI[chunkBufferIndex] = chunkCount
						updateChunkStarCountBuffer = true
					end
				else
					chunks[x][y][z] = {}
					chunkStarCountDataFFI[chunkBufferIndex] = 0
					updateChunkStarCountBuffer = true
				end
			end
		end
	end

	if updateChunkStarCountBuffer then
		chunkStarCountBuffer:setArrayData(chunkStarCountData, 1, 1, consts.chunksInRange)
	end

	return generatedChunks
end

local function loadPoints()
	-- for chunkX = 0, consts.chunksPerAxis - 1 do
	-- 	for chunkY = 0, consts.chunksPerAxis - 1 do
	-- 		for chunkZ = 0, consts.chunksPerAxis - 1 do
	-- 			generateChunk(chunkX, chunkY, chunkZ)
	-- 		end
	-- 	end
	-- end
	-- print("Star count: " .. numPoints)

	-- initialiseCloudShader:send("intensityPerPoint", consts.intensityPerPoint)
	-- initialiseCloudShader:send("attenuation", attenuationTexture)
	-- initialiseCloudShader:send("emission", emissionTexture)
	-- initialiseCloudShader:send("textureSize", {vec3.components(consts.volumetricTextureSizeSpace)})
	-- local groupCount = math.ceil(consts.volumetricTextureSideLength / initialiseCloudShader:getLocalThreadgroupSize())
	-- love.graphics.dispatchThreadgroups(initialiseCloudShader, groupCount, groupCount, groupCount)
end

local function blockInRange(size, x, y, z, viewRadiusMultiplier)
	viewRadiusMultiplier = viewRadiusMultiplier or 1
	local viewRadius = consts.cloudFadeRadius * viewRadiusMultiplier
	local minX, maxX = math.floor((camera.position.x - viewRadius) / size.x), math.floor((camera.position.x + viewRadius) / size.x)
	local minY, maxY = math.floor((camera.position.y - viewRadius) / size.y), math.floor((camera.position.y + viewRadius) / size.y)
	local minZ, maxZ = math.floor((camera.position.z - viewRadius) / size.z), math.floor((camera.position.z + viewRadius) / size.z)
	return
		minX <= x and x <= maxX and
		minY <= y and y <= maxY and
		minZ <= z and z <= maxZ
end

local function drawOutput()
	local worldToCameraStationary = mat4.camera(vec3(), camera.orientation)
	local aspectRatio = outputCanvas:getWidth() / outputCanvas:getHeight()
	local cameraToClip = mat4.perspectiveLeftHanded(
		aspectRatio,
		camera.verticalFOV,
		camera.farPlaneDistance,
		camera.nearPlaneDistance
	)
	local skyToClip = cameraToClip * worldToCameraStationary
	local clipToSky = mat4.inverse(skyToClip)

	if mode == "cloud" or mode == "both" then
		love.graphics.setCanvas(cloudCanvas)
		love.graphics.clear()

		love.graphics.setShader(cloudShader)
		sendGalaxyUniforms(cloudShader)
		cloudShader:send("fadeInRadius", consts.pointFadeRadius)
		cloudShader:send("fadeOutRadius", consts.cloudFadeRadius)
		cloudShader:send("clipToSky", {mat4.components(clipToSky)})
		cloudShader:send("cameraPosition", {vec3.components(camera.position)})
		-- cloudShader:send("attenuation", attenuationTexture)
		-- cloudShader:send("textureSize", {vec3.components(consts.volumetricTextureSizeSpace)})
		-- cloudShader:send("emission", emissionTexture)
		cloudShader:send("rayLength", consts.rayLength)
		cloudShader:send("rayStepCount", consts.rayStepCount)
		cloudShader:send("nebulaStepCount", consts.nebulaStepCount)
		love.graphics.draw(dummyTexture, 0, 0, 0, love.graphics.getCanvas():getDimensions())
	end

	if mode == "point" or mode == "both" then
		love.graphics.setCanvas(starCanvas)
		love.graphics.clear(0, 0, 0, 1)

		sendGalaxyUniforms(starAttenuationShader)
		starAttenuationShader:send("rayLength", consts.cloudFadeRadius)
		starAttenuationShader:send("textureSize", {starAttenuationTexture:getWidth(), starAttenuationTexture:getHeight(), starAttenuationTexture:getDepth()})
		starAttenuationShader:send("clipToSky", {mat4.components(clipToSky)})
		starAttenuationShader:send("cameraPosition", {vec3.components(camera.position)})
		starAttenuationShader:send("resultTexture", starAttenuationTexture)
		local xSize, ySize = starAttenuationShader:getLocalThreadgroupSize()
		local w, h = starAttenuationTexture:getDimensions()
		local xCount = math.ceil(w / xSize)
		local yCount = math.ceil(h / ySize)
		love.graphics.dispatchThreadgroups(starAttenuationShader, xCount, yCount, 1)

		local distanceToSphere = 1 - math.cos(consts.pointLightBlurAngularRadius) -- Unit sphere spherical cap height from angular radius
		local diskArea = consts.tau * distanceToSphere
		local scaleToGetAngularRadius = math.tan(consts.pointLightBlurAngularRadius)
		local cameraUp = mathsies.vec3.rotate(consts.upVector, camera.orientation)
		local cameraRight = mathsies.vec3.rotate(consts.rightVector, camera.orientation)

		local pointGroups = {
			{
				start = 0,
				count = consts.maxPoints
			}
		}

		pointIndirectDrawArgsBuffer:setArrayData({
			diskMesh:getVertexCount(),
			0, -- This gets incremented (on the GPU)
			0,
			0
		})

		blurredPointPreparationShader:send("chunkBufferSize", {vec3.components(consts.chunkRange)})
		blurredPointPreparationShader:send("viewMinFloatLocationInChunkBuffer", {
			(camera.position.x / consts.chunkSize.x - consts.chunkRange.x / 2) % consts.chunkRange.x,
			(camera.position.y / consts.chunkSize.y - consts.chunkRange.y / 2) % consts.chunkRange.y,
			(camera.position.z / consts.chunkSize.z - consts.chunkRange.z / 2) % consts.chunkRange.z
		})
		local chunkBufferCameraPos = vec3(
			(camera.position.x / consts.chunkSize.x + consts.chunkRange.x / 2) % consts.chunkRange.x + consts.chunkRange.x / 2,
			(camera.position.y / consts.chunkSize.y + consts.chunkRange.y / 2) % consts.chunkRange.y + consts.chunkRange.y / 2,
			(camera.position.z / consts.chunkSize.z + consts.chunkRange.z / 2) % consts.chunkRange.z + consts.chunkRange.z / 2
		)
		blurredPointPreparationShader:send("cameraPosition", {vec3.components(chunkBufferCameraPos)})
		local diagonalFOV = camera.verticalFOV * math.sqrt(1 ^ 2 + aspectRatio ^ 2) -- Angular distance from camera forwards at corners of screen
		local maxAngleFromCentre = diagonalFOV / 2 + consts.pointLightBlurAngularRadius
		blurredPointPreparationShader:send("minDot", math.cos(maxAngleFromCentre))
		blurredPointPreparationShader:send("cameraForwards", {vec3.components(vec3.rotate(consts.forwardVector, camera.orientation))})
		blurredPointPreparationShader:send("IndirectDrawBuffer", pointIndirectDrawArgsBuffer)
		blurredPointPreparationShader:send("ChunkStarCounts", chunkStarCountBuffer)
		blurredPointPreparationShader:send("chunksStart", 0) -- Where in the LightSources buffer is the first chunk
		blurredPointPreparationShader:send("maxStarsPerChunk", consts.maxStarsPerChunk) -- How many light sources wide are the chunks in the LightSources buffer
		blurredPointPreparationShader:send("LightSources", lightSourceBuffer)
		blurredPointPreparationShader:send("Points", blurredPointBuffer)
		local chunkShaderDistanceScale = 1 / math.max( -- used in chunk generation too
			consts.chunkSize.x,
			consts.chunkSize.y,
			consts.chunkSize.z
		)
		blurredPointPreparationShader:send("fadeInRadius", consts.pointFadeRadius * chunkShaderDistanceScale)
		blurredPointPreparationShader:send("fadeOutRadius", consts.cloudFadeRadius * chunkShaderDistanceScale)
		blurredPointPreparationShader:send("skyToClip", {mat4.components(skyToClip)})
		blurredPointPreparationShader:send("starAttenuationTexture", starAttenuationTexture)
		for _, group in ipairs(pointGroups) do
			local offset = group.offset
			blurredPointPreparationShader:send("pointStart", group.start)
			blurredPointPreparationShader:send("pointCount", group.count)
			local unreachable = group.start + group.count -- Use unreachable value for skip (one after the last element to be reached) if no skipped value specified
			blurredPointPreparationShader:send("skipIndex", group.skip or unreachable)
			local threadgroupCount = math.ceil(group.count / blurredPointPreparationShader:getLocalThreadgroupSize())
			love.graphics.dispatchThreadgroups(blurredPointPreparationShader, threadgroupCount)
		end

		blurredPointInstanceShader:send("Points", blurredPointBuffer)
		blurredPointInstanceShader:send("diskDistanceToSphere", distanceToSphere)
		blurredPointInstanceShader:send("scale", scaleToGetAngularRadius)
		blurredPointInstanceShader:send("diskArea", diskArea)
		blurredPointInstanceShader:send("cameraUp", {mathsies.vec3.components(cameraUp)})
		blurredPointInstanceShader:send("cameraRight", {mathsies.vec3.components(cameraRight)})
		blurredPointInstanceShader:send("skyToClip", {mathsies.mat4.components(skyToClip)})
		love.graphics.setShader(blurredPointInstanceShader)
		love.graphics.setBlendMode("add")
		for _, group in ipairs(pointGroups) do
			blurredPointInstanceShader:send("pointStart", group.start)
			love.graphics.drawIndirect(diskMesh, pointIndirectDrawArgsBuffer, 1)
		end
	end

	love.graphics.setBlendMode("add")
	love.graphics.setShader()

	love.graphics.setCanvas(outputCanvas)
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.draw(cloudCanvas, 0, 0, 0, outputCanvas:getWidth() / cloudCanvas:getWidth(), outputCanvas:getHeight() / cloudCanvas:getHeight())
	love.graphics.draw(starCanvas, 0, 0, 0, outputCanvas:getWidth() / starCanvas:getWidth(), outputCanvas:getHeight() / starCanvas:getHeight())

	love.graphics.setBlendMode("alpha")
	love.graphics.setCanvas()
end

local function getAverage(modeName)
	mode = modeName
	drawOutput()
	local data = love.graphics.readbackTexture(outputCanvas)
	local total, num = 0, 0
	for x = 0, data:getWidth() - 1 do
		for y = 0, data:getHeight() - 1 do
			local r, g, b, a = data:getPixel(x, y)
			total = total + r
			num = num + 1
		end
	end
	return total / num
end

function love.load()
	nebulae = {}
	for _=1, love.math.random(0, consts.maxNebulae) do
	-- for _=1, consts.maxNebulae do
		local position = util.randomInSphereVolume(galaxyRadius * 0.5)
		position =
			position.x * galaxyRight +
			position.y * galaxyUp +
			position.z * galaxyForwards * nebulaSquashAmount
		local radius = util.randomRange(consts.minNebulaSize, consts.maxNebulaSize) -- Spherical for now. TODO: Randomise orientation and make into random ellipsoids
		local size = vec3(radius)

		local collision = false
		local largestRadius = math.max(size.x, size.y, size.z)
		for _, otherNebula in ipairs(nebulae) do
			local otherNebulaLargestRadius = math.max(otherNebula.size.x, otherNebula.size.y, otherNebula.size.z)
			if vec3.distance(position, otherNebula.position) <= largestRadius + otherNebulaLargestRadius then -- Expect nebula textures to not reach to their corners (sphere inside cube)
				collision = true
				break
			end
		end
		if collision then
			goto continue
		end

		local newId = #nebulae
		table.insert(nebulae, {
			position = position,
			size = size,
			id = newId
		})

	    ::continue::
	end

	camera = {
		-- position = consts.volumetricTextureSizeSpace / 2,
		-- position = vec3(galaxyRadius / 2, 0, galaxyRadius / 2),
		-- position = vec3(0, 0, -galaxyRadius),
		position = vec3(),
		-- position = vec3.clone(nebulae[1].position),
		-- orientation = quat.fromAxisAngle(vec3(0, consts.tau / 2, 0)),
		orientation = quat(),
		verticalFOV = math.rad(90),
		speed = 1,
		angularSpeed = 1,
		farPlaneDistance = 2048,
		nearPlaneDistance = 0.125
	}

	starRNG = love.math.newRandomGenerator()

	dummyTexture = love.graphics.newImage(love.image.newImageData(1, 1))
	starCanvas = love.graphics.newCanvas(math.floor(love.graphics.getWidth() * consts.starCanvasScale), math.floor(love.graphics.getHeight() * consts.starCanvasScale), {format = "rgba16f"})
	-- starCanvas:setFilter("nearest", "nearest")
	cloudCanvas = love.graphics.newCanvas(math.floor(love.graphics.getWidth() * consts.cloudCanvasScale), math.floor(love.graphics.getHeight() * consts.cloudCanvasScale), {format = "rgba16f"})
	outputCanvas = love.graphics.newCanvas(love.graphics.getWidth(), love.graphics.getHeight(), {format = "rgba32f"})
	local attenuationTextureScale = 0.25
	starAttenuationTexture = love.graphics.newCanvas(
		math.floor(love.graphics.getWidth() * attenuationTextureScale),
		math.floor(love.graphics.getHeight() * attenuationTextureScale),
		consts.starAttenuationTextureSteps,
		{
			type = "volume",
			format = "r16f",
			computewrite = true
		}
	)
	starAttenuationTexture:setFilter(consts.volumetricsCanvasFilter or "nearest")
	starAttenuationTexture:setWrap("clamp", "clamp", "clamp")

	nebulaeTexture = love.graphics.newCanvas(
		consts.nebulaResolution,
		consts.nebulaResolution,
		consts.nebulaResolution,
		{
			type = "volume",
			format = "r16f",
			computewrite = true
		}
	)
	nebulaeTexture:setFilter(consts.volumetricsCanvasFilter or "nearest")
	nebulaeTexture:setWrap("clampzero", "clampzero", "clampzero")
	createNebulaShader = love.graphics.newComputeShader(
		love.filesystem.read("shaders/include/lib/dist.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/lib/random.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/lib/worley.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/lib/voronoiEdge.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/lib/simplex4d.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/lib/simplex3d.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/init/createNebula.glsl")
	)

	nebulaeBuffer = love.graphics.newBuffer(consts.nebulaeBufferFormat, consts.maxNebulae, {shaderstorage = true})
	local bufferData = {}
	for _, nebula in ipairs(nebulae) do
		table.insert(bufferData, {
			nebula.position.x, nebula.position.y, nebula.position.z,
			nebula.size.x, nebula.size.y, nebula.size.z,
		})
	end
	if #nebulae > 0 then
		nebulaeBuffer:setArrayData(bufferData)
	end

	createNebulaShader:send("nebulaeTexture", nebulaeTexture)
	createNebulaShader:send("nebulaTextureResolution", consts.nebulaResolution)
	local sizeX, sizeY, sizeZ = createNebulaShader:getLocalThreadgroupSize()
	local countX = math.ceil(consts.nebulaResolution / sizeX)
	local countY = math.ceil(consts.nebulaResolution / sizeY)
	local countZ = math.ceil(consts.nebulaResolution / sizeZ)
	for _, nebula in ipairs(nebulae) do
		createNebulaShader:send("nebulaId", nebula.id)
		createNebulaShader:send("nebulaPosition", {vec3.components(nebula.position)})
		safeSend(createNebulaShader, "nebulaSize", {vec3.components(nebula.size)})
		love.graphics.dispatchThreadgroups(createNebulaShader, countX, countY, countZ)
	end

	local bitsPerInt = 4 -- 32-bit, as in GLSL
	chunkStarCountBuffer = love.graphics.newBuffer({{name = "count", format = "int32"}}, consts.chunksInRange, {shaderstorage = true})
	chunkStarCountData = love.data.newByteData(bitsPerInt * consts.chunksInRange)
	chunkStarCountDataFFI = ffi.cast("int32_t*", chunkStarCountData:getFFIPointer())
	for i = 0, consts.chunksInRange - 1 do
		chunkStarCountDataFFI[i] = 0
	end

	blurredPointPreparationShader = love.graphics.newComputeShader(
		love.filesystem.read("shaders/drawing/preparePointLightSources.glsl"),
		{defines = {
			THREADGROUP_SIZE = consts.pointLightComputeThreadgroupSize
		}}
	)
	blurredPointInstanceShader = love.graphics.newShader("shaders/drawing/blurredPoint.glsl", {defines = {INSTANCED = true}})
	diskMesh = util.generateDiskMesh(consts.diskMeshVertices, false)

	lightSourceBuffer = love.graphics.newBuffer(consts.lightSourceBufferFormat, consts.maxPoints, {shaderstorage = true})
	blurredPointBuffer = love.graphics.newBuffer(consts.blurredPointBufferFormat, consts.maxPoints, {shaderstorage = true})
	lightSourceData = love.data.newByteData(lightSourceBuffer:getElementStride() * consts.maxPoints)
	lightSourceDataFFI = ffi.cast("float*", lightSourceData:getFFIPointer())

	starAttenuationShader = love.graphics.newComputeShader(
		"#pragma language glsl4\n" ..
		"#line 1\n" .. love.filesystem.read("shaders/include/raycasts.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/galaxy.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/drawing/pointLightAttenuation.glsl"),
		{defines = {
			MAX_NEBULAE = consts.maxNebulae
		}}
	)

	cloudShader = love.graphics.newShader(
		"#pragma language glsl4\n" ..
		"#line 1\n" .. love.filesystem.read("shaders/include/raycasts.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/galaxy.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/include/viewDirection.glsl") ..
		"#line 1\n" .. love.filesystem.read("shaders/drawing/cloud.glsl"),
		{defines = {
			MAX_NEBULAE = consts.maxNebulae
		}}
	)

	-- cloudTextureViews = {}

	-- local function newCloudTexture(name, format, debugName)
	-- 	local size = consts.volumetricTextureSideLength
	-- 	local canvas = love.graphics.newCanvas(size, size, size, {
	-- 		type = "volume",
	-- 		format = format,
	-- 		computewrite = true,
	-- 		mipmaps = "manual",
	-- 		debugname = debugName
	-- 	})
	-- 	canvas:setFilter(consts.volumetricsCanvasFilter or "nearest")
	-- 	canvas:setWrap("clampzero", "clampzero", "clampzero")

	-- 	local viewSet = {}
	-- 	assert(canvas:getMipmapCount() == consts.volumetricTextureMipmapCount, "Wrong number of mipmaps...?")

	-- 	for i = 1, consts.volumetricTextureMipmapCount do
	-- 		viewSet[i] = love.graphics.newTextureView(canvas, {
	-- 			mipmapstart = i,
	-- 			mipmapcount = 1,
	-- 			debugname = debugName .. " View " .. i
	-- 		})
	-- 	end
	-- 	cloudTextureViews[name] = viewSet

	-- 	return canvas
	-- end

	-- attenuationTexture = newCloudTexture("attenuation", "r16f", "Attenuation Texture")
	-- emissionTexture = newCloudTexture("emission", "rgba16f", "Emission Texture")

	-- initialiseCloudShader = love.graphics.newComputeShader(
	-- 	love.filesystem.read("shaders/include/lib/simplex4d.glsl") ..
	-- 	"#line 1\n" .. love.filesystem.read("shaders/init/initCloud.glsl")
	-- )

	pointIndirectDrawArgsBuffer = love.graphics.newBuffer(consts.indirectDrawBufferFormat, 1, {shaderstorage = true, indirectarguments = true})

	chunks = {}
	for x = 0, consts.chunkRange.x - 1 do
		chunks[x] = {}
		for y = 0, consts.chunkRange.y - 1 do
			chunks[x][y] = {}
			for z = 0, consts.chunkRange.z - 1 do
				chunks[x][y][z] = {}
			end
		end
	end
	handleChunkGeneration()

	local testing = false -- Not maintained
	if not testing then
		loadPoints()
		mode = "both"
		return
	end

	local function nudge()
		love.event.pump()
		for name, a,b,c,d,e,f in love.event.poll() do
			if name == "quit" then
				if not love.quit or not love.quit() then
					return true
				end
			end
			love.handlers[name](a,b,c,d,e,f)
		end
		love.graphics.clear()
		love.graphics.draw(outputCanvas, 0, 0, 0, 1 / canvasScale)
		love.graphics.present()
	end

	-- The ratio improves (ie is closer to 1) when the disk mesh is higher resolution. It looks like the problem might be related to resolution, and could be fixed with MSAA or something
	local total, num = 0, 0
	for angle = 0, consts.tau, 1 do
		local orientation = quat.fromAxisAngle(vec3(0, angle, 0))
		camera = {
			position = consts.volumetricTextureSizeSpace / 2 + consts.volumetricTextureSizeSpace * vec3.rotate(vec3(0, 0, -1.6), orientation),
			orientation = orientation,
			verticalFOV = math.rad(70),
			speed = 10,
			angularSpeed = 1,
			farPlaneDistance = 2048,
			nearPlaneDistance = 0.125
		}
		for angularRadius = 5e-3, 1e-2, 5e-3 do
			consts.pointLightBlurAngularRadius = angularRadius
			for intensity = 1e-5, 1e-4, 7.5e-5 do
				consts.intensityPerPoint = intensity

				loadPoints()
				local p = getAverage("point")
				local quit = nudge()
				if quit then
					love.event.quit()
					return
				end
				local c = getAverage("cloud")
				local quit = nudge()
				if quit then
					love.event.quit()
					return
				end
				total = total + p /c
				num = num + 1
				print(string.format("%f    %f    %f    %f    %f    %f", angle, consts.pointLightBlurAngularRadius, consts.intensityPerPoint, p, c, p / c))
			end
		end
	end
	print("done, average ratio:", total / num)
end

function love.keypressed(key)
	if key == "space" then
		local prevChunkSize = consts.chunkSize
		consts.chunkSize = consts.chunkSize * 32
		local prevChunkVolume = consts.chunkVolume
		consts.chunkVolume = consts.chunkSize.x * consts.chunkSize.y * consts.chunkSize.z
		local total = 0
		local minX, maxX, minY, maxY, minZ, maxZ = getGalaxyBoundingBoxChunks()
		for x = minX, maxX do
			print(x - minX, maxX - minX)
			for y = minY, maxY do
				for z = minZ, maxZ do
					local chunkCoord = vec3(x, y, z)
					local chunkPosition = chunkCoord * consts.chunkSize
					local samplePosition = chunkPosition + 0.5 * consts.chunkSize
					local sample = getDensity(vec3.components(samplePosition))
					local widthChunks = maxX - minX + 1
					local heightChunks = maxY - minY + 1
					local depthChunks = maxZ - minZ + 1
					local x2, y2, z2 = x - minX, y - minY, z - minZ
					local chunkId = x2 + y2 * widthChunks + z2 * heightChunks * depthChunks
					starRNG:setSeed(chunkId)
					local count = getStarCount(sample * consts.chunkVolume, consts.starCountVariance, starRNG)
					total = total + count
				end
			end
		end
		print("total stars: " .. total)
		consts.chunkSize = prevChunkSize
		consts.chunkVolume = prevChunkVolume
	end
end

function love.update(dt)
	local translation = vec3()
	if love.keyboard.isDown(consts.controls.moveRight) then
		translation = translation + consts.rightVector
	end
	if love.keyboard.isDown(consts.controls.moveLeft) then
		translation = translation - consts.rightVector
	end
	if love.keyboard.isDown(consts.controls.moveUp) then
		translation = translation + consts.upVector
	end
	if love.keyboard.isDown(consts.controls.moveDown) then
		translation = translation - consts.upVector
	end
	if love.keyboard.isDown(consts.controls.moveForwards) then
		translation = translation + consts.forwardVector
	end
	if love.keyboard.isDown(consts.controls.moveBackwards) then
		translation = translation - consts.forwardVector
	end
	local speed = camera.speed * (love.keyboard.isDown("lshift") and 50 or love.keyboard.isDown("lctrl") and 0.05 or 1)
	camera.position = camera.position + vec3.rotate(util.normaliseOrZero(translation), camera.orientation) * speed * dt

	local rotation = vec3()
	if love.keyboard.isDown(consts.controls.pitchDown) then
		rotation = rotation + consts.rightVector
	end
	if love.keyboard.isDown(consts.controls.pitchUp) then
		rotation = rotation - consts.rightVector
	end
	if love.keyboard.isDown(consts.controls.yawRight) then
		rotation = rotation + consts.upVector
	end
	if love.keyboard.isDown(consts.controls.yawLeft) then
		rotation = rotation - consts.upVector
	end
	if love.keyboard.isDown(consts.controls.rollAnticlockwise) then
		rotation = rotation + consts.forwardVector
	end
	if love.keyboard.isDown(consts.controls.rollClockwise) then
		rotation = rotation - consts.forwardVector
	end
	local rotationQuat = quat.fromAxisAngle(util.limitVectorLength(rotation, camera.angularSpeed * dt))
	camera.orientation = quat.normalise(camera.orientation * rotationQuat) -- Normalise to prevent numeric drift

	handleChunkGeneration()
end

function love.draw()
	drawOutput()
	love.graphics.draw(outputCanvas, 0, 0, 0, 1)
	local activePoints = 0
	for i = 0, consts.chunksInRange - 1 do
		activePoints = activePoints + chunkStarCountDataFFI[i]
	end
	love.graphics.print(
		love.timer.getFPS() .. "\n" ..
		activePoints .. "\n" ..
		consts.maxPoints
	)
end
