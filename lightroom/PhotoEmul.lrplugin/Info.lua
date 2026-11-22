--[[ PhotoEmul for Lightroom Classic

Round-trips the selected photos through the PhotoEmul interactive editor
(film stock, print paper, exposure, enlarger filters, grain, halation, ...)
and stacks the rendered 16-bit TIFF with the original.

film modeling powered by spektrafilm - https://github.com/andreavolpato/spektrafilm
]]

local menuItems = {
	{
		title = "PhotoEmul에서 편집 (라이트룸 보정 적용)...",
		file = "EditRendered.lua",
		enabledWhen = "photosSelected",
	},
	{
		title = "PhotoEmul에서 편집 (원본 RAW)...",
		file = "EditRaw.lua",
		enabledWhen = "photosSelected",
	},
}

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = "com.github.spektrafilm4lr.edit",
	LrPluginName = "PhotoEmul",
	LrPluginInfoUrl = "https://github.com/andreavolpato/spektrafilm",

	LrLibraryMenuItems = menuItems,
	LrExportMenuItems = menuItems,

	LrPluginInfoProvider = "PluginInfoProvider.lua",

	VERSION = { major = 0, minor = 1, revision = 0, display = "0.1.0" },
}
