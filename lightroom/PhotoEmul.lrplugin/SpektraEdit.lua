--[[ Lightroom -> PhotoEmul -> Lightroom round trip.

For each selected photo:
  1. render a full-size 16-bit ProPhoto RGB TIFF with the current Develop
     settings (or, in raw mode, take the original raw file),
  2. open it in PhotoEmul and wait
     until the user presses "Save to Lightroom" or closes the window,
  3. add the result next to the original and stack it on top.

With the native editor and several photos, the user can instead edit once and
apply that edit to all of them (one editor session, --batch-list).
The original photo path is passed as --key so reopening a photo resumes its edit.
]]

local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrLogger = import "LrLogger"
local LrPathUtils = import "LrPathUtils"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"

local Prefs = require "Prefs"

local logger = LrLogger("PhotoEmul")
logger:enable("logfile") -- ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/PhotoEmul.log

local SpektraEdit = {}

local OUTPUT_SUFFIX = "-photoemul"

local function shellQuote(s)
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function workDir()
	local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "PhotoEmul")
	LrFileUtils.createAllDirectories(dir)
	return dir
end

-- <folder>/<name>-photoemul.tif, or -photoemul-2.tif, ... if taken.
local function outputPathFor(photo)
	local source = photo:getRawMetadata("path")
	local folder = LrPathUtils.parent(source)
	local stem = LrPathUtils.removeExtension(LrPathUtils.leafName(source)) .. OUTPUT_SUFFIX
	local candidate = LrPathUtils.child(folder, stem .. ".tif")
	local n = 2
	while LrFileUtils.exists(candidate) do
		candidate = LrPathUtils.child(folder, stem .. "-" .. n .. ".tif")
		n = n + 1
	end
	return candidate
end

local function renderTiff(photo, dir)
	local session = LrExportSession {
		photosToExport = { photo },
		exportSettings = {
			LR_export_destinationType = "specificFolder",
			LR_export_destinationPathPrefix = dir,
			LR_export_useSubfolder = false,
			-- Two photos with the same name from different folders must not share one input file.
			LR_collisionHandling = "rename",
			LR_renamingTokensOn = true,
			LR_tokens = "{{image_originalName}}_lrinput",
			LR_format = "TIFF",
			LR_export_bitDepth = 16,
			LR_export_colorSpace = "ProPhotoRGB",
			LR_tiff_compressionMethod = "compressionMethod_ZIP",
			LR_size_doConstrain = false,
			LR_outputSharpeningOn = false,
			LR_minimizeEmbeddedMetadata = false,
			LR_removeLocationMetadata = false,
			LR_includeVideoFiles = false,
			LR_reimportExportedPhoto = false,
			LR_export_postProcessing = "doNothing",
		},
	}
	for _, rendition in session:renditions() do
		local ok, pathOrMessage = rendition:waitForRender()
		if ok then
			return pathOrMessage
		end
		return nil, pathOrMessage
	end
	return nil, LOC "$$$/PhotoEmul/Error/NothingToRender=No photo to render."
end

local function readTail(path, maxChars)
	local ok, text = pcall(LrFileUtils.readFile, path)
	if not ok or text == nil then
		return ""
	end
	if #text > maxChars then
		text = "..." .. string.sub(text, -maxChars)
	end
	return text
end

-- The editor binary inside PhotoEmul.app, or nil when it is missing.
local function nativeEditor(prefs)
	if prefs.appPath == nil or prefs.appPath == "" then
		return nil
	end
	local macos = LrPathUtils.child(LrPathUtils.child(prefs.appPath, "Contents"), "MacOS")
	-- "Emulsa" and "SpektraLab" are the app's former names; older builds and saved paths still use them.
	for _, name in ipairs({ "PhotoEmul", "Emulsa", "SpektraLab" }) do
		local binary = LrPathUtils.child(macos, name)
		if LrFileUtils.exists(binary) then
			return binary
		end
	end
	return nil
