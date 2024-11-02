-- File: lua/claude.lua

local M = {}
local api = vim.api
local uv = vim.loop

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
        ask_selection = "ca",  -- Visual mode mapping
        insert_code = "cp",
        apply_recommendation = "cr",
    },
    ui = {
        prompt_width = 0.8,    -- Percentage of screen width
        prompt_height = 0.2,   -- Percentage of screen height
        response_width = 0.8,  -- Percentage of screen width
        response_height = 0.4, -- Percentage of screen height
        border = "rounded",    -- Border style: 'none', 'single', 'double', 'rounded'
    },
}

-- Chat history storage
local chat_history = {}

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

-- Create a centered floating window
local function create_floating_win(width_percent, height_percent, border)
    local width = math.floor(vim.o.columns * width_percent)
    local height = math.floor(vim.o.lines * height_percent)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = api.nvim_create_buf(false, true)
    local opts = {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = border,
    }
    
    return api.nvim_open_win(buf, true, opts), buf
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
    local function safe_del_keymap(mode, lhs)
        if vim.fn.maparg(lhs, mode) ~= '' then
            api.nvim_del_keymap(mode, lhs)
        end
    end

    safe_del_keymap('n', M.config.keymaps.ask)
    safe_del_keymap('v', M.config.keymaps.ask_selection)
    safe_del_keymap('n', M.config.keymaps.insert_code)
    safe_del_keymap('n', M.config.keymaps.apply_recommendation)

    -- Define key mappings
    api.nvim_set_keymap('n', M.config.keymaps.ask, ':lua require("claude").open_prompt()<CR>', { noremap = true, silent = true })
    api.nvim_set_keymap('v', M.config.keymaps.ask_selection, ':lua require("claude").ask_about_selection()<CR>', { noremap = true, silent = true })
    api.nvim_set_keymap('n', M.config.keymaps.insert_code, ':lua require("claude").insert_code_at_cursor()<CR>', { noremap = true, silent = true })
    api.nvim_set_keymap('n', M.config.keymaps.apply_recommendation, ':lua require("claude").apply_ai_recommendation()<CR>', { noremap = true, silent = true })
end

function M.open_prompt()
    local win, buf = create_floating_win(
        M.config.ui.prompt_width,
        M.config.ui.prompt_height,
        M.config.ui.border
    )

    api.nvim_buf_set_option(buf, 'buftype', 'prompt')
    vim.fn.prompt_setprompt(buf, '🤖 Ask Claude: ')
    api.nvim_command('startinsert!')

    -- Map <CR> to handle input and <Esc> to close
    api.nvim_buf_set_keymap(buf, 'i', '<CR>', '<Cmd>lua require("claude").handle_prompt_input()<CR>', { noremap = true, silent = true })
    api.nvim_buf_set_keymap(buf, 'i', '<Esc>', '<Cmd>close<CR>', { noremap = true, silent = true })
    
    return win, buf
end

