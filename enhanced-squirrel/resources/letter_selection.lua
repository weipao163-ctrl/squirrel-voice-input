-- Two-stage selection. No candidate.text commits, input rewriting or menu filters.
local M = {}
local NOOP, ACCEPTED = 2, 1
local PHASE, KEYS, RESET = "_letter_selection_phase", "_letter_selection_keys", "_letter_selection_reset"

local function strings(config, path)
  local result, list = {}, config:get_list(path)
  if list then
    for i = 0, list.size - 1 do
      local value = list:get_value_at(i)
      if value then result[#result + 1] = value.value end
    end
  end
  return result
end

local function segment(ctx)
  if ctx.composition:empty() then return nil end
  return ctx.composition:back()
end

local function enabled(env)
  return env.valid and env.enabled and not env.engine.context:get_option("letter_selection_disabled")
end

local function eligible(env)
  local ctx = env.engine.context
  if not enabled(env) or env.external_hide or ctx:get_option("ascii_mode") or not ctx:has_menu() then return false end
  local seg = segment(ctx)
  if not seg or not seg:has_tag(env.tag) or seg:has_tag("raw") then return false end
  local input = ctx.input:sub(seg.start + 1)
  if input == "" or not input:match("^[a-z']+$") then return false end
  if env.passthrough[input] then return false end
  for _, pattern in ipairs(env.patterns) do
    if input:match(pattern) then return false end
  end
  local candidate = ctx:get_selected_candidate()
  if candidate and env.excluded[candidate.type] then return false end
  return true
end

local function property(ctx, name, value)
  if ctx:get_property(name) ~= value then ctx:set_property(name, value) end
end

local function literal_text(env)
  return (env.literal_prefix or "") .. env.engine.context.input:sub((env.literal_start or 0) + 1)
end

local function publish(env)
  local ctx = env.engine.context
  local active = eligible(env)
  local showing_letters = active and env.armed
  if env.can_set_keys then
    -- Schema.select_keys is per engine/session, unlike the shared ConfigData.
    -- It controls frontend labels only while the explicit gate is armed.
    if env.last_select_keys and env.engine.schema.select_keys ~= env.last_select_keys then
      env.original_select_keys = env.engine.schema.select_keys
    end
    local keys = showing_letters and env.keys or env.original_select_keys
    if env.engine.schema.select_keys ~= keys then env.engine.schema.select_keys = keys end
    env.last_select_keys = keys
  end
  local hide = env.original_hide
  if active then hide = not env.armed and env.hide_candidates end
  if env.literal then hide = true end
  hide = env.external_hide or hide
  if ctx:get_option("_hide_candidate") ~= hide then
    env.writing_hide = true
    ctx:set_option("_hide_candidate", hide)
    env.writing_hide = false
  end
  property(ctx, KEYS, active and env.keys or "")
  property(ctx, PHASE, env.literal and "literal" or (active and (env.armed and "selecting" or "editing") or "off"))
  property(ctx, "_letter_selection_literal_text", env.literal and literal_text(env) or "")
  property(ctx, "_letter_selection_literal_caret", env.literal and
    tostring(#(env.literal_prefix or "") + math.max(0, ctx.caret_pos - (env.literal_start or 0))) or "")
  property(ctx, "_letter_selection_hide_editing", active and env.hide_candidates and "true" or "false")
end

local function accepted(env)
  env.consumed = env.consumed + 1
  property(env.engine.context, "_letter_selection_consumed", tostring(env.consumed))
  return ACCEPTED
end

local function snapshot(env)
  local ctx, seg = env.engine.context, segment(env.engine.context)
  env.input, env.caret, env.start = ctx.input, ctx.caret_pos, seg and seg.start
end

local function disarm(env)
  env.armed = false
  snapshot(env)
  publish(env)
end

local function arm(env)
  env.armed = eligible(env)
  snapshot(env)
  publish(env)
end

local function synchronize(env)
  local ctx, seg = env.engine.context, segment(env.engine.context)
  if env.literal and (ctx.input == "" or not enabled(env) or ctx:get_option("ascii_mode") or
      not ctx.input:sub((env.literal_start or 0) + 1):find("%d")) then env.literal = false end
  if env.armed and (not eligible(env) or ctx.input ~= env.input or
      (seg and seg.start == env.start and ctx.caret_pos ~= env.caret)) then
    env.armed = false
  end
  publish(env)
end

local function can_input_digit(env)
  local ctx, seg = env.engine.context, segment(env.engine.context)
  if not enabled(env) or ctx:get_option("ascii_mode") or not seg or ctx.input == "" then return false end
  if not ctx.input:match("^[a-zA-Z0-9']+$") or not (seg:has_tag(env.tag) or seg:has_tag("raw")) then return false end
  local input = ctx.input:sub(seg.start + 1)
  if env.passthrough[input] then return false end
  for _, pattern in ipairs(env.patterns) do if input:match(pattern) then return false end end
  local candidate = ctx:get_selected_candidate()
  return not candidate or not env.excluded[candidate.type]
end

local function begin_literal(env)
  local ctx = env.engine.context
  env.literal, env.armed, env.literal_start, env.literal_prefix = true, false, 0, ""
  -- Keep only segments explicitly chosen by the user, never guessed candidates.
  for _, seg in ipairs(ctx.composition:toSegmentation():get_segments()) do
    if seg.status ~= "kSelected" and seg.status ~= "kConfirmed" then break end
    local candidate = seg:get_selected_candidate()
    env.literal_prefix = env.literal_prefix .. (candidate and candidate.text or ctx.input:sub(seg.start + 1, seg._end))
    env.literal_start = candidate and candidate._end or seg._end
  end
end

local function commit_literal(env, suffix)
  local ctx = env.engine.context
  local raw = ctx.input:sub(env.literal_start + 1) .. (suffix or "")
  local prefix, prefix_input = env.literal_prefix, ctx.input:sub(1, env.literal_start)
  env.literal = false
  if prefix_input ~= "" then
    ctx.input = prefix_input
    if ctx:get_commit_text() == prefix then ctx:commit()
    else ctx:clear(); env.engine:commit_text(prefix) end
  else ctx:clear() end
  -- This is literal ASCII input, not candidate.text selection. Normal Chinese
  -- and any already-confirmed prefix keep the engine's selection/learning path.
  env.engine:commit_text(raw)
  disarm(env)
end

function M.init(env)
  local config, ctx = env.engine.schema.config, env.engine.context
  env.enabled = config:get_bool("letter_selection/enabled") ~= false
  env.hide_candidates = config:get_bool("letter_selection/hide_candidates") ~= false
  env.original_hide = ctx:get_option("_hide_candidate")
  env.external_hide = ctx:get_option("letter_selection_external_hide")
  env.consumed = 0
  env.original_select_keys = env.engine.schema.select_keys or ""
  env.can_set_keys = pcall(function()
    env.engine.schema.select_keys = env.original_select_keys
  end)
  env.keys = config:get_string("letter_selection/keys") or "asdfghjkl"
  env.tag = config:get_string("letter_selection/tag") or "abc"
  env.entry = config:get_string("letter_selection/entry_key") or "space"
  env.confirm = config:get_string("letter_selection/confirm_key") or "space"
  env.cancel = config:get_string("letter_selection/cancel_key") or "Escape"
  env.backspace = config:get_string("letter_selection/backspace_key") or "BackSpace"
  env.valid, env.indices, env.passthrough, env.excluded = true, {}, {}, {}
  for _, field in ipairs({"entry", "confirm", "cancel", "backspace"}) do
    local parsed = KeyEvent(env[field])
    if parsed.keycode == 0 or parsed.modifier ~= 0 or env[field]:match("^[1-9]$") then
      env.valid = false
    else
      env[field] = parsed:repr()
    end
  end
  local page_size = env.engine.schema.page_size
  if #env.keys ~= page_size or page_size < 1 or page_size > 9 or not env.keys:match("^[a-z]+$") then env.valid = false end
  for i = 1, #env.keys do
    local key = env.keys:sub(i, i)
    if env.indices[key] then env.valid = false end
    env.indices[key] = i - 1
  end
  local bridge_required = not env.can_set_keys
  if bridge_required then env.valid = false end
  -- Reserved selection letters would make displayed labels impossible to honour.
  if env.indices[env.entry] or env.indices[env.confirm] or env.indices[env.cancel] or
      env.indices[env.backspace] or env.cancel == env.backspace or
      env.cancel == env.entry or env.cancel == env.confirm or
      env.backspace == env.entry or env.backspace == env.confirm then env.valid = false end
  env.patterns = strings(config, "letter_selection/passthrough_patterns")
  env.navigation = {}
  for _, name in ipairs(strings(config, "letter_selection/navigation_keys")) do
    local event = KeyEvent(name)
    if event.keycode ~= 0 then env.navigation[event:repr()] = true else env.valid = false end
  end
  -- Respect punctuation-based paging in the ORIGINAL key_binder, including
  -- schemas using comma/period or minus/equal. Read deployed config paths;
  -- no second navigation algorithm and no replacement of original bindings.
  local bindings = config:get_list("key_binder/bindings")
  local navigation_sends = {Page_Up=true, Page_Down=true, Up=true, Down=true,
    Left=true, Right=true, Home=true, End=true}
  if bindings then
    for i = 0, bindings.size - 1 do
      local path = "key_binder/bindings/@" .. i .. "/"
      local send, accept = config:get_string(path .. "send"), config:get_string(path .. "accept")
      if navigation_sends[send] and accept then
        local event = KeyEvent(accept)
        if event.keycode ~= 0 then env.navigation[event:repr()] = true end
      end
    end
  end
  for _, pattern in ipairs(env.patterns) do
    if not pcall(string.match, "", pattern) then env.valid = false end
  end
  for _, value in ipairs(strings(config, "letter_selection/passthrough_inputs")) do env.passthrough[value] = true end
  for _, value in ipairs(strings(config, "letter_selection/excluded_candidate_types")) do env.excluded[value] = true end
  -- Common schema-specific Lua triggers are not necessarily given distinct tags/types.
  for _, path in ipairs({"lunar", "uuid", "date_translator/date", "date_translator/time",
      "date_translator/week", "date_translator/datetime", "date_translator/timestamp",
      "date_translator/datezh", "date_translator/dateen"}) do
    local trigger = config:get_string(path)
    if trigger then env.passthrough[trigger] = true end
  end
  property(ctx, "_letter_selection_error", env.valid and "" or
    (bridge_required and "schema_select_keys_setter_unavailable" or "invalid_keys_or_patterns"))
  property(ctx, "_letter_selection_label_backend", env.can_set_keys and "schema_select_keys" or "unavailable")
  property(ctx, "_letter_selection_lua_version", _VERSION)
  env.armed, env.literal, env.connections = false, false, {}
  env.connections[#env.connections + 1] = ctx.update_notifier:connect(function() synchronize(env) end)
  env.connections[#env.connections + 1] = ctx.select_notifier:connect(function()
    -- Engine's OnSelect has already advanced/committed the segment. Keep the native
    -- selection/learning path, and re-arm remaining input after letters or mouse.
    if env.armed then arm(env) else synchronize(env) end
  end)
  env.connections[#env.connections + 1] = ctx.commit_notifier:connect(function() disarm(env) end)
  env.connections[#env.connections + 1] = ctx.option_update_notifier:connect(function(_, name)
    if name == "ascii_mode" or name == "letter_selection_disabled" then disarm(env) end
    if name == "_hide_candidate" and not env.writing_hide then
      -- Foreign writers own the baseline; their hide=true wins. They should use a
      -- separate ownership option when asserting an already-true shared option.
      env.external_hide = ctx:get_option("_hide_candidate")
      env.original_hide = env.external_hide
      disarm(env)
    end
    if name == "letter_selection_external_hide" then
      env.external_hide = ctx:get_option(name)
      disarm(env)
    end
  end)
  env.connections[#env.connections + 1] = ctx.property_update_notifier:connect(function(_, name)
    if name == RESET then disarm(env) end
    if name == "_letter_selection_runtime_revision" then
      local keys = ctx:get_property("_letter_selection_runtime_keys")
      local hide = ctx:get_property("_letter_selection_runtime_hide")
      local indices, valid = {}, #keys == env.engine.schema.page_size and keys:match("^[a-z]+$")
      for i = 1, #keys do
        local k = keys:sub(i, i)
        if indices[k] then valid = false end
        indices[k] = i - 1
      end
      if valid and (hide == "true" or hide == "false") then
        env.keys, env.indices, env.hide_candidates = keys, indices, hide == "true"
      else
        property(ctx, "_letter_selection_error", "runtime_settings_require_deployment")
      end
      disarm(env)
    end
  end)
  snapshot(env)
  publish(env)
end

function M.func(key, env)
  local ctx = env.engine.context
  synchronize(env)
  if key:release() then return NOOP end
  -- A shortcut is never a letter selection, even when its keycode is a letter.
  if key:ctrl() or key:alt() or key:super() then return NOOP end
  local repr = key:repr()
  local digit = key.keycode >= 48 and key.keycode <= 57 and not key:shift()
  if not digit and key.keycode >= 0xffb0 and key.keycode <= 0xffb9 then digit = true end
  if digit and (env.literal or can_input_digit(env)) then
    if not env.literal then begin_literal(env) end
    ctx:push_input(string.char(key.keycode >= 0xffb0 and key.keycode - 0xffb0 + 48 or key.keycode))
    snapshot(env); publish(env)
    return ACCEPTED -- ordinary typing: do not suppress held-number repeats
  end
  if env.literal then
    local code = key.keycode
    if code >= 65 and code <= 90 or code >= 97 and code <= 122 or code == 95 or code == 45 then
      local text = string.char(code)
      if key:shift() then text = text:upper() end
      ctx:push_input(text); snapshot(env); publish(env); return ACCEPTED
    end
    if repr == "BackSpace" and ctx.caret_pos > env.literal_start then
      ctx:pop_input(1); snapshot(env); publish(env); return ACCEPTED
    end
    if repr == "Delete" then ctx:delete_input(); snapshot(env); publish(env); return ACCEPTED end
    if repr == "Left" or repr == "Right" or repr == "Home" or repr == "End" then
      local caret = ctx.caret_pos
      if repr == "Left" then caret = math.max(env.literal_start, caret - 1) end
      if repr == "Right" then caret = math.min(#ctx.input, caret + 1) end
      if repr == "Home" then caret = env.literal_start end
      if repr == "End" then caret = #ctx.input end
      ctx.caret_pos = caret; snapshot(env); publish(env); return ACCEPTED
    end
    if repr == "Escape" then ctx:clear(); disarm(env); return ACCEPTED end
    if repr == "Return" or repr == "KP_Enter" then commit_literal(env); return ACCEPTED end
    if repr == "space" then commit_literal(env, " "); return ACCEPTED end
    if code >= 32 and code <= 126 or repr == "Tab" then
      commit_literal(env); return NOOP -- delimiter handled once by original path
    end
    return NOOP
  end
  if not eligible(env) then return NOOP end
  if key:shift() or repr == "Caps_Lock" or repr == "Shift_L" or repr == "Shift_R" then
    disarm(env); return NOOP
  end
  if env.armed and repr == env.cancel then
    disarm(env)
    return accepted(env)
  end
  if env.armed and repr == env.backspace then
    disarm(env)
    return NOOP -- exactly one BackSpace through the original processors/editor
  end
  if env.armed and repr == env.confirm then
    ctx:confirm_current_selection()
    if ctx:has_menu() then arm(env) else disarm(env) end
    return accepted(env)
  end
  if not env.armed and repr == env.entry then
    arm(env)
    return accepted(env) -- no commit, no space output, no input/caret change
  end
  if env.armed then
    local index = env.indices[repr]
    if index ~= nil then
      local seg, size = segment(ctx), env.engine.schema.page_size
      if seg and index < size then
        local page_start = math.floor(seg.selected_index / size) * size
        ctx:select(page_start + index) -- false for missing item; never clamp or leak
      end
      if ctx:has_menu() then arm(env) else disarm(env) end
      return accepted(env)
    end
    if env.navigation[repr] then return NOOP end
    -- Unmapped letters resume editing; paging/navigation and modifiers retain the
    -- original scheme's handling. Caret changes are observed by update_notifier.
    if repr:match("^[a-zA-Z]$") or repr:match("^[%p]$") or
        repr == "Return" or repr == "Delete" or repr == "Tab" then disarm(env) end
  end
  return NOOP
end

function M.fini(env)
  for _, connection in ipairs(env.connections or {}) do connection:disconnect() end
  env.armed, env.literal = false, false
  if env.can_set_keys and env.engine.schema.select_keys == env.last_select_keys then
    env.engine.schema.select_keys = env.original_select_keys
  end
  env.engine.context:set_option("_hide_candidate", env.external_hide or env.original_hide)
  property(env.engine.context, PHASE, "off")
  property(env.engine.context, KEYS, "")
  property(env.engine.context, "_letter_selection_literal_text", "")
  property(env.engine.context, "_letter_selection_literal_caret", "")
end

return M