end

local function checkSetup(prefs)
	if nativeEditor(prefs) then
		return nil
	end
	return LOC "$$$/PhotoEmul/Error/AppMissing=Cannot find PhotoEmul.app:" .. "\n" .. tostring(prefs.appPath)
end

-- The editor input for a photo: the raw original, or a rendered TIFF (second value).
local function prepareInput(photo, options, dir)
	if options.raw and photo:getRawMetadata("fileFormat") == "RAW" then
		return photo:getRawMetadata("path"), nil
	end
	local renderedPath, message = renderTiff(photo, dir)
	if renderedPath == nil then
		return nil, LOC "$$$/PhotoEmul/Error/RenderFailed=Rendering the TIFF failed:" .. " " .. tostring(message)
	end
	return renderedPath, renderedPath
end

-- Returns the output path on success, nil + message on error, or nil when
-- the user closed the editor without saving.
local function editOne(photo, options, prefs)
	local dir = workDir()
	local inputPath, renderedPath = prepareInput(photo, options, dir)
	if inputPath == nil then
		return nil, renderedPath
	end

	local outputPath = outputPathFor(photo)
	local logPath = LrPathUtils.child(dir, "lr_edit.log")
	local command = table.concat({
		shellQuote(nativeEditor(prefs)),
		"--input", shellQuote(inputPath),
		"--output", shellQuote(outputPath),
		"--key", shellQuote(photo:getRawMetadata("path")),
		">", shellQuote(logPath), "2>&1",
	}, " ")
	logger:info("run: " .. command)
	local status = LrTasks.execute(command)
	logger:info("exit status: " .. tostring(status))

	if renderedPath and not prefs.keepRenderedInput then
		LrFileUtils.delete(renderedPath)
	end

	if LrFileUtils.exists(outputPath) then
		return outputPath
	end
	local log = readTail(logPath, 1500)
	if string.find(log, "Error") then
		return nil, LOC "$$$/PhotoEmul/Error/Run=PhotoEmul failed:" .. "\n\n" .. log
	end
	return nil -- closed without saving
end

