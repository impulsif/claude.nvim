-- File: lua/claude.lua

local M = {}
local api = vim.api
local uv = vim.loop
local fn = vim.fn

-- Default configuration
M.config = {
    api_key = os.getenv("ANTHROPIC_API_KEY") or "",
    model = "claude-3-5-sonnet-20241022",
    endpoint = "https://api.anthropic.com/v1/messages",
    max_tokens = 8192,
    temperature = 1,
    system_prompt = "You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Any comment that is asking you for something should be removed after you satisfy them. Other comments should be left alone. Do not output backticks.",
    keymaps = {
        ask = "cl",                    -- Changed from 'ca' to 'cl'
        ask_selection = "cl",          -- Visual mode mapping
        insert_code = "cp",            -- Insert code at cursor
        apply_recommendation = "cr",    -- Apply AI recommendation
        toggle_auto_format = "cf",     -- Toggle auto-formatting of response
        cycle_history = "ch",          -- Cycle through chat history
        save_snippet = "cs",           -- Save code snippet to file
        explain_code = "ce",           -- Get explanation for selected code
        optimize_code = "co",          -- Get optimization suggestions
        generate_tests = "ct",         -- Generate unit tests for selected code
        generate_docs = "cd",          -- Generate documentation
    },
    ui = {
        prompt_width = 0.8,
        prompt_height = 0.2,
        response_width = 0.8,
        response_height = 0.4,
        border = "rounded",
        float_border = {
            { "╭", "FloatBorder" },
            { "─", "FloatBorder" },
            { "╮", "FloatBorder" },
            { "│", "FloatBorder" },
            { "╯", "FloatBorder" },
            { "─", "FloatBorder" },
            { "╰", "FloatBorder" },
            { "│", "FloatBorder" },
        },
        highlights = {
            border = "FloatBorder",
            background = "NormalFloat",
        },
    },
    snippets_dir = vim.fn.stdpath("data") .. "/claude_snippets",
    auto_format_response = true,
    syntax_highlight = true,
    save_chat_history = true,
    chat_history_file = vim.fn.stdpath("data") .. "/claude_history.json",
    max_history_size = 100,
    language_specific_prompts = {
        python = {
            test_framework = "pytest",
            doc_style = "google",
        },
        javascript = {
            test_framework = "jest",
            doc_style = "jsdoc",
        },
        -- Add more language-specific settings
    },
}

-- Chat history storage
local chat_history = {}
local current_history_index = 0
local auto_format_enabled = true

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

-- Create directories if they don't exist
local function ensure_directories()
    -- Create snippets directory
    fn.mkdir(M.config.snippets_dir, "p")
    
    -- Create directory for chat history
    local history_dir = fn.fnamemodify(M.config.chat_history_file, ":h")
    fn.mkdir(history_dir, "p")
end

-- Save chat history to file
local function save_chat_history()
    if not M.config.save_chat_history then return end
    
    local file = io.open(M.config.chat_history_file, "w")
    if file then
        file:write(vim.fn.json_encode(chat_history))
        file:close()
    end
end

-- Load chat history from file
local function load_chat_history()
    if not M.config.save_chat_history then return end
    
    local file = io.open(M.config.chat_history_file, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local success, decoded = pcall(vim.fn.json_decode, content)
        if success then
            chat_history = decoded
            current_history_index = #chat_history
        end
    end
end

-- Get current buffer's filetype
local function get_current_filetype()
    return vim.bo.filetype
end

-- Create a centered floating window with enhanced styling
local function create_floating_win(width_percent, height_percent)
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
        border = M.config.ui.border,
        title = ' Claude.nvim ',
        title_pos = 'center',
    }

    if type(M.config.ui.border) == "table" then
        opts.border = M.config.ui.float_border
    end
    
    local win = api.nvim_open_win(buf, true, opts)
    
    -- Apply highlights
    api.nvim_win_set_option(win, 'winhighlight', 'Normal:' .. M.config.ui.highlights.background)
    
    return win, buf
end