function M.ask_about_selection()
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local lines = api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
    
    if #lines == 0 then
        vim.notify("[claude.nvim] No text selected", vim.log.levels.WARN)
        return
    end

    -- Adjust the last line to account for partial selection
    if #lines > 0 then
        local start_col = start_pos[3] - 1
        local end_col = end_pos[3]
        if #lines == 1 then
            lines[1] = lines[1]:sub(start_col + 1, end_col)
        else
            lines[1] = lines[1]:sub(start_col + 1)
            lines[#lines] = lines[#lines]:sub(1, end_col)
        end
    end

    local selected_text = table.concat(lines, '\n')
    local win, buf = M.open_prompt()
    api.nvim_buf_set_lines(buf, 0, -1, false, {
        "Regarding this code:\n\n" .. selected_text .. "\n\nMy question: "
    })
    api.nvim_win_set_cursor(win, {4, 13}) -- Position cursor after "My question: "
end

function M.handle_prompt_input()
    local buf = api.nvim_get_current_buf()
    local input = api.nvim_buf_get_lines(buf, 0, -1, false)
    input = table.concat(input, '\n')
    api.nvim_win_close(0, true)

    -- Show loading indicator
    vim.notify("[claude.nvim] Thinking...", vim.log.levels.INFO)

    M.send_to_claude(input)
end

function M.send_to_claude(prompt)
    local headers = {
        ["Content-Type"] = "application/json",
        ["anthropic-version"] = "2023-06-01",
        ["x-api-key"] = M.config.api_key,
    }

    local body = vim.fn.json_encode({
        model = M.config.model,
        max_tokens = M.config.max_tokens,
        messages = {
            { role = "user", content = prompt }
        },
        system = M.config.system_prompt,
        temperature = M.config.temperature,
    })

    -- Prepare curl command
    local cmd = {
        'curl', '-s', '-X', 'POST', M.config.endpoint,
        '-H', 'Content-Type: application/json',
        '-H', 'anthropic-version: 2023-06-01',
        '-H', 'x-api-key: ' .. M.config.api_key,
        '-d', body,
    }

    -- Use vim.loop for async execution
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    local handle

    handle = uv.spawn('curl', {
        args = cmd,
        stdio = {nil, stdout, stderr}
    }, function(code)
        -- Cleanup
        stdout:close()
        stderr:close()
        handle:close()
    end)

    local response_data = ''
    stdout:read_start(function(err, data)
        if err then
            vim.schedule(function()
                vim.notify("[claude.nvim] Error reading response: " .. err, vim.log.levels.ERROR)
            end)
            return
        end
        if data then
            response_data = response_data .. data
        else
            -- Process complete response
            vim.schedule(function()
                local success, decoded = pcall(vim.fn.json_decode, response_data)
                if success and decoded.content and decoded.content[1] and decoded.content[1].text then
                    -- Store in chat history
                    table.insert(chat_history, {
                        role = "user",
                        content = prompt
                    })
                    table.insert(chat_history, {
                        role = "assistant",
                        content = decoded.content[1].text
                    })
                    
                    -- Display response
                    M.show_response(decoded.content[1].text)
                else
                    vim.notify("[claude.nvim] Error parsing response", vim.log.levels.ERROR)
                end
            end)
        end
    end)

    stderr:read_start(function(err, data)
        if err or data then
            vim.schedule(function()
                vim.notify("[claude.nvim] Error: " .. (data or err), vim.log.levels.ERROR)
            end)
        end
    end)
end

function M.show_response(response)
    local win, buf = create_floating_win(
        M.config.ui.response_width,
        M.config.ui.response_height,
        M.config.ui.border
    )

    -- Set buffer options
    api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    api.nvim_buf_set_option(buf, 'swapfile', false)
    api.nvim_buf_set_option(buf, 'modifiable', true)

    -- Set content
    local lines = vim.split(response, '\n')
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Make buffer readonly after setting content
    api.nvim_buf_set_option(buf, 'modifiable', false)

    -- Set mappings for the response window
    api.nvim_buf_set_keymap(buf, 'n', 'q', ':close<CR>', { noremap = true, silent = true })
    api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>', { noremap = true, silent = true })
    
    -- Enable syntax highlighting for code blocks
    vim.cmd('set syntax=markdown')
end

function M.insert_code_at_cursor()
    if #chat_history == 0 then
        vim.notify("[claude.nvim] No code available to insert", vim.log.levels.WARN)
        return
    end

    -- Get the last assistant response
    local last_response
    for i = #chat_history, 1, -1 do
        if chat_history[i].role == "assistant" then
            last_response = chat_history[i].content
            break
        end
    end

    if not last_response then
        vim.notify("[claude.nvim] No code found in last response", vim.log.levels.WARN)
        return
    end

    -- Extract code blocks from the response
    local code = last_response:match("```[%w+]*(.-)\n(.-)\n```")
    if code then
        local pos = api.nvim_win_get_cursor(0)
        local row = pos[1] - 1
        local col = pos[2]
        api.nvim_buf_set_text(0, row, col, row, col, vim.split(code, '\n'))
        vim.notify("[claude.nvim] Code inserted", vim.log.levels.INFO)
    else
        vim.notify("[claude.nvim] No code block found in response", vim.log.levels.WARN)
    end
end

function M.apply_ai_recommendation()
    if #chat_history == 0 then
        vim.notify("[claude.nvim] No recommendations available", vim.log.levels.WARN)
        return
    end

    -- Get the last assistant response
    local last_response
    for i = #chat_history, 1, -1 do
        if chat_history[i].role == "assistant" then
            last_response = chat_history[i].content
            break
        end
    end

    if last_response then
        local pos = api.nvim_win_get_cursor(0)
        local row = pos[1] - 1
        local col = pos[2]
        api.nvim_buf_set_text(0, row, col, row, col, vim.split(last_response, '\n'))
        vim.notify("[claude.nvim] Recommendation applied", vim.log.levels.INFO)
    else
        vim.notify("[claude.nvim] No recommendation found", vim.log.levels.WARN)
    end
end

return M
