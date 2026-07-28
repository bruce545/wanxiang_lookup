--@amzxyz https://github.com/amzxyz/rime-wanxiang
--wanxiang_lookup: #设置归属于super_lookup.lua
--tags: [ abc ]  # 检索当前tag的候选
--key: "`"       # 输入中反查引导符
--lookup: [ wanxiang_reverse ] #反查滤镜数据库
--data_source: [ aux, db ] # 优先级：写在前面优先。即使只写db，只要开启enable_tone也能从注释获取声调。
--enable_tone: true  #启用声调反查
--enable_direct: true  #启用无引导的直接辅助码反查
--并键方案仅自动读取最终 speller/algebra；无需也不支持额外手动配置
--performance_cache: 内置查询级缓存，不改变二字/三字词保护与匹配顺序

local wanxiang = require("wanxiang/wanxiang")

-- 1. 基础工具函数 (UTF8处理 / 字符串 / 声调)
local function alt_lua_punc(s)
    if not s then
        return ""
    end
    return s:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
end


-- 通用并键支持（仅自动模式）
--
-- 用户方案通常通过下列方式引用万象代数预设：
--
-- patch:
--   speller/algebra:
--     __patch:
--       - wanxiang_algebra:/base/全拼
--       - wanxiang_algebra:/18jian
--
-- Rime 完成配置合并后，Lua 运行时读取到的 speller/algebra 已经是展开后的实际规则。
-- 本脚本只扫描这个最终规则列表，自动寻找覆盖完整字母键盘的压缩 xlit，例如：
--
--   xlit/qwertyuiopasdfghjklzxcvbnm/qwwrryuiipassffhjjlzxxvbbm
--
-- 若换成 /14jian 或其他并键预设，只要最终代数中包含同类完整键盘 xlit，
-- 就会自动生成“底层键 -> 并键”和“并键 -> 多个底层键”的双向映射。
-- 找不到并键规则时自动按普通 26 键运行。
--
-- 不再读取：
--   wanxiang_lookup/key_merge_source
--   wanxiang_lookup/key_merge_target
--   wanxiang_lookup/is_18jian
local KEY_MERGE_EXPAND_LIMIT = 512

local function count_distinct_ascii_letters(s)
    local seen = {}
    local count = 0
    if not s then
        return 0
    end
    for i = 1, #s do
        local c = s:sub(i, i):lower()
        if c:match("[a-z]") and not seen[c] then
            seen[c] = true
            count = count + 1
        end
    end
    return count
end