-- Format code based on filetype
local function format_code(code, filetype)
    if not M.config.auto_format_response or not auto_format_enabled then
        return code
    end

    -- Add more formatters as needed
    local formatters = {
        python = "black -",
        javascript = "prettier --parser babel",
        typescript = "prettier --parser typescript",
        lua = "lua-format",
        -- Add more language formatters
    }

    local formatter = formatters[filetype]
    if not formatter then return code end

    local tmp_file = os.tmpname()
    local f = io.open(tmp_file, "w")
    f:write(code)
    f:close()

    local formatted = vim.fn.system(formatter .. " " .. tmp_file)
    os.remove(tmp_file)

    return formatted
end

-- Enhanced setup function
function M.setup(user_config)
    if user_config then
        M.config = tbl_deep_extend(M.config, user_config)
    end

    ensure_directories()
    load_chat_history()

    if M.config.api_key == "" then
        vim.notify("[claude.nvim] Error: API key not set. Set ANTHROPIC_API_KEY environment variable.", vim.log.levels.ERROR)
        return false
    end

    -- Set up keymaps
    local function set_keymap(mode, lhs, rhs, opts)
        opts = vim.tbl_extend('force', { noremap = true, silent = true }, opts or {})
        if vim.fn.maparg(lhs, mode) ~= '' then
            api.nvim_del_keymap(mode, lhs)
        end
        api.nvim_set_keymap(mode, lhs, rhs, opts)
    end

    -- Define enhanced keymaps
    local keymaps = {
        { 'n', M.config.keymaps.ask, ':lua require("claude").open_prompt()<CR>' },
        { 'v', M.config.keymaps.ask_selection, ':lua require("claude").ask_about_selection()<CR>' },
        { 'n', M.config.keymaps.insert_code, ':lua require("claude").insert_code_at_cursor()<CR>' },
        { 'n', M.config.keymaps.apply_recommendation, ':lua require("claude").apply_ai_recommendation()<CR>' },
        { 'n', M.config.keymaps.toggle_auto_format, ':lua require("claude").toggle_auto_format()<CR>' },
        { 'n', M.config.keymaps.cycle_history, ':lua require("claude").cycle_history()<CR>' },
        { 'n', M.config.keymaps.save_snippet, ':lua require("claude").save_snippet()<CR>' },
        { 'v', M.config.keymaps.explain_code, ':lua require("claude").explain_code()<CR>' },
        { 'v', M.config.keymaps.optimize_code, ':lua require("claude").optimize_code()<CR>' },
        { 'v', M.config.keymaps.generate_tests, ':lua require("claude").generate_tests()<CR>' },
        { 'v', M.config.keymaps.generate_docs, ':lua require("claude").generate_docs()<CR>' },
    }

    for _, keymap in ipairs(keymaps) do
        set_keymap(unpack(keymap))
    end

    -- Create highlight groups
    vim.cmd([[
        highlight default link ClaudeFloatBorder FloatBorder
        highlight default link ClaudeBackground NormalFloat
    ]])
end

-- Enhanced prompt handling
function M.open_prompt()
    local win, buf = create_floating_win(
        M.config.ui.prompt_width,
        M.config.ui.prompt_height
    )

    api.nvim_buf_set_option(buf, 'buftype', 'prompt')
    vim.fn.prompt_setprompt(buf, '🤖 Ask Claude: ')
    api.nvim_command('startinsert!')

    -- Enhanced keymaps for prompt window
    local prompt_maps = {
        { 'i', '<CR>', '<Cmd>lua require("claude").handle_prompt_input()<CR>' },
        { 'i', '<Esc>', '<Cmd>close<CR>' },
        { 'i', '<C-p>', '<Cmd>lua require("claude").cycle_history(-1)<CR>' },
        { 'i', '<C-n>', '<Cmd>lua require("claude").cycle_history(1)<CR>' },
    }

    for _, map in ipairs(prompt_maps) do
        api.nvim_buf_set_keymap(buf, unpack(map), { noremap = true, silent = true })
    end
    
    return win, buf
end

