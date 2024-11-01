local M = {}
local api = vim.api

M.config = {
	api_key = os.getenv("ANTHROPIC_API_KEY") or "", -- Use environment variable for API key
	model = "claude-3-5-sonnet-20241022",
	endpoint = "https://api.anthropic.com/v1/messages", -- Updated to correct Anthropic API endpoint
	max_tokens = 4096, -- Increased max tokens
	temperature = 0.7, -- More flexible temperature
	system_prompt = "You are a helpful AI assistant specialized in code generation and support.",
}

function M.setup(user_config)
	-- Merge user config with default config
	if user_config then
		M.config = vim.tbl_deep_merge(M.config, user_config)
	end

	-- Validate API key
	if M.config.api_key == "" then
		vim.notify(
			"[claude.nvim] Error: API key for Claude is not set. Set ANTHROPIC_API_KEY environment variable.",
			vim.log.levels.ERROR
		)
		return false
	end

	-- Check for required dependencies
	local has_plenary, plenary = pcall(require, "plenary.job")
	local has_curl, curl = pcall(require, "plenary.curl")
	if not (has_plenary and has_curl) then
		vim.notify("[claude.nvim] Error: 'plenary.nvim' with curl support is required.", vim.log.levels.ERROR)
		return false
	end

	M.define_commands()
	return true
end

function M.ask(prompt, callback)
	if prompt == "" then
		vim.notify("[claude.nvim] Error: Prompt is empty.", vim.log.levels.WARN)
		return
	end

	local payload = {
		model = M.config.model,
		max_tokens = M.config.max_tokens,
		temperature = M.config.temperature,
		system = M.config.system_prompt,
		messages = {
			{ role = "user", content = prompt },
		},
	}

	-- Use plenary.curl for more robust HTTP requests
	require("plenary.curl").post({
		url = M.config.endpoint,
		headers = {
			["Content-Type"] = "application/json",
			["x-api-key"] = M.config.api_key,
			["anthropic-version"] = "2023-06-01",
		},
		body = vim.fn.json_encode(payload),
		callback = vim.schedule_wrap(function(response)
			if response.status ~= 200 then
				vim.notify(
					string.format("[claude.nvim] HTTP Error %d: %s", response.status, response.body),
					vim.log.levels.ERROR
				)
				return
			end

			local success, parsed = pcall(vim.fn.json_decode, response.body)
			if not success then
				vim.notify("[claude.nvim] Failed to parse JSON response", vim.log.levels.ERROR)
				return
			end

			local answer = parsed.content and parsed.content[1] and parsed.content[1].text
			if not answer then
				vim.notify("[claude.nvim] Unexpected response structure", vim.log.levels.WARN)
				return
			end

			if callback and type(callback) == "function" then
				callback(answer)
			end
		end),
	})
end

function M.define_commands()
	api.nvim_create_user_command("ClaudeAsk", function(opts)
		local prompt = table.concat(opts.fargs, " ")
		M.ask(prompt, function(answer)
			M.display_answer(answer)
		end)
	end, { nargs = "+" })

	-- Added a command to configure Claude
	api.nvim_create_user_command("ClaludeConfigure", function(opts)
		-- Allow runtime configuration
		local config = {}
		if opts.fargs[1] then
			config.model = opts.fargs[1]
		end
		if opts.fargs[2] then
			config.temperature = tonumber(opts.fargs[2])
		end
		M.setup(config)
	end, { nargs = "*" })
end

function M.display_answer(answer)
	local buf = api.nvim_create_buf(false, true)
	if not buf then
		vim.notify("[claude.nvim] Failed to create buffer", vim.log.levels.ERROR)
		return
	end

	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.6) -- Increased height
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = api.nvim_open_win(buf, true, {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		border = "rounded",
	})

	api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	api.nvim_buf_set_option(buf, "filetype", "markdown")
	api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(answer, "\n"))

	-- Add keymapping to close the window
	api.nvim_buf_set_keymap(buf, "n", "q", ":q<CR>", { noremap = true, silent = true })
end

return M
