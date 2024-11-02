-- File: lua/claude.lua

local M = {}
local api = vim.api

M.config = {
    api_key = os.getenv("ANTHROPIC_API_KEY") or "",
    model = "claude-3-5-sonnet-20241022",
    endpoint = "https://api.anthropic.com/v1/messages",
    max_tokens = 8192,
    temperature = 1,
    system_prompt = "You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them. Other comments should left alone. Do not output backticks'",
}

function M.setup(user_config)
    -- Merge user_config with default config
    if user_config then
        M.config = vim.tbl_extend("force", M.config, user_config)
    end

    -- Validate API key
    if M.config.api_key == "" then
        vim.notify("[claude.nvim] Error: API key for Claude is not set. Set ANTHROPIC_API_KEY environment variable.", vim.log.levels.ERROR)
        return false
    end

    -- Define key mappings for your functionalities
    api.nvim_set_keymap('n', 'ca', ':lua require("claude").open_empty_prompt()<CR>', { noremap = true, silent = true })
    api.nvim_set_keymap('n', 'cp', ':lua require("claude").insert_code_at_cursor()<CR>', { noremap = true, silent = true })
    api.nvim_set_keymap('n', 'cr', ':lua require("claude").apply_ai_recommendation()<CR>', { noremap = true, silent = true })
end

function M.open_empty_prompt()
    local buf = api.nvim_create_buf(false, true)  -- Scratch buffer
    local width = math.floor(vim.o.columns * 0.8)
    local height = 1
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
    vim.fn.prompt_setprompt(buf, '')
    api.nvim_command('startinsert')

    -- Map <CR> to handle prompt input
    api.nvim_buf_set_keymap(buf, 'i', '<CR>', '<Cmd>lua require("claude").handle_prompt_input(' .. buf .. ',' .. win .. ')<CR>', { noremap = true, silent = true })
end

function M.handle_prompt_input(buf, win)
    local input = api.nvim_buf_get_lines(buf, 0, -1, false)[1] or ""
    api.nvim_win_close(win, true)

    local cur_buf = api.nvim_get_current_buf()
    local pos = api.nvim_win_get_cursor(0)
    local row = pos[1] - 1
    local col = pos[2]
    api.nvim_buf_set_text(cur_buf, row, col, row, col, { input })
end

function M.insert_code_at_cursor()
    -- Modify this to retrieve code dynamically if needed
    local code_to_insert = "your code here"

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
    local prompt = M.config.system_prompt
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

    local response = vim.fn.system({
        'curl', '-s', '-X', 'POST', M.config.endpoint,
        '-H', 'Content-Type: application/json',
        '-H', 'x-api-key: ' .. M.config.api_key,
        '-d', vim.fn.json_encode(body),
    })

    local result = vim.fn.json_decode(response)
    if result and result.completion then
        return result.completion
    else
        return nil
    end
end

return M
