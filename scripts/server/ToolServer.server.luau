function waitforchild(ins,name,tim)
	local cloc = os.clock()
	local me
	local yiel = false
	local s,f = pcall(function()
		me = ins:FindChild(name)
	end)
	if me ~= nil then 
		return me
	end
	repeat
		local s,f = pcall(function()
			me = ins:FindChild(name)
		end)
		if tim ~= nil and os.clock()-cloc > tim then
			break
		elseif tim == nil and os.clock()-cloc > 5 and not yiel then
			yiel = true
			print(string.format("Infinite yield on waitforchild(%s,'%s')",ins.Name,name))
		end
		wait()
	until me ~= nil
end
function safefindclass(inst,class)
	local s,f = pcall(function()
		return inst:FindChildByClass(class)
	end)
	if s then
		return f
	end
end
function safefindchild(inst,name)
	local s,f = pcall(function()
		return inst:FindChild(name)
	end)
	if s then
		return f
	end
end

local tool = script.Parent

tool.Shared.mindamage = 20
tool.Shared.mandamage = 40