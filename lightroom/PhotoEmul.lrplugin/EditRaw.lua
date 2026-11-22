local LrTasks = import "LrTasks"

local SpektraEdit = require "SpektraEdit"

LrTasks.startAsyncTask(function()
	SpektraEdit.run({ raw = true })
end)
