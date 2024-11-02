-- File: lua/claude.lua

local M = {}
local api = vim.api

-- Default configuration
M.config = {
    api_key = os.getenv("ANTHROPIC_API_KEY") or "",
    model = "claude-3-5-sonnet-20241022",
    endpoint = "https://api.anthropic.com/v1/messages",
    max_tokens = 8192,
    temperature = 1,
    system_prompt = "You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them. Other comments should be left alone. Do not output backticks.",
    keymaps = {
        ask = "ca",
        insert_code = "cp",
        apply_recommendation = "cr",
    },
}

-- Helper function to merge configurations
local function tbl_deep_extend(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k] or false) == "table" then
            tbl_deep_extend(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

function M.setup(user_config)
    -- Merge user_config with default config
    if user_config then
        M.config = tbl_deep_extend(M.config, user_config)
    end

    -- Validate API key
    if M.config.api_key == "" then
        vim.notify("[claude.nvim] Error: API key for Claude is not set. Set ANTHROPIC_API_KEY environment variable.", vim.log.levels.ERROR)
        return false
    end

    -- Remove existing key mappings to avoid conflicts
    api.nvim_del_keymap('n', M.config.keymaps.ask)
    api.nvim_del_keymap('v', M.config.keymaps.ask)

    -- Define key mappings for your functionalities
    api.nvim_set_keymap('n', M.config.keymaps.ask, ':lua require("claude").open_empty_prompt()<CR>', { noremap = true, silent = true })
    api.nvim_set_keymap('n', M.config.keymaps.insert_code, ':lua require("claude").insert_code_at_cursor()<CR>', { noremap = true, silent = true })
    api.nvim_set_keymap('n', M.config.keymaps.apply_recommendation, ':lua require("claude").apply_ai_recommendation()<CR>', { noremap = true, silent = true })
end

function M.open_empty_prompt()
    local buf = api.nvim_create_buf(false, true)  -- Create a scratch buffer
    local width = math.floor(vim.o.columns * 0.8)
    local height = 1  -- Single line for prompt
    local opts = {
        relative = 'editor',
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = 'minimal',
        border = 'none',
    }
    local win = api.nvim_open_win(buf, true, opts)
    api.nvim_buf_set_option(buf, 'buftype', 'prompt')
    vim.fn.prompt_setprompt(buf, '')  -- Set an empty prompt
    api.nvim_command('startinsert')  -- Start in insert mode

    -- Map <CR> in the prompt buffer to handle the input
    api.nvim_buf_set_keymap(buf, 'i', '<CR>', '<Cmd>lua require("claude").handle_prompt_input(' .. buf .. ',' .. win .. ')<CR>', { noremap = true, silent = true })
end

function M.handle_prompt_input(buf, win)
    local input = api.nvim_buf_get_lines(buf, 0, -1, false)[1] or ""
    api.nvim_win_close(win, true)  -- Close the prompt window

    -- Insert the input at the cursor position in the original buffer
    local cur_buf = api.nvim_get_current_buf()
    local pos = api.nvim_win_get_cursor(0)
    local row = pos[1] - 1  -- Zero-based indexing
    local col = pos[2]
    api.nvim_buf_set_text(cur_buf, row, col, row, col, { input })
end

function M.insert_code_at_cursor()
    -- Modify this to retrieve code dynamically if needed
    local code_to_insert = "your code here"  -- Replace with actual code

    local pos = api.nvim_win_get_cursor(0)
    local row = pos[1] - 1
    local col = pos[2]
    api.nvim_buf_set_text(0, row, col, row, col, { code_to_insert })
end

function M.apply_ai_recommendation()
    local recommendation = M.get_recommendation()
    if recommendation then
        local pos = api.nvim_win_get_cursor(0)
        local row = pos[1] - 1
        local col = pos[2]
        api.nvim_buf_set_text(0, row, col, row, col, { recommendation })
    else
        vim.notify("[claude.nvim] No recommendation available.", vim.log.levels.INFO)
    end
end

function M.get_recommendation()
    -- Implement the logic to interact with the Claude API

    local prompt = M.config.system_prompt

    -- Prepare the headers and body for the API request
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = M.config.api_key,
    }

    local body = {
        model = M.config.model,
        prompt = prompt,
        max_tokens_to_sample = M.config.max_tokens,
        temperature = M.config.temperature,
    }

    -- Use vim.fn.jobstart for asynchronous execution
    local cmd = {
        'curl', '-s', '-X', 'POST', M.config.endpoint,
        '-H', 'Content-Type: application/json',
        '-H', 'x-api-key: ' .. M.config.api_key,
        '-d', vim.fn.json_encode(body),
    }

    local result = vim.fn.system(cmd)
    local response = vim.fn.json_decode(result)

    if response and response.completion then
        return response.completion
    else
        return nil
    end
end

return M
