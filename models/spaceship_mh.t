local S = terralib.require("qs.lib.std")
local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)

local flip = prob.flip
local uniform = prob.uniform

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	-- This program interprets geoRes as a flag toggling whether we're doing
	-- lo res or hi res
	local nBevelBox
	local bevAmt
	local nCylinder
	if geoRes == 1 then
		nBevelBox = 1
		bevAmt = 0
		nCylinder = 8
	elseif geoRes == 2 then
		nBevelBox = 10
		bevAmt = 0.15
		nCylinder = 32
	else
		error(string.format("spaceship - unrecognized geoRes flag %d", geoRes))
	end

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBeveledBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen, bevAmt, nBevelBox)
	end)
	local taperedbox = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double, taper: double)
		Shapes.addTaperedBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen, taper)
	end)
	local wingseg = makeGeoPrim(terra(mesh: &Mesh, xbase: double, zbase: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBeveledBox(mesh, Vec3.create(xbase + 0.5*xlen, 0.0, zbase), xlen, ylen, zlen, bevAmt, nBevelBox)
		Shapes.addBeveledBox(mesh, Vec3.create(-(xbase + 0.5*xlen), 0.0, zbase), xlen, ylen, zlen, bevAmt, nBevelBox)
	end)

	local function wi(i, w)
		return math.exp(-w*i)
	end

	local function genWing(xbase, zlo, zhi)
		local i = 0
		repeat
			prob.setAddressLoopIndex(i)
			local zbase = uniform(zlo, zhi, "wingzbase")
			local xlen = uniform(0.25, 2.0, "wingxlen")
			local ylen = uniform(0.25, 1.25, "wingylen")
			local zlen = uniform(0.5, 4.0, "wingzlen")
			wingseg(xbase, zbase, xlen, ylen, zlen)
			xbase = xbase + xlen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
			local keepGenerating = flip(wi(i, 0.6), "wingcontinue")
			i = i + 1
		until not keepGenerating
	end

	local function genFin(ybase, zlo, zhi, xmax)
		local i = 0
		repeat
			prob.setAddressLoopIndex(i)
			local xlen = uniform(0.5, 1.0, "finxlen") * xmax
			xmax = xlen
			local ylen = uniform(0.1, 0.5, "finylen")
			local zlen = uniform(0.5, 1.0, "finzlen") * (zhi - zlo)
			local zbase = 0.5*(zlo + zhi)
			box(0.0, ybase + 0.5*ylen, zbase, xlen, ylen, zlen)
			ybase = ybase + ylen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
			local keepGenerating = flip(wi(i, 0.2), "fincontinue")
			i = i + 1
		until not keepGenerating
	end

	local function genShip(rearz)
		local i = 0
		repeat
			prob.setAddressLoopIndex(i)
			local xlen = uniform(1.0, 3.0, "bodyxlen")
			local ylen = uniform(0.5, 1.0, "bodyylen") * xlen
			local zlen = uniform(2.0, 5.0, "bodyzlen")
			box(0.0, 0.0, rearz + 0.5*zlen, xlen, ylen, zlen)
			rearz = rearz + zlen
			-- Gen wing?
			local wingprob = wi(i+1, 0.5)
			if flip(wingprob, "winggen") then
				local xbase = 0.5*xlen
				local zlo = rearz - zlen + 0.5
				local zhi = rearz - 0.5
				prob.pushAddress("wing")
				genWing(xbase, zlo, zhi)
				prob.popAddress()
			end
			-- Gen fin?
			local finprob = 0.7
			if flip(finprob, "fingen") then
				local ybase = 0.5*ylen
				local zlo = rearz - zlen
				local zhi = rearz
				local xmax = 0.6*xlen
				prob.pushAddress("fin")
				genFin(ybase, zlo, zhi, xmax)
				prob.popAddress()
			end
			local keepGenerating = flip(wi(i, 0.4), "bodycontinue")
			i = i + 1
		until not keepGenerating
		if flip(0.75, "nosegen") then
			-- Generate tapered nose
			local xlen = uniform(1.0, 3.0, "nosexlen")
			local ylen = uniform(0.5, 1.0, "noseylen") * xlen
			local zlen = uniform(1.0, 3.0, "nosezlen")
			local taper = uniform(0.3, 1.0, "nosetaper")
			taperedbox(0.0, 0.0, rearz + 0.5*zlen, xlen, ylen, zlen, taper)
		end
	end

	return function()
		prob.pushAddress("body")
		genShip(-5.0)
		prob.popAddress()
	end

end)



