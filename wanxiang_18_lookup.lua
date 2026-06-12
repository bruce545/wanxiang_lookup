--@amzxyz https://github.com/amzxyz/rime_wanxiang
--wanxiang_lookup: #设置归属于super_lookup.lua
  --tags: [ abc ]  # 检索当前tag的候选
  --key: "`"       # 输入中反查引导符
  --lookup: [ wanxiang_reverse ] #反查滤镜数据库
  --data_source: [ aux, db ] # 优先级：写在前面优先。即使只写db，只要开启enable_tone也能从注释获取声调。
  --enable_tone: true  #启用声调反查
  --is_18jian: true # 可选，手动开启 18 键映射支持（如果不填，脚本也会自动从 speller/algebra 中检测 xlit 规则）

local wanxiang = require("wanxiang/wanxiang")
local function alt_lua_punc(s)
    return s and s:gsub('([%.%+%-%*%?%[%]%^%$%(%)%%])', '%%%1') or ''
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
    local fuma_list = env.is_18jian and expand_18jian_to_26jian(fuma) or {fuma}
    for _, f in ipairs(fuma_list) do
        local probe = pinyin .. f
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
        table.insert(fuma_chunks, string.upper(code) .. digit)
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
        
        -- 【全新重写】：重码展开与分支生成
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
            if ((cand.type == 'sentence' and cand_len > 1) or (cand.type == 'phrase' and cand_len > 3)) and #syllables >= (cand_len + syl_offset) then
                if #fuma_chunks > 0 then
                    local fuma_len = #fuma_chunks
                    local phrase_matched = false
                    -- 记录多条生成路径，起始只有原始词
                    local variants = { { text = cand.text, corrected_count = 0, search_end_idx = cand_len, match_count = 0 } }

                    -- 【路线1：词组快车道】调用 Translator 查出原生词组，进行逐字辅码质检
                    if fuma_len > 1 and fuma_len <= cand_len and env.main_translator then
                        for w_start = cand_len - fuma_len + 1, 1, -1 do
                            local w_end = w_start + fuma_len - 1
                            local pure_pinyin_parts = {}
                            local valid_window = true
                            
                            for k = 1, fuma_len do
                                local syl = syllables[w_start + k - 1 + syl_offset]
                                if not syl then valid_window = false break end
                                if #syl > 2 then syl = string.sub(syl, 1, 2) end
                                table.insert(pure_pinyin_parts, syl)
                            end
                            
                            if valid_window then
                                local query_str = table.concat(pure_pinyin_parts, "")
                                local best_phrases = {}
                                
                                local seg_trans = Segment(0, #query_str)
                                seg_trans.tags = Set({"abc"})
                                local translation = env.main_translator:query(query_str, seg_trans)
                                
                                if translation then
                                    for c in translation:iter() do
                                        local phrase_text = c.text
                                        if get_utf8_len(phrase_text) == fuma_len then
                                            local match_all = true
                                            local char_idx = 1
                                            for _, code_pt in utf8.codes(phrase_text) do
                                                local char = utf8.char(code_pt)
                                                if not check_char_fuma_match(env, pure_pinyin_parts[char_idx], fuma_chunks[char_idx], char) then
                                                    match_all = false
                                                    break
                                                end
                                                char_idx = char_idx + 1
                                            end
                                            -- 汇聚所有符合条件的重码词组
                                            if match_all then
                                                table.insert(best_phrases, phrase_text)
                                                if #best_phrases >= 8 then break end -- 防止过度展开
                                            end
                                        end
                                    end
                                end
                                
                                if #best_phrases > 0 then
                                    local new_variants = {}
                                    for _, phrase in ipairs(best_phrases) do
                                        local out = {}
                                        local char_idx = 1
                                        for _, code_pt in utf8.codes(cand.text) do
                                            if char_idx >= w_start and char_idx <= w_end then
                                                if char_idx == w_start then table.insert(out, phrase) end
                                            else
                                                table.insert(out, utf8.char(code_pt))
                                            end
                                            char_idx = char_idx + 1
                                        end
                                        
                                        local orig_phrase = ""
                                        for k = w_start, w_end do orig_phrase = orig_phrase .. get_utf8_char_at(cand.text, k) end
                                        local is_changed = (orig_phrase ~= phrase)
                                        
                                        table.insert(new_variants, {
                                            text = table.concat(out),
                                            corrected_count = is_changed and 1 or 0,
                                            search_end_idx = w_start - 1,
                                            match_count = fuma_len
                                        })
                                    end
                                    variants = new_variants
                                    phrase_matched = true
                                    break
                                end
                            end
                        end
                    end

                    -- 【路线1.B：单辅码推导词组】解决“天上星星”改“天上行星”等多选逻辑
                    if not phrase_matched and fuma_len == 1 and cand_len >= 2 and env.main_translator then
                        for w_start = cand_len - 1, 1, -1 do
                            local w_end = w_start + 1
                            local pure_pinyin_parts = {}
                            local valid_window = true
                            
                            for k = 0, 1 do
                                local syl = syllables[w_start + k + syl_offset]
                                if not syl then valid_window = false break end
                                if #syl > 2 then syl = string.sub(syl, 1, 2) end
                                table.insert(pure_pinyin_parts, syl)
                            end
                            
                            if valid_window then
                                local query_str = pure_pinyin_parts[1] .. pure_pinyin_parts[2]
                                local seg_trans = Segment(0, #query_str)
                                seg_trans.tags = Set({"abc"})
                                
                                local ok, translation = pcall(function() return env.main_translator:query(query_str, seg_trans) end)
                                local best_phrases = {}
                                
                                if ok and translation then
                                    local orig_char1 = get_utf8_char_at(cand.text, w_start)
                                    local orig_char2 = get_utf8_char_at(cand.text, w_end)
                                    local fuma = fuma_chunks[1]
                                    for c in translation:iter() do
                                        if get_utf8_len(c.text) == 2 then
                                            local char1 = get_utf8_char_at(c.text, 1)
                                            local char2 = get_utf8_char_at(c.text, 2)
                                            
                                            local case_a = (char2 == orig_char2) and check_char_fuma_match(env, pure_pinyin_parts[1], fuma, char1)
                                            local case_b = (char1 == orig_char1) and check_char_fuma_match(env, pure_pinyin_parts[2], fuma, char2)
                                            
                                            if case_a or case_b then
                                                table.insert(best_phrases, c.text)
                                                if #best_phrases >= 8 then break end
                                            end
                                        end
                                    end
                                end
                                
                                if #best_phrases > 0 then
                                    local new_variants = {}
                                    for _, phrase in ipairs(best_phrases) do
                                        local out = {}
                                        local char_idx = 1
                                        for _, code_pt in utf8.codes(cand.text) do
                                            if char_idx >= w_start and char_idx <= w_end then
                                                if char_idx == w_start then table.insert(out, phrase) end
                                            else
                                                table.insert(out, utf8.char(code_pt))
                                            end
                                            char_idx = char_idx + 1
                                        end
                                        
                                        local orig_phrase = get_utf8_char_at(cand.text, w_start) .. get_utf8_char_at(cand.text, w_end)
                                        local is_changed = (orig_phrase ~= phrase)
                                        
                                        table.insert(new_variants, {
                                            text = table.concat(out),
                                            corrected_count = is_changed and 1 or 0,
                                            search_end_idx = w_start - 1,
                                            match_count = 1
                                        })
                                    end
                                    variants = new_variants
                                    phrase_matched = true
                                    break
                                end
                            end
                        end
                    end

                    -- 【路线2：单字精准兜底，支持多候选分支】
                    if not phrase_matched then
                        for c_idx = #fuma_chunks, 1, -1 do
                            local chunk_fuma = fuma_chunks[c_idx]
                            local fuma_list = env.is_18jian and expand_18jian_to_26jian(chunk_fuma) or {chunk_fuma}
                            local next_variants = {}
                            
                            for _, var in ipairs(variants) do
                                local best_pos = nil
                                local candidate_chars_at_pos = nil
                                
                                for i = var.search_end_idx, 1, -1 do
                                    local orig_char = get_utf8_char_at(var.text, i)
                                    local pinyin_code = syllables[i + syl_offset]
                                    
                                    if not pinyin_code then goto next_i end
                                    if #pinyin_code > 2 then pinyin_code = string.sub(pinyin_code, 1, 2) end
                                    
                                    local valid_chars = {}
                                    local seen_chars = {}

                                    for _, f in ipairs(fuma_list) do
                                        local probe_code = pinyin_code .. f

                                        if env.mem:dict_lookup(probe_code, true, 200) then
                                            for entry in env.mem:iter_dict() do
                                                if get_utf8_len(entry.text) == 1 then
                                                    if not seen_chars[entry.text] then
                                                        seen_chars[entry.text] = true
                                                        table.insert(valid_chars, {char = entry.text, weight = entry.weight or 0})
                                                    end
                                                end
                                            end
                                        end
                                        
                                        if env.mem:user_lookup(probe_code, true) then
                                            for entry in env.mem:iter_user() do
                                                if get_utf8_len(entry.text) == 1 then
                                                    if not seen_chars[entry.text] then
                                                        seen_chars[entry.text] = true
                                                        table.insert(valid_chars, {char = entry.text, weight = (entry.weight or 0) + 500})
                                                    end
                                                end
                                            end
                                        end
                                    end

                                    -- 一旦在该位置找到符合辅码的汉字库，直接打断搜索，创建分支候选
                                    if #valid_chars > 0 then
                                        table.sort(valid_chars, function(a, b) return a.weight > b.weight end)
                                        candidate_chars_at_pos = valid_chars
                                        best_pos = i
                                        break
                                    end
                                    ::next_i::
                                end

                                if best_pos and candidate_chars_at_pos then
                                    for idx, vc in ipairs(candidate_chars_at_pos) do
                                        if idx > 8 then break end -- 防止过度分支导致卡顿
                                        local new_text = replace_utf8_char_at(var.text, best_pos, vc.char)
                                        local is_changed = (vc.char ~= get_utf8_char_at(var.text, best_pos))
                                        table.insert(next_variants, {
                                            text = new_text,
                                            corrected_count = var.corrected_count + (is_changed and 1 or 0),
                                            search_end_idx = best_pos - 1,
                                            match_count = var.match_count + 1
                                        })
                                    end
                                else
                                    table.insert(next_variants, var) -- 如果本轮没有任何字匹配，传递原候选不增加 match_count
                                end
                            end
                            
                            if #next_variants > 16 then
                                local capped = {}
                                for v=1,16 do table.insert(capped, next_variants[v]) end
                                variants = capped
                            else
                                variants = next_variants
                            end
                        end
                    end

                    -- 最终结算上屏：把成功匹配辅码的所有组合选项都抛出
                    local yielded_any = false
                    local seen_texts = {}
                    for _, var in ipairs(variants) do
                        if var.match_count == #fuma_chunks then
                            if not seen_texts[var.text] then
                                seen_texts[var.text] = true
                                -- 只要被修正过，或是恰巧和原始词相同（代表用户正好打出了该词的正确辅码），就作为结果弹出
                                if var.corrected_count > 0 or var.text == cand.text then
                                    local fixed_cand = Candidate(cand.type, cand.start, cand._end, var.text, cand.comment or "")
                                    fixed_cand.quality = cand.quality
                                    fixed_cand.preedit = cand.preedit
                                    yield(fixed_cand)
                                    yielded_any = true
                                end
                            end
                        end
                    end
                    
                    if not yielded_any then
                        yield(cand)
                    end
                    goto skip
                else
                    yield(cand)
                    goto skip
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