local function build_key_merge_maps(source, target)
    if not source or not target or source == "" or #source ~= #target then
        return nil, nil
    end

    local forward = {}
    local reverse = {}

    local function add_reverse(key, value)
        local list = reverse[key]
        if not list then
            list = {}
            reverse[key] = list
        end
        for _, old in ipairs(list) do
            if old == value then
                return
            end
        end
        list[#list + 1] = value
    end

    for i = 1, #source do
        local src = source:sub(i, i)
        local dst = target:sub(i, i)
        forward[src] = dst
        forward[src:upper()] = dst:upper()
        add_reverse(dst, src)
        add_reverse(dst:upper(), src:upper())
    end

    return forward, reverse
end

local function parse_xlit_mapping_rule(rule)
    if not rule then
        return nil, nil
    end

    -- 万象 algebra 中的并键规则通常没有结尾斜杠，例如：
    -- xlit/qwertyuiopasdfghjklzxcvbnm/qwwrryuiipassffhjjlzxxvbbm
    -- 同时兼容传统的 xlit/source/target/ 写法。
    local source, target = rule:match("^%s*xlit/([^/]*)/([^/]*)/?%s*$")
    if not source or not target or source == "" or #source ~= #target then
        return nil, nil
    end
    return source, target
end

local function is_likely_key_merge_mapping(source, target)
    if not source or not target or #source ~= #target then
        return false
    end
    if not source:match("^[A-Za-z]+$") or not target:match("^[A-Za-z]+$") then
        return false
    end

    local source_keys = count_distinct_ascii_letters(source)
    local target_keys = count_distinct_ascii_letters(target)

    -- 排除声调、声母等短 xlit。键盘并键规则应覆盖绝大多数英文字母，
    -- 且目标实际按键数必须少于源按键数。
    return source_keys >= 20 and target_keys < source_keys
end

local function apply_key_merge(s, forward_map)
    if not s or not forward_map then
        return s
    end
    return (s:gsub(".", function(c)
        return forward_map[c] or c
    end))
end

local function expand_key_merge_to_base(s, reverse_map, max_variants)
    if not s or s == "" then
        return { "" }
    end
    if not reverse_map then
        return { s }
    end

    local limit = max_variants or KEY_MERGE_EXPAND_LIMIT
    local results = { "" }

    for i = 1, #s do
        local char = s:sub(i, i)
        local choices = reverse_map[char] or { char }
        local next_results = {}
        local seen = {}

        for _, prefix in ipairs(results) do
            for _, base_char in ipairs(choices) do
                local value = prefix .. base_char
                if not seen[value] then
                    seen[value] = true
                    next_results[#next_results + 1] = value
                    if #next_results >= limit then
                        break
                    end
                end
            end
            if #next_results >= limit then
                break
            end
        end

        results = next_results
        if #results == 0 then
            return { s }
        end
    end

    return results
end

local function detect_key_merge_from_algebra(config)
    -- __patch 引用的 wanxiang_algebra:/18jian 等预设，在运行时已经展开到这里。
    local algebra = config:get_list("speller/algebra")
    if not algebra or algebra.size == 0 then
        return false, nil, nil, nil, nil, "disabled"
    end

    local best_source, best_target = nil, nil
    local best_source_keys = -1
    local best_reduction = -1
    local best_index = -1

    for i = 0, algebra.size - 1 do
        local value = algebra:get_value_at(i)
        local rule = value and value.value or nil
        local source, target = parse_xlit_mapping_rule(rule)

        if is_likely_key_merge_mapping(source, target) then
            local source_keys = count_distinct_ascii_letters(source)
            local target_keys = count_distinct_ascii_letters(target)
            local reduction = source_keys - target_keys

            -- 优先覆盖字母更多、压缩程度更大的规则；完全相同时采用列表中靠后的规则，
            -- 与 __patch 后追加特殊键盘布局的常见配置方式一致。
            if source_keys > best_source_keys
                or (source_keys == best_source_keys and reduction > best_reduction)
                or (source_keys == best_source_keys and reduction == best_reduction and i > best_index)
            then
                best_source = source
                best_target = target
                best_source_keys = source_keys
                best_reduction = reduction
                best_index = i
            end
        end
    end

    if not best_source or not best_target then
        return false, nil, nil, nil, nil, "disabled"
    end

    local forward, reverse = build_key_merge_maps(best_source, best_target)
    if not forward or not reverse then
        return false, nil, nil, nil, nil, "disabled"
    end

    return true, forward, reverse, best_source, best_target, "auto_algebra"
end

-- 匹配缓存参数。只缓存查询结果，不改变任何匹配范围、顺序或评分规则。
local SINGLE_PROBE_CACHE_MAX = 2048
local LOCAL_QUERY_CACHE_MAX = 512

local function clear_match_caches(env)
    env._fuma_variant_cache = {}
    env._single_probe_cache = {}
    env._single_probe_cache_count = 0
    env._local_query_cache = {}
    env._local_query_cache_count = 0
end

local function get_fuma_probe_variants(env, fuma)
    local cache = env._fuma_variant_cache
    if cache and cache[fuma] then
        return cache[fuma]
    end

    local variants
    if env.key_merge_enabled then
        variants = expand_key_merge_to_base(fuma, env.key_merge_reverse_map, KEY_MERGE_EXPAND_LIMIT)
    else
        variants = { fuma }
    end

    if cache then
        cache[fuma] = variants
    end
    return variants
end

local tones_map = {
    ["ā"] = "7",
    ["á"] = "8",
    ["ǎ"] = "9",
    ["à"] = "0",
    ["ō"] = "7",
    ["ó"] = "8",
    ["ǒ"] = "9",
    ["ò"] = "0",
    ["ē"] = "7",
    ["é"] = "8",
    ["ě"] = "9",
    ["è"] = "0",
    ["ī"] = "7",
    ["í"] = "8",
    ["ǐ"] = "9",
    ["ì"] = "0",
    ["ū"] = "7",
    ["ú"] = "8",
    ["ǔ"] = "9",
    ["ù"] = "0",
    ["ǖ"] = "7",
    ["ǘ"] = "8",
    ["ǚ"] = "9",
    ["ǜ"] = "0",
}

local function get_utf8_len(s)
    if utf8 and utf8.len then
        return utf8.len(s)
    end
    local _, count = string.gsub(s, "[^\128-\193]", "")
    return count
end

local function get_tone_from_pinyin(pinyin)
    if not pinyin or #pinyin == 0 then
        return nil
    end
    for char, tone in pairs(tones_map) do
        if string.find(pinyin, char, 1, true) then
            return tone
        end
    end
    return "0"
end

local function get_utf8_char_at(text, idx)
    local i = 1
    for _, code in utf8.codes(text) do
        if i == idx then
            return utf8.char(code)
        end
        i = i + 1
    end
    return ""
end

-- 提取一段 UTF8 字符片段
local function get_utf8_string_range(text, start_idx, end_idx)
    local chars = {}
    local i = 1
    for _, code in utf8.codes(text) do
        if i > end_idx then
            break
        end
        if i >= start_idx then
            chars[#chars + 1] = utf8.char(code)
        end
        i = i + 1
    end
    return table.concat(chars)
end

-- 将 UTF8 字符串转为字符数组
local function text_to_chars(text)
    if not text or text == "" then
        return {}
    end
    local chars = {}
    for _, cp in utf8.codes(text) do
        table.insert(chars, utf8.char(cp))
    end
    return chars
end

-- 将字符数组拼回字符串
local function chars_to_text(chars)
    return table.concat(chars)
end

-- 替换一段 UTF8 字符片段
local function replace_text_range(current_text, start_idx, end_idx, new_str)
    local out = {}
    local char_idx = 1
    for _, code_pt in utf8.codes(current_text) do
        if char_idx >= start_idx and char_idx <= end_idx then
            if char_idx == start_idx then
                table.insert(out, new_str)
            end
        else
            table.insert(out, utf8.char(code_pt))
        end
        char_idx = char_idx + 1
    end
    return table.concat(out)
end

local function list_contains(list, target)
    if not list then
        return false
    end
    for _, v in ipairs(list) do
        if v == target then
            return true
        end
    end
    return false
end

-- 2. 核心解析逻辑 (输入拆分 / 辅码提取 / 音节切分)
local function split_lookup_input(input, key, bypass_prefix)
    if not input or input == "" or not key or key == "" then
        return nil
    end

    local scan_from = 1
    if bypass_prefix and bypass_prefix ~= "" and input:sub(1, #bypass_prefix) == bypass_prefix then
        scan_from = #bypass_prefix + 1
    end

    local input_body = input:sub(scan_from)
    if input_body:sub(1, #key) == key and not key:match("^%w+$") then
        return nil
    end

    local s_start = nil
    local s_end = nil
    local from = scan_from

    while true do
        local s, e = input:find(key, from, true)
        if not s then
            break
        end
        s_start = s
        s_end = e
        from = s + 1
    end

    if not s_start then
        return nil
    end

    return input:sub(1, s_start - 1), input:sub(s_end + 1), s_start, s_end
end

-- 解析输入的辅码，仅将 7,8,9,0 视为声调，其余为常规辅码
local function parse_fuma_rules(fuma)
    local tone_filter_seq = {}
    local fuma_chunks = {}
    local clean_fuma = ""

    for i = 1, #fuma do
        local char = fuma:sub(i, i)
        if char == "7" or char == "8" or char == "9" or char == "0" then
            table.insert(tone_filter_seq, char)
        else
            clean_fuma = clean_fuma .. char
        end
    end

    for code, digit in fuma:gmatch("(%a%a?)(%d*)") do
        table.insert(fuma_chunks, string.upper(code) .. digit)
    end

    return clean_fuma, tone_filter_seq, fuma_chunks
end

local function parse_comment_part(part, enable_tone, key_merge_forward_map)
    local p1, p2 = part:find(";")
    local pinyin_part = p1 and part:sub(1, p1 - 1) or part
    local codes_part = p1 and part:sub(p2 + 1) or ""
    local codes_list = {}

    if #codes_part > 0 then
        for c in codes_part:gmatch("[^,]+") do
            local trimmed = c:gsub("^%s+", ""):gsub("%s+$", "")
            if key_merge_forward_map then
                trimmed = apply_key_merge(trimmed, key_merge_forward_map)
            end
            if #trimmed > 0 then
                codes_list[#codes_list + 1] = trimmed
            end
        end
    end

    if enable_tone then
        local tone = get_tone_from_pinyin(pinyin_part)
        if tone then
            codes_list[#codes_list + 1] = tone
        end
    end

    return codes_list
end

local function parse_comment_codes(comment, pattern, target_len, enable_tone, key_merge_forward_map)
    if not comment or comment == "" then
        return nil
    end

    if target_len == 1 then
        return { parse_comment_part(comment, enable_tone, key_merge_forward_map) }
    end

    local result = {}
    local count = 0
    for part in comment:gmatch(pattern) do
        count = count + 1
        result[count] = parse_comment_part(part, enable_tone, key_merge_forward_map)
    end

    if count ~= target_len then
        return nil
    end

    return result
end

local function get_script_text_parts(ctx, reverse_key)
    local parts = {}
    if not ctx or not ctx.composition or ctx.composition:empty() then
        return parts
    end

    local spans = ctx.composition:spans()
    if not spans then
        return parts
    end

    local count = type(spans.count) == "function" and spans:count() or spans.count
    if count == 0 then
        return parts
    end

    local vertices = type(spans.vertices) == "function" and spans:vertices() or spans.vertices
    if not vertices or #vertices < 2 then
        return parts
    end

    local raw_in = ctx.input or ""
    for i = 1, #vertices - 1 do
        local start_byte = vertices[i] + 1
        local end_byte = vertices[i + 1]
        local raw_syl = raw_in:sub(start_byte, end_byte)

        if raw_syl and raw_syl ~= "" then
            if reverse_key and reverse_key ~= "" then
                local split_pos = raw_syl:find(reverse_key, 1, true)
                if split_pos then
                    raw_syl = raw_syl:sub(1, split_pos - 1)
                end
            end
            raw_syl = raw_syl:gsub("['%s]", "")
            if raw_syl ~= "" then
                table.insert(parts, raw_syl)
            end
        end
    end

    return parts
end

-- 3. 数据库反查与展开算法 (Algebra/Projection)
local function parse_and_separate_rules(schema_id)
    if not schema_id or #schema_id == 0 then
        return nil, nil
    end

    local schema = Schema(schema_id)
    if not schema then
        return nil, nil
    end

    local algebra_list = schema.config and schema.config:get_list("speller/algebra")
    if not algebra_list or algebra_list.size == 0 then
        return nil, nil
    end

    local main_rules = {}
    local xlit_rules = {}

    for i = 0, algebra_list.size - 1 do
        local rule = algebra_list:get_value_at(i).value
        if rule and #rule > 0 then
            if rule:match("^xlit/HSPZN/") then
                table.insert(xlit_rules, rule)
            else
                table.insert(main_rules, rule)
            end
        end
    end

    local final_main = nil
    if #main_rules > 0 then
        final_main = main_rules
    end

    local final_xlit = nil
    if #xlit_rules > 0 then
        final_xlit = xlit_rules
    end

    return final_main, final_xlit
end

local function ensure_lookup_resources(env)
    if not env.has_db or env.db_table then
        return
    end

    env.db_table = {}
    for i = 1, #env.db_names do
        env.db_table[i] = ReverseLookup(env.db_names[i])
    end

    local main_rules, xlit_rules = parse_and_separate_rules(env.db_names[1])
    if main_rules then
        env.main_projection = Projection()
        env.main_projection:load(main_rules)
    end
    if xlit_rules then
        env.xlit_projection = Projection()
        env.xlit_projection:load(xlit_rules)
    end
end

local function add_unique(list, seen, value)
    if value and #value > 0 and not seen[value] then
        seen[value] = true
        list[#list + 1] = value
    end
end

local function extract_odd_positions(s)
    if not s or not s:match("^%l+$") or #s % 2 ~= 0 then
        return nil
    end

    local result = ""
    for i = 1, #s, 2 do
        result = result .. s:sub(i, i)
    end
    return result
end

local function get_v_variant(s)
    if not s or not s:match("^%l+$") or #s % 2 ~= 0 then
        return nil
    end

    local result = ""
    local has_change = false
    for i = 1, #s, 2 do
        local odd = s:sub(i, i)
        local even = s:sub(i + 1, i + 1)
        if (odd == "j" or odd == "q" or odd == "x" or odd == "y") and even == "v" then
            result = result .. odd .. "u"
            has_change = true
        else
            result = result .. odd .. even
        end
    end

    if has_change then
        return result
    end
    return nil
end

local function expand_code_variant(main_projection, xlit_projection, part, need_main, need_xlit)
    local out = need_main and {} or nil
    local seen = need_main and {} or nil
    local out_xlit = need_xlit and {} or nil
    local seen_xlit = need_xlit and {} or nil

    if need_main then
        local _, quote_count = part:gsub("'", "")
        if quote_count == 1 then
            local s1, s2 = part:match("^([^']*)'([^']*)$")
            if s1 and s2 and #s1 > 0 and #s2 > 0 then
                add_unique(out, seen, s1:sub(1, 1) .. s2:sub(1, 1))
            end
        end

        if part:match("^%l+$") then
            add_unique(out, seen, part)
        end

        add_unique(out, seen, extract_odd_positions(part))

        if main_projection and not part:match("^%u+$") then
            local projected = main_projection:apply(part, true)
            if projected and #projected > 0 then
                add_unique(out, seen, projected)
                add_unique(out, seen, get_v_variant(projected))
                add_unique(out, seen, extract_odd_positions(projected))
            end
        end
    end

    if need_xlit and part:match("^%u+$") and xlit_projection then
        local xlit_result = xlit_projection:apply(part, true)
        if xlit_result and #xlit_result > 0 then
            add_unique(out_xlit, seen_xlit, xlit_result)
        end
    end

    return out, out_xlit
end

local function build_reverse_group(main_projection, xlit_projection, db_table, text, need_main, need_xlit, key_merge_forward_map)
    local group_main = need_main and {} or nil
    local seen_main = need_main and {} or nil
    local group_xlit = need_xlit and {} or nil
    local seen_xlit = need_xlit and {} or nil

    for _, db in ipairs(db_table) do
        local code = db:lookup(text)
        if code and #code > 0 then
            for part in code:gmatch("%S+") do
                local main_variants, xlit_variants =
                    expand_code_variant(main_projection, xlit_projection, part, need_main, need_xlit)

                if need_main then
                    for _, value in ipairs(main_variants) do
                        if key_merge_forward_map then
                            value = apply_key_merge(value, key_merge_forward_map)
                        end
                        add_unique(group_main, seen_main, value)
                    end
                end

                if need_xlit then
                    for _, value in ipairs(xlit_variants) do
                        if key_merge_forward_map then
                            value = apply_key_merge(value, key_merge_forward_map)
                        end
                        add_unique(group_xlit, seen_xlit, value)
                    end
                end
            end
        end
    end

    return group_main, group_xlit
end

-- 4. 匹配判定引擎 (精准 / 模糊递归)
-- 将“拼音 + 辅码”的底层词典扫描结果缓存起来。
-- check_char_fuma_match 与 collect_best_single_char_match 共用同一份结果，
-- 避免任意并键展开后的多个 probe 在同一按键过程中被重复扫描。
local function get_single_char_probe_data(env, pinyin, fuma)
    local cache_key = pinyin .. "\31" .. fuma
    local cache = env._single_probe_cache
    if cache and cache[cache_key] then
        return cache[cache_key]
    end

    local candidate_weights = {}
    local valid_chars = {}
    local fuma_list = get_fuma_probe_variants(env, fuma)

    for _, expanded_fuma in ipairs(fuma_list) do
        local probe = pinyin .. expanded_fuma

        if env.mem:dict_lookup(probe, true, 200) then
            for entry in env.mem:iter_dict() do
                if get_utf8_len(entry.text) == 1 then
                    local char = entry.text
                    local weight = entry.weight or 0
                    valid_chars[char] = true
                    if candidate_weights[char] == nil or weight > candidate_weights[char] then
                        candidate_weights[char] = weight
                    end
                end
            end
        end

        if env.mem:user_lookup(probe, true) then
            for entry in env.mem:iter_user() do
                if get_utf8_len(entry.text) == 1 then
                    local char = entry.text
                    local weight = (entry.weight or 0) + 500
                    valid_chars[char] = true
                    if candidate_weights[char] == nil or weight > candidate_weights[char] then
                        candidate_weights[char] = weight
                    end
                end
            end
        end
    end

    local ranked = {}
    for char, weight in pairs(candidate_weights) do
        ranked[#ranked + 1] = { char = char, weight = weight }
    end
    table.sort(ranked, function(a, b)
        if a.weight == b.weight then
            return a.char < b.char
        end
        return a.weight > b.weight
    end)

    local data = {
        valid_chars = valid_chars,
        ranked = ranked,
    }

    if cache then
        if (env._single_probe_cache_count or 0) >= SINGLE_PROBE_CACHE_MAX then
            env._single_probe_cache = {}
            env._single_probe_cache_count = 0
            cache = env._single_probe_cache
        end
        cache[cache_key] = data
        env._single_probe_cache_count = (env._single_probe_cache_count or 0) + 1
    end

    return data
end

local function check_char_fuma_match(env, pinyin, fuma, target_char)
    local data = get_single_char_probe_data(env, pinyin, fuma)
    return data.valid_chars[target_char] == true
end

-- 收集一个拼音位置在当前辅码下最优的单字。
-- 18键模式会把并键辅码展开后合并结果，原字只要命中任一展开分支就优先保留。
local function collect_best_single_char_match(env, pinyin, fuma, orig_char)
    local data = get_single_char_probe_data(env, pinyin, fuma)
    local orig_valid = data.valid_chars[orig_char] == true
    local first_char = nil
    local second_char = nil

    -- 原实现会在原字有效时把原字排除在替换候选之外；这里保持完全相同的行为。
    for _, item in ipairs(data.ranked) do
        if item.char ~= orig_char then
            if not first_char then
                first_char = item.char
            elseif not second_char then
                second_char = item.char
                break
            end
        end
    end

    if orig_valid then
        return true, nil, first_char
    end

    return false, first_char, second_char
end

local function group_match(group, fuma)
    if not group then
        return false
    end
    for i = 1, #group do
        if string.sub(group[i], 1, #fuma) == fuma then
            return true
        end
    end
    return false
end

local function match_direct_word(codes_seq, idx, target, is_db)
    if not codes_seq[idx] then
        return false
    end
    for _, code in ipairs(codes_seq[idx]) do
        local skip = false
        if is_db and #code > 3 then
            skip = true
        end
        if code:match("^%d+$") then
            skip = true
        end

        if not skip then
            local i = 1
            local j = 1
            while i <= #target and j <= #code do
                if target:byte(i) == code:byte(j) then
                    i = i + 1
                end
                j = j + 1
            end
            if i > #target then
                return true
            end
        end
    end
    return false
end

local function match_fuzzy_recursive(codes_sequence, idx, input_str, input_idx, memo, is_phrase_mode)
    if input_idx > #input_str then
        return true
    end
    if idx > #codes_sequence then
        return false
    end

    local state_key = idx * 1000 + input_idx
    if memo[state_key] ~= nil then
        return memo[state_key]
    end

    local codes = codes_sequence[idx]
    local result = false

    if codes then
        for _, code in ipairs(codes) do
            local skip = false
            if is_phrase_mode and #code > 3 then
                skip = true
            end
            if code:match("^%d+$") then
                skip = true
            end

            if not skip then
                local i_curr = input_idx
                local c_curr = 1
                while i_curr <= #input_str and c_curr <= #code do
                    if input_str:byte(i_curr) == code:byte(c_curr) then
                        i_curr = i_curr + 1
                    end
                    c_curr = c_curr + 1
                end
                if match_fuzzy_recursive(codes_sequence, idx + 1, input_str, i_curr, memo, is_phrase_mode) then
                    result = true
                    break
                end
            end
        end
    else
        if match_fuzzy_recursive(codes_sequence, idx + 1, input_str, input_idx, memo, is_phrase_mode) then
            result = true
        end
    end

    memo[state_key] = result
    return result
end

-- 5. 候选项数据构建核心
local function ensure_db_cache_entry(env, char_str, need_xlit)
    local db_cache = env._db_cache
    local entry = db_cache[char_str]

    if not entry then
        local main_codes, xlit_codes =
            build_reverse_group(env.main_projection, env.xlit_projection, env.db_table, char_str, true, need_xlit, env.key_merge_forward_map)
        entry = {
            main = main_codes or {},
            xlit = need_xlit and (xlit_codes or {}) or nil,
            combined = nil,
        }
        db_cache[char_str] = entry
        env.cache_size = env.cache_size + 1
    elseif need_xlit and entry.xlit == nil then
        local _, xlit_codes =
            build_reverse_group(env.main_projection, env.xlit_projection, env.db_table, char_str, false, true, env.key_merge_forward_map)
        entry.xlit = xlit_codes or {}
    end

    if need_xlit and entry.combined == nil then
        local combined = {}
        local count = 0
        for _, value in ipairs(entry.main) do
            count = count + 1
            combined[count] = value
        end
        for _, value in ipairs(entry.xlit or {}) do
            count = count + 1
            combined[count] = value
        end
        entry.combined = combined
    end

    return entry
end

local function build_candidate_raw_data(cand, cand_len, env)
    local raw_data = {}
    local comment_cache = env._comment_cache
    local cand_text = cand.text

    if env.has_comment then
        local genuine = cand:get_genuine()
        local comment_text = ""
        if genuine and genuine.comment then
            comment_text = genuine.comment
        end

        if comment_text ~= "" then
            local cache_key = cand_text .. "_" .. comment_text
            local parsed_comment = comment_cache[cache_key]
            if parsed_comment == nil then
                parsed_comment = parse_comment_codes(comment_text, env.comment_split_ptrn, cand_len, env.enable_tone, env.key_merge_forward_map)
                    or false
                comment_cache[cache_key] = parsed_comment
                env.cache_size = env.cache_size + 1
            end
            if parsed_comment then
                raw_data.aux = parsed_comment
                raw_data._comment_internal = parsed_comment
            end
        end
    end

    if env.has_db then
        raw_data.db = {}
        local i = 0
        local need_xlit = cand_len == 1

        for _, code_point in utf8.codes(cand_text) do
            i = i + 1
            local char_str = utf8.char(code_point)
            local entry = ensure_db_cache_entry(env, char_str, need_xlit)
            local codes = need_xlit and entry.combined or entry.main

            if codes and #codes > 0 then
                raw_data.db[i] = codes
            else
                raw_data.db[i] = nil
            end
        end
    end

    return raw_data
end

-- 6. 引导模式核心逻辑 (声调翻译 / 词组及单字纠错回溯)
local function get_syl_offset(cand, ctx)
    local syl_offset = 0
    local spans = ctx.composition:spans()
    if not spans then
        return 0
    end

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

    return syl_offset
end

local function attempt_pure_tone_translation(cand, env, syllables, tone_filter_seq, current_syl_count, syl_offset)
    local tone_len = #tone_filter_seq
    if current_syl_count ~= tone_len or not env.main_translator then
        return nil
    end

    local pure_pinyin_parts = {}
    for k = 1, tone_len do
        local syl = syllables[k + syl_offset]
        if syl then
            if #syl > 2 then
                syl = string.sub(syl, 1, 2)
            end
            table.insert(pure_pinyin_parts, syl .. tone_filter_seq[k])
        end
    end

    if #pure_pinyin_parts == tone_len then
        local query_str = table.concat(pure_pinyin_parts, "")
        local seg_trans = Segment(0, #query_str)
        seg_trans.tags = Set({ "abc" })

        local ok, translation = pcall(function()
            return env.main_translator:query(query_str, seg_trans)
        end)

        if ok and translation then
            for c in translation:iter() do
                local custom_cand = Candidate(cand.type, cand.start, cand._end, c.text, c.comment)
                custom_cand.quality = c.quality
                custom_cand.preedit = cand.preedit
                return custom_cand
            end
        end
    end

    return nil
end

-- [词组纠错] 1. 尝试长词组整体匹配
-- 从左向右扫描窗口，使较早输入的辅码优先修改句子左侧位置。
local function try_match_long_phrase(current_text, cand_len, env, syllables, fuma_chunks, syl_offset)
    local fuma_len = #fuma_chunks
    if fuma_len <= 1 or fuma_len > cand_len or not env.main_translator then
        return nil
    end

    for w_start = 1, cand_len - fuma_len + 1 do
        local w_end = w_start + fuma_len - 1
        local pure_pinyin_parts = {}
        local valid_window = true

        for k = 1, fuma_len do
            local syl = syllables[w_start + k - 1 + syl_offset]
            if not syl then
                valid_window = false
                break
            end
            if #syl > 2 then
                syl = string.sub(syl, 1, 2)
            end
            table.insert(pure_pinyin_parts, syl)
        end

        if valid_window then
            local query_str = table.concat(pure_pinyin_parts, "")
            local seg_trans = Segment(0, #query_str)
            seg_trans.tags = Set({ "abc" })

            local translation = env.main_translator:query(query_str, seg_trans)
            local orig_phrase_text = get_utf8_string_range(current_text, w_start, w_end)
            local matched_texts = {}
            local seen = {}

            if translation then
                for c in translation:iter() do
                    local phrase_text = c.text
                    if get_utf8_len(phrase_text) == fuma_len and phrase_text ~= orig_phrase_text and not seen[phrase_text] then
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

                        if match_all then
                            seen[phrase_text] = true
                            matched_texts[#matched_texts + 1] = replace_text_range(current_text, w_start, w_end, phrase_text)
                            if #matched_texts >= 2 then
                                break
                            end
                        end
                    end
                end
            end

            if #matched_texts > 0 then
                return matched_texts[1], fuma_len, w_end + 1, matched_texts[2]
            end
        end
    end

    return nil
end

-- [词组纠错] 2. 尝试2字词双向辅助匹配
-- 从 search_start_idx 开始向右寻找第一个可修改的二字窗口。
local function try_match_two_char_phrase(current_text, search_start_idx, cand_len, env, syllables, fuma_chunk, syl_offset)
    if search_start_idx > cand_len - 1 or not env.main_translator then
        return nil
    end

    for w_start = search_start_idx, cand_len - 1 do
        local w_end = w_start + 1
        local pure_pinyin_parts = {}
        local valid_window = true

        for k = 0, 1 do
            local syl = syllables[w_start + k + syl_offset]
            if not syl then
                valid_window = false
                break
            end
            if #syl > 2 then
                syl = string.sub(syl, 1, 2)
            end
            table.insert(pure_pinyin_parts, syl)
        end

        if valid_window then
            local query_str = pure_pinyin_parts[1] .. pure_pinyin_parts[2]
            local seg_trans = Segment(0, #query_str)
            seg_trans.tags = Set({ "abc" })

            local ok, translation = pcall(function()
                return env.main_translator:query(query_str, seg_trans)
            end)

            if ok and translation then
                local orig_phrase_text = get_utf8_string_range(current_text, w_start, w_end)
                local matched_texts = {}
                local seen = {}

                for c in translation:iter() do
                    if get_utf8_len(c.text) == 2 and c.text ~= orig_phrase_text and not seen[c.text] then
                        local char1 = get_utf8_char_at(c.text, 1)
                        local char2 = get_utf8_char_at(c.text, 2)
                        local orig_char1 = get_utf8_char_at(orig_phrase_text, 1)
                        local orig_char2 = get_utf8_char_at(orig_phrase_text, 2)

                        local case_a = char2 == orig_char2
                            and check_char_fuma_match(env, pure_pinyin_parts[1], fuma_chunk, char1)
                        local case_b = char1 == orig_char1
                            and check_char_fuma_match(env, pure_pinyin_parts[2], fuma_chunk, char2)

                        if case_a or case_b then
                            seen[c.text] = true
                            matched_texts[#matched_texts + 1] = replace_text_range(current_text, w_start, w_end, c.text)
                            if #matched_texts >= 2 then
                                break
                            end
                        end
                    end
                end

                if #matched_texts > 0 then
                    return matched_texts[1], 1, w_end + 1, matched_texts[2]
                end
            end
        end
    end

    return nil
end

-- 局部词组保护参数。
-- 默认仍然选择最靠左的匹配；只有左侧替换明显破坏已有词组时，
-- 才允许上下文更合理的后方位置覆盖它。
local LOCAL_CONTEXT_WEIGHTS = {
    [2] = 4,
    [3] = 7,
}
local LOCAL_CONTEXT_STRONG_MARGIN = 7
local LOCAL_CONTEXT_QUERY_LIMIT = 200

local function build_local_pinyin_query(syllables, start_idx, end_idx, syl_offset)
    local parts = {}

    for i = start_idx, end_idx do
        local syl = syllables[i + syl_offset]
        if not syl then
            return nil
        end
        if #syl > 2 then
            syl = string.sub(syl, 1, 2)
        end
        parts[#parts + 1] = syl
    end

    return table.concat(parts)
end

local function build_local_phrase_text(chars, start_idx, end_idx, replace_pos, replace_char)
    local parts = {}

    for i = start_idx, end_idx do
        if i == replace_pos then
            parts[#parts + 1] = replace_char
        else
            parts[#parts + 1] = chars[i]
        end
    end

    return table.concat(parts)
end

-- 对同一个拼音窗口，主翻译器只查询一次，并缓存前 LOCAL_CONTEXT_QUERY_LIMIT 个词条。
-- 原逻辑对每个“原词/替换词”分别 query；现在改成一次 query 后做集合成员判断，
-- 但查询上限、候选顺序和存在性判定均保持不变。
local function get_local_query_text_set(env, query_str)
    local cache = env._local_query_cache
    if cache and cache[query_str] then
        return cache[query_str]
    end

    local text_set = {}
    if env.main_translator then
        local seg_trans = Segment(0, #query_str)
        seg_trans.tags = Set({ "abc" })

        local ok, translation = pcall(function()
            return env.main_translator:query(query_str, seg_trans)
        end)

        if ok and translation then
            local checked = 0
            for cand in translation:iter() do
                checked = checked + 1
                text_set[cand.text] = true
                if checked >= LOCAL_CONTEXT_QUERY_LIMIT then
                    break
                end
            end
        end
    end

    if cache then
        if (env._local_query_cache_count or 0) >= LOCAL_QUERY_CACHE_MAX then
            env._local_query_cache = {}
            env._local_query_cache_count = 0
            cache = env._local_query_cache
        end
        cache[query_str] = text_set
        env._local_query_cache_count = (env._local_query_cache_count or 0) + 1
    end

    return text_set
end

-- 查询某个二字或三字片段是否是主翻译器能够直接给出的词条。
-- cache 只保存“查询串 + 具体词条”的布尔结果；真正的翻译器结果按查询串复用。
local function local_phrase_exists(
    env,
    phrase_text,
    syllables,
    start_idx,
    end_idx,
    syl_offset,
    cache
)
    if not env.main_translator or not phrase_text or phrase_text == "" then
        return false
    end

    local query_str = build_local_pinyin_query(syllables, start_idx, end_idx, syl_offset)
    if not query_str or query_str == "" then
        return false
    end

    local cache_key = query_str .. "\31" .. phrase_text
    if cache[cache_key] ~= nil then
        return cache[cache_key]
    end

    local text_set = get_local_query_text_set(env, query_str)
    local found = text_set[phrase_text] == true

    cache[cache_key] = found
    return found
end

-- 计算替换某个字前后，周围二字词、三字词的词库支持变化。
-- 正数：替换后局部词组更完整；负数：替换破坏了已有词组。
local function get_local_context_delta(
    chars,
    pos,
    replacement_char,
    env,
    syllables,
    syl_offset,
    cache
)
    if not replacement_char or replacement_char == chars[pos] then
        return 0
    end

    local original_support = 0
    local replacement_support = 0
    local total_len = #chars

    for phrase_len = 2, 3 do
        local weight = LOCAL_CONTEXT_WEIGHTS[phrase_len] or 0
        local min_start = math.max(1, pos - phrase_len + 1)
        local max_start = math.min(pos, total_len - phrase_len + 1)

        for start_idx = min_start, max_start do
            local end_idx = start_idx + phrase_len - 1
            local original_text = build_local_phrase_text(chars, start_idx, end_idx, pos, chars[pos])
            local replacement_text = build_local_phrase_text(chars, start_idx, end_idx, pos, replacement_char)

            if local_phrase_exists(
                env,
                original_text,
                syllables,
                start_idx,
                end_idx,
                syl_offset,
                cache
            ) then
                original_support = original_support + weight
            end

            if replacement_text ~= original_text and local_phrase_exists(
                env,
                replacement_text,
                syllables,
                start_idx,
                end_idx,
                syl_offset,
                cache
            ) then
                replacement_support = replacement_support + weight
            end
        end
    end

    return replacement_support - original_support
end

-- 保持“从左到右”为默认规则，只做保守的上下文覆盖：
-- 1. 左侧候选会破坏词组，而后方候选不破坏词组；或
-- 2. 后方候选的局部词组得分至少高一个三字词权重。
local function should_override_leftmost_match(left_score, later_score)
    if left_score < 0 and later_score >= 0 then
        return true
    end

    return later_score - left_score >= LOCAL_CONTEXT_STRONG_MARGIN
end

-- [词组纠错] 3. 尝试单字逐个向右替换
-- 按输入顺序处理辅码；每个辅码选择当前范围内最靠左的可匹配位置。
-- 词频只用于决定同一位置采用哪个候选字，避免后面的高频字抢走辅码。
local function try_match_single_chars(
    current_text,
    search_start_idx,
    env,
    syllables,
    fuma_chunks,
    syl_offset,
    match_count
)
    local chars = text_to_chars(current_text)
    local current_start = math.max(search_start_idx or 1, 1)
    local m_count = match_count
    local changed = false
    local alternate_chars = nil
    local context_cache = {}

    -- 辅码按输入顺序从左向右处理。
    for c_idx = 1, #fuma_chunks do
        local chunk_fuma = fuma_chunks[c_idx]
        local leftmost_match = nil
        local best_context_match = nil

        -- 为尚未处理的辅码预留足够字符。
        -- 例如四字句输入四块辅码时，第 1 块只能落在第 1 个字，
        -- 防止局部词组评分把它跳到后面，导致最后一块无处匹配。
        local remaining_chunks = #fuma_chunks - c_idx
        local max_match_pos = #chars - remaining_chunks

        -- 仍然从左向右扫描，但不再遇到第一个候选就立刻结束。
        -- 先记录最靠左候选，再检查有效范围内是否存在明显更合理的词组位置。
        for i = current_start, max_match_pos do
            local orig_char = chars[i]
            local pinyin_code = syllables[i + syl_offset]

            if pinyin_code and orig_char then
                if #pinyin_code > 2 then
                    pinyin_code = string.sub(pinyin_code, 1, 2)
                end

                local is_orig_valid, local_best_cand, local_second_cand =
                    collect_best_single_char_match(env, pinyin_code, chunk_fuma, orig_char)

                local matched_char = nil
                if is_orig_valid then
                    matched_char = orig_char
                elseif local_best_cand then
                    matched_char = local_best_cand
                end

                if matched_char then
                    local context_score = get_local_context_delta(
                        chars,
                        i,
                        matched_char,
                        env,
                        syllables,
                        syl_offset,
                        context_cache
                    )

                    local current_match = {
                        pos = i,
                        char = matched_char,
                        alt_char = local_second_cand,
                        context_score = context_score,
                    }

                    if not leftmost_match then
                        leftmost_match = current_match
                        best_context_match = current_match
                    elseif context_score > best_context_match.context_score then
                        best_context_match = current_match
                    end
                end
            end
        end

        local selected_match = leftmost_match
        if
            leftmost_match
            and best_context_match
            and best_context_match.pos ~= leftmost_match.pos
            and should_override_leftmost_match(
                leftmost_match.context_score,
                best_context_match.context_score
            )
        then
            selected_match = best_context_match
        end

        if selected_match then
            m_count = m_count + 1

            -- 已经建立次优分支后，后续确定修改同步应用到次优分支。
            if alternate_chars then
                alternate_chars[selected_match.pos] = selected_match.char
            elseif selected_match.alt_char and selected_match.alt_char ~= selected_match.char then
                alternate_chars = {}
                for j = 1, #chars do
                    alternate_chars[j] = chars[j]
                end
                alternate_chars[selected_match.pos] = selected_match.alt_char
            end

            if selected_match.char ~= chars[selected_match.pos] then
                chars[selected_match.pos] = selected_match.char
                changed = true
            end

            -- 下一块辅码继续在最终选中位置的右侧搜索。
            current_start = selected_match.pos + 1
            -- 不清空 context_cache：键中已包含拼音串和具体词条，
            -- 前文变化会自然产生新键，旧结果仍可安全复用。
        end
    end

    local alternate_text = alternate_chars and chars_to_text(alternate_chars) or nil

    if changed then
        return chars_to_text(chars), m_count, current_start, alternate_text
    end

    return current_text, m_count, current_start, alternate_text
end

-- 将最后一个单字母辅码拆为“半码预览块”。
-- 例如 HH GV LK R -> 完整块 HH/GV/LK，预览块 R。
local function split_fuma_chunks_for_preview(fuma_chunks)
    local completed_chunks = {}

    for i, chunk in ipairs(fuma_chunks) do
        completed_chunks[i] = chunk
    end

    local preview_chunk = nil
    local last_chunk = completed_chunks[#completed_chunks]

    if last_chunk then
        local letters = last_chunk:gsub("%d", "")
        local digits = last_chunk:gsub("%a", "")

        -- 仅把没有声调数字的末尾单字母视为半码。
        if #letters == 1 and digits == "" then
            preview_chunk = last_chunk
            table.remove(completed_chunks)
        end
    end

    return completed_chunks, preview_chunk
end

-- 使用末尾半码生成一个临时候选。
-- 从 search_start_idx 向右选择最靠左的匹配位置；如果找不到，不影响完整辅码结果。
local function try_preview_half_chunk(
    current_text,
    search_start_idx,
    env,
    syllables,
    preview_chunk,
    syl_offset
)
    if not preview_chunk or preview_chunk == "" then
        return current_text, false, search_start_idx
    end

    local chars = text_to_chars(current_text)
    local first_pos = math.max(search_start_idx or 1, 1)
    local context_cache = {}
    local leftmost_match = nil
    local best_context_match = nil

    for i = first_pos, #chars do
        local orig_char = chars[i]
        local pinyin_code = syllables[i + syl_offset]

        if pinyin_code and orig_char then
            if #pinyin_code > 2 then
                pinyin_code = string.sub(pinyin_code, 1, 2)
            end

            -- 半码仍使用前缀查询；18键模式会展开当前半码的全部26键可能。
            local is_orig_valid, best_char, second_char =
                collect_best_single_char_match(env, pinyin_code, preview_chunk, orig_char)

            local matched_char = nil
            if is_orig_valid then
                matched_char = orig_char
            elseif best_char then
                matched_char = best_char
            end

            if matched_char then
                local context_score = get_local_context_delta(
                    chars,
                    i,
                    matched_char,
                    env,
                    syllables,
                    syl_offset,
                    context_cache
                )

                local current_match = {
                    pos = i,
                    char = matched_char,
                    alt_char = second_char,
                    context_score = context_score,
                }

                if not leftmost_match then
                    leftmost_match = current_match
                    best_context_match = current_match
                elseif context_score > best_context_match.context_score then
                    best_context_match = current_match
                end
            end
        end
    end

    local selected_match = leftmost_match
    if
        leftmost_match
        and best_context_match
        and best_context_match.pos ~= leftmost_match.pos
        and should_override_leftmost_match(
            leftmost_match.context_score,
            best_context_match.context_score
        )
    then
        selected_match = best_context_match
    end

    if selected_match then
        local alternate_text = nil
        if selected_match.alt_char and selected_match.alt_char ~= selected_match.char then
            local alt_chars = {}
            for j = 1, #chars do
                alt_chars[j] = chars[j]
            end
            alt_chars[selected_match.pos] = selected_match.alt_char
            alternate_text = chars_to_text(alt_chars)
        end

        if selected_match.char ~= chars[selected_match.pos] then
            chars[selected_match.pos] = selected_match.char
            return chars_to_text(chars), true, selected_match.pos + 1, alternate_text
        end

        return current_text, true, selected_match.pos + 1, alternate_text
    end

    return current_text, false, search_start_idx, nil
end

-- 组装引导模式的主词组/单字纠错逻辑
local function attempt_phrase_correction(cand, cand_len, env, syllables, fuma_chunks, syl_offset)
    if #fuma_chunks == 0 then
        return nil
    end

    local completed_chunks, preview_chunk = split_fuma_chunks_for_preview(fuma_chunks)
    local current_text = cand.text
    local alternate_text = nil
    local match_count = 0
    local search_start_idx = 1
    local preview_matched = false

    if #completed_chunks > 0 then
        local new_text, count, next_start, second_text =
            try_match_long_phrase(current_text, cand_len, env, syllables, completed_chunks, syl_offset)

        if new_text then
            current_text = new_text
            alternate_text = second_text
            match_count = count
            search_start_idx = next_start
        elseif #completed_chunks == 1 then
            new_text, count, next_start, second_text =
                try_match_two_char_phrase(
                    current_text,
                    search_start_idx,
                    cand_len,
                    env,
                    syllables,
                    completed_chunks[1],
                    syl_offset
                )

            if new_text then
                current_text = new_text
                alternate_text = second_text
                match_count = count
                search_start_idx = next_start
            end
        end

        if match_count == 0 then
            current_text, match_count, search_start_idx, alternate_text =
                try_match_single_chars(
                    current_text,
                    search_start_idx,
                    env,
                    syllables,
                    completed_chunks,
                    syl_offset,
                    match_count
                )
        end
    end

    if preview_chunk then
        local preview_start = search_start_idx
        local preview_alt = nil
        current_text, preview_matched, search_start_idx, preview_alt =
            try_preview_half_chunk(
                current_text,
                preview_start,
                env,
                syllables,
                preview_chunk,
                syl_offset
            )

        if alternate_text then
            local alt_preview_text = nil
            alt_preview_text = select(1, try_preview_half_chunk(
                alternate_text,
                preview_start,
                env,
                syllables,
                preview_chunk,
                syl_offset
            ))
            if alt_preview_text then
                alternate_text = alt_preview_text
            end
        elseif preview_alt then
            alternate_text = preview_alt
        end
    end

    if match_count ~= #completed_chunks then
        return nil
    end

    local comment = cand.comment or ""
    if preview_chunk and preview_matched then
        comment = comment .. "〔半码预览〕"
    end

    local function make_candidate(text, quality_offset)
        if not text or text == "" then
            return nil
        end
        if text == cand.text and quality_offset and quality_offset < 0 then
            return nil
        end

        local fixed_cand = Candidate(cand.type, cand.start, cand._end, text, comment)
        if cand.quality ~= nil then
            fixed_cand.quality = cand.quality + (quality_offset or 0)
        end
        fixed_cand.preedit = cand.preedit
        return fixed_cand
    end

    local primary = make_candidate(current_text, 0)
    local secondary = nil
    if alternate_text and alternate_text ~= current_text then
        secondary = make_candidate(alternate_text, -0.001)
    end

    return primary, secondary
end

-- 判断声调是否匹配通过；数据库声调不足时直接借用注释码，不再创建嵌套声调表。
local function check_explicit_tone_match(codes_seq, tone_filter_seq, comment_internal, source_type)
    if #tone_filter_seq > #codes_seq then
        return false
    end

    for k, tone_input in ipairs(tone_filter_seq) do
        local has_tone = list_contains(codes_seq[k], tone_input)
        if not has_tone and source_type == "db" and comment_internal then
            has_tone = list_contains(comment_internal[k], tone_input)
        end
        if not has_tone then
            return false
        end
    end
    return true
end

-- 综合匹配判断引擎 (引导模式使用)
local function check_explicit_match(raw_data, cand_len, clean_fuma, tone_filter_seq, apply_tone_filter, env)
    for _, source_type in ipairs(env.data_sources) do
        local codes_seq = raw_data[source_type]
        if codes_seq then
            local tone_match_pass = true
            if apply_tone_filter then
                tone_match_pass =
                    check_explicit_tone_match(codes_seq, tone_filter_seq, raw_data._comment_internal, source_type)
            end

            if tone_match_pass then
                if source_type == "aux" or source_type == "db" then
                    if cand_len == 1 then
                        if group_match(codes_seq[1], clean_fuma) then
                            return true
                        end
                    else
                        local memo = {}
                        if match_fuzzy_recursive(codes_seq, 1, clean_fuma, 1, memo, source_type == "db") then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- 7. 动态引擎逻辑判定提取 (动态模式使用)
local function check_direct_match(raw_data, cand_len, clean_fuma, data_sources)
    for _, source_type in ipairs(data_sources) do
        local codes_seq = raw_data[source_type]
        if codes_seq then
            if cand_len == 1 then
                if group_match(codes_seq[1], clean_fuma) then
                    return true
                end
            elseif cand_len == 2 then
                local is_db = false
                if source_type == "db" then
                    is_db = true
                end

                local fl = #clean_fuma
                if fl == 1 then
                    if
                        match_direct_word(codes_seq, 1, clean_fuma, is_db)
                        or match_direct_word(codes_seq, 2, clean_fuma, is_db)
                    then
                        return true
                    end
                elseif fl == 2 then
                    local case1 = match_direct_word(codes_seq, 1, clean_fuma, is_db)
                    local case2 = match_direct_word(codes_seq, 2, clean_fuma, is_db)
                    local case3 = false
                    if
                        match_direct_word(codes_seq, 1, clean_fuma:sub(1, 1), is_db)
                        and match_direct_word(codes_seq, 2, clean_fuma:sub(2, 2), is_db)
                    then
                        case3 = true
                    end

                    if case1 or case2 or case3 then
                        return true
                    end
                end
            else
                local memo = {}
                if match_fuzzy_recursive(codes_seq, 1, clean_fuma, 1, memo, source_type == "db") then
                    return true
                end
            end
        end
    end
    return false
end

local function create_direct_candidate(cand, ctx_input, pure_code, fuma)
    local ext_cand = Candidate(cand.type, cand.start, #ctx_input, cand.text, cand.comment)
    ext_cand.quality = cand.quality + 100
    local orig_preedit = cand.preedit

    if orig_preedit and orig_preedit ~= "" then
        ext_cand.preedit = orig_preedit:gsub("%s+$", "") .. " " .. fuma
    else
        ext_cand.preedit = pure_code .. " " .. fuma
    end

    return ext_cand
end

-- 8. 模式分发调度控制器 (主干函数)

-- A. 引导模式 (Explicit Mode) 控制器
local function handle_explicit_mode(input, env, ctx_input, pure_code, explicitly_fuma, s_end)
    ensure_lookup_resources(env)

    if not env.mem then
        env.mem = Memory(env.engine, env.engine.schema)
    end

    if not env.main_translator and Component and Component.Translator then
        pcall(function()
            env.main_translator = Component.Translator(env.engine, "translator", "script_translator")
        end)
    end

    local ctx = env.engine.context
    local clean_fuma, tone_filter_seq, fuma_chunks = parse_fuma_rules(explicitly_fuma)
    local apply_tone_filter = false
    if env.enable_tone and #tone_filter_seq > 0 then
        apply_tone_filter = true
    end

    local if_single_char_first = ctx:get_option("char_priority")
    local buckets = {}
    local long_word_cands = {}
    local max_len = 0
    local has_any_match = false
    local is_first_cand = true

    -- 获取输入音节片段；历史切分只读不改，直接复用原表。
    local syllables
    if pure_code == env.history_input and env.history_parts and #env.history_parts > 0 then
        syllables = env.history_parts
    else
        syllables = get_script_text_parts(ctx, env.reverse_key)
    end

    for cand in input:iter() do
        local cand_len = get_utf8_len(cand.text)

        -- 首个候选修正：纯声调翻译与多字纠错
        if is_first_cand then
            is_first_cand = false
            local syl_offset = get_syl_offset(cand, ctx)

            if apply_tone_filter and clean_fuma == "" then
                local current_syl_count = #syllables - syl_offset
                local tone_cand =
                    attempt_pure_tone_translation(cand, env, syllables, tone_filter_seq, current_syl_count, syl_offset)
                if tone_cand then
                    yield(tone_cand)
                    goto skip
                end
            end

            if
                ((cand.type == "sentence" and cand_len > 1) or (cand.type == "phrase" and cand_len > 3))
                and #syllables >= (cand_len + syl_offset)
            then
                local corr_cand, corr_cand2 =
                    attempt_phrase_correction(cand, cand_len, env, syllables, fuma_chunks, syl_offset)
                if corr_cand then
                    yield(corr_cand)
                    if corr_cand2 and corr_cand2.text ~= corr_cand.text then
                        yield(corr_cand2)
                    end
                    goto skip
                end
            end
        end

        -- 数据校验与匹配判定
        if cand.type == "sentence" or not cand_len or cand_len == 0 then
            goto skip
        end
        if string.byte(cand.text, 1) and string.byte(cand.text, 1) < 128 then
            goto skip
        end

        local raw_data = build_candidate_raw_data(cand, cand_len, env)

        if
            raw_data and check_explicit_match(raw_data, cand_len, clean_fuma, tone_filter_seq, apply_tone_filter, env)
        then
            has_any_match = true
            if if_single_char_first and cand_len > 1 then
                table.insert(long_word_cands, cand)
            else
                if not buckets[cand_len] then
                    buckets[cand_len] = {}
                end
                table.insert(buckets[cand_len], cand)
                if cand_len > max_len then
                    max_len = cand_len
                end
            end
        end

        ::skip::
    end

    -- 输出匹配结果 (依单字优先策略不同排序输出)
    if if_single_char_first then
        if buckets[1] then
            for _, c in ipairs(buckets[1]) do
                yield(c)
            end
        end
        for l = max_len, 2, -1 do
            if buckets[l] then
                for _, c in ipairs(buckets[l]) do
                    yield(c)
                end
            end
        end
    else
        for l = max_len, 1, -1 do
            if buckets[l] then
                for _, c in ipairs(buckets[l]) do
                    yield(c)
                end
            end
        end
    end

    for _, c in ipairs(long_word_cands) do
        yield(c)
    end

    -- 兜底：如果完全没有匹配且包含声调过滤，则生成影候选
    if not has_any_match and apply_tone_filter and #clean_fuma > 0 and env.has_db and env.db_table then
        local fallback_fuma_list = get_fuma_probe_variants(env, clean_fuma)
        for _, db_obj in ipairs(env.db_table) do
            for _, expanded_fuma in ipairs(fallback_fuma_list) do
                local res_str = db_obj:lookup(expanded_fuma)
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

-- B. 动态直辅模式 (direct Mode) 控制器
local function snapshot_direct_candidate(cand)
    return {
        type = cand.type,
        start = cand.start,
        _end = cand._end,
        text = cand.text,
        comment = cand.comment or "",
        quality = cand.quality,
        preedit = cand.preedit,
    }
end

local function restore_direct_candidate(saved)
    local cand = Candidate(saved.type, saved.start, saved._end, saved.text, saved.comment or "")
    if saved.quality ~= nil then
        cand.quality = saved.quality
    end
    if saved.preedit and saved.preedit ~= "" then
        cand.preedit = saved.preedit
    end
    return cand
end

local function handle_direct_mode(input, env, ctx_input)
    local direct_cache = env.direct_cache
    local base_input = direct_cache and direct_cache.input or ""
    local follows_base = base_input ~= ""
        and #ctx_input > #base_input
        and #ctx_input <= #base_input + 2
        and ctx_input:sub(1, #base_input) == base_input
    local extra_len = follows_base and (#ctx_input - #base_input) or 0

    local first_seen = false
    local mode = nil
    local cache_candidates = nil
    local cache_open = false

    local matched_cands = nil
    local matched_text_count = nil
    local clean_fuma = ""
    local fuma = ""
    local matches_yielded = false

    local function clear_direct_cache()
        env.direct_cache = nil
        direct_cache = nil
    end

    local function build_matches()
        ensure_lookup_resources(env)

        matched_cands = {}
        matched_text_count = {}
        fuma = ctx_input:sub(#base_input + 1):gsub("['%s]", "")
        clean_fuma = fuma:gsub("[7890]", "")

        if #clean_fuma ~= 1 and #clean_fuma ~= 2 then
            return
        end

        for _, saved in ipairs(direct_cache.candidates or {}) do
            local cached_cand = restore_direct_candidate(saved)
            local raw_data = build_candidate_raw_data(cached_cand, 2, env)
            if raw_data and check_direct_match(raw_data, 2, clean_fuma, env.data_sources) then
                local ext_cand = create_direct_candidate(cached_cand, ctx_input, base_input, fuma)
                matched_cands[#matched_cands + 1] = ext_cand
                matched_text_count[saved.text] = (matched_text_count[saved.text] or 0) + 1
            end
        end
    end

    local function should_skip_current(cand)
        if not matched_text_count then
            return false
        end
        local count = matched_text_count[cand.text]
        if count and count > 0 then
            matched_text_count[cand.text] = count - 1
            return true
        end
        return false
    end

    local function yield_matches()
        if matches_yielded or not matched_cands then
            return
        end
        for _, cand in ipairs(matched_cands) do
            yield(cand)
        end
        matches_yielded = true
    end

    for cand in input:iter() do
        local cand_len = get_utf8_len(cand.text)

        if not first_seen then
            first_seen = true

            -- 第一位辅码只有在当前首选由两字变成三字时才启动。
            if follows_base and extra_len == 1 and direct_cache and not direct_cache.active and cand_len == 3 then
                direct_cache.active = true
                mode = "lookup"
                build_matches()

            -- 已经启动后，允许继续输入第二位辅码；保持原双码功能。
            elseif follows_base and extra_len >= 1 and extra_len <= 2 and direct_cache and direct_cache.active then
                mode = "lookup"
                build_matches()

            -- 首选两字且完整吃码：建立下一轮直辅缓存。
            elseif cand_len == 2 and cand._end == #ctx_input then
                mode = "cache"
                cache_candidates = {}
                cache_open = true
                env.direct_cache = {
                    input = ctx_input,
                    candidates = cache_candidates,
                    active = false,
                }
            else
                mode = "passthrough"
                if direct_cache then
                    clear_direct_cache()
                end
            end
        end

        if mode == "cache" then
            if cache_open and cand_len == 2 then
                local first_byte = string.byte(cand.text, 1)
                if cand.type ~= "sentence" and (not first_byte or first_byte >= 128) and cand._end == #ctx_input then
                    cache_candidates[#cache_candidates + 1] = snapshot_direct_candidate(cand)
                end
            else
                cache_open = false
            end
            yield(cand)
        elseif mode == "lookup" and matched_cands and #matched_cands > 0 then
            if #clean_fuma == 1 then
                yield_matches()
                if not should_skip_current(cand) then
                    yield(cand)
                end
            else
                if not matches_yielded and cand_len >= 3 then
                    if not should_skip_current(cand) then
                        yield(cand)
                    end
                else
                    yield_matches()
                    if not should_skip_current(cand) then
                        yield(cand)
                    end
                end
            end
        else
            yield(cand)
        end
    end

    if mode == "cache" then
        if cache_candidates and #cache_candidates > 0 then
            env.direct_cache = {
                input = ctx_input,
                candidates = cache_candidates,
                active = false,
            }
        else
            env.direct_cache = nil
        end
    elseif mode == "lookup" and matched_cands and #matched_cands > 0 and #clean_fuma == 2 and not matches_yielded then
        yield_matches()
    end
end

-- 9. Rime 暴露接口 (Init / Func / Fini)
local f = {}

function f.init(env)
    local config = env.engine.schema.config

    -- 仅从 __patch 合并后的最终 speller/algebra 自动读取实际并键规则。
    local merge_enabled, forward_map, reverse_map, merge_source, merge_target, merge_mode =
        detect_key_merge_from_algebra(config)
    env.key_merge_enabled = merge_enabled
    env.key_merge_forward_map = forward_map
    env.key_merge_reverse_map = reverse_map
    env.key_merge_source = merge_source
    env.key_merge_target = merge_target
    env.key_merge_mode = merge_mode


    env.enable_tone = config:get_bool("wanxiang_lookup/enable_tone")
    if env.enable_tone == nil then
        env.enable_tone = true
    end

    env.enable_direct = config:get_bool("wanxiang_lookup/enable_direct")
    if env.enable_direct == nil then
        env.enable_direct = false
    end

    local sources_list = config:get_list("wanxiang_lookup/data_source")
    env.data_sources = {}
    local config_has_aux_source = false
    env.has_db = false

    if sources_list and sources_list.size > 0 then
        for i = 0, sources_list.size - 1 do
            local s = sources_list:get_value_at(i).value
            table.insert(env.data_sources, s)
            if s == "aux" then
                config_has_aux_source = true
            end
            if s == "db" then
                env.has_db = true
            end
        end
    else
        env.data_sources = { "aux", "db" }
        config_has_aux_source = true
        env.has_db = true
    end

    env.has_comment = false
    if config_has_aux_source or env.enable_tone then
        env.has_comment = true
    end

    env.db_names = {}
    env.db_table = nil
    env.main_projection = nil
    env.xlit_projection = nil

    if env.has_db then
        local db_list = config:get_list("wanxiang_lookup/lookup")
        if db_list and db_list.size > 0 then
            for i = 0, db_list.size - 1 do
                env.db_names[#env.db_names + 1] = db_list:get_value_at(i).value
            end
        else
            env.has_db = false
        end
    end

    if env.has_comment then
        local delimiter = config:get_string("speller/delimiter") or " '"
        if delimiter == "" then
            delimiter = " "
        end
        env.comment_split_ptrn = "[^" .. alt_lua_punc(delimiter) .. "]+"
    end

    env.reverse_key = config:get_string("wanxiang_lookup/key") or "`"
    env.reverse_key_alt = alt_lua_punc(env.reverse_key)
    env.bypass_prefix = config:get_string("add_user_dict/prefix")

    local tag = config:get_list("wanxiang_lookup/tags")
    if tag and tag.size > 0 then
        env.tag = {}
        for i = 0, tag.size - 1 do
            table.insert(env.tag, tag:get_value_at(i).value)
        end
    else
        env.tag = { "abc" }
    end

    env.notifier = env.engine.context.select_notifier:connect(function(ctx)
        local input = ctx.input
        local code, fuma = split_lookup_input(input, env.reverse_key, env.bypass_prefix)
        if not code or #code == 0 then
            return
        end

        local preedit = ctx:get_preedit()
        local no_search_string = code

        local preedit_text = ""
        if preedit and preedit.text then
            preedit_text = preedit.text
        end

        local edit = select(1, split_lookup_input(preedit_text, env.reverse_key, env.bypass_prefix))
        if edit and edit:match("[%w/]") then
            ctx.input = no_search_string .. env.reverse_key
        else
            ctx.input = no_search_string
            ctx:commit()
            clear_match_caches(env)
        end
    end)

    env._db_cache = {}
    env._comment_cache = {}
    env.cache_size = 0
    env.direct_cache = nil
    clear_match_caches(env)
    -- 双轨缓存系统
    env.history_parts = {}
    env.history_input = ""
    -- 专为引导模式(Explicit)的监听器，用于在敲击反查引导符前，保留完美的拼音切分案底
    env.update_conn = env.engine.context.update_notifier:connect(function(ctx)
        if not ctx:is_composing() then
            env.history_parts = {}
            env.history_input = ""
            env.direct_cache = nil
            clear_match_caches(env)
            return
        end
        local raw_in = ctx.input or ""
        if raw_in == "" then
            return
        end

        if env.reverse_key and raw_in:find(env.reverse_key, 1, true) then
            return
        end

        local parts = get_script_text_parts(ctx, env.reverse_key)
        if parts and #parts > 0 then
            env.history_parts = parts
            env.history_input = raw_in
        end
    end)
end

function f.tags_match(seg, env)
    for _, v in ipairs(env.tag) do
        if seg.tags[v] then
            return true
        end
    end
    return false
end

function f.func(input, env)
    local context = env.engine.context
    local seg = context.composition:back()

    if not seg or not f.tags_match(seg, env) or #env.data_sources == 0 then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    if env.cache_size > 2000 then
        env._db_cache = {}
        env._comment_cache = {}
        env.cache_size = 0
    end

    local ctx_input = context.input
    local pure_code, explicitly_fuma, s_start, s_end = split_lookup_input(ctx_input, env.reverse_key, env.bypass_prefix)

    if s_start then
        if not explicitly_fuma or #explicitly_fuma == 0 then
            -- 只输入反查引导符时原样透传，不创建整候选 raw_data 预热表。
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        return handle_explicit_mode(input, env, ctx_input, pure_code, explicitly_fuma, s_end)
    else
        if not env.enable_direct or wanxiang.is_pro_scheme(env) then
            env.direct_cache = nil
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        return handle_direct_mode(input, env, ctx_input)
    end
end

function f.fini(env)
    if env.update_conn then
        env.update_conn:disconnect()
    end
    if env.notifier then
        env.notifier:disconnect()
    end
    if env.mem then
        env.mem:disconnect()
    end

    env.db_names = nil
    env.db_table = nil
    env.main_projection = nil
    env.xlit_projection = nil
    env._db_cache = nil
    env._comment_cache = nil
    env._fuma_variant_cache = nil
    env._single_probe_cache = nil
    env._local_query_cache = nil
    env.history_parts = nil
    env.direct_cache = nil

    collectgarbage("collect")
end
return f
