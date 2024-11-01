-- claude.lua
-- Claude.nvim: Neovim plugin integrating Claude AI for enhanced code assistance

local M = {}
local api = vim.api
local uv = vim.loop

-- Configuration table
M.config = {
    api_key = '', -- Claude API Key
    api_url = 'https://api.claude.ai/v1/chat', -- Claude API Endpoint
    default_model = 'claude-instant', -- Default model to use
}

-- Utility function to display messages
local function notify(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO, { title = 'Claude.nvim' })
end

-- Utility function to read selected text
local function get_selected_text()
    local mode = vim.fn.mode()
    if mode:find('v') then
        local start_pos = api.nvim_buf_get_mark(0, '<')
        local end_pos = api.nvim_buf_get_mark(0, '>')
        local lines = api.nvim_buf_get_lines(0, start_pos[1]-1, end_pos[1], false)
        -- Adjust for start and end columns
        if #lines == 1 then
            lines[1] = string.sub(lines[1], start_pos[2]+1, end_pos[2])
        else
            lines[1] = string.sub(lines[1], start_pos[2]+1)
            lines[#lines] = string.sub(lines[#lines], 1, end_pos[2])
        end
        return table.concat(lines, '\n')
    else
        return vim.fn.expand('<cword>')
    end
end

-- Utility function to replace selected text
local function replace_selected_text(replacement)
    local mode = vim.fn.mode()
    if mode:find('v') then
        vim.cmd('normal! gv')
        api.nvim_put({ replacement }, 'c', true, true)
    else
        -- Insert below the current line
        api.nvim_put({ replacement }, 'l', true, true)
    end
end

-- Function to send request to Claude API
local function send_request(prompt, callback)
    if M.config.api_key == '' then
        notify('Claude API key is not set. Please configure it in the plugin settings.', vim.log.levels.ERROR)
        return
    end

    local body = {
        model = M.config.default_model,
        prompt = prompt,
        max_tokens = 1500,
        temperature = 0.7,
    }

    local json_body = vim.fn.json_encode(body)

    local headers = {
        'Content-Type: application/json',
        'Authorization: Bearer ' .. M.config.api_key,
    }

    local response_chunks = {}
    local req = vim.loop.new_tcp()
    local host = vim.fn.split(M.config.api_url, '/')[3]
    local port = 443
    local path = '/' .. table.concat(vim.fn.split(M.config.api_url, '/'), '/', 4)

    local function on_error(err)
        notify('Claude API request failed: ' .. err, vim.log.levels.ERROR)
        req:close()
    end

    req:connect(host, port, function(err)
        if err then
            on_error(err)
            return
        end

        local tls = vim.loop.new_tls()
        tls:connect(req, host, port, function(err)
            if err then
                on_error(err)
                return
            end

            local request = {
                'POST ' .. path .. ' HTTP/1.1',
                'Host: ' .. host,
                table.unpack(headers),
                'Content-Length: ' .. #json_body,
                '',
                json_body,
            }
            local request_str = table.concat(request, '\r\n')
            tls:write(request_str)
        end)

        tls:read_start(function(err, chunk)
            if err then
                on_error(err)
                return
            end
            if chunk then
                table.insert(response_chunks, chunk)
            else
                -- Combine chunks and parse JSON
                local response = table.concat(response_chunks)
                local header_end = response:find('\r\n\r\n')
                if header_end then
                    local body = response:sub(header_end + 4)
                    local decoded = vim.fn.json_decode(body)
                    if decoded and decoded.choices and decoded.choices[1] and decoded.choices[1].text then
                        callback(decoded.choices[1].text)
                    else
                        notify('Invalid response from Claude API.', vim.log.levels.ERROR)
                    end
                else
                    notify('Malformed response from Claude API.', vim.log.levels.ERROR)
                end
                req:close()
            end
        end)
    end)
end

-- Core function to handle different actions
local function handle_action(action)
    local selected_text = get_selected_text()
    if selected_text == '' then
        notify('No text selected.', vim.log.levels.WARN)
        return
    end

    local prompt = ''

    -- Define prompts based on action
    if action == 'enhance' then
        prompt = 'Enhance the following code for better readability and performance:\n\n' .. selected_text
    elseif action == 'refactor' then
        prompt = 'Refactor the following code to improve its structure and maintainability without changing its functionality:\n\n' .. selected_text
    elseif action == 'documentation' then
        prompt = 'Generate comprehensive documentation for the following code:\n\n' .. selected_text
    elseif action == 'explain_errors' then
        prompt = 'Explain the errors in the following code and suggest possible fixes:\n\n' .. selected_text
    elseif action == 'translate' then
        prompt = 'Translate the following code from its current programming language to Python:\n\n' .. selected_text
    elseif action == 'optimize' then
        prompt = 'Optimize the following code for better performance:\n\n' .. selected_text
    elseif action == 'add_comments' then
        prompt = 'Add meaningful comments to the following code to explain its functionality:\n\n' .. selected_text
    elseif action == 'generate_tests' then
        prompt = 'Generate unit tests for the following code:\n\n' .. selected_text
    elseif action == 'create_snippet' then
        prompt = 'Create a reusable code snippet based on the following code:\n\n' .. selected_text
    else
        notify('Unknown action: ' .. action, vim.log.levels.ERROR)
        return
    end

    -- Send request to Claude
    send_request(prompt, function(response)
        vim.schedule(function()
            replace_selected_text(response)
            notify('Action "' .. action .. '" completed successfully.', vim.log.levels.INFO)
        end)
    end)
end

-- Public function to set configuration
function M.setup(user_config)
    M.config = vim.tbl_extend('force', M.config, user_config or {})

    -- Define user commands
    vim.api.nvim_create_user_command('ClaudeEnhance', function()
        handle_action('enhance')
    end, { nargs = 0, range = true, desc = 'Enhance selected code' })

    vim.api.nvim_create_user_command('ClaudeRefactor', function()
        handle_action('refactor')
    end, { nargs = 0, range = true, desc = 'Refactor selected code' })

    vim.api.nvim_create_user_command('ClaudeDocs', function()
        handle_action('documentation')
    end, { nargs = 0, range = true, desc = 'Generate documentation for selected code' })

    vim.api.nvim_create_user_command('ClaudeExplainErrors', function()
        handle_action('explain_errors')
    end, { nargs = 0, range = true, desc = 'Explain errors in selected code' })

    vim.api.nvim_create_user_command('ClaudeTranslate', function()
        handle_action('translate')
    end, { nargs = 0, range = true, desc = 'Translate selected code to Python' })

    vim.api.nvim_create_user_command('ClaudeOptimize', function()
        handle_action('optimize')
    end, { nargs = 0, range = true, desc = 'Optimize selected code' })

    vim.api.nvim_create_user_command('ClaudeAddComments', function()
        handle_action('add_comments')
    end, { nargs = 0, range = true, desc = 'Add comments to selected code' })

    vim.api.nvim_create_user_command('ClaudeGenerateTests', function()
        handle_action('generate_tests')
    end, { nargs = 0, range = true, desc = 'Generate unit tests for selected code' })

    vim.api.nvim_create_user_command('ClaudeCreateSnippet', function()
        handle_action('create_snippet')
    end, { nargs = 0, range = true, desc = 'Create a reusable snippet from selected code' })

    -- Define key mappings (optional)
    local opts = { noremap = true, silent = true, expr = false }
    vim.api.nvim_set_keymap('v', '<leader>ce', ':ClaudeEnhance<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>cr', ':ClaudeRefactor<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>cd', ':ClaudeDocs<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>cex', ':ClaudeExplainErrors<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>ct', ':ClaudeTranslate<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>co', ':ClaudeOptimize<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>ca', ':ClaudeAddComments<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>cg', ':ClaudeGenerateTests<CR>', opts)
    vim.api.nvim_set_keymap('v', '<leader>cs', ':ClaudeCreateSnippet<CR>', opts)

    notify('Claude.nvim configured successfully!', vim.log.levels.INFO)
end

return M
