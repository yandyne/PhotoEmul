local LrView = import "LrView"

local Prefs = require "Prefs"

local function sectionsForTopOfDialog(f, _propertyTable)
	local prefs = Prefs.get()
	local bind = LrView.bind
	return {
		{
			title = "PhotoEmul 설정",
			bind_to_object = prefs,
			f:row {
				f:static_text { title = "PhotoEmul:", width_in_chars = 10 },
				f:edit_field { value = bind "appPath", width_in_chars = 60 },
			},
			f:row {
				f:checkbox { title = "라이트룸에서 렌더링한 입력 TIFF 보관 (디버그용)", value = bind "keepRenderedInput" },
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
