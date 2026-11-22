local LrView = import "LrView"

local Prefs = require "Prefs"

local function sectionsForTopOfDialog(f, _propertyTable)
	local prefs = Prefs.get()
	local bind = LrView.bind
	return {
		{
			title = LOC "$$$/PhotoEmul/Prefs/Title=PhotoEmul Settings",
			bind_to_object = prefs,
			f:row {
				f:static_text { title = "PhotoEmul:", width_in_chars = 10 },
				f:edit_field { value = bind "appPath", width_in_chars = 60 },
			},
			f:row {
				f:checkbox { title = LOC "$$$/PhotoEmul/Prefs/KeepInput=Keep the TIFF rendered by Lightroom (for debugging)", value = bind "keepRenderedInput" },
			},
			f:static_text {
				title = "film modeling powered by spektrafilm (GPLv3 / profile data CC BY-SA 4.0)\n"
					.. "https://github.com/andreavolpato/spektrafilm",
				height_in_lines = 2,
			},
		},
	}
end

return {
	sectionsForTopOfDialog = sectionsForTopOfDialog,
}
