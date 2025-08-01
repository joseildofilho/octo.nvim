---@diagnostic disable
local gh = require "octo.gh"
local graphql = require "octo.gh.graphql"
local queries = require "octo.gh.queries"
local utils = require "octo.utils"
local octo_config = require "octo.config"
local navigation = require "octo.navigation"
local Snacks = require "snacks"

local M = {}

local function get_filter(opts, kind)
  local filter = ""
  local allowed_values = {}
  if kind == "issue" then
    allowed_values = { "since", "createdBy", "assignee", "mentioned", "labels", "milestone", "states" }
  elseif kind == "pull_request" then
    allowed_values = { "baseRefName", "headRefName", "labels", "states" }
  end

  for _, value in pairs(allowed_values) do
    if opts[value] then
      local val
      if #vim.split(opts[value], ",") > 1 then
        -- list
        val = vim.split(opts[value], ",")
      else
        -- string
        val = opts[value]
      end
      val = vim.json.encode(val)
      val = string.gsub(val, '"OPEN"', "OPEN")
      val = string.gsub(val, '"CLOSED"', "CLOSED")
      val = string.gsub(val, '"MERGED"', "MERGED")
      filter = filter .. value .. ":" .. val .. ","
    end
  end

  return filter
end

function M.not_implemented()
  utils.error "Not implemented yet"
end

