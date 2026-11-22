local LrFileUtils = import "LrFileUtils"
local LrPrefs = import "LrPrefs"

local Config = require "Config"

local Prefs = {}

-- Plugin preferences, falling back to the paths written by install.sh.
function Prefs.get()
	local prefs = LrPrefs.prefsForPlugin()
	-- A saved path to the app under a former name (SpektraLab.app, Emulsa.app) that is gone follows the rename.
	local renamed = prefs.appPath ~= nil
		and (string.find(prefs.appPath, "SpektraLab%.app$") or string.find(prefs.appPath, "Emulsa%.app$"))
		and not LrFileUtils.exists(prefs.appPath)
	if prefs.appPath == nil or prefs.appPath == "" or renamed then
		prefs.appPath = Config.appPath or ""
	end
	if prefs.keepRenderedInput == nil then
		prefs.keepRenderedInput = false
	end
	return prefs
end

return Prefs
