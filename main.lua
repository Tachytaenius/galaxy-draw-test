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

local lightSourceData
local lightSourceDataFFI

local camera
local pointIdSets

local mode

local starRNG

local canvasScale = 1

-- TODO: Move all to consts...
local squashAmount = 0.04
local nebulaSquashAmount = 0.04
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

	safeSend(shader, "nebulaCount", #nebulae)
	safeSend(shader, "nebulaeTexture", nebulaeTexture)
	safeSend(shader, "Nebulae", nebulaeBuffer)
end

local function getStarCount(average, variance) -- Average can be a float! This function is uniform-ish. It returns numbers with the desired average
	local ret = math.floor(util.randomRange(1 - variance, (1 + variance)) * average)
	if love.math.random() < average % 1 then -- Use fractional part of average as a probability
		ret = ret + 1
	end
	return ret
end

local function setStarData(id, ...)
	local floatCount = select("#", ...)
	assert(floatCount == consts.floatsPerLightSource, "Wrong argument count to setStarData")
	local bytesPerFloat = 4
	local curAddr = id * lightSourceBuffer:getElementStride() / bytesPerFloat
	for i = 1, floatCount do
		local property = select(i, ...)
		lightSourceDataFFI[curAddr] = property -- Casts from double to float
		curAddr = curAddr + 1
	end
end

local function generateChunk(chunkX, chunkY, chunkZ, pointIdStart, chunkId)
	starRNG:setSeed(chunkId)

	local chunkCoord = vec3(chunkX, chunkY, chunkZ)
	local chunkPosition = chunkCoord * consts.chunkSize
	local samplePosition = chunkPosition + 0.5 * consts.chunkSize

	local sample = getDensity(vec3.components(samplePosition))
	local count = getStarCount(sample * consts.chunkVolume, consts.starCountVariance)
	local chunk = {
		idStart = pointIdStart,
		pointCount = count
	}
	for i = 0, count - 1 do
		local pointPositionX = chunkPosition.x + consts.chunkSize.x * starRNG:random()
		local pointPositionY = chunkPosition.y + consts.chunkSize.y * starRNG:random()
		local pointPositionZ = chunkPosition.z + consts.chunkSize.z * starRNG:random()

		-- Colour is dimensionless (under this model). Will learn more another time
		local r = starRNG:random() * 0.9 + 0.1
		local g = starRNG:random() * 0.9 + 0.1
		local b = starRNG:random() * 0.9 + 0.1
		-- Make sure the highest is 1
		local max = math.max(r, g, b)
		r = r / max
		g = g / max
		b = b / max

		local intensityMultiplier = (starRNG:random() * 2 - 1) * 0.9 + 1
		local intensity = consts.intensityPerPoint * intensityMultiplier

		if pointIdStart + i >= consts.maxPoints then
			-- Too many points!!
			return chunk
		end
		setStarData(
			pointIdStart + i,

			pointPositionX,
			pointPositionY,
			pointPositionZ,
			intensity,
			r,
			g,
			b
		)
	end
	return chunk
end

local function loadPoints()
	pointIdSets = {}
	for i = 1, consts.maxPointIdSets do
		pointIdSets[i] = {
			i = i,
			free = true
		}
	end

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

local function iterateInRangeBlocks(size, func, viewRadiusMultiplier)
	viewRadiusMultiplier = viewRadiusMultiplier or 1
	local viewRadius = consts.cloudFadeRadius * viewRadiusMultiplier
	local minX, maxX = math.floor((camera.position.x - viewRadius) / size.x), math.floor((camera.position.x + viewRadius) / size.x)
	local minY, maxY = math.floor((camera.position.y - viewRadius) / size.y), math.floor((camera.position.y + viewRadius) / size.y)
	local minZ, maxZ = math.floor((camera.position.z - viewRadius) / size.z), math.floor((camera.position.z + viewRadius) / size.z)
	for x = minX, maxX do
		for y = minY, maxY do
			for z = minZ, maxZ do
				func(x, y, z)
			end
		end
	end
end

local function drawOutput()
	local info = {
		activePoints = 0,
		activeChunks = 0,
		activeSets = 0
	}

	love.graphics.setCanvas(outputCanvas)
	love.graphics.clear(0, 0, 0, 1)

	local worldToCameraStationary = mat4.camera(vec3(), camera.orientation)
	local cameraToClip = mat4.perspectiveLeftHanded(
		outputCanvas:getWidth() / outputCanvas:getHeight(),
		camera.verticalFOV,
		camera.farPlaneDistance,
		camera.nearPlaneDistance
	)
	local skyToClip = cameraToClip * worldToCameraStationary
	local clipToSky = mat4.inverse(skyToClip)

	if mode == "cloud" or mode == "both" then
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
		love.graphics.draw(dummyTexture, 0, 0, 0, outputCanvas:getDimensions())
	end

	if mode == "point" or mode == "both" then
		love.graphics.setShader(starAttenuationShader)
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

		local pointGroups = {}
		for i, pointIdSet in ipairs(pointIdSets) do
			if not pointIdSet.free then
				local start = (i - 1) * consts.pointsPerIdSet
				local count = pointIdSet.currentPoints

				local finish = start + count
				if finish > start + consts.pointsPerIdSet then
					info.tooManyPoints = true
					finish = math.min(start + consts.pointsPerIdSet, finish)
					count = finish - start
				end

				if count > 0 then
					table.insert(pointGroups, {
						start = start,
						count = count
					})
					info.activeSets = info.activeSets + 1
					info.activePoints = info.activePoints + pointIdSet.currentPoints
					info.activeChunks = info.activeChunks + pointIdSet.currentChunks
				end
			end
		end

		blurredPointPreparationShader:send("LightSources", lightSourceBuffer)
		blurredPointPreparationShader:send("Points", blurredPointBuffer)
		blurredPointPreparationShader:send("fadeInRadius", consts.pointFadeRadius)
		blurredPointPreparationShader:send("fadeOutRadius", consts.cloudFadeRadius)
		blurredPointPreparationShader:send("skyToClip", {mat4.components(skyToClip)}) -- TEMP
		blurredPointPreparationShader:send("starAttenuationTexture", starAttenuationTexture)
		for _, group in ipairs(pointGroups) do
			local offset = group.offset
			blurredPointPreparationShader:send("cameraPosition", {vec3.components(camera.position + (offset or vec3()))})
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
		blurredPointInstanceShader:send("worldToClip", {mathsies.mat4.components(cameraToClip * mat4.camera(vec3(), camera.orientation))})
		love.graphics.setShader(blurredPointInstanceShader)
		love.graphics.setBlendMode("add")
		for _, group in ipairs(pointGroups) do
			blurredPointInstanceShader:send("pointStart", group.start)
			love.graphics.drawInstanced(diskMesh, group.count)
		end
	end

	love.graphics.setBlendMode("alpha")
	love.graphics.setCanvas()
	love.graphics.setShader()

	return info
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
		position = vec3(galaxyRadius / 2, 0, galaxyRadius / 2),
		-- position = vec3(),
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
	outputCanvas = love.graphics.newCanvas(love.graphics.getWidth() * canvasScale, love.graphics.getHeight() * canvasScale, {format = "rgba32f"})
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
	nebulaeBuffer:setArrayData(bufferData)

	createNebulaShader:send("nebulaeTexture", nebulaeTexture)
	createNebulaShader:send("nebulaTextureResolution", consts.nebulaResolution)
	local sizeX, sizeY, sizeZ = createNebulaShader:getLocalThreadgroupSize()
	local countX = math.ceil(consts.nebulaResolution / sizeX)
	local countY = math.ceil(consts.nebulaResolution / sizeY)
	local countZ = math.ceil(consts.nebulaResolution / sizeZ)
	for _, nebula in ipairs(nebulae) do
		createNebulaShader:send("nebulaId", nebula.id)
		createNebulaShader:send("nebulaPosition", {vec3.components(nebula.position)})
		createNebulaShader:send("nebulaSize", {vec3.components(nebula.size)})
		love.graphics.dispatchThreadgroups(createNebulaShader, countX, countY, countZ)
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

-- function love.keypressed(key)
-- 	if key == "space" then
-- 		if mode == "point" then
-- 			mode = "cloud"
-- 		else
-- 			mode = "point"
-- 		end
-- 	end
-- end

local function tryGenerateChunkIntoSet(set, x, y, z, id)
	local chunks = set.chunks
	chunks[x] = chunks[x] or {}
	chunks[x][y] = chunks[x][y] or {}
	if not chunks[x][y][z] then
		local setStart = (set.i - 1) * consts.pointsPerIdSet
		local chunkStart = setStart + set.currentPoints
		local chunk = generateChunk(x, y, z, chunkStart, id)
		chunks[x][y][z] = chunk
		set.currentChunks = set.currentChunks + 1
		set.currentPoints = set.currentPoints + chunk.pointCount

		if chunk.pointCount > 0 then
			if chunkStart + chunk.pointCount > setStart + consts.pointsPerIdSet then
				-- Too many points!!
				return false
			else
				lightSourceBuffer:setArrayData(lightSourceData, chunkStart + 1, chunkStart + 1, chunk.pointCount)
				return true
			end
		end
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

	local freePointIdSets = {}
	for _, pointIdSet in ipairs(pointIdSets) do
		if not pointIdSet.free and not blockInRange(consts.pointIdSetSize, pointIdSet.x, pointIdSet.y, pointIdSet.z, consts.pointSetFreeRangeMultiplier) then
			pointIdSet.free = true
			pointIdSet.x, pointIdSet.y, pointIdSet.z = nil, nil, nil
			pointIdSet.currentChunks = nil
			pointIdSet.currentPoints = nil
			pointIdSet.chunks = nil
		end

		if pointIdSet.free then
			table.insert(freePointIdSets, pointIdSet)
		end
	end

	local minX, maxX, minY, maxY, minZ, maxZ = getGalaxyBoundingBoxChunks()
	local widthChunks = maxX - minX + 1
	local heightChunks = maxY - minY + 1
	local depthChunks = maxZ - minZ + 1

	iterateInRangeBlocks(consts.chunkSize, function(x, y, z)
		if not (
			minX <= x and x <= maxX and
			minY <= y and y <= maxY and
			minZ <= z and z <= maxZ
		) then
			return
		end

		local setX = math.floor(x / consts.pointIdSetSideLengthChunks)
		local setY = math.floor(y / consts.pointIdSetSideLengthChunks)
		local setZ = math.floor(z / consts.pointIdSetSideLengthChunks)

		local set
		for _, pointIdSet in ipairs(pointIdSets) do
			if
				not pointIdSet.free and
				pointIdSet.x == setX and
				pointIdSet.y == setY and
				pointIdSet.z == setZ
			then
				set = pointIdSet
			end
		end

		if not set then
			set = table.remove(freePointIdSets)
			if not set then
				error("Out of point id sets!")
			end

			-- Claim
			set.free = false
			set.x = setX
			set.y = setY
			set.z = setZ
			set.chunks = {}
			set.currentChunks = 0
			set.currentPoints = 0
		end

		local x2, y2, z2 = x - minX, y - minY, z - minZ
		local chunkId = x2 + y2 * widthChunks + z2 * heightChunks * depthChunks
		tryGenerateChunkIntoSet(set, x, y, z, chunkId)
	end)

	-- if love.keyboard.isDown("space") then
	-- 	for _, set in ipairs(pointIdSets) do
	-- 		if not set.free then
	-- 			for ox = 0, consts.pointIdSetSideLengthChunks - 1 do
	-- 				for oy = 0, consts.pointIdSetSideLengthChunks - 1 do
	-- 					for oz = 0, consts.pointIdSetSideLengthChunks - 1 do
	-- 						local x = ox + set.x * consts.pointIdSetSideLengthChunks
	-- 						local y = oy + set.y * consts.pointIdSetSideLengthChunks
	-- 						local z = oz + set.z * consts.pointIdSetSideLengthChunks

	-- 						tryGenerateChunkIntoSet(set, x, y, z)
	-- 					end
	-- 				end
	-- 			end
	-- 		end
	-- 	end
	-- end
end

function love.draw()
	local info = drawOutput()
	love.graphics.draw(outputCanvas, 0, 0, 0, 1 / canvasScale)

	local idSetInfoTable = {}
	for i, idSet in ipairs(pointIdSets) do
		if idSet.free then
			idSetInfoTable[i] = "-"
		else
			local proportion = idSet.currentChunks / consts.chunksPerIdPointSet
			idSetInfoTable[i] = math.floor(proportion * 100 + 0.5) .. "%"
			local proportion = idSet.currentPoints / consts.pointsPerIdSet
			idSetInfoTable[i] = idSetInfoTable[i] .. " " .. math.floor(proportion * 100 + 0.5) .. "%"
		end
	end
	love.graphics.print(
		love.timer.getFPS() .. "\n" ..
		info.activePoints .. "\n" ..
		info.activeChunks .. "\n" ..
		info.activeSets .. "\n" ..
		"\n" ..
		(info.tooManyPoints and "Too many points in the id sets! Not drawing all of them..." or "") .. "\n" ..
		"\n" ..
		table.concat(idSetInfoTable, "\n") .. "\n"
	)
end
