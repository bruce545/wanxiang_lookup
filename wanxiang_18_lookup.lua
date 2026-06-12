--@amzxyz https://github.com/amzxyz/rime_wanxiang
--wanxiang_lookup: #设置归属于super_lookup.lua
  --tags: [ abc ]  # 检索当前tag的候选
  --key: "`"       # 输入中反查引导符
  --lookup: [ wanxiang_reverse ] #反查滤镜数据库
  --data_source: [ aux, db ] # 优先级：写在前面优先。即使只写db，只要开启enable_tone也能从注释获取声调。
  --enable_tone: true  #启用声调反查
  --is_18jian: true # 可选，手动开启 18 键映射支持（如果不填，脚本也会自动从 speller/algebra 中检测 xlit 规则）

local wanxiang = require("wanxiang/wanxiang")

-- =====================
-- 脚本内置配置区
-- =====================
-- 控制本脚本在辅码修正/联想时最多输出前几个重组候选。
-- 1 = 只输出 top1；2 = 输出 top2；3 = 输出 top3。
-- 建议不要超过 5，过大会让候选栏变乱，也会增加计算量。
local LOOKUP_OUTPUT_TOP_N = 1

-- 安全上限：防止误填过大导致候选爆炸。
local LOOKUP_OUTPUT_TOP_N_LIMIT = 10

local function alt_lua_punc(s)
    return s and s:gsub('([%.%+%-%*%?%[%]%^%$%(%)%%])', '%%%1') or ''
end

local function safe_config_int(config, key, default_value)
    if not config then return default_value end
    local ok, val = pcall(function() return config:get_int(key) end)
    if ok and type(val) == "number" and val > 0 then return val end
    return default_value
end

-- 18键方案映射 (qwwrryuiipassffhjjlzxxvbbm)
local map_18jian = {
    ["e"] = "w", ["t"] = "r", ["o"] = "i", ["d"] = "s",
    ["g"] = "f", ["k"] = "j", ["c"] = "x", ["n"] = "b",
    ["E"] = "W", ["T"] = "R", ["O"] = "I", ["D"] = "S",
    ["G"] = "F", ["K"] = "J", ["C"] = "X", ["N"] = "B"
}

-- 18键反向映射：用于输入18键辅码时，展开为26键底层词典探测
local reverse_map_18jian = {
    ["w"] = {"w", "e"}, ["r"] = {"r", "t"}, ["i"] = {"i", "o"}, ["s"] = {"s", "d"},
    ["f"] = {"f", "g"}, ["j"] = {"j", "k"}, ["x"] = {"x", "c"}, ["b"] = {"b", "n"},
    ["W"] = {"W", "E"}, ["R"] = {"R", "T"}, ["I"] = {"I", "O"}, ["S"] = {"S", "D"},
    ["F"] = {"F", "G"}, ["J"] = {"J", "K"}, ["X"] = {"X", "C"}, ["B"] = {"B", "N"}
}

local function apply_18jian(s)
    if not s then return nil end
    return (s:gsub("[etodgkcnETODGKCN]", map_18jian))
end

local function expand_18jian_to_26jian(s)
    if not s or s == "" then return {""} end
    local results = {""}
    for i = 1, #s do
        local c = s:sub(i, i)
        local mapped = reverse_map_18jian[c]
        local new_results = {}
        if mapped then
            for _, prefix in ipairs(results) do
                table.insert(new_results, prefix .. mapped[1])
                table.insert(new_results, prefix .. mapped[2])
            end
        else
            for _, prefix in ipairs(results) do
                table.insert(new_results, prefix .. c)
            end
        end
        results = new_results
    end
    return results
end

local tones_map = {
    ["ā"]="7", ["á"]="8", ["ǎ"]="9", ["à"]="0",
    ["ō"]="7", ["ó"]="8", ["ǒ"]="9", ["ò"]="0",
    ["ē"]="7", ["é"]="8", ["ě"]="9", ["è"]="0",
    ["ī"]="7", ["í"]="8", ["ǐ"]="9", ["ì"]="0",
    ["ū"]="7", ["ú"]="8", ["ǔ"]="9", ["ù"]="0",
    ["ǖ"]="7", ["ǘ"]="8", ["ǚ"]="9", ["ǜ"]="0"
}

local function get_utf8_len(s)
    if utf8 and utf8.len then return utf8.len(s) end
    local _, count = string.gsub(s, "[^\128-\193]", "")
    return count
end

local function get_tone_from_pinyin(pinyin)
    if not pinyin or #pinyin == 0 then return nil end
    for char, tone in pairs(tones_map) do
        if string.find(pinyin, char, 1, true) then return tone end
    end
    return "0"
end

local function get_utf8_char_at(text, idx)
    local i = 1
    for _, code in utf8.codes(text) do
        if i == idx then return utf8.char(code) end
        i = i + 1
    end
    return ""
end

local function replace_utf8_char_at(text, index, new_char)
    local out = {}
    local i = 1
    for _, code in utf8.codes(text) do
        if i == index then
            table.insert(out, new_char)
        else
            table.insert(out, utf8.char(code))
        end
        i = i + 1
    end
    return table.concat(out)
end

local function get_script_text_parts(ctx, search_key_str)
    local parts = {}
    if not ctx or not ctx.composition or ctx.composition:empty() then return parts end
    local spans = ctx.composition:spans()
    if not spans then return parts end
    local count = type(spans.count) == "function" and spans:count() or spans.count
    if count == 0 then return parts end
    local vertices = type(spans.vertices) == "function" and spans:vertices() or spans.vertices
    if not vertices or #vertices < 2 then return parts end
    local raw_in = ctx.input or ""
    for i = 1, #vertices - 1 do
        local start_byte = vertices[i] + 1 
        local end_byte = vertices[i + 1]   
        local raw_syl = raw_in:sub(start_byte, end_byte)
        if raw_syl and raw_syl ~= "" then
            if search_key_str and search_key_str ~= "" then
                local split_pos = raw_syl:find(search_key_str, 1, true)
                if split_pos then raw_syl = raw_syl:sub(1, split_pos - 1) end
            end
            raw_syl = raw_syl:gsub("['%s]", "")
            if raw_syl ~= "" then table.insert(parts, raw_syl) end
        end
    end
    return parts
end

-- 🛠️ 核心质检工具：验证单字是否符合辅码条件（支持 18 键展开）
local function check_char_fuma_match(env, pinyin, fuma, target_char)
    local pinyin_part = (pinyin or ""):lower()
    local fuma_part = (fuma or ""):lower()
    local fuma_list = env.is_18jian and expand_18jian_to_26jian(fuma_part) or {fuma_part}
    for _, f in ipairs(fuma_list) do
        local probe = pinyin_part .. (f or ""):lower()
        if env.mem:dict_lookup(probe, true, 200) then
            for e in env.mem:iter_dict() do
                if e.text == target_char then return true end
            end
        end
        if env.mem:user_lookup(probe, true) then
            for e in env.mem:iter_user() do
                if e.text == target_char then return true end
            end
        end
    end
    return false
end