-- Enhanced selection handling
function M.ask_about_selection()
    local mode = fn.mode()
    if mode ~= 'v' and mode ~= 'V' then
        vim.notify("[claude.nvim] No text selected", vim.log.levels.WARN)
        return
    end

    local start_pos = fn.getpos("'<")
    local end_pos = fn.getpos("'>")
    local lines = api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
    
    if #lines == 0 then
        vim.notify("[claude.nvim] No text selected", vim.log.levels.WARN)
        return
    end

    -- Adjust selection
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
    local filetype = get_current_filetype()
    
    local win, buf = M.open_prompt()
    api.nvim_buf_set_lines(buf, 0, -1, false, {
        string.format("Regarding this %s code:\n\n%s\n\nMy question: ", 
            filetype ~= "" and filetype or "code",
            selected_text
        )
    })
    api.nvim_win_set_cursor(win, {4, 13})
end

-- Enhanced prompt input handling
function M.handle_prompt_input()
    local buf = api.nvim_get_current_buf()
    local input = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    api.nvim_win_close(0, true)

    vim.notify("[claude.nvim] Thinking...", vim.log.levels.INFO)
    M.send_to_claude(input)
end

-- Enhanced Claude API interaction
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

    local cmd = {
        'curl', '-s', '-X', 'POST', M.config.endpoint,
        '-H', 'Content-Type: application/json',
        '-H', 'anthropic-version: 2023-06-01',
        '-H', 'x-api-key: ' .. M.config.api_key,
        '-d', body,
    }

    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    local handle

    handle = uv.spawn('curl', {
        args = cmd,
        stdio = {nil, stdout, stderr}
    }, function(code)
        stdout:close()
        stderr:close()
        handle:close()
    end)

    local response_data = ''
    stdout:read_start(function(err, data)
        if err then
            vim.schedule(function()
                vim.notify("[claude.nvim] Error reading response: " .. err, vim.log.levels.ERROR)
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

-- Enhanced response display with syntax highlighting
function M.show_response(response)
    local win, buf = create_floating_win(
        M.config.ui.response_width,
        M.config.ui.response_height
    )

    -- Set buffer options
    api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    api.nvim_buf_set_option(buf, 'swapfile', false)
    api.nvim_buf_set_option(buf, 'modifiable', true)

    -- Process and format code blocks if enabled
    local formatted_response = response
    if M.config.syntax_highlight then
        -- Extract code blocks and apply syntax highlighting
        formatted_response = response:gsub("```(%w+)\n(.-)\n```", function(lang, code)
            local formatted = format_code(code, lang:lower())
            return string.format("```%s\n%s\n```", lang, formatted)
        end)
    end

    -- Set content
    local lines = vim.split(formatted_response, '\n')
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Make buffer readonly after setting content
    api.nvim_buf_set_option(buf, 'modifiable', false)

    -- Enhanced keymaps for response window
    local response_maps = {
        { 'n', 'q', ':close<CR>' },
        { 'n', '<Esc>', ':close<CR>' },
        { 'n', 'yc', ':lua require("claude").yank_code_blocks()<CR>' },
        { 'n', '<C-s>', ':lua require("claude").save_response()<CR>' },
        { 'n', '<C-f>', ':lua require("claude").toggle_auto_format()<CR>' },
    }

    for _, map in ipairs(response_maps) do
        api.nvim_buf_set_keymap(buf, unpack(map), { noremap = true, silent = true })
    end

    -- Enable syntax highlighting
    if M.config.syntax_highlight then
        vim.cmd('set syntax=markdown')
    end
end

-- New function to toggle auto-formatting
function M.toggle_auto_format()
    auto_format_enabled = not auto_format_enabled
    vim.notify(
        string.format("[claude.nvim] Auto-formatting %s", 
        auto_format_enabled and "enabled" or "disabled"),
        vim.log.levels.INFO
    )
end

-- Enhanced history cycling
function M.cycle_history(direction)
    if #chat_history == 0 then return end

    current_history_index = current_history_index + (direction * 2)
    if current_history_index < 1 then
        current_history_index = 1
    elseif current_history_index > #chat_history then
        current_history_index = #chat_history
    end

    local history_item = chat_history[current_history_index]
    if history_item and history_item.role == "user" then
        local buf = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(history_item.content, '\n'))
    end
end

-- New function to save code snippets
function M.save_snippet()
    local last_response = chat_history[#chat_history]
    if not last_response or last_response.role ~= "assistant" then
        vim.notify("[claude.nvim] No code snippet to save", vim.log.levels.WARN)
        return
    end

    -- Extract code blocks
    local code_blocks = {}
    for lang, code in last_response.content:gmatch("```(%w+)\n(.-)\n```") do
        table.insert(code_blocks, {lang = lang, code = code})
    end

    if #code_blocks == 0 then
        vim.notify("[claude.nvim] No code blocks found", vim.log.levels.WARN)
        return
    end

    -- Create snippet file
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local filename = string.format("%s/snippet_%s.%s", 
        M.config.snippets_dir,
        timestamp,
        code_blocks[1].lang
    )

    local file = io.open(filename, "w")
    if file then
        file:write(code_blocks[1].code)
        file:close()
        vim.notify(string.format("[claude.nvim] Snippet saved to %s", filename), vim.log.levels.INFO)
    else
        vim.notify("[claude.nvim] Error saving snippet", vim.log.levels.ERROR)
    end
end

-- New function to explain code
function M.explain_code()
    local mode = fn.mode()
    if mode ~= 'v' and mode ~= 'V' then
        vim.notify("[claude.nvim] No code selected", vim.log.levels.WARN)
        return
    end

    local selected_text = M.get_visual_selection()
    local prompt = string.format(
        "Please explain this %s code in detail:\n\n```%s\n%s\n```",
        vim.bo.filetype,
        vim.bo.filetype,
        selected_text
    )

    M.send_to_claude(prompt)
end

-- New function to optimize code
function M.optimize_code()
    local mode = fn.mode()
    if mode ~= 'v' and mode ~= 'V' then
        vim.notify("[claude.nvim] No code selected", vim.log.levels.WARN)
        return
    end

    local selected_text = M.get_visual_selection()
    local prompt = string.format(
        "Please optimize this %s code and explain the improvements:\n\n```%s\n%s\n```",
        vim.bo.filetype,
        vim.bo.filetype,
        selected_text
    )

    M.send_to_claude(prompt)
end

-- New function to generate tests
function M.generate_tests()
    local mode = fn.mode()
    if mode ~= 'v' and mode ~= 'V' then
        vim.notify("[claude.nvim] No code selected", vim.log.levels.WARN)
        return
    end

    local selected_text = M.get_visual_selection()
    local filetype = vim.bo.filetype
    local test_framework = M.config.language_specific_prompts[filetype] 
        and M.config.language_specific_prompts[filetype].test_framework
        or "default"

    local prompt = string.format(
        "Generate unit tests for this %s code using %s:\n\n```%s\n%s\n```",
        filetype,
        test_framework,
        filetype,
        selected_text
    )

    M.send_to_claude(prompt)
end

-- New function to generate documentation
function M.generate_docs()
    local mode = fn.mode()
    if mode ~= 'v' and mode ~= 'V' then
        vim.notify("[claude.nvim] No code selected", vim.log.levels.WARN)
        return
    end

    local selected_text = M.get_visual_selection()
    local filetype = vim.bo.filetype
    local doc_style = M.config.language_specific_prompts[filetype] 
        and M.config.language_specific_prompts[filetype].doc_style
        or "default"

    local prompt = string.format(
        "Generate %s style documentation for this %s code:\n\n```%s\n%s\n```",
        doc_style,
        filetype,
        filetype,
        selected_text
    )

    M.send_to_claude(prompt)
end

-- Helper function to get visual selection
function M.get_visual_selection()
    local start_pos = fn.getpos("'<")
    local end_pos = fn.getpos("'>")
    local lines = api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
    
    if #lines == 0 then return "" end

    -- Adjust the lines for partial selections
    if #lines == 1 then
        lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
    else
        lines[1] = lines[1]:sub(start_pos[3])
        lines[#lines] = lines[#lines]:sub(1, end_pos[3])
    end

    return table.concat(lines, '\n')
end

return M