-- One editor session for all photos: the edit made on the first photo is saved to
-- every photo. Returns a list of { photo, outputPath } or nil + message.
local function editBatch(photos, options, prefs, progress)
	local dir = workDir()
	local lines, items, rendered, reserved = {}, {}, {}, {}
	for i, photo in ipairs(photos) do
		if progress:isCanceled() then
			break
		end
		progress:setCaption(LOC "$$$/PhotoEmul/Progress/Preparing=Preparing:" .. " " .. (photo:getFormattedMetadata("fileName") or ""))
		progress:setPortionComplete(i - 1, #photos)
		local inputPath, renderedPath = prepareInput(photo, options, dir)
		if inputPath == nil then
			for _, path in ipairs(rendered) do LrFileUtils.delete(path) end
			return nil, renderedPath
		end
		if renderedPath then
			rendered[#rendered + 1] = renderedPath
		end
		-- Two photos with the same name in one folder must not get the same output path.
		local outputPath = outputPathFor(photo)
		local n = 2
		while reserved[outputPath] do
			outputPath = LrPathUtils.removeExtension(outputPath) .. "-" .. n .. ".tif"
			n = n + 1
		end
		reserved[outputPath] = true
		lines[#lines + 1] = table.concat({ inputPath, outputPath, photo:getRawMetadata("path") }, "\t")
		items[#items + 1] = { photo = photo, outputPath = outputPath }
	end
	-- Cancelled while preparing: do not open the editor with only part of the selection.
	if progress:isCanceled() then
		for _, path in ipairs(rendered) do LrFileUtils.delete(path) end
		return {}
	end

	local listPath = LrPathUtils.child(dir, "batch.tsv")
	local file = io.open(listPath, "w")
	file:write(table.concat(lines, "\n"), "\n")
	file:close()

	local logPath = LrPathUtils.child(dir, "lr_edit.log")
	progress:setCaption(LOC "$$$/PhotoEmul/Progress/BatchEdit=Edit the first photo in the editor, then click 'Save to Lightroom'")
	local command = table.concat({
		shellQuote(nativeEditor(prefs)),
		"--batch-list", shellQuote(listPath),
		">", shellQuote(logPath), "2>&1",
	}, " ")
	logger:info("run: " .. command)
	local status = LrTasks.execute(command)
	logger:info("exit status: " .. tostring(status))

	if not prefs.keepRenderedInput then
		for _, path in ipairs(rendered) do LrFileUtils.delete(path) end
	end
	LrFileUtils.delete(listPath)

	local done = {}
	for _, item in ipairs(items) do
		if LrFileUtils.exists(item.outputPath) then
			done[#done + 1] = item
		end
	end
	if #done == 0 then
		local log = readTail(logPath, 1500)
		if string.find(log, "Error") then
			return nil, LOC "$$$/PhotoEmul/Error/Run=PhotoEmul failed:" .. "\n\n" .. log
		end
	end
	return done
end

local function importStacked(catalog, photo, outputPath)
	local added
	catalog:withWriteAccessDo(LOC "$$$/PhotoEmul/Undo/AddResult=Add PhotoEmul Result", function()
		added = catalog:addPhoto(outputPath, photo, "above")
	end)
	return added
end

function SpektraEdit.run(options)
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	if #photos == 0 then
		return
	end

	local prefs = Prefs.get()
	local setupError = checkSetup(prefs)
	if setupError then
		LrDialogs.message("PhotoEmul", setupError
			.. "\n\n" .. LOC "$$$/PhotoEmul/Error/SetPath=Set the path in File > Plug-in Manager > PhotoEmul.", "critical")
		return
	end

	local batch = false
	if #photos > 1 then
		local choice = LrDialogs.confirm(
			LOC("$$$/PhotoEmul/Batch/Selected=^1 photos selected.", #photos),
			LOC "$$$/PhotoEmul/Batch/Explain=Edit once and apply the same edit to every photo, or edit them one by one.",
			LOC "$$$/PhotoEmul/Batch/Same=Same Edit for All", LOC "$$$/PhotoEmul/Batch/Cancel=Cancel",
			LOC "$$$/PhotoEmul/Batch/OneByOne=One by One")
		if choice == "cancel" then
			return
		end
		batch = choice == "ok"
	end

	local progress = LrProgressScope {
		title = LOC "$$$/PhotoEmul/Progress/Editing=Editing in PhotoEmul (click 'Save to Lightroom' in the editor window)",
	}
	local added = {}
	if batch then
		local ok, done, message = LrTasks.pcall(editBatch, photos, options, prefs, progress)
		if not ok then
			message = tostring(done)
			done = nil
		end
		if done then
			for _, item in ipairs(done) do
				local newPhoto = importStacked(catalog, item.photo, item.outputPath)
				if newPhoto then
					added[#added + 1] = newPhoto
				end
			end
		elseif message then
			logger:error(message)
			LrDialogs.message("PhotoEmul", message, "critical")
		end
		photos = {}
	end
	for i, photo in ipairs(photos) do
		if progress:isCanceled() then
			break
		end
		progress:setCaption(photo:getFormattedMetadata("fileName") or "")
		progress:setPortionComplete(i - 1, #photos)
		local ok, outputPath, message = LrTasks.pcall(editOne, photo, options, prefs)
		if not ok then
			message = tostring(outputPath)
			outputPath = nil
		end
		if outputPath then
			local newPhoto = importStacked(catalog, photo, outputPath)
			if newPhoto then
				added[#added + 1] = newPhoto
			end
		elseif message then
			logger:error(message)
			LrDialogs.message("PhotoEmul", message, "critical")
			break
		end
	end
	progress:done()

	if #added > 0 then
		catalog:setSelectedPhotos(added[1], added)
	end
end

return SpektraEdit