-- 以下为反查组相关工具函数...
local function parse_and_separate_rules(schema_id)
    if not schema_id or #schema_id == 0 then return nil, nil end
    local schema = Schema(schema_id)
    if not schema then return nil, nil end
    local config = schema.config
    if not config then return nil, nil end
    local algebra_list = config:get_list('speller/algebra')
    if not algebra_list or algebra_list.size == 0 then return nil, nil end
    local main_rules, xlit_rules = {}, {}
    for i = 0, algebra_list.size - 1 do
        local rule = algebra_list:get_value_at(i).value
        if rule and #rule > 0 then
            if rule:match("^xlit/HSPZN/") then table.insert(xlit_rules, rule)
            else table.insert(main_rules, rule) end
        end
    end
    if #main_rules == 0 and #xlit_rules == 0 then return nil, nil end
    return main_rules, xlit_rules
end

local function get_schema_rules(env)
    local config = env.engine.schema.config
    local db_list = config:get_list("wanxiang_lookup/lookup")
    if not db_list or db_list.size == 0 then return {}, {} end
    local schema_id = db_list:get_value_at(0).value
    if not schema_id or #schema_id == 0 then return {}, {} end
    local main_rules, xlit_rules = parse_and_separate_rules(schema_id)
    if not main_rules and not xlit_rules then return {}, {} end
    return main_rules or {}, xlit_rules or {}
end

local function expand_code_variant(main_projection, xlit_projection, part)
    local out, seen = {}, {}
    local out_xlit, seen_xlit = {}, {}
    local function add(s) if s and #s > 0 and not seen[s] then seen[s] = true table.insert(out, s) end end
    local function add_xlit(s) if s and #s > 0 and not seen_xlit[s] then seen_xlit[s] = true table.insert(out_xlit, s) end end
    local function extract_odd_positions(s)
        if not s or not s:match("^%l+$") or #s % 2 ~= 0 then return nil end
        local res = ""
        for i = 1, #s, 2 do res = res .. s:sub(i, i) end
        return res
    end
    local function get_v_variant(s)
        if not s or not s:match("^%l+$") or #s % 2 ~= 0 then return nil end
        local res, has_change = "", false
        for i = 1, #s, 2 do
            local char_odd, char_even = s:sub(i, i), s:sub(i+1, i+1)
            if (char_odd == 'j' or char_odd == 'q' or char_odd == 'x' or char_odd == 'y') and char_even == 'v' then
                res = res .. char_odd .. 'u'
                has_change = true
            else
                res = res .. char_odd .. char_even
            end
        end
        return has_change and res or nil
    end

    local _, quote_count = part:gsub("'", "")
    if quote_count == 1 then
        local s1, s2 = part:match("^([^']*)'([^']*)$")
        if s1 and s2 and #s1 > 0 and #s2 > 0 then add(s1:sub(1,1) .. s2:sub(1,1)) end
    end
    if part:match("^%l+$") then add(part) end
    local raw_extracted = extract_odd_positions(part)
    if raw_extracted then add(raw_extracted) end

    if main_projection and not part:match('^%u+$') then
        local p = main_projection:apply(part, true)
        if p and #p > 0 then
            add(p) 
            local v_variant = get_v_variant(p)
            if v_variant then add(v_variant) end
            local proj_extracted = extract_odd_positions(p)
            if proj_extracted then add(proj_extracted) end
        end
    end
    if part:match('^%u+$') and xlit_projection then
        local xlit_result = xlit_projection:apply(part, true)
        if xlit_result and #xlit_result > 0 then add_xlit(xlit_result) end
    end
    return out, out_xlit
end