function M.issues(opts)
  opts = opts or {}
  if not opts.states then
    opts.states = "OPEN"
  end
  local filter = get_filter(opts, "issue")
  if utils.is_blank(opts.repo) then
    opts.repo = utils.get_remote_name()
  end
  if not opts.repo then
    utils.error "Cannot find repo"
    return
  end

  local owner, name = utils.split_repo(opts.repo)
  local cfg = octo_config.values
  local order_by = cfg.issues.order_by
  local query = graphql("issues_query", owner, name, filter, order_by.field, order_by.direction, { escape = false })
  utils.info "Fetching issues (this may take a while) ..."
  gh.run {
    args = { "api", "graphql", "--paginate", "--jq", ".", "-f", string.format("query=%s", query) },
    cb = function(output, stderr)
      if stderr and not utils.is_blank(stderr) then
        utils.error(stderr)
      elseif output then
        local resp = utils.aggregate_pages(output, "data.repository.issues.nodes")
        local issues = resp.data.repository.issues.nodes
        if #issues == 0 then
          utils.error(string.format("There are no matching issues in %s.", opts.repo))
          return
        end
        local max_number = -1
        for _, issue in ipairs(issues) do
          if issue.number > max_number then
            max_number = issue.number
          end
          issue.text = string.format("#%d %s", issue.number, issue.title)
          issue.file = utils.get_issue_uri(issue.number, issue.repository.nameWithOwner)
          issue.kind = issue.__typename:lower()
        end

        -- Prepare actions and keys for Snacks
        local final_actions = {}
        local final_keys = {}
        local default_mode = { "n", "i" }

        -- Process custom actions from config array
        local custom_actions_defined = {} -- Keep track of names defined by user
        if
          cfg.picker_config.snacks
          and cfg.picker_config.snacks.actions
          and cfg.picker_config.snacks.actions.issues
        then
          for _, action_item in ipairs(cfg.picker_config.snacks.actions.issues) do
            if action_item.name and action_item.fn then
              final_actions[action_item.name] = action_item.fn
              custom_actions_defined[action_item.name] = true
              if action_item.lhs then
                final_keys[action_item.lhs] = { action_item.name, mode = action_item.mode or default_mode }
              end
            end
          end
        end

        -- Add default actions/keys if not overridden by name or lhs
        if not custom_actions_defined["open_in_browser"] then
          final_actions["open_in_browser"] = function(_picker, item)
            navigation.open_in_browser(item.kind, item.repository.nameWithOwner, item.number)
          end
        end
        if not final_keys[cfg.picker_config.mappings.open_in_browser.lhs] then
          final_keys[cfg.picker_config.mappings.open_in_browser.lhs] = { "open_in_browser", mode = default_mode }
        end

        if not custom_actions_defined["copy_url"] then
          final_actions["copy_url"] = function(_picker, item)
            utils.copy_url(item.url)
          end
        end
        if not final_keys[cfg.picker_config.mappings.copy_url.lhs] then
          final_keys[cfg.picker_config.mappings.copy_url.lhs] = { "copy_url", mode = default_mode }
        end

        Snacks.picker.pick {
          title = opts.preview_title or "Issues",
          items = issues,
          format = function(item, _)
            local a = Snacks.picker.util.align
            ---@type snacks.picker.Highlight[]
            local ret = {}

            ---@diagnostic disable-next-line: assign-type-mismatch
            ret[#ret + 1] = utils.get_icon { kind = item.kind, obj = item }

            ret[#ret + 1] = { " " }

            local issue_id = string.format("#%d", item.number)
            local issue_id_width = #tostring(max_number) + 1

            ret[#ret + 1] = { a(issue_id, issue_id_width), "SnacksPickerGitIssue" }

            ret[#ret + 1] = { " " }

            ret[#ret + 1] = { item.title }

            return ret
          end,
          win = {
            input = {
              keys = final_keys, -- Use the constructed keys map
            },
          },
          actions = final_actions, -- Use the constructed actions map
        }
      end
    end,
  }
end

function M.pull_requests(opts)
  opts = opts or {}
  if not opts.states then
    opts.states = "OPEN"
  end
  local filter = get_filter(opts, "pull_request")
  if utils.is_blank(opts.repo) then
    opts.repo = utils.get_remote_name()
  end
  if not opts.repo then
    utils.error "Cannot find repo"
    return
  end

  local owner, name = utils.split_repo(opts.repo)
  local cfg = octo_config.values
  local order_by = cfg.pull_requests.order_by
  local query =
    graphql("pull_requests_query", owner, name, filter, order_by.field, order_by.direction, { escape = false })
  utils.info "Fetching pull requests (this may take a while) ..."
  gh.run {
    args = { "api", "graphql", "--paginate", "--jq", ".", "-f", string.format("query=%s", query) },
    cb = function(output, stderr)
      if stderr and not utils.is_blank(stderr) then
        utils.error(stderr)
      elseif output then
        local resp = utils.aggregate_pages(output, "data.repository.pullRequests.nodes")
        local pull_requests = resp.data.repository.pullRequests.nodes
        if #pull_requests == 0 then
          utils.error(string.format("There are no matching pull requests in %s.", opts.repo))
          return
        end
        local max_number = -1
        for _, pull in ipairs(pull_requests) do
          if pull.number > max_number then
            max_number = pull.number
          end
          pull.text = string.format("#%d %s", pull.number, pull.title)
          pull.file = utils.get_pull_request_uri(pull.number, pull.repository.nameWithOwner)
          pull.kind = pull.__typename:lower() == "pullrequest" and "pull_request" or "unknown"
        end

        -- Prepare actions and keys for Snacks
        local final_actions = {}
        local final_keys = {}
        local default_mode = { "n", "i" }

        -- Process custom actions from config array
        local custom_actions_defined = {}
        if
          cfg.picker_config.snacks
          and cfg.picker_config.snacks.actions
          and cfg.picker_config.snacks.actions.pull_requests
        then
          for _, action_item in ipairs(cfg.picker_config.snacks.actions.pull_requests) do
            if action_item.name and action_item.fn then
              final_actions[action_item.name] = action_item.fn
              custom_actions_defined[action_item.name] = true
              if action_item.lhs then
                final_keys[action_item.lhs] = { action_item.name, mode = action_item.mode or default_mode }
              end
            end
          end
        end

        -- Add default actions/keys if not overridden
        if not custom_actions_defined["open_in_browser"] then
          final_actions["open_in_browser"] = function(_picker, item)
            navigation.open_in_browser(item.kind, item.repository.nameWithOwner, item.number)
          end
        end
        if not final_keys[cfg.picker_config.mappings.open_in_browser.lhs] then
          final_keys[cfg.picker_config.mappings.open_in_browser.lhs] = { "open_in_browser", mode = default_mode }
        end

        if not custom_actions_defined["copy_url"] then
          final_actions["copy_url"] = function(_picker, item)
            utils.copy_url(item.url)
          end
        end
        if not final_keys[cfg.picker_config.mappings.copy_url.lhs] then
          final_keys[cfg.picker_config.mappings.copy_url.lhs] = { "copy_url", mode = default_mode }
        end

        if not custom_actions_defined["check_out_pr"] then
          final_actions["check_out_pr"] = function(_picker, item)
            utils.checkout_pr(item.number)
          end
        end
        if not final_keys[cfg.picker_config.mappings.checkout_pr.lhs] then
          final_keys[cfg.picker_config.mappings.checkout_pr.lhs] = { "check_out_pr", mode = default_mode }
        end

        if not custom_actions_defined["merge_pr"] then
          final_actions["merge_pr"] = function(_picker, item)
            utils.merge_pr(item.number)
          end
        end
        if not final_keys[cfg.picker_config.mappings.merge_pr.lhs] then
          final_keys[cfg.picker_config.mappings.merge_pr.lhs] = { "merge_pr", mode = default_mode }
        end

        if not custom_actions_defined["copy_sha"] then
          final_actions["copy_sha"] = function(_picker, item)
            -- Fetch PR details to get the head SHA
            utils.info "Fetching PR details for SHA..."
            local owner, repo = utils.split_repo(item.repository.nameWithOwner)
            gh.api.get {
              "/repos/{owner}/{repo}/pulls/{pull_number}",
              format = { owner = owner, repo = repo, pull_number = item.number },
              opts = {
                cb = gh.create_callback {
                  success = function(output)
                    local pr_data = vim.json.decode(output)
                    utils.copy_sha(pr_data.head.sha)
                  end,
                },
              },
            }
          end
        end
        if not final_keys[cfg.picker_config.mappings.copy_sha.lhs] then
          final_keys[cfg.picker_config.mappings.copy_sha.lhs] = { "copy_sha", mode = default_mode }
        end

        Snacks.picker.pick {
          title = opts.preview_title or "Pull Requests",
          items = pull_requests,
          format = function(item, _)
            ---@type snacks.picker.Highlight[]
            local ret = {}
            ---@diagnostic disable-next-line: assign-type-mismatch
            ret[#ret + 1] = utils.get_icon { kind = item.kind, obj = item }
            ret[#ret + 1] = { string.format("#%d", item.number), "Comment" }
            ret[#ret + 1] = { (" "):rep(#tostring(max_number) - #tostring(item.number) + 1) }
            ret[#ret + 1] = { item.title, "Normal" }
            return ret
          end,
          win = {
            input = {
              keys = final_keys, -- Use the constructed keys map
            },
          },
          actions = final_actions, -- Use the constructed actions map
        }
      end
    end,
  }
end

function M.notifications(opts)
  opts = opts or {}
  local cfg = octo_config.values

  local endpoint = "/notifications"
  if opts.repo then
    local owner, name = utils.split_repo(opts.repo)
    endpoint = string.format("/repos/%s/%s/notifications", owner, name)
  end
  opts.prompt_title = opts.repo and string.format("%s Notifications", opts.repo) or "Github Notifications"

  opts.preview_title = ""
  opts.results_title = ""

  gh.run {
    args = { "api", "--paginate", endpoint },
    headers = { "Accept: application/vnd.github.v3.diff" },
    cb = function(output, stderr)
      if stderr and not utils.is_blank(stderr) then
        utils.error(stderr)
      elseif output then
        local notifications = vim.json.decode(output)

        if #notifications == 0 then
          utils.info "There are no notifications"
          return
        end

        local safe_notifications = {}

        for _, notification in ipairs(notifications) do
          local safe = false
          notification.subject.number = notification.subject.url:match "%d+$"
          notification.text = string.format("#%d %s", notification.subject.number, notification.subject.title)
          notification.kind = notification.subject.type:lower()
          if notification.kind == "pullrequest" then
            notification.kind = "pull_request"
          end
          notification.status = notification.unread and "unread" or "read"
          if notification.kind == "issue" then
            notification.file = utils.get_issue_uri(notification.subject.number, notification.repository.full_name)
            safe = true
          elseif notification.kind == "pull_request" then
            notification.file =
              utils.get_pull_request_uri(notification.subject.number, notification.repository.full_name)
            safe = true
          end
          if safe then
            safe_notifications[#safe_notifications + 1] = notification
          end
        end

        -- Prepare actions and keys for Snacks
        local final_actions = {}
        local final_keys = {}
        local default_mode = { "n", "i" }

        -- Process custom actions from config array
        local custom_actions_defined = {}
        if
          cfg.picker_config.snacks
          and cfg.picker_config.snacks.actions
          and cfg.picker_config.snacks.actions.notifications
        then
          for _, action_item in ipairs(cfg.picker_config.snacks.actions.notifications) do
            if action_item.name and action_item.fn then
              final_actions[action_item.name] = action_item.fn
              custom_actions_defined[action_item.name] = true
              if action_item.lhs then
                final_keys[action_item.lhs] = { action_item.name, mode = action_item.mode or default_mode }
              end
            end
          end
        end

        -- Add default actions/keys if not overridden
        if not custom_actions_defined["open_in_browser"] then
          final_actions["open_in_browser"] = function(_picker, item)
            navigation.open_in_browser(item.kind, item.repository.full_name, item.subject.number)
          end
        end
        if not final_keys[cfg.picker_config.mappings.open_in_browser.lhs] then
          final_keys[cfg.picker_config.mappings.open_in_browser.lhs] = { "open_in_browser", mode = default_mode }
        end

        if not custom_actions_defined["copy_url"] then
          final_actions["copy_url"] = function(_picker, item)
            -- Note: notification item doesn't have a direct .url, need to construct or use subject URL?
            -- Using subject URL for now, might need adjustment depending on desired behavior.
            utils.copy_url(item.subject.url or "")
          end
        end
        if not final_keys[cfg.picker_config.mappings.copy_url.lhs] then
          final_keys[cfg.picker_config.mappings.copy_url.lhs] = { "copy_url", mode = default_mode }
        end

        if not custom_actions_defined["copy_sha"] then
          final_actions["copy_sha"] = function(_picker, item)
            if item.kind == "pull_request" then
              -- For PR notifications, we need to fetch the PR details to get the head SHA
              -- This is a simplified approach - in a real implementation, you might want to cache this
              utils.info "Fetching PR details for SHA..."
              local owner, repo = item.repository.full_name:match "([^/]+)/(.+)"
              gh.api.get {
                "/repos/{owner}/{repo}/pulls/{pull_number}",
                format = { owner = owner, repo = repo, pull_number = item.subject.number },
                opts = {
                  cb = gh.create_callback {
                    success = function(output)
                      local pr_data = vim.json.decode(output)
                      utils.copy_sha(pr_data.head.sha)
                    end,
                  },
                },
              }
            else
              utils.info "Copy SHA not available for this notification type"
            end
          end
        end
        if not final_keys[cfg.picker_config.mappings.copy_sha.lhs] then
          final_keys[cfg.picker_config.mappings.copy_sha.lhs] = { "copy_sha", mode = default_mode }
        end

        if not custom_actions_defined["mark_notification_read"] then
          final_actions["mark_notification_read"] = function(picker, item)
            local url = string.format("/notifications/threads/%s", item.id)
            gh.run {
              args = { "api", "--method", "PATCH", url },
              headers = { "Accept: application/vnd.github.v3.diff" },
              cb = function(_, stderr)
                if stderr and not utils.is_blank(stderr) then
                  utils.error(stderr)
                  return
                end
              end,
            }
            -- TODO: No current way to redraw the list/remove just this item
            picker:close()
            M.notifications(opts)
          end
        end
        -- Use the default mapping from the main config section for 'read'
        if
          cfg.mappings.notification
          and cfg.mappings.notification.read
          and not final_keys[cfg.mappings.notification.read.lhs]
        then
          final_keys[cfg.mappings.notification.read.lhs] = { "mark_notification_read", mode = default_mode }
        end

        Snacks.picker.pick {
          title = opts.preview_title or "Notifications",
          items = safe_notifications,
          format = function(item, _)
            ---@type snacks.picker.Highlight[]
            local ret = {}
            ---@diagnostic disable-next-line: assign-type-mismatch
            ret[#ret + 1] = utils.icons.notification[item.kind][item.status]
            ret[#ret + 1] = { string.format("#%d", item.subject.number), "Comment" }
            ret[#ret + 1] = { " " }
            ret[#ret + 1] = { item.repository.full_name, "Function" }
            ret[#ret + 1] = { " " }
            ret[#ret + 1] = { item.subject.title, "Normal" }
            return ret
          end,
          win = {
            input = {
              keys = final_keys, -- Use the constructed keys map
            },
          },
          actions = final_actions, -- Use the constructed actions map
        }
      end
    end,
  }
end

function M.issue_templates(templates, cb)
  if not templates or #templates == 0 then
    utils.error "No templates found"
    return
  end

  local formatted_templates = {}
  for _, template in ipairs(templates) do
    if template and not vim.tbl_isempty(template) then
      local item = {
        value = template.name,
        display = template.name .. (template.about and (" - " .. template.about) or ""),
        ordinal = template.name .. " " .. (template.about or ""),
        template = template,
      }
      table.insert(formatted_templates, item)
    end
  end

  local function preview_fn(ctx)
    ctx.preview:reset()

    local item = ctx.item
    if not item or not item.template or not item.template.body then
      ctx.preview:set_lines { "No template body available" }
      return
    end

    local lines = vim.split(item.template.body, "\n")
    ctx.preview:set_lines(lines)
    ctx.preview:highlight { ft = "markdown" }
  end

  local cfg = octo_config.values

  -- Prepare actions and keys for Snacks
  local final_actions = {}
  local final_keys = {}
  local default_mode = { "n", "i" }

  -- Process custom actions from config array
  local custom_actions_defined = {}
  if
    cfg.picker_config.snacks
    and cfg.picker_config.snacks.actions
    and cfg.picker_config.snacks.actions.issue_templates
  then
    for _, action_item in ipairs(cfg.picker_config.snacks.actions.issue_templates) do
      if action_item.name and action_item.fn then
        final_actions[action_item.name] = action_item.fn
        custom_actions_defined[action_item.name] = true
        if action_item.lhs then
          final_keys[action_item.lhs] = { action_item.name, mode = action_item.mode or default_mode }
        end
      end
    end
  end

  -- Add default confirm action if not overridden
  if not custom_actions_defined["confirm"] then
    final_actions["confirm"] = function(_, item)
      if type(cb) == "function" then
        cb(item.template)
      end
    end
  end
  -- Default key for confirm is usually <CR> handled by Snacks itself, but allow override
  -- No explicit default key mapping added here unless specified in config

  Snacks.picker.pick {
    title = "Issue Templates",
    items = formatted_templates,
    format = function(item)
      if type(item) ~= "table" then
        return { { "Invalid item", "Error" } }
      end

      local ret = {}
      ret[#ret + 1] = { item.value or "", "Function" }

      if item.template and item.template.about and item.template.about ~= "" then
        ret[#ret + 1] = { " - ", "Comment" }
        ret[#ret + 1] = { item.template.about, "Normal" }
      end

      return ret
    end,
    preview = preview_fn, -- Use our custom preview function
    win = {
      input = {
        keys = final_keys, -- Use the constructed keys map
      },
    },
    actions = final_actions, -- Use the constructed actions map
  }
end

function M.search(opts)
  opts = opts or {}
  opts.type = opts.type or "ISSUE"

  if opts.type == "REPOSITORY" then
    M.not_implemented()
    return
  end

  local cfg = octo_config.values
  if type(opts.prompt) == "string" then
    opts.prompt = { opts.prompt }
  end

  local search_results = {}

  local function process_results(results)
    if #results == 0 then
      return
    end

    for _, item in ipairs(results) do
      if item.__typename == "Issue" then
        item.kind = "issue"
        item.file = utils.get_issue_uri(item.number, item.repository.nameWithOwner)
      elseif item.__typename == "PullRequest" then
        item.kind = "pull_request"
        item.file = utils.get_pull_request_uri(item.number, item.repository.nameWithOwner)
      elseif item.__typename == "Discussion" then
        item.kind = "discussion"
        item.file = utils.get_discussion_uri(item.number, item.repository.nameWithOwner)
      end

      item.text = item.title .. " #" .. item.number .. (item.category and (" " .. item.category.name) or "")
      table.insert(search_results, item)
    end
  end

  for _, val in ipairs(opts.prompt) do
    local output = gh.api.graphql {
      query = queries.search,
      fields = { prompt = val, type = opts.type },
      jq = ".data.search.nodes",
      opts = { mode = "sync" },
    }

    if not utils.is_blank(output) then
      local results = vim.json.decode(output)
      process_results(results)

      if #results == 0 then
        utils.info(string.format("No results found for query: %s", val))
      end
    end
  end

  if #search_results > 0 then
    local max_number = -1
    for _, item in ipairs(search_results) do
      if item.number and item.number > max_number then
        max_number = item.number
      end
    end

    -- Prepare actions and keys for Snacks
    local final_actions = {}
    local final_keys = {}
    local default_mode = { "n", "i" }

    -- Process custom actions from config array
    local custom_actions_defined = {}
    if cfg.picker_config.snacks and cfg.picker_config.snacks.actions and cfg.picker_config.snacks.actions.search then
      for _, action_item in ipairs(cfg.picker_config.snacks.actions.search) do
        if action_item.name and action_item.fn then
          final_actions[action_item.name] = action_item.fn
          custom_actions_defined[action_item.name] = true
          if action_item.lhs then
            final_keys[action_item.lhs] = { action_item.name, mode = action_item.mode or default_mode }
          end
        end
      end
    end

    -- Add default actions/keys if not overridden
    if not custom_actions_defined["open_in_browser"] then
      final_actions["open_in_browser"] = function(_picker, item)
        navigation.open_in_browser(item.kind, item.repository.nameWithOwner, item.number)
      end
    end
    if not final_keys[cfg.picker_config.mappings.open_in_browser.lhs] then
      final_keys[cfg.picker_config.mappings.open_in_browser.lhs] = { "open_in_browser", mode = default_mode }
    end

    if not custom_actions_defined["copy_url"] then
      final_actions["copy_url"] = function(_picker, item)
        utils.copy_url(item.url)
      end
    end
    if not final_keys[cfg.picker_config.mappings.copy_url.lhs] then
      final_keys[cfg.picker_config.mappings.copy_url.lhs] = { "copy_url", mode = default_mode }
    end

    if not custom_actions_defined["copy_sha"] then
      final_actions["copy_sha"] = function(_picker, item)
        if item.kind == "pull_request" then
          -- For PR search results, we need to fetch the PR details to get the head SHA
          utils.info "Fetching PR details for SHA..."
          local owner, repo = utils.split_repo(item.repository.nameWithOwner)
          gh.api.get {
            "/repos/{owner}/{repo}/pulls/{pull_number}",
            format = { owner = owner, repo = repo, pull_number = item.number },
            opts = {
              cb = gh.create_callback {
                success = function(output)
                  local pr_data = vim.json.decode(output)
                  utils.copy_sha(pr_data.head.sha)
                end,
              },
            },
          }
        else
          utils.info "Copy SHA not available for this item type"
        end
      end
    end
    if not final_keys[cfg.picker_config.mappings.copy_sha.lhs] then
      final_keys[cfg.picker_config.mappings.copy_sha.lhs] = { "copy_sha", mode = default_mode }
    end

    Snacks.picker.pick {
      title = opts.preview_title or "GitHub Search Results",
      items = search_results,
      format = function(item, _)
        local a = Snacks.picker.util.align
        local ret = {} ---@type snacks.picker.Highlight[]

        ---@diagnostic disable-next-line: assign-type-mismatch
        ret[#ret + 1] = utils.get_icon { kind = item.kind, obj = item }

        ret[#ret + 1] = { " " }

        local issue_id = string.format("#%d", item.number)
        local issue_id_width = #tostring(max_number) + 1

        ret[#ret + 1] = { a(issue_id, issue_id_width), "SnacksPickerGitIssue" }

        ret[#ret + 1] = { " " }

        ret[#ret + 1] = { item.title }

        if item.kind == "discussion" and item.category then
          ret[#ret + 1] = { " [" .. item.category.name .. "]", "SnacksPickerSpecial" }
        end

        return ret
      end,
      win = {
        preview = {
          title = "",
          minimal = true,
        },
        input = {
          keys = final_keys, -- Use the constructed keys map
        },
      },
      actions = final_actions, -- Use the constructed actions map
    }
  else
    utils.info "No search results found"
  end
end

function M.changed_files(opts)
  opts = opts or {}
  local buffer = utils.get_current_buffer()
  if not buffer or not buffer:isPullRequest() then
    utils.error "Changed files picker only works in pull request buffers"
    return
  end

  gh.api.get {
    "/repos/{owner}/{repo}/pulls/{pull_number}/files",
    format = { owner = buffer.repo:match "([^/]+)/", repo = buffer.repo:match "/(.+)", pull_number = buffer.number },
    opts = {
      paginate = true,
      cb = gh.create_callback {
        success = function(output)
          local results = vim.json.decode(output)
          if #results == 0 then
            utils.error "No changed files found for this pull request"
            return
          end

          -- Format files for snacks picker
          for _, file in ipairs(results) do
            file.text = file.filename
            file.kind = "file"
          end

          local cfg = octo_config.values

          -- Prepare actions and keys for Snacks
          local final_actions = {}
          local final_keys = {}
          local default_mode = { "n", "i" }

          -- Process custom actions from config array
          local custom_actions_defined = {}
          if
            cfg.picker_config.snacks
            and cfg.picker_config.snacks.actions
            and cfg.picker_config.snacks.actions.changed_files
          then
            for _, action_item in ipairs(cfg.picker_config.snacks.actions.changed_files) do
              if action_item.name and action_item.fn then
                final_actions[action_item.name] = action_item.fn
                custom_actions_defined[action_item.name] = true
                if action_item.lhs then
                  final_keys[action_item.lhs] = { action_item.name, mode = action_item.mode or default_mode }
                end
              end
            end
          end

          -- Add default confirm action (what happens when you press Enter)
          if not custom_actions_defined["confirm"] then
            final_actions["confirm"] = function(_picker, item)
              utils.edit_file(item.filename)
            end
          end

          -- Add default actions/keys if not overridden
          if not custom_actions_defined["open_in_browser"] then
            final_actions["open_in_browser"] = function(_picker, item)
              local file_url =
                string.format("https://github.com/%s/pull/%s/files#diff-%s", buffer.repo, buffer.number, item.sha)
              navigation.open_in_browser_raw(file_url)
            end
          end
          if not final_keys[cfg.picker_config.mappings.open_in_browser.lhs] then
            final_keys[cfg.picker_config.mappings.open_in_browser.lhs] = { "open_in_browser", mode = default_mode }
          end

          Snacks.picker.pick {
            title = opts.title or "Changed Files",
            items = results,
            format = function(item, _)
              local ret = {} ---@type snacks.picker.Highlight[]

              -- File status indicator (GitHub API can return: added, removed, modified, renamed, copied)
              local status_icon = item.status == "added" and "A"
                or item.status == "removed" and "D"
                or item.status == "modified" and "M"
                or item.status == "renamed" and "R"
                or item.status == "copied" and "C"
                or "?"
              local status_highlight = item.status == "added" and "GitSignsAdd"
                or item.status == "removed" and "GitSignsDelete"
                or item.status == "modified" and "GitSignsChange"
                or item.status == "renamed" and "GitSignsChange"
                or item.status == "copied" and "GitSignsChange"
                or "Normal"

              ret[#ret + 1] = { status_icon, status_highlight }
              ret[#ret + 1] = { " " }

              -- Filename
              ret[#ret + 1] = { item.filename, "Normal" }

              -- Show additions/deletions if available
              if item.additions and item.deletions then
                ret[#ret + 1] = { " (", "Comment" }
                ret[#ret + 1] = { string.format("+%d", item.additions), "GitSignsAdd" }
                ret[#ret + 1] = { "/", "Comment" }
                ret[#ret + 1] = { string.format("-%d", item.deletions), "GitSignsDelete" }
                ret[#ret + 1] = { ")", "Comment" }
              end

              return ret
            end,
            preview = function(ctx)
              local item = ctx.item
              if not item then
                return
              end

              ctx.preview:reset()

              -- Show file diff preview
              local lines = {
                string.format("File: %s", item.filename),
                string.format("Status: %s", item.status),
                "",
              }

              local line_count = #lines
              if item.additions and item.deletions then
                lines[#lines + 1] = string.format("Changes: +%d -%d", item.additions, item.deletions)
                lines[#lines + 1] = ""
              end

              -- Add patch content if available
              if item.patch then
                lines[#lines + 1] = "Patch:"
                lines[#lines + 1] = ""
                local patch_lines = vim.split(item.patch, "\n")
                vim.list_extend(lines, patch_lines)
              end

              ctx.preview:set_lines(lines)

              -- Apply diff highlighting to the entire preview
              if item.patch then
                ctx.preview:highlight { ft = "diff" }
              end
            end,
            win = {
              input = {
                keys = final_keys,
              },
            },
            actions = final_actions,
          }
        end,
      },
    },
  }
end

M.picker = {
  actions = M.not_implemented,
  assigned_labels = M.not_implemented,
  assignees = M.not_implemented,
  changed_files = M.changed_files,
  commits = M.not_implemented,
  discussions = M.not_implemented,
  gists = M.not_implemented,
  issue_templates = M.issue_templates,
  issues = M.issues,
  labels = M.not_implemented,
  notifications = M.notifications,
  pending_threads = M.not_implemented,
  project_cards = M.not_implemented,
  project_cards_v2 = M.not_implemented,
  project_columns = M.not_implemented,
  project_columns_v2 = M.not_implemented,
  prs = M.pull_requests,
  repos = M.not_implemented,
  workflow_runs = M.not_implemented,
  review_commits = M.not_implemented,
  search = M.search,
  users = M.not_implemented,
  milestones = M.not_implemented,
}

return M
