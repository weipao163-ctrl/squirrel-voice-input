-- Whole-word suggestions for the full-pinyin schema. Look up plausible spellings
-- in the deployed Rime dictionary, so rebuilding a word list needs no second index.
local M = {}
local syllables = {}
local inventory = [[
a ai an ang ao
ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
e ei en eng er
fa fan fang fei fen feng fiao fo fou fu
ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo
la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve
ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve
o ou
pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
wa wai wan wang wei wen weng wo wu
xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
]]
for s in inventory:gmatch('%l+') do syllables[s] = true end

-- Compare log weights from the deployed dictionary. Only familiar words earn
-- an extra suggestion from the much more ambiguous syllable-reversal operation.
local confident_exact_weight = -12
local familiar_reversal_weight = -9
local reversal_penalty = -2
local neighbours = {}
local rows = {'qwertyuiop', 'asdfghjkl', 'zxcvbnm'}
local offsets = {0, 0.25, 0.75}
for r, row in ipairs(rows) do
  for i = 1, #row do
    local nearby = {}
    for rr = math.max(1, r-1), math.min(3, r+1) do
      for j = 1, #rows[rr] do
        if (r ~= rr or i ~= j) and math.abs(i+offsets[r]-j-offsets[rr]) <= 1 then
          nearby[#nearby+1] = rows[rr]:sub(j,j)
        end
      end
    end
    neighbours[row:sub(i,i)] = table.concat(nearby)
  end
end

-- Memoize shared suffixes across all one-edit variants of this input.
local function spellings(raw, allow_reversal)
  local memo = {[''] = ''}
  local function split(s)
    if memo[s] ~= nil then return memo[s] end
    for n = math.min(6, #s), 1, -1 do
      local first = s:sub(1,n)
      if syllables[first] then
        local rest = split(s:sub(n+1))
        if rest then
          memo[s] = rest == '' and first or first .. ' ' .. rest
          return memo[s]
        end
      end
    end
    memo[s] = false
    return false
  end
  local variants = {}
  local function add(key, bonus)
    if key == raw then return end
    local code = split(key)
    if code and code:find(' ',1,true) and (not variants[code] or variants[code] < bonus) then
      variants[code] = bonus
    end
  end
  for i = 1, #raw+1 do
    local left, right = raw:sub(1,i-1), raw:sub(i)
    local c, next_c = right:sub(1,1), right:sub(2,2)
    for ch in ('abcdefghijklmnopqrstuvwxyz'):gmatch('.') do add(left..ch..right, 0) end
    if c ~= '' then
      for ch in neighbours[c]:gmatch('.') do add(left..ch..right:sub(2), 0.1) end
      if next_c ~= '' then
        if c == next_c then add(left..right:sub(2), 1.1)
        else add(left..next_c..c..right:sub(3), 0.8) end
      end
    end
  end
  if allow_reversal then
    local code = split(raw)
    if code then
      local parts = {}
      for s in code:gmatch('%l+') do parts[#parts+1] = s end
      for i = 1, #parts-1 do
        if parts[i] ~= parts[i+1] then
          parts[i],parts[i+1] = parts[i+1],parts[i]
          local reversed = table.concat(parts,' ')
          if not variants[reversed] then variants[reversed] = reversal_penalty end
          parts[i],parts[i+1] = parts[i+1],parts[i]
        end
      end
    end
  end
  return variants
end

function M.init(env)
  local config = env.engine.schema.config
  if config:get_string('translator/dictionary') ~= config:get_string('typo_reference/dictionary') then return end
  env.reference = Component.Translator(env.engine,'','script_translator@typo_reference')
  -- Native selection and durable learning match phrases by language identity.
  -- A profile may keep its existing user dictionary while changing the static dictionary.
  local learning_name = config:get_string('translator/user_dict')
  local namespace = learning_name and learning_name ~= config:get_string('translator/dictionary')
    and 'translator' or 'typo_reference'
  env.decoder = Memory(env.engine, env.engine.schema, namespace)
end

function M.fini(env)
  if env.decoder then env.decoder:disconnect() end
end

local function suggestions(raw, first, env)
  local ctx = env.engine.context
  local first_exact = false
  if first then
    local g = first:get_genuine()
    local ph = g:to_phrase()
    if ph and not g:to_sentence() and g._end == #raw then
      local entry = ph.entry
      if entry.remaining_code_length == 0 and table.concat(env.decoder:decode(ph.code)) == raw then
        first_exact = true
        if g.type == 'user_phrase' or entry.weight > confident_exact_weight then return {} end
      end
    end
    if g.type == 'user_table' or (g.type == 'table' and first.text:lower() == raw) then return {} end
  end
  local results = {}
  local function offer(text, code, score, spelling_entry)
    if first and first.text == text then return end
    local prior = results[text]
    if not prior or score > prior.score or (score == prior.score and code < prior.code) then
      results[text] = {text=text, code=code, score=score, spelling_entry=spelling_entry}
    end
  end
  local variants = spellings(raw,not first_exact)
  -- Disconnect the temporary reader before returning any suggestions. It must
  -- never become a second writer during a real selection or open incognito data.
  local user
  if next(variants) and not ctx:get_option('incognito_mode') and not ctx:get_option('disable_user_dict') then
    user = Memory(env.engine,env.engine.schema,'translator')
  end
  for code, bonus in pairs(variants) do
    local query = code:gsub(' ',"'")
    local seg = Segment(0,#query)
    seg.tags = Set{'abc'}
    local spelling_entry
    local tr = env.reference:query(query,seg)
    if tr then
      for cand in tr:iter() do
        local g = cand:get_genuine()
        local ph = g:to_phrase()
        if g._end == #query and g.type == 'phrase' and ph and ph.entry.remaining_code_length == 0
          and table.concat(env.decoder:decode(ph.code),' ') == code then
          spelling_entry = ph.entry
          if bonus ~= reversal_penalty or spelling_entry.weight >= familiar_reversal_weight then
            offer(ph.text, code, spelling_entry.weight + bonus, spelling_entry)
          end
        end
        break
      end
    end
    if user and user:user_lookup(code,false) then
      for entry in user:iter_user() do
        if entry.custom_code == code..' ' and entry.commit_count > 0 then
          offer(entry.text, code, math.min(0,entry.weight) + bonus, spelling_entry)
          break
        end
      end
    end
  end
  if user then user:disconnect() end
  local ranked = {}
  for _,item in pairs(results) do ranked[#ranked+1] = item end
  table.sort(ranked,function(a,b)
    if a.score ~= b.score then return a.score > b.score end
    return a.text < b.text
  end)
  return ranked
end

function M.func(input,env)
  local ctx = env.engine.context
  local raw = ctx.input
  local seg = not ctx.composition:empty() and ctx.composition:back()
  if not env.reference or not env.decoder or env.failed or #raw < 4 or #raw > 30 or not raw:match('^[a-z]+$') or ctx.caret_pos ~= #raw or
      not seg or seg.start ~= 0 or seg._end ~= #raw or not seg:has_tag('abc') or
      ctx:get_option('ascii_mode') or ctx:get_option('search_single_char') then
    for cand in input:iter() do yield(cand) end
    return
  end
  local first
  for cand in input:iter() do first = cand; yield(cand); break end
  local ok, ranked = pcall(suggestions, raw, first, env)
  if not ok then
    -- Keep typing functional even if an optional dictionary becomes unavailable.
    -- Avoid logging the spelling or any word from the user's dictionary.
    env.failed = true
    log.error('pinyin_typo_filter: dictionary lookup failed; keeping native candidates')
    for cand in input:iter() do yield(cand) end
    return
  end
  local added = {}
  for i = 1,math.min(2,#ranked) do
    local item = ranked[i]
    added[item.text] = true
    local comment = '纠错 · '..item.code
    if item.spelling_entry then
      -- Keep a native, independently owned entry under the RIGHT spelling. The
      -- candidate spans the actual input, including its missing or extra key.
      local entry = DictEntry(item.spelling_entry)
      entry.text = item.text
      local cand = Phrase(env.decoder,'typo_correction',0,#raw,entry):toCandidate()
      cand.comment = comment
      cand.preedit = raw
      yield(cand)
    else
      -- A learned-only phrase may have no corresponding static syllable IDs.
      -- Its existing userdb record is authoritative; avoid writing a guessed code.
      yield(Candidate('typo_correction',0,#raw,item.text,comment))
    end
  end
  for cand in input:iter() do if not added[cand.text] then yield(cand) end end
end
return M