local function build_reverse_group(main_projection, xlit_projection, db_table, text, is_18jian)
    local group_main, seen_main = {}, {}
    local group_xlit, seen_xlit = {}, {}
    for _, db in ipairs(db_table) do
        local code = db:lookup(text)
        if code and #code > 0 then
            for part in code:gmatch('%S+') do
                local main_variants, xlit_variants = expand_code_variant(main_projection, xlit_projection, part)
                for _, v in ipairs(main_variants) do 
                    if is_18jian then v = apply_18jian(v) end
                    if not seen_main[v] then seen_main[v] = true group_main[#group_main + 1] = v end 
                end
                for _, v in ipairs(xlit_variants) do 
                    if is_18jian then v = apply_18jian(v) end
                    if not seen_xlit[v] then seen_xlit[v] = true group_xlit[#group_xlit + 1] = v end 
                end
            end
        end
    end
    return group_main, group_xlit
end

local function group_match(group, fuma)
    if not group then return false end
    for i = 1, #group do if string.sub(group[i], 1, #fuma) == fuma then return true end end
    return false
end

local function match_fuzzy_recursive(codes_sequence, idx, input_str, input_idx, memo, is_phrase_mode)
    if input_idx > #input_str then return true end
    if idx > #codes_sequence then return false end
    local state_key = idx * 1000 + input_idx
    if memo[state_key] ~= nil then return memo[state_key] end
    local codes = codes_sequence[idx]
    local result = false
    if codes then
        for _, code in ipairs(codes) do
            local skip = false
            if is_phrase_mode and #code > 3 then skip = true end
            if code:match("^%d+$") then skip = true end
            if not skip then
                local i_curr, c_curr = input_idx, 1
                local i_limit, c_limit = #input_str, #code
                while i_curr <= i_limit and c_curr <= c_limit do
                    if input_str:byte(i_curr) == code:byte(c_curr) then i_curr = i_curr + 1 end
                    c_curr = c_curr + 1
                end
                if match_fuzzy_recursive(codes_sequence, idx + 1, input_str, i_curr, memo, is_phrase_mode) then
                    result = true break
                end
            end
        end
    else
        if match_fuzzy_recursive(codes_sequence, idx + 1, input_str, input_idx, memo, is_phrase_mode) then result = true end
    end
    memo[state_key] = result
    return result
end

local function list_contains(list, target)
    if not list then return false end
    for _, v in ipairs(list) do if v == target then return true end end
    return false
end

local function split_lookup_input(input, key, bypass_prefix)
    if not input or input == "" or not key or key == "" then return nil end
    local scan_from = 1
    if bypass_prefix and bypass_prefix ~= "" and input:sub(1, #bypass_prefix) == bypass_prefix then
        scan_from = #bypass_prefix + 1
    end
    local s_start, s_end = nil, nil
    local from = scan_from
    while true do
        local s, e = input:find(key, from, true)
        if not s then break end
        s_start, s_end = s, e
        from = s + 1
    end
    if not s_start then return nil end
    local code = input:sub(1, s_start - 1)
    local fuma = input:sub(s_end + 1)
    return code, fuma, s_start, s_end
end

local function parse_comment_codes(comment, pattern, target_len, enable_tone, is_18jian)
    if not comment or comment == "" then return nil end
    local parts = {}
    if target_len == 1 then parts = { comment }
    else
        for seg in comment:gmatch(pattern) do table.insert(parts, seg) end
        if #parts ~= target_len then return nil end
    end
    local result = {}
    for i, part in ipairs(parts) do
        local p1, p2 = part:find(";")
        local pinyin_part = p1 and part:sub(1, p1 - 1) or part
        local codes_part = p1 and part:sub(p2 + 1) or ""
        local codes_list = {}
        if #codes_part > 0 then
            for c in codes_part:gmatch("[^,]+") do 
                local trimmed = c:gsub("^%s+", ""):gsub("%s+$", "")
                if is_18jian then trimmed = apply_18jian(trimmed) end
                if #trimmed > 0 then table.insert(codes_list, trimmed) end
            end
        end
        if enable_tone then
            local tone = get_tone_from_pinyin(pinyin_part)
            if tone then table.insert(codes_list, tone) end
        end
        result[i] = codes_list
    end
    return result
end

local f = {}

function f.init(env)
    local config = env.engine.schema.config
    
    -- 检测 18键 并键映射设置
    env.is_18jian = config:get_bool('wanxiang_lookup/is_18jian') or false
    local main_algebra = config:get_list('speller/algebra')
    if main_algebra and not env.is_18jian then
        for i = 0, main_algebra.size - 1 do
            local rule = main_algebra:get_value_at(i).value
            if rule and rule:find("xlit/qwertyuiopasdfghjklzxcvbnm/qwwrryuiipassffhjjlzxxvbbm/") then
                env.is_18jian = true
                break
            end
        end
    end

    -- 并键多结果展开的性能阈值：仍从 schema 读取，用于控制内部搜索宽度。
    -- max_route_branches：单一路线、单一步骤最多保留多少个同码候选。
    -- max_total_variants：逐段消耗过程中最多保留多少条分支路径。
    env.max_route_branches = safe_config_int(config, 'wanxiang_lookup/max_route_branches', 8)
    env.max_total_variants = safe_config_int(config, 'wanxiang_lookup/max_total_variants', 32)

    -- 输出 top 几：直接改脚本顶部 LOOKUP_OUTPUT_TOP_N，不从 schema 读取。
    env.output_top_n = tonumber(LOOKUP_OUTPUT_TOP_N) or 1
    if env.output_top_n < 1 then env.output_top_n = 1 end
    if env.output_top_n > LOOKUP_OUTPUT_TOP_N_LIMIT then env.output_top_n = LOOKUP_OUTPUT_TOP_N_LIMIT end

    -- 词组联想打分：词组候选必须明显压过单字兜底，否则会表现成“一个字一个字改”。
    env.phrase_bonus = safe_config_int(config, 'wanxiang_lookup/phrase_bonus', 8000)
    env.phrase_len_bonus = safe_config_int(config, 'wanxiang_lookup/phrase_len_bonus', 1000)
    env.single_char_fallback_bonus = safe_config_int(config, 'wanxiang_lookup/single_char_fallback_bonus', 800)

    -- 长度分流：二字候选更偏向词组；三字及以上更偏向单字。
    env.two_char_phrase_bonus = safe_config_int(config, 'wanxiang_lookup/two_char_phrase_bonus', 12000)
    env.two_char_single_bonus = safe_config_int(config, 'wanxiang_lookup/two_char_single_bonus', 200)
    env.long_phrase_bonus = safe_config_int(config, 'wanxiang_lookup/long_phrase_bonus', 1000)
    env.long_single_char_bonus = safe_config_int(config, 'wanxiang_lookup/long_single_char_bonus', 5000)

    -- 辅码逐段匹配不保存模式状态：
    -- 每次 f.func 调用都先严格左到右；本轮左侧失败时，才临时启动右侧优先兜底。

    env.enable_tone = config:get_bool('wanxiang_lookup/enable_tone')
    if env.enable_tone == nil then env.enable_tone = true end
    
    local sources_list = config:get_list('wanxiang_lookup/data_source')
    env.data_sources = {}
    local config_has_aux_source = false
    env.has_db = false
    
    if sources_list and sources_list.size > 0 then
        for i = 0, sources_list.size - 1 do
            local s = sources_list:get_value_at(i).value
            table.insert(env.data_sources, s)
            if s == 'aux' then config_has_aux_source = true end
            if s == 'db' then env.has_db = true end
        end
    else
        env.data_sources = { 'aux', 'db' }
        config_has_aux_source = true
        env.has_db = true
    end

    env.has_comment = config_has_aux_source or env.enable_tone

    env.db_table = nil
    if env.has_db then
        local db_list = config:get_list("wanxiang_lookup/lookup")
        if db_list and db_list.size > 0 then
            env.db_table = {}
            for i = 0, db_list.size - 1 do
                table.insert(env.db_table, ReverseLookup(db_list:get_value_at(i).value))
            end
            local main_rules, xlit_rules = get_schema_rules(env)
            env.main_projection = (type(main_rules) == 'table' and #main_rules > 0) and Projection() or nil
            if env.main_projection then env.main_projection:load(main_rules) end
            env.xlit_projection = (type(xlit_rules) == 'table' and #xlit_rules > 0) and Projection() or nil
            if env.xlit_projection then env.xlit_projection:load(xlit_rules) end
        else
            env.has_db = false
        end
    end

    if env.has_comment then
        local delimiter = config:get_string('speller/delimiter') or " '"
        if delimiter == "" then delimiter = " " end
        env.comment_split_ptrn = "[^" .. alt_lua_punc(delimiter) .. "]+"
    end

    env.search_key_str = config:get_string('wanxiang_lookup/key') or '`'
    env.search_key_alt = alt_lua_punc(env.search_key_str)
    env.bypass_prefix = config:get_string('add_user_dict/prefix')

    local tag = config:get_list('wanxiang_lookup/tags')
    if tag and tag.size > 0 then
        env.tag = {}
        for i = 0, tag.size - 1 do table.insert(env.tag, tag:get_value_at(i).value) end
    else
        env.tag = { 'abc' }
    end

    env.notifier = env.engine.context.select_notifier:connect(function(ctx)
        local input = ctx.input
        local code, fuma = split_lookup_input(input, env.search_key_str, env.bypass_prefix)
        if (not code or #code == 0) then return end
        local preedit = ctx:get_preedit()
        local no_search_string = code
        local preedit_text = (preedit and preedit.text) or ""
        local edit = select(1, split_lookup_input(preedit_text, env.search_key_str, env.bypass_prefix))
        if edit and edit:match('[%w/]') then
            ctx.input = no_search_string .. env.search_key_str
        else
            ctx.input = no_search_string
            env.commit_code = no_search_string
            ctx:commit()
        end
    end)

    env._global_db_cache = {}
    env._global_comment_cache = {}
    env.cache_size = 0 
    
    env.history_parts = {}
    env.history_input = ""
    env.update_conn = env.engine.context.update_notifier:connect(function(ctx)
        if not ctx:is_composing() then return end
        local raw_in = ctx.input or ""
        local key = env.search_key_str or "`"
        if key ~= "" and not raw_in:find(key, 1, true) then
            local parts = get_script_text_parts(ctx, key)
            if #parts > 0 then
                env.history_parts = parts
                env.history_input = raw_in
            end
        end
    end)
end

function f.func(input, env)
    local context = env.engine.context
    local seg = context.composition:back()

    if not seg or not f.tags_match(seg, env) then
        for cand in input:iter() do yield(cand) end
        return
    end
    if #env.data_sources == 0 then
        for cand in input:iter() do yield(cand) end
        return
    end

    local ctx_input = env.engine.context.input
    local pure_code, fuma, s_start, s_end = split_lookup_input(ctx_input, env.search_key_str, env.bypass_prefix)
    if not s_start then for cand in input:iter() do yield(cand) end return end
    if #fuma == 0 then for cand in input:iter() do yield(cand) end return end
    if not env.mem then
        env.mem = Memory(env.engine, env.engine.schema)
    end
    if not env.main_translator and Component and Component.Translator then
        pcall(function() 
            env.main_translator = Component.Translator(env.engine, "translator", "script_translator")
        end)
    end

    local tone_filter_seq = {}
    local clean_fuma = ""
    for i = 1, #fuma do
        local char = fuma:sub(i, i)
        if char == "7" or char == "8" or char == "9" or char == "0" then table.insert(tone_filter_seq, char)
        else clean_fuma = clean_fuma .. char end
    end
    local apply_tone_filter = env.enable_tone and (#tone_filter_seq > 0)

    local if_single_char_first = env.engine.context:get_option('char_priority')
    local buckets = {}
    local long_word_cands = {}
    local max_len = 0
    local has_any_match = false 

    if env.cache_size > 2000 then
        env._global_db_cache = {}
        env._global_comment_cache = {}
        env.cache_size = 0
    end
    local db_cache = env._global_db_cache
    local comment_cache = env._global_comment_cache

    local fuma_chunks = {}
    for code, digit in fuma:gmatch("(%a%a?)(%d*)") do
        table.insert(fuma_chunks, code:lower() .. digit)
    end

    local is_first_cand = true
    local ctx = env.engine.context
    local syllables = {}
    if pure_code == env.history_input and #env.history_parts > 0 then
        for _, v in ipairs(env.history_parts) do table.insert(syllables, v) end
    else
        syllables = get_script_text_parts(ctx, env.search_key_str)
    end

    for cand in input:iter() do
        local cand_len = get_utf8_len(cand.text)
        
        -- 【全新重写】：路线1 -> 路线1B -> 路线2，最右侧优先并逐段消耗辅码
        if is_first_cand then
            is_first_cand = false
            
            local syl_offset = 0
            local spans = ctx.composition:spans()
            if spans then
                local vertices = type(spans.vertices) == "function" and spans:vertices() or spans.vertices
                if vertices then
                    for i = 1, #vertices - 1 do
                        if vertices[i] < cand.start then
                            syl_offset = syl_offset + 1
                        else
                            break
                        end
                    end
                end
            end
            local current_syl_count = #syllables - syl_offset

            if apply_tone_filter and clean_fuma == "" and #tone_filter_seq > 0 then
                local tone_len = #tone_filter_seq
                if current_syl_count == tone_len and env.main_translator then
                    local pure_pinyin_parts = {}
                    for k = 1, tone_len do
                        local syl = syllables[k + syl_offset] 
                        if syl then
                            if #syl > 2 then syl = string.sub(syl, 1, 2) end
                            table.insert(pure_pinyin_parts, syl .. tone_filter_seq[k])
                        end
                    end
                    
                    if #pure_pinyin_parts == tone_len then
                        local query_str = table.concat(pure_pinyin_parts, "")
                        local seg_trans = Segment(0, #query_str)
                        seg_trans.tags = Set({"abc"})
                        
                        local ok, translation = pcall(function() return env.main_translator:query(query_str, seg_trans) end)
                        local yielded_any = false
                        
                        if ok and translation then
                            for c in translation:iter() do
                                local custom_cand = Candidate(cand.type, cand.start, cand._end, c.text, c.comment)
                                custom_cand.quality = c.quality
                                custom_cand.preedit = cand.preedit
                                yield(custom_cand)
                                yielded_any = true
                                break
                            end
                        end
                        
                        if yielded_any then
                            goto skip
                        end
                    end
                end
            end
            -- 双拼兜底：composition spans 没有正确拆成两码一音时，退回按 2 字母切分 pure_code
            local function split_code_by_2(code)
                local parts = {}
                if not code or code == "" or (#code % 2 ~= 0) then return parts end
                for i = 1, #code, 2 do
                    table.insert(parts, code:sub(i, i + 1):lower())
                end
                return parts
            end

            if #syllables < cand_len + syl_offset then
                local fallback_parts = split_code_by_2(pure_code)
                if #fallback_parts >= cand_len + syl_offset then
                    syllables = fallback_parts
                end
            end

            if ((cand.type == 'sentence' and cand_len > 1) or (cand.type == 'phrase' and cand_len > 1)) and #syllables >= (cand_len + syl_offset) then
                local current_text = cand.text
                local corrected_count = 0
                local match_count = 0

                if #fuma_chunks > 0 then
                    local MAX_ROUTE_BRANCHES = env.max_route_branches or 8
                    local MAX_TOTAL_VARIANTS = env.max_total_variants or 32
                    local OUTPUT_TOP_N = env.output_top_n or 1

                    -- 本轮候选长度策略：
                    -- 2 字：优先相信 translator 给出的二字词组联想；
                    -- >2 字：优先按每个辅码锁定单字，避免长句被词组重组整体带偏。
                    local prefer_phrase_for_two = (cand_len == 2)
                    local prefer_single_for_long = (cand_len > 2)
                    local route_phrase_bonus = prefer_phrase_for_two and (env.two_char_phrase_bonus or 12000)
                        or (prefer_single_for_long and (env.long_phrase_bonus or 1000) or (env.phrase_bonus or 8000))
                    local route_single_bonus = prefer_phrase_for_two and (env.two_char_single_bonus or 200)
                        or (prefer_single_for_long and (env.long_single_char_bonus or 5000) or (env.single_char_fallback_bonus or 800))

                    local function get_phrase_text(text, w_start, w_end)
                        local out = {}
                        for k = w_start, w_end do
                            table.insert(out, get_utf8_char_at(text, k))
                        end
                        return table.concat(out)
                    end

                    local function replace_utf8_range(text, w_start, w_end, new_text)
                        local out = {}
                        local char_idx = 1
                        for _, code_pt in utf8.codes(text) do
                            if char_idx >= w_start and char_idx <= w_end then
                                if char_idx == w_start then table.insert(out, new_text) end
                            else
                                table.insert(out, utf8.char(code_pt))
                            end
                            char_idx = char_idx + 1
                        end
                        return table.concat(out)
                    end

                    local function get_pinyin_window(w_start, w_end)
                        local pure_pinyin_parts = {}
                        for pos = w_start, w_end do
                            local syl = syllables[pos + syl_offset]
                            if not syl then return nil end
                            if #syl > 2 then syl = string.sub(syl, 1, 2) end
                            table.insert(pure_pinyin_parts, syl:lower())
                        end
                        return pure_pinyin_parts
                    end

                    local function sort_and_cap_variants(list, cap)
                        table.sort(list, function(a, b)
                            if (a.score or 0) ~= (b.score or 0) then return (a.score or 0) > (b.score or 0) end
                            if (a.corrected_count or 0) ~= (b.corrected_count or 0) then return (a.corrected_count or 0) < (b.corrected_count or 0) end
                            return (a.text or "") < (b.text or "")
                        end)
                        if #list <= cap then return list end
                        local capped = {}
                        for i = 1, cap do capped[i] = list[i] end
                        return capped
                    end

                    local function add_or_update_char_candidate(list, seen, char, weight, orig_char)
                        if not char or char == "" then return end
                        local score = weight or 0
                        if char == orig_char then score = score + 1000 end -- 原字本身符合辅码时，优先保留原候选
                        local old = seen[char]
                        if old then
                            if score > old.weight then old.weight = score end
                        else
                            local item = { char = char, weight = score }
                            seen[char] = item
                            table.insert(list, item)
                        end
                    end

                    local function lookup_single_char_candidates(pinyin_code, chunk_fuma, orig_char)
                        local fuma_list = env.is_18jian and expand_18jian_to_26jian((chunk_fuma or ""):lower()) or {(chunk_fuma or ""):lower()}
                        local candidates = {}
                        local seen_chars = {}

                        for _, f in ipairs(fuma_list) do
                            local probe_code = (pinyin_code or ""):lower() .. (f or ""):lower()

                            if env.mem:dict_lookup(probe_code, true, 200) then
                                for entry in env.mem:iter_dict() do
                                    if get_utf8_len(entry.text) == 1 then
                                        add_or_update_char_candidate(candidates, seen_chars, entry.text, entry.weight or 0, orig_char)
                                    end
                                end
                            end

                            if env.mem:user_lookup(probe_code, true) then
                                for entry in env.mem:iter_user() do
                                    if get_utf8_len(entry.text) == 1 then
                                        add_or_update_char_candidate(candidates, seen_chars, entry.text, (entry.weight or 0) + 500, orig_char)
                                    end
                                end
                            end
                        end

                        table.sort(candidates, function(a, b) return (a.weight or 0) > (b.weight or 0) end)
                        if #candidates <= MAX_ROUTE_BRANCHES then return candidates end
                        local capped = {}
                        for i = 1, MAX_ROUTE_BRANCHES do capped[i] = candidates[i] end
                        return capped
                    end

                    local function branch_route1(var)
                        if not env.main_translator then return nil end
                        if var.right_fuma_idx < 2 or var.search_end_idx < 2 then return nil end

                        local max_phrase_len = math.min(var.right_fuma_idx, var.search_end_idx)
                        for phrase_len = max_phrase_len, 2, -1 do
                            local w_end = var.search_end_idx
                            local w_start = w_end - phrase_len + 1
                            local fuma_start = var.right_fuma_idx - phrase_len + 1
                            local pure_pinyin_parts = get_pinyin_window(w_start, w_end)

                            if pure_pinyin_parts then
                                local query_str = table.concat(pure_pinyin_parts, "")
                                local seg_trans = Segment(0, #query_str)
                                seg_trans.tags = Set({"abc"})

                                local ok, translation = pcall(function()
                                    return env.main_translator:query(query_str, seg_trans)
                                end)

                                if ok and translation then
                                    local orig_phrase_text = get_phrase_text(var.text, w_start, w_end)
                                    local branches = {}
                                    local seen_phrase = {}

                                    for c in translation:iter() do
                                        local phrase_text = c.text
                                        if get_utf8_len(phrase_text) == phrase_len and not seen_phrase[phrase_text] then
                                            local match_all = true
                                            local char_idx = 1

                                            for _, code_pt in utf8.codes(phrase_text) do
                                                local char = utf8.char(code_pt)
                                                local fuma_idx = fuma_start + char_idx - 1
                                                if not check_char_fuma_match(env, pure_pinyin_parts[char_idx], fuma_chunks[fuma_idx], char) then
                                                    match_all = false
                                                    break
                                                end
                                                char_idx = char_idx + 1
                                            end

                                            if match_all then
                                                seen_phrase[phrase_text] = true
                                                local is_changed = (orig_phrase_text ~= phrase_text)
                                                table.insert(branches, {
                                                    text = is_changed and replace_utf8_range(var.text, w_start, w_end, phrase_text) or var.text,
                                                    corrected_count = var.corrected_count + (is_changed and 1 or 0),
                                                    match_count = var.match_count + phrase_len,
                                                    search_end_idx = w_start - 1,
                                                    right_fuma_idx = fuma_start - 1,
                                                    score = (var.score or 0) + (c.quality or 0)
                                                        + route_phrase_bonus
                                                        + phrase_len * (env.phrase_len_bonus or 1000)
                                                        + (is_changed and 0 or 1000)
                                                })
                                                if #branches >= MAX_ROUTE_BRANCHES then break end
                                            end
                                        end
                                    end

                                    if #branches > 0 then
                                        return sort_and_cap_variants(branches, MAX_ROUTE_BRANCHES)
                                    end
                                end
                            end
                        end
                        return nil
                    end

                    local function branch_route1b(var)
                        if not env.main_translator then return nil end
                        if var.right_fuma_idx < 1 or var.search_end_idx < 2 then return nil end

                        local w_end = var.search_end_idx
                        local w_start = w_end - 1
                        local pure_pinyin_parts = get_pinyin_window(w_start, w_end)
                        if not pure_pinyin_parts then return nil end

                        local query_str = pure_pinyin_parts[1] .. pure_pinyin_parts[2]
                        local seg_trans = Segment(0, #query_str)
                        seg_trans.tags = Set({"abc"})

                        local ok, translation = pcall(function()
                            return env.main_translator:query(query_str, seg_trans)
                        end)
                        if not ok or not translation then return nil end

                        local orig_char1 = get_utf8_char_at(var.text, w_start)
                        local orig_char2 = get_utf8_char_at(var.text, w_end)
                        local orig_phrase_text = orig_char1 .. orig_char2
                        local chunk_fuma = fuma_chunks[var.right_fuma_idx]
                        local branches = {}
                        local seen_phrase = {}

                        for c in translation:iter() do
                            if get_utf8_len(c.text) == 2 and c.text ~= orig_phrase_text and not seen_phrase[c.text] then
                                local char1 = get_utf8_char_at(c.text, 1)
                                local char2 = get_utf8_char_at(c.text, 2)

                                -- 模式A：保留旧逻辑：左变右不变，例如“星星”->“行星”。
                                local case_a = (char2 == orig_char2) and check_char_fuma_match(env, pure_pinyin_parts[1], chunk_fuma, char1)
                                -- 模式B：词组联想逻辑：只要右字符合当前辅码，允许左字随词组一起变化。
                                -- 否则“行星/星形”这类二字词会被退化成单字修改。
                                local case_b = check_char_fuma_match(env, pure_pinyin_parts[2], chunk_fuma, char2)

                                if case_a or case_b then
                                    seen_phrase[c.text] = true
                                    table.insert(branches, {
                                        text = replace_utf8_range(var.text, w_start, w_end, c.text),
                                        corrected_count = var.corrected_count + 1,
                                        match_count = var.match_count + 1,
                                        search_end_idx = w_start - 1,
                                        right_fuma_idx = var.right_fuma_idx - 1,
                                        score = (var.score or 0) + (c.quality or 0) + route_phrase_bonus + 2 * (env.phrase_len_bonus or 1000)
                                    })
                                    if #branches >= MAX_ROUTE_BRANCHES then break end
                                end
                            end
                        end

                        if #branches > 0 then return sort_and_cap_variants(branches, MAX_ROUTE_BRANCHES) end
                        return nil
                    end

                    local function branch_route2(var)
                        if var.right_fuma_idx < 1 or var.search_end_idx < 1 then return nil end

                        local chunk_fuma = fuma_chunks[var.right_fuma_idx]

                        for i = var.search_end_idx, 1, -1 do
                            local orig_char = get_utf8_char_at(var.text, i)
                            local pinyin_code = syllables[i + syl_offset]
                            if pinyin_code then
                                if #pinyin_code > 2 then pinyin_code = string.sub(pinyin_code, 1, 2) end
                                pinyin_code = pinyin_code:lower()

                                local char_candidates = lookup_single_char_candidates(pinyin_code, chunk_fuma, orig_char)

                                -- 严格右向左：只要当前位置存在任意合法字，就只在这个位置生成所有合法分支，不继续向左找。
                                if #char_candidates > 0 then
                                    local branches = {}
                                    for _, vc in ipairs(char_candidates) do
                                        local is_changed = (vc.char ~= orig_char)
                                        table.insert(branches, {
                                            text = is_changed and replace_utf8_char_at(var.text, i, vc.char) or var.text,
                                            corrected_count = var.corrected_count + (is_changed and 1 or 0),
                                            match_count = var.match_count + 1,
                                            search_end_idx = i - 1,
                                            right_fuma_idx = var.right_fuma_idx - 1,
                                            score = (var.score or 0) + (vc.weight or 0) + route_single_bonus
                                        })
                                    end
                                    return sort_and_cap_variants(branches, MAX_ROUTE_BRANCHES)
                                end
                            end
                        end

                        return nil
                    end

                    local function branch_route1_left(var)
                        if not env.main_translator then return nil end
                        if var.left_fuma_idx > (#fuma_chunks - 1) or var.search_start_idx > (cand_len - 1) then return nil end

                        local remain_fuma = #fuma_chunks - var.left_fuma_idx + 1
                        local remain_chars = cand_len - var.search_start_idx + 1
                        local max_phrase_len = math.min(remain_fuma, remain_chars)

                        for phrase_len = max_phrase_len, 2, -1 do
                            local w_start = var.search_start_idx
                            local w_end = w_start + phrase_len - 1
                            local fuma_start = var.left_fuma_idx
                            local pure_pinyin_parts = get_pinyin_window(w_start, w_end)

                            if pure_pinyin_parts then
                                local query_str = table.concat(pure_pinyin_parts, "")
                                local seg_trans = Segment(0, #query_str)
                                seg_trans.tags = Set({"abc"})

                                local ok, translation = pcall(function()
                                    return env.main_translator:query(query_str, seg_trans)
                                end)

                                if ok and translation then
                                    local orig_phrase_text = get_phrase_text(var.text, w_start, w_end)
                                    local branches = {}
                                    local seen_phrase = {}

                                    for c in translation:iter() do
                                        local phrase_text = c.text
                                        if get_utf8_len(phrase_text) == phrase_len and not seen_phrase[phrase_text] then
                                            local match_all = true
                                            local char_idx = 1

                                            for _, code_pt in utf8.codes(phrase_text) do
                                                local char = utf8.char(code_pt)
                                                local fuma_idx = fuma_start + char_idx - 1
                                                if not check_char_fuma_match(env, pure_pinyin_parts[char_idx], fuma_chunks[fuma_idx], char) then
                                                    match_all = false
                                                    break
                                                end
                                                char_idx = char_idx + 1
                                            end

                                            if match_all then
                                                seen_phrase[phrase_text] = true
                                                local is_changed = (orig_phrase_text ~= phrase_text)
                                                table.insert(branches, {
                                                    text = is_changed and replace_utf8_range(var.text, w_start, w_end, phrase_text) or var.text,
                                                    corrected_count = var.corrected_count + (is_changed and 1 or 0),
                                                    match_count = var.match_count + phrase_len,
                                                    search_start_idx = w_end + 1,
                                                    left_fuma_idx = fuma_start + phrase_len,
                                                    score = (var.score or 0) + (c.quality or 0)
                                                        + route_phrase_bonus
                                                        + phrase_len * (env.phrase_len_bonus or 1000)
                                                        + (is_changed and 0 or 1000)
                                                })
                                                if #branches >= MAX_ROUTE_BRANCHES then break end
                                            end
                                        end
                                    end

                                    if #branches > 0 then
                                        return sort_and_cap_variants(branches, MAX_ROUTE_BRANCHES)
                                    end
                                end
                            end
                        end
                        return nil
                    end

                    local function branch_route1b_left(var)
                        if var.left_fuma_idx > #fuma_chunks or var.search_start_idx > cand_len then return nil end

                        -- 【严格左到右前缀匹配】
                        -- 第 n 个辅码只能绑定第 n 个尚未处理的字位；不扫描右侧、不从末尾倒推。
                        -- 但为了 wubi`hh 能优先得到“五笔”，允许用当前二字拼音窗口重组词组：
                        -- 当前辅码只锁定左字，右字由 translator 根据原拼音窗口补全。
                        local w_start = var.search_start_idx
                        local w_end = math.min(w_start + 1, cand_len)
                        local pure_pinyin_parts = get_pinyin_window(w_start, w_end)
                        if not pure_pinyin_parts then return nil end

                        local chunk_fuma = fuma_chunks[var.left_fuma_idx]
                        local orig_char1 = get_utf8_char_at(var.text, w_start)
                        local orig_char2 = (w_end > w_start) and get_utf8_char_at(var.text, w_end) or ""
                        local orig_phrase_text = orig_char1 .. orig_char2

                        -- 先查“当前位置拼音 + 当前辅码”能得到哪些单字。
                        -- 后续所有左侧分支都必须以前缀字集合为准，保证 hh 只能匹配第一个字，不会跑到第二个字去生成“无皕”。
                        local left_char_candidates = lookup_single_char_candidates(pure_pinyin_parts[1], chunk_fuma, orig_char1)
                        if not left_char_candidates or #left_char_candidates == 0 then return nil end

                        local left_char_weight = {}
                        for _, item in ipairs(left_char_candidates) do
                            left_char_weight[item.char] = item.weight or 0
                        end

                        local branches = {}
                        local seen_text = {}

                        -- 三字及以上：先做严格单字修正。这样“长句/长词”不会被二字词组窗口反复改偏。
                        if prefer_single_for_long then
                            for idx, item in ipairs(left_char_candidates) do
                                if idx > MAX_ROUTE_BRANCHES then break end
                                local new_text = replace_utf8_char_at(var.text, w_start, item.char)
                                if not seen_text[new_text] then
                                    seen_text[new_text] = true
                                    local is_changed = (item.char ~= orig_char1)
                                    table.insert(branches, {
                                        text = new_text,
                                        corrected_count = var.corrected_count + (is_changed and 1 or 0),
                                        match_count = var.match_count + 1,
                                        search_start_idx = w_start + 1,
                                        left_fuma_idx = var.left_fuma_idx + 1,
                                        score = (var.score or 0) + (item.weight or 0) + route_single_bonus + (is_changed and 0 or 1000)
                                    })
                                end
                            end
                            if #branches > 0 then return sort_and_cap_variants(branches, MAX_ROUTE_BRANCHES) end
                        end

                        -- 二字候选：优先用二字窗口重新组词，但只校验左字是否属于当前辅码候选。
                        -- 例如 wubi`hh：translator 查询 wubi，返回“五笔”时，只要求“五”符合 wu+hh。
                        if w_end > w_start and env.main_translator then
                            local query_str = pure_pinyin_parts[1] .. pure_pinyin_parts[2]
                            local seg_trans = Segment(0, #query_str)
                            seg_trans.tags = Set({"abc"})

                            local ok, translation = pcall(function()
                                return env.main_translator:query(query_str, seg_trans)
                            end)

                            if ok and translation then
                                for c in translation:iter() do
                                    local phrase_text = c.text
                                    if get_utf8_len(phrase_text) == 2 and not seen_text[phrase_text] then
                                        local char1 = get_utf8_char_at(phrase_text, 1)
                                        local char2 = get_utf8_char_at(phrase_text, 2)
                                        local cw = left_char_weight[char1]


					if cw then
    						seen_text[phrase_text] = true
    						local is_changed = (orig_phrase_text ~= phrase_text)
    						local phrase_bonus = route_phrase_bonus
    						table.insert(branches, {
                                                text = is_changed and replace_utf8_range(var.text, w_start, w_end, phrase_text) or var.text,
                                                corrected_count = var.corrected_count + (is_changed and 1 or 0),
                                                match_count = var.match_count + 1,
                                                -- 严格左到右：只消耗当前辅码和当前字位；不会从中间或末尾重定位。
                                                search_start_idx = w_start + 1,
                                                left_fuma_idx = var.left_fuma_idx + 1,
                                                score = (var.score or 0) + (c.quality or 0) + cw + phrase_bonus + (is_changed and 0 or 1000)
                                            })
                                            if #branches >= MAX_ROUTE_BRANCHES then break end
                                        end
                                    end
                                end
                            end
                        end

                        -- 兜底：如果 translator 没有合适二字词，也至少生成“以当前辅码字开头”的结果。
                        -- 这仍是严格左绑定，不会扫描其它位置。
                        if #branches == 0 then
                            for idx, item in ipairs(left_char_candidates) do
                                if idx > MAX_ROUTE_BRANCHES then break end
                                local new_text = replace_utf8_char_at(var.text, w_start, item.char)
                                if not seen_text[new_text] then
                                    seen_text[new_text] = true
                                    local is_changed = (item.char ~= orig_char1)
                                    table.insert(branches, {
                                        text = new_text,
                                        corrected_count = var.corrected_count + (is_changed and 1 or 0),
                                        match_count = var.match_count + 1,
                                        search_start_idx = w_start + 1,
                                        left_fuma_idx = var.left_fuma_idx + 1,
                                        score = (var.score or 0) + (item.weight or 0) + route_single_bonus + (is_changed and 0 or 1000)
                                    })
                                end
                            end
                        end

                        if #branches > 0 then return sort_and_cap_variants(branches, MAX_ROUTE_BRANCHES) end
                        return nil
                    end

                    -- 左到右流程不再定义/调用路线2；左侧路线1和路线1B失败后直接切换到右侧完整流程。

                    local function collect_right_variants()
                        local variants = {{
                            text = cand.text,
                            corrected_count = 0,
                            match_count = 0,
                            search_end_idx = cand_len,
                            right_fuma_idx = #fuma_chunks,
                            score = 0,
                            direction = 'right'
                        }}

                        while true do
                            local has_pending = false
                            for _, var in ipairs(variants) do
                                if var.right_fuma_idx > 0 then
                                    has_pending = true
                                    break
                                end
                            end
                            if not has_pending then break end

                            local next_variants = {}
                            for _, var in ipairs(variants) do
                                if var.right_fuma_idx <= 0 then
                                    table.insert(next_variants, var)
                                else
                                    local branches = nil
                                    if prefer_single_for_long then
                                        -- 三字及以上：单字精准修正优先，词组只兜底。
                                        branches = branch_route2(var)
                                        if not branches then branches = branch_route1b(var) end
                                        if not branches then branches = branch_route1(var) end
                                    else
                                        -- 二字/普通短词：词组重组优先，单字兜底。
                                        branches = branch_route1(var)
                                        if not branches then branches = branch_route1b(var) end
                                        if not branches then branches = branch_route2(var) end
                                    end

                                    if branches then
                                        for _, nv in ipairs(branches) do
                                            nv.direction = 'right'
                                            table.insert(next_variants, nv)
                                        end
                                    end
                                    -- 三条路线都失败：该分支丢弃，不进入 next_variants
                                end
                            end

                            if #next_variants == 0 then
                                variants = {}
                                break
                            end

                            variants = sort_and_cap_variants(next_variants, MAX_TOTAL_VARIANTS)
                        end

                        local final = {}
                        for _, var in ipairs(variants) do
                            if var.right_fuma_idx <= 0 and var.match_count == #fuma_chunks then
                                table.insert(final, var)
                            end
                        end
                        return final
                    end

                    local function collect_left_variants()
                        local variants = {{
                            text = cand.text,
                            corrected_count = 0,
                            match_count = 0,
                            search_start_idx = 1,
                            left_fuma_idx = 1,
                            score = 0,
                            direction = 'left'
                        }}

                        while true do
                            local has_pending = false
                            for _, var in ipairs(variants) do
                                if var.left_fuma_idx <= #fuma_chunks then
                                    has_pending = true
                                    break
                                end
                            end
                            if not has_pending then break end

                            local next_variants = {}
                            for _, var in ipairs(variants) do
                                if var.left_fuma_idx > #fuma_chunks then
                                    table.insert(next_variants, var)
                                else
                                    -- 左到右只允许走路线1 -> 路线1B。
                                    -- 一旦当前位置/当前窗口无法被这两条路线消耗，立即宣布左侧流程失败，交给右侧完整流程兜底。
                                    local branches = nil
                                    if prefer_single_for_long then
                                        -- 三字及以上：先尝试当前位置单字修正；失败才允许词组兜底。
                                        branches = branch_route1b_left(var)
                                        if not branches then branches = branch_route1_left(var) end
                                    else
                                        -- 二字：词组优先。
                                        branches = branch_route1_left(var)
                                        if not branches then branches = branch_route1b_left(var) end
                                    end

                                    if branches then
                                        for _, nv in ipairs(branches) do
                                            nv.direction = 'left'
                                            table.insert(next_variants, nv)
                                        end
                                    else
                                        return {}, true
                                    end
                                end
                            end

                            if #next_variants == 0 then
                                return {}, true
                            end

                            variants = sort_and_cap_variants(next_variants, MAX_TOTAL_VARIANTS)
                        end

                        local final = {}
                        for _, var in ipairs(variants) do
                            if var.left_fuma_idx > #fuma_chunks and var.match_count == #fuma_chunks then
                                table.insert(final, var)
                            end
                        end
                        return final, false
                    end

                    -- 【总调度】：本轮计算先严格左到右前缀匹配。
                    -- 左侧第 n 个辅码只匹配第 n 个字位；左侧失败时，本轮临时启动右侧优先兜底。
                    -- 不在 env 中保存“已切右侧”状态，所以用户回退/改字后会重新从左侧判断。
                    local final_variants, left_failed = collect_left_variants()

                    if left_failed or #final_variants == 0 then
                        final_variants = collect_right_variants()
                    end

                    -- 运算阶段保留多分支参与竞争；显示阶段按脚本顶部 LOOKUP_OUTPUT_TOP_N 输出前 N 个结果。
                    final_variants = sort_and_cap_variants(final_variants, MAX_TOTAL_VARIANTS)
                    if #final_variants > 0 then
                        local yielded_count = 0
                        local yielded_text = {}
                        for _, best_var in ipairs(final_variants) do
                            if best_var and best_var.text and not yielded_text[best_var.text] then
                                yielded_text[best_var.text] = true
                                local fixed_cand = Candidate(cand.type, cand.start, cand._end, best_var.text, cand.comment or "")
                                -- 保持综合分高的重组候选排在前面。
                                fixed_cand.quality = (cand.quality or 0) + ((best_var.score or 0) / 10000) - (yielded_count * 0.0001)
                                fixed_cand.preedit = cand.preedit
                                yield(fixed_cand)
                                yielded_count = yielded_count + 1
                                if yielded_count >= OUTPUT_TOP_N then break end
                            end
                        end
                        goto skip
                    else
                        goto skip
                    end
                end
            end
        end

        if cand.type == 'sentence' then goto skip end
        local cand_text = cand.text
        if not cand_len or cand_len == 0 then goto skip end
        local b = string.byte(cand_text, 1)
        if b and b < 128 then goto skip end

        local raw_data = {}
        if env.has_comment then
            local genuine = cand:get_genuine()
            local comment_text = genuine and genuine.comment or ""
            if comment_text ~= "" then
                local cache_key = cand_text .. "_" .. comment_text
                if not comment_cache[cache_key] then
                    comment_cache[cache_key] = parse_comment_codes(comment_text, env.comment_split_ptrn, cand_len, env.enable_tone, env.is_18jian) or false
                    env.cache_size = env.cache_size + 1
                end
                if comment_cache[cache_key] then
                    raw_data.aux = comment_cache[cache_key]
                    raw_data._comment_internal = comment_cache[cache_key]
                end
            end
        end

        if env.has_db then
            raw_data.db = {}
            local i = 0
            for _, code_point in utf8.codes(cand_text) do
                i = i + 1
                local char_str = utf8.char(code_point)
                if not db_cache[char_str] then
                    -- 注入 is_18jian 支持
                    local main_codes, xlit_codes = build_reverse_group(env.main_projection, env.xlit_projection, env.db_table, char_str, env.is_18jian)
                    db_cache[char_str] = { main = main_codes or {}, xlit = xlit_codes or {} }
                    env.cache_size = env.cache_size + 1 
                end
                if cand_len == 1 then
                    local combined = {}
                    for _, v in ipairs(db_cache[char_str].main) do table.insert(combined, v) end
                    for _, v in ipairs(db_cache[char_str].xlit) do table.insert(combined, v) end
                    raw_data.db[i] = (#combined > 0) and combined or nil
                else
                    local main_data = db_cache[char_str].main
                    raw_data.db[i] = (main_data and #main_data > 0) and main_data or nil
                end
            end
        end

        local borrowed_tones = {} 
        if raw_data._comment_internal then
            for k, codes in ipairs(raw_data._comment_internal) do
                borrowed_tones[k] = {}
                for _, c in ipairs(codes) do
                    if c:match("^%d+$") then borrowed_tones[k][c] = true end
                end
            end
        end

        local is_match_any = false
        for i, source_type in ipairs(env.data_sources) do
            local codes_seq = raw_data[source_type]
            if codes_seq then
                local tone_match_pass = true
                if apply_tone_filter then
                    if #tone_filter_seq > #codes_seq then
                        tone_match_pass = false
                    else
                        for k, tone_input in ipairs(tone_filter_seq) do
                            local has_tone = list_contains(codes_seq[k], tone_input)
                            if not has_tone and source_type == 'db' then
                                if borrowed_tones[k] and borrowed_tones[k][tone_input] then has_tone = true end
                            end
                            if not has_tone then
                                tone_match_pass = false
                                break
                            end
                        end
                    end
                end

                if tone_match_pass then
                    local is_match = false
                    if source_type == 'aux' then
                        if cand_len == 1 then
                            if group_match(codes_seq[1], clean_fuma) then is_match = true end
                        else
                            local memo = {}
                            if match_fuzzy_recursive(codes_seq, 1, clean_fuma, 1, memo, false) then is_match = true end
                        end
                    elseif source_type == 'db' then
                        if cand_len == 1 then
                             if group_match(codes_seq[1], clean_fuma) then is_match = true end
                        else
                             local memo = {}
                             if match_fuzzy_recursive(codes_seq, 1, clean_fuma, 1, memo, true) then is_match = true end
                        end
                    end
                    
                    if is_match then
                        is_match_any = true
                        break 
                    end
                end
            end
        end

        if is_match_any then
            has_any_match = true
            if if_single_char_first and cand_len > 1 then table.insert(long_word_cands, cand)
            else
                if not buckets[cand_len] then buckets[cand_len] = {} end
                table.insert(buckets[cand_len], cand)
                if cand_len > max_len then max_len = cand_len end
            end
        end
        ::skip::
    end

    if if_single_char_first then
        if buckets[1] then for _, c in ipairs(buckets[1]) do yield(c) end end
        for l = max_len, 2, -1 do
            if buckets[l] then for _, c in ipairs(buckets[l]) do yield(c) end end
        end
    else
        for l = max_len, 1, -1 do
            if buckets[l] then for _, c in ipairs(buckets[l]) do yield(c) end end
        end
    end
    
    for _, c in ipairs(long_word_cands) do yield(c) end

    -- 补充逻辑：最底部的万象影子词典，也同时支持18键探测展开
    if not has_any_match and apply_tone_filter and #clean_fuma > 0 and env.has_db and env.db_table then
        local fallback_fuma_list = env.is_18jian and expand_18jian_to_26jian(clean_fuma) or {clean_fuma}
        for _, db_obj in ipairs(env.db_table) do
            for _, f in ipairs(fallback_fuma_list) do
                local res_str = db_obj:lookup(f)
                if res_str and #res_str > 0 then
                    for word in res_str:gmatch("%S+") do
                        local cand = Candidate("wanxiang_shadow", s_end, #ctx_input, word, "")
                        cand.quality = 1 
                        yield(cand)
                    end
                end
            end
        end
    end
end

function f.tags_match(seg, env)
    for _, v in ipairs(env.tag) do if seg.tags[v] then return true end end
    return false
end

function f.fini(env)
    if env.update_conn then env.update_conn:disconnect() end
    if env.notifier then env.notifier:disconnect() end
    if env.mem then env.mem:disconnect() end
    env.db_table = nil
    env._global_db_cache = nil
    env._global_comment_cache = nil
    env.history_parts = nil
    collectgarbage('collect')
end

return f
