local scriptService = game['ScriptService']

local gunFramework = scriptService['GunFramework']

local tool = script.Parent
repeat wait() until gunFramework.Shared.initalized
gunFramework['Client']:Call("initalize", tool)
print('true')