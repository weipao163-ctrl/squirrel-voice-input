-- A deliberately limited unit-test double. It is not a real librime test.
local function notifier()
  local n = {slots = {}}
  function n:connect(fn)
    local c = {connected = true, fn = fn}
    function c:disconnect() self.connected = false end
    self.slots[#self.slots + 1] = c
    return c
  end
  function n:emit(...)
    for _, c in ipairs(self.slots) do if c.connected then c.fn(...) end end
  end
  return n
end

local codes = {space=32, Escape=0xff1b, BackSpace=0xff08, Return=0xff0d,
  Tab=0xff09, Page_Down=0xff56, Page_Up=0xff55, Left=0xff51, Delete=0xffff}
function KeyEvent(repr, mods)
  local k = {name=repr, mods=mods or {}, modifier=0}
  local name = repr
  if repr:find("+", 1, true) then name = repr:match("([^+]+)$"); k.modifier = 4 end
  k.keycode = codes[name] or (#name == 1 and name:byte() or 0)
  function k:repr() return self.name end
  function k:release() return self.mods.release or false end
  function k:ctrl() return self.mods.ctrl or false end
  function k:alt() return self.mods.alt or false end
  function k:super() return self.mods.super or false end
  function k:shift() return self.mods.shift or false end
  return k
end

function make_env(options)
  options = options or {}
  local ctx = {input=options.input or "ni", caret_pos=options.caret or 2,
    properties={}, options={_hide_candidate=options.original_hide or false},
    selected={}, commits={}, confirm_calls=0, select_calls=0, push_calls=0}
  local seg = {start=0, selected_index=options.index or 0, tags={abc=true}, candidate_type="phrase"}
  function seg:has_tag(tag) return self.tags[tag] or false end
  ctx.seg = seg
  ctx.composition = {}
  function ctx.composition:empty() return ctx.input == "" end
  function ctx.composition:back() return ctx.input ~= "" and seg or nil end
  for _, name in ipairs({"update", "select", "commit", "option_update", "property_update"}) do
    ctx[name .. "_notifier"] = notifier()
  end
  function ctx:is_composing() return self.input ~= "" end
  function ctx:has_menu() return self.input ~= "" and not self.no_menu end
  function ctx:get_selected_candidate() return self:has_menu() and {type=seg.candidate_type} or nil end
  function ctx:get_option(name) return self.options[name] or false end
  function ctx:set_option(name, value)
    self.options[name] = value
    self.option_update_notifier:emit(self, name)
  end
  function ctx:get_property(name) return self.properties[name] or "" end
  function ctx:set_property(name, value)
    self.properties[name] = value
    self.property_update_notifier:emit(self, name)
  end
  function ctx:clear()
    self.input, self.caret_pos = "", 0
    self.update_notifier:emit(self)
  end
  function ctx:select(index)
    self.select_calls = self.select_calls + 1
    if index >= (self.candidate_count or 20) then return false end
    self.selected[#self.selected + 1] = index
    seg.selected_index = index
    if self.partial then
      seg.start = 2
      seg.selected_index = 0
      self.partial = false
      self.update_notifier:emit(self)
    else
      self.commits[#self.commits + 1] = "candidate:" .. index
      self.commit_notifier:emit(self)
      self:clear()
    end
    self.select_notifier:emit(self)
    return true
  end
  function ctx:confirm_current_selection()
    self.confirm_calls = self.confirm_calls + 1
    return self:select(seg.selected_index)
  end
  function ctx:edit(text)
    self.input, self.caret_pos = text, #text
    self.update_notifier:emit(self)
  end
  local config = {values=options.config or {}}
  function config:get_string(path)
    local v = self.values[path]
    return type(v) == "string" and v or nil
  end
  function config:get_bool(path)
    local v = self.values[path]
    if type(v) == "boolean" then return v end
    return nil
  end
  function config:get_list(path)
    local values = self.values[path]
    if type(values) ~= "table" then return nil end
    return {size=#values, get_value_at=function(_, i) return {value=values[i+1]} end}
  end
  return {engine={context=ctx, schema={config=config, page_size=options.page_size or 9,
    select_keys=options.select_keys or ""}}}
end
