--[[ PhotoEmul for Lightroom Classic

Round-trips the selected photos through the PhotoEmul interactive editor
(film stock, print paper, exposure, enlarger filters, grain, halation, ...)
and stacks the rendered 16-bit TIFF with the original.

film modeling powered by spektrafilm - https://github.com/andreavolpato/spektrafilm
]]

local menuItems = {
	{
		-- English defaults; Korean in TranslatedStrings_ko.txt.
		title = LOC "$$$/PhotoEmul/Menu/Rendered=Edit in PhotoEmul (with Lightroom Adjustments)...",
		file = "EditRendered.lua",
		enabledWhen = "photosSelected",
	},
	{
		title = LOC "$$$/PhotoEmul/Menu/Raw=Edit in PhotoEmul (Original Raw)...",
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
