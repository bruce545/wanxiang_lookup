
local wanxiang = require("wanxiang/wanxiang")

local function alt_lua_punc(s)
    if not s then
        return ""
    end
    return s:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
end

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

local function chars_to_text(chars)
    return table.concat(chars)
end

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
        candidate_weights = candidate_weights,
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

local function collect_best_single_char_match(env, pinyin, fuma, orig_char)
    local data = get_single_char_probe_data(env, pinyin, fuma)
    local orig_valid = data.valid_chars[orig_char] == true
    local orig_weight = (data.candidate_weights and data.candidate_weights[orig_char]) or -math.huge
    local first_char = nil
    local second_char = nil
    local first_weight = -math.huge
    local second_weight = -math.huge

    for _, item in ipairs(data.ranked) do
        if item.char ~= orig_char then
            if not first_char then
                first_char = item.char
                first_weight = item.weight or -math.huge
            elseif not second_char then
                second_char = item.char
                second_weight = item.weight or -math.huge
                break
            end
        end
    end

    return orig_valid, first_char, second_char,
        first_weight, second_weight, orig_weight
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

local function find_leftmost_direct_match_pos(
    current_text,
    cand_len,
    env,
    syllables,
    fuma_chunk,
    syl_offset,
    search_start_idx,
    max_pos
)
    local chars = text_to_chars(current_text)
    local first_pos = math.max(search_start_idx or 1, 1)
    local last_pos = math.min(max_pos or cand_len, cand_len)

    for i = first_pos, last_pos do
        local orig_char = chars[i]
        local pinyin_code = syllables[i + syl_offset]

        if pinyin_code and orig_char then
            if #pinyin_code > 2 then
                pinyin_code = string.sub(pinyin_code, 1, 2)
            end

            local is_orig_valid, best_char =
                collect_best_single_char_match(env, pinyin_code, fuma_chunk, orig_char)

            if is_orig_valid or best_char then
                return i
            end
        end
    end

    return nil
end

local function is_active_chunk_spec(active_spec, chunk_idx)
    if type(active_spec) == "table" then
        return active_spec[chunk_idx] == true
    end
    return active_spec and active_spec > 0 and chunk_idx == active_spec
end

local function try_match_long_phrase(
    current_text,
    cand_len,
    env,
    syllables,
    fuma_chunks,
    syl_offset,
    active_chunk_index,
    search_start_idx
)
    local fuma_len = #fuma_chunks
    if fuma_len <= 1 or fuma_len > cand_len or not env.main_translator then
        return nil
    end

    local max_start = cand_len - fuma_len + 1
    local first_start = math.max(search_start_idx or 1, 1)
    if first_start > max_start then
        return nil
    end

    local anchor_start = find_leftmost_direct_match_pos(
        current_text,
        cand_len,
        env,
        syllables,
        fuma_chunks[1],
        syl_offset,
        first_start,
        max_start
    )

    if not anchor_start then
        return nil
    end

    for w_start = anchor_start, anchor_start do
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
                            local orig_char = get_utf8_char_at(orig_phrase_text, char_idx)
                            local char_matches = check_char_fuma_match(
                                env,
                                pure_pinyin_parts[char_idx],
                                fuma_chunks[char_idx],
                                char
                            )

                            if not char_matches then
                                match_all = false
                                break
                            end

                            local is_active_chunk = is_active_chunk_spec(active_chunk_index, char_idx)
                            if not is_active_chunk and orig_char and orig_char ~= "" then
                                local orig_matches = check_char_fuma_match(
                                    env,
                                    pure_pinyin_parts[char_idx],
                                    fuma_chunks[char_idx],
                                    orig_char
                                )
                                if orig_matches and char ~= orig_char then
                                    match_all = false
                                    break
                                end
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
                local positions = {}
                for pos = w_start, w_end do
                    positions[#positions + 1] = pos
                end
                return matched_texts[1], fuma_len, w_end + 1, matched_texts[2], positions
            end
        end
    end

    return nil
end

local function try_match_two_char_phrase(current_text, search_start_idx, cand_len, env, syllables, fuma_chunk, syl_offset)
    if search_start_idx > cand_len or not env.main_translator then
        return nil
    end

    local anchor_pos = find_leftmost_direct_match_pos(
        current_text,
        cand_len,
        env,
        syllables,
        fuma_chunk,
        syl_offset,
        search_start_idx,
        cand_len
    )

    if not anchor_pos then
        return nil
    end

    local window_starts = {}
    local seen_starts = {}

    local function add_window_start(pos)
        if pos >= search_start_idx and pos >= 1 and pos <= cand_len - 1 and not seen_starts[pos] then
            seen_starts[pos] = true
            window_starts[#window_starts + 1] = pos
        end
    end

    add_window_start(anchor_pos - 1)
    add_window_start(anchor_pos)

    for _, w_start in ipairs(window_starts) do
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

                        local changes_anchor = false

                        if anchor_pos == w_start then
                            changes_anchor = char2 == orig_char2
                                and check_char_fuma_match(env, pure_pinyin_parts[1], fuma_chunk, char1)
                        elseif anchor_pos == w_end then
                            changes_anchor = char1 == orig_char1
                                and check_char_fuma_match(env, pure_pinyin_parts[2], fuma_chunk, char2)
                        end

                        if changes_anchor then
                            seen[c.text] = true
                            matched_texts[#matched_texts + 1] = replace_text_range(current_text, w_start, w_end, c.text)
                            if #matched_texts >= 2 then
                                break
                            end
                        end
                    end
                end

                if #matched_texts > 0 then
                    return matched_texts[1], 1, anchor_pos + 1, matched_texts[2], { anchor_pos }
                end
            end
        end
    end

    return nil
end

local LOCAL_CONTEXT_WEIGHTS = {
    [2] = 4,
    [3] = 7,
}
local LOCAL_CONTEXT_STRONG_MARGIN = 7
local LOCAL_CONTEXT_MIN_OVERRIDE_DISTANCE = 2
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

    return replacement_support - original_support, original_support, replacement_support
end

local function allow_adjacent_context_override(left_match, later_match, allow_weight_rescue)
    if not allow_weight_rescue or not left_match or not later_match then
        return false
    end

    if (later_match.pos or 0) - (left_match.pos or 0) ~= 1 then
        return false
    end

    if not left_match.is_change or not later_match.is_change then
        return false
    end

    local left_original = left_match.original_support or 0
    local left_replacement = left_match.replacement_support or 0
    local later_replacement = later_match.replacement_support or 0
    local left_score = left_match.context_score or 0
    local later_score = later_match.context_score or 0

    return left_original > left_replacement
        and later_replacement > left_replacement
        and later_replacement > 0
        and later_score >= left_score
end

local function override_distance_allowed(left_match, later_match, allow_weight_rescue)
    if not left_match or not later_match then
        return false
    end

    local distance = (later_match.pos or 0) - (left_match.pos or 0)
    if distance >= LOCAL_CONTEXT_MIN_OVERRIDE_DISTANCE then
        return true
    end

    return allow_adjacent_context_override(left_match, later_match, allow_weight_rescue)
end

local function should_override_leftmost_match(
    left_match,
    later_match,
    allow_weight_rescue
)
    if not override_distance_allowed(left_match, later_match, allow_weight_rescue) then
        return false
    end

    local left_score = left_match.context_score or 0
    local later_score = later_match.context_score or 0
    local left_weight = left_match.weight or -math.huge
    local later_weight = later_match.weight or -math.huge

    if (later_match.pos or 0) - (left_match.pos or 0) == 1 then
        return true
    end

    if left_score < 0 and later_score >= 0 then
        return true
    end

    if later_score - left_score >= LOCAL_CONTEXT_STRONG_MARGIN then
        return true
    end

    if allow_weight_rescue
        and later_match.is_change
        and later_score >= left_score
        and later_weight > left_weight
    then
        return true
    end

    return false
end

local function can_match_remaining_chunks(
    chars,
    start_pos,
    fuma_chunks,
    next_chunk_idx,
    env,
    syllables,
    syl_offset
)
    if next_chunk_idx > #fuma_chunks then
        return true
    end

    local current_pos = math.max(start_pos or 1, 1)

    for c_idx = next_chunk_idx, #fuma_chunks do
        local remaining_after = #fuma_chunks - c_idx
        local max_pos = #chars - remaining_after
        local found_pos = nil

        for i = current_pos, max_pos do
            local orig_char = chars[i]
            local pinyin_code = syllables[i + syl_offset]

            if pinyin_code and orig_char then
                if #pinyin_code > 2 then
                    pinyin_code = string.sub(pinyin_code, 1, 2)
                end

                local is_orig_valid, best_char = collect_best_single_char_match(
                    env,
                    pinyin_code,
                    fuma_chunks[c_idx],
                    orig_char
                )

                if is_orig_valid or best_char then
                    found_pos = i
                    break
                end
            end
        end

        if not found_pos then
            return false
        end

        current_pos = found_pos + 1
    end

    return true
end

local POSITION_RESCUE_CANDIDATE_LIMIT = 6

local function is_better_position_rescue(candidate, current_best)
    if not candidate then
        return false
    end
    if not current_best then
        return true
    end

    local candidate_support = candidate.replacement_support or 0
    local best_support = current_best.replacement_support or 0
    if candidate_support ~= best_support then
        return candidate_support > best_support
    end

    local candidate_weight = candidate.weight or -math.huge
    local best_weight = current_best.weight or -math.huge
    if candidate_weight ~= best_weight then
        return candidate_weight > best_weight
    end

    local candidate_delta = candidate.context_score or 0
    local best_delta = current_best.context_score or 0
    if candidate_delta ~= best_delta then
        return candidate_delta > best_delta
    end

    return (candidate.pos or math.huge) < (current_best.pos or math.huge)
end

local function is_better_same_position_match(candidate, current_best, prefer_change)
    if not candidate then
        return false
    end
    if not current_best then
        return true
    end

    local candidate_support = candidate.replacement_support or 0
    local best_support = current_best.replacement_support or 0
    if candidate_support ~= best_support then
        return candidate_support > best_support
    end

    local candidate_delta = candidate.context_score or 0
    local best_delta = current_best.context_score or 0
    if candidate_delta ~= best_delta then
        return candidate_delta > best_delta
    end

    if candidate.is_change ~= current_best.is_change then
        if prefer_change then
            return candidate.is_change
        end
        return not candidate.is_change
    end

    local candidate_weight = candidate.weight or -math.huge
    local best_weight = current_best.weight or -math.huge
    if candidate_weight ~= best_weight then
        return candidate_weight > best_weight
    end

    return tostring(candidate.char or "") < tostring(current_best.char or "")
end


local RELEASE_BACKTRACK_MAX_STATES = 768
local RELEASE_BACKTRACK_MAX_RESULTS = 2
local RELEASE_BACKTRACK_CANDIDATES_PER_POSITION = 6

local function copy_char_list(chars)
    local out = {}
    for i = 1, #chars do
        out[i] = chars[i]
    end
    return out
end

local function copy_number_list(values)
    local out = {}
    for i = 1, #(values or {}) do
        out[i] = values[i]
    end
    return out
end

local function collect_release_position_matches(
    chars,
    pos,
    chunk_fuma,
    env,
    syllables,
    syl_offset,
    context_cache,
    prefer_change
)
    local orig_char = chars[pos]
    local pinyin_code = syllables[pos + syl_offset]
    if not orig_char or not pinyin_code then
        return {}
    end

    if #pinyin_code > 2 then
        pinyin_code = string.sub(pinyin_code, 1, 2)
    end

    local probe_data = get_single_char_probe_data(env, pinyin_code, chunk_fuma)
    local matches = {}
    local seen = {}

    local function add_match(char, weight)
        if not char or seen[char] then
            return
        end
        seen[char] = true

        local context_score, original_support, replacement_support =
            get_local_context_delta(
                chars,
                pos,
                char,
                env,
                syllables,
                syl_offset,
                context_cache
            )

        matches[#matches + 1] = {
            pos = pos,
            char = char,
            weight = weight or -math.huge,
            context_score = context_score or 0,
            original_support = original_support or 0,
            replacement_support = replacement_support or 0,
            is_change = char ~= orig_char,
        }
    end

    if probe_data.valid_chars[orig_char] then
        add_match(
            orig_char,
            (probe_data.candidate_weights and probe_data.candidate_weights[orig_char])
                or -math.huge
        )
    end

    for _, item in ipairs(probe_data.ranked or {}) do
        if item.char ~= orig_char then
            add_match(item.char, item.weight)
            if #matches >= RELEASE_BACKTRACK_CANDIDATES_PER_POSITION then
                break
            end
        end
    end

    table.sort(matches, function(a, b)
        return is_better_same_position_match(a, b, prefer_change)
    end)

    while #matches > RELEASE_BACKTRACK_CANDIDATES_PER_POSITION do
        table.remove(matches)
    end

    return matches
end

local function has_preview_match_from(
    chars,
    search_start_idx,
    preview_chunk,
    env,
    syllables,
    syl_offset
)
    if not preview_chunk or preview_chunk == "" then
        return true
    end

    local first_pos = math.max(search_start_idx or 1, 1)
    for pos = first_pos, #chars do
        local orig_char = chars[pos]
        local pinyin_code = syllables[pos + syl_offset]
        if orig_char and pinyin_code then
            if #pinyin_code > 2 then
                pinyin_code = string.sub(pinyin_code, 1, 2)
            end

            local probe_data = get_single_char_probe_data(
                env,
                pinyin_code,
                preview_chunk
            )
            if probe_data.valid_chars[orig_char]
                or (probe_data.ranked and #probe_data.ranked > 0)
            then
                return true
            end
        end
    end

    return false
end

local function try_match_single_chars_with_release(
    current_text,
    search_start_idx,
    env,
    syllables,
    fuma_chunks,
    syl_offset,
    match_count,
    active_chunk_index,
    required_preview_chunk
)
    local base_chars = text_to_chars(current_text)
    local first_pos = math.max(search_start_idx or 1, 1)
    local results = {}
    local seen_texts = {}
    local explored_states = 0
    local context_cache = {}

    local function add_result(chars, next_start, positions)
        local text_value = chars_to_text(chars)
        local pos_key = table.concat(positions or {}, ",")
        local result_key = text_value .. "\31" .. pos_key
        if seen_texts[result_key] then
            return
        end
        seen_texts[result_key] = true
        results[#results + 1] = {
            text = text_value,
            next_start = next_start,
            positions = copy_number_list(positions),
        }
    end

    local function dfs(chars, chunk_idx, current_start, positions)
        if #results >= RELEASE_BACKTRACK_MAX_RESULTS
            or explored_states >= RELEASE_BACKTRACK_MAX_STATES
        then
            return
        end

        explored_states = explored_states + 1

        if chunk_idx > #fuma_chunks then
            if has_preview_match_from(
                chars,
                current_start,
                required_preview_chunk,
                env,
                syllables,
                syl_offset
            ) then
                add_result(chars, current_start, positions)
            end
            return
        end

        local remaining_after = #fuma_chunks - chunk_idx
        local preview_reserve = required_preview_chunk and 1 or 0
        local max_pos = #chars - remaining_after - preview_reserve
        if current_start > max_pos then
            return
        end

        local is_active_chunk = is_active_chunk_spec(active_chunk_index, chunk_idx)
        local prefer_change = is_active_chunk and current_start > 1

        for pos = current_start, max_pos do
            local position_matches = collect_release_position_matches(
                chars,
                pos,
                fuma_chunks[chunk_idx],
                env,
                syllables,
                syl_offset,
                context_cache,
                prefer_change
            )

            for _, match in ipairs(position_matches) do
                local next_chars = copy_char_list(chars)
                next_chars[pos] = match.char

                if chunk_idx == #fuma_chunks
                    or can_match_remaining_chunks(
                        next_chars,
                        pos + 1,
                        fuma_chunks,
                        chunk_idx + 1,
                        env,
                        syllables,
                        syl_offset
                    )
                then
                    local next_positions = copy_number_list(positions)
                    next_positions[#next_positions + 1] = pos
                    dfs(next_chars, chunk_idx + 1, pos + 1, next_positions)
                end

                if #results >= RELEASE_BACKTRACK_MAX_RESULTS
                    or explored_states >= RELEASE_BACKTRACK_MAX_STATES
                then
                    return
                end
            end
        end
    end

    dfs(base_chars, 1, first_pos, {})

    if #results == 0 then
        return nil
    end

    local primary = results[1]
    local secondary = results[2]
    return primary.text,
        match_count + #fuma_chunks,
        primary.next_start,
        secondary and secondary.text or nil,
        primary.positions
end

local function try_match_single_chars(
    current_text,
    search_start_idx,
    env,
    syllables,
    fuma_chunks,
    syl_offset,
    match_count,
    active_chunk_index
)
    local original_text = current_text
    local original_start = math.max(search_start_idx or 1, 1)
    local initial_match_count = match_count
    local chars = text_to_chars(current_text)
    local current_start = original_start
    local m_count = match_count
    local changed = false
    local alternate_chars = nil
    local matched_positions = {}
    local context_cache = {}

    for c_idx = 1, #fuma_chunks do
        local chunk_fuma = fuma_chunks[c_idx]
        local is_active_chunk = is_active_chunk_spec(active_chunk_index, c_idx)
        local leftmost_match = nil
        local best_context_match = nil
        local best_position_rescue = nil

        local remaining_chunks = #fuma_chunks - c_idx
        local max_match_pos = #chars - remaining_chunks

        for i = current_start, max_match_pos do
            local orig_char = chars[i]
            local pinyin_code = syllables[i + syl_offset]

            if pinyin_code and orig_char then
                if #pinyin_code > 2 then
                    pinyin_code = string.sub(pinyin_code, 1, 2)
                end

                local probe_data = get_single_char_probe_data(env, pinyin_code, chunk_fuma)
                local is_orig_valid = probe_data.valid_chars[orig_char] == true
                local orig_weight = (probe_data.candidate_weights and probe_data.candidate_weights[orig_char])
                    or -math.huge

                local replacement_items = {}
                for _, item in ipairs(probe_data.ranked or {}) do
                    if item.char ~= orig_char then
                        replacement_items[#replacement_items + 1] = item
                        if #replacement_items >= POSITION_RESCUE_CANDIDATE_LIMIT then
                            break
                        end
                    end
                end

                local best_item = replacement_items[1]
                local second_item = replacement_items[2]

                local matched_char = nil
                local matched_weight = -math.huge
                local alternate_char = nil
                local alternate_weight = -math.huge

                if not is_active_chunk then
                    if is_orig_valid then
                        matched_char = orig_char
                        matched_weight = orig_weight
                    elseif best_item then
                        matched_char = best_item.char
                        matched_weight = best_item.weight or -math.huge
                        if second_item then
                            alternate_char = second_item.char
                            alternate_weight = second_item.weight or -math.huge
                        end
                    end
                else
                    local prefer_replacement = current_start > 1
                    if best_item and (not is_orig_valid or prefer_replacement) then
                        matched_char = best_item.char
                        matched_weight = best_item.weight or -math.huge
                        if is_orig_valid then
                            alternate_char = orig_char
                            alternate_weight = orig_weight
                        elseif second_item then
                            alternate_char = second_item.char
                            alternate_weight = second_item.weight or -math.huge
                        end
                    elseif is_orig_valid then
                        matched_char = orig_char
                        matched_weight = orig_weight
                        if best_item then
                            alternate_char = best_item.char
                            alternate_weight = best_item.weight or -math.huge
                        end
                    end
                end

                local function make_match(char, weight, alt_char, alt_weight)
                    if not char then
                        return nil
                    end

                    local context_score, original_support, replacement_support =
                        get_local_context_delta(
                            chars,
                            i,
                            char,
                            env,
                            syllables,
                            syl_offset,
                            context_cache
                        )

                    return {
                        pos = i,
                        char = char,
                        alt_char = alt_char,
                        weight = weight or -math.huge,
                        alt_weight = alt_weight or -math.huge,
                        context_score = context_score or 0,
                        original_support = original_support or 0,
                        replacement_support = replacement_support or 0,
                        is_change = char ~= orig_char,
                    }
                end

                local primary_match = make_match(
                    matched_char,
                    matched_weight,
                    alternate_char,
                    alternate_weight
                )

                if is_active_chunk then
                    local same_position_matches = {}
                    local original_match = nil
                    local position_original_support = 0

                    if is_orig_valid then
                        original_match = make_match(orig_char, orig_weight, nil, -math.huge)
                    end

                    for _, item in ipairs(replacement_items) do
                        local item_match = make_match(item.char, item.weight, nil, -math.huge)
                        if item_match then
                            same_position_matches[#same_position_matches + 1] = item_match
                            if (item_match.original_support or 0) > position_original_support then
                                position_original_support = item_match.original_support or 0
                            end
                        end
                    end

                    if original_match then
                        original_match.original_support = position_original_support
                        original_match.replacement_support = position_original_support
                        original_match.context_score = 0
                        same_position_matches[#same_position_matches + 1] = original_match
                    end

                    if #same_position_matches > 0 then
                        local prefer_change = current_start > 1
                        table.sort(same_position_matches, function(a, b)
                            return is_better_same_position_match(a, b, prefer_change)
                        end)

                        primary_match = same_position_matches[1]
                        local same_position_second = same_position_matches[2]
                        if same_position_second
                            and same_position_second.char ~= primary_match.char
                        then
                            primary_match.alt_char = same_position_second.char
                            primary_match.alt_weight = same_position_second.weight or -math.huge
                        else
                            primary_match.alt_char = nil
                            primary_match.alt_weight = -math.huge
                        end
                    end
                end

                if primary_match then
                    if not leftmost_match then
                        leftmost_match = primary_match
                        best_context_match = primary_match
                    elseif primary_match.context_score > best_context_match.context_score
                        or (
                            primary_match.context_score == best_context_match.context_score
                            and primary_match.replacement_support > (best_context_match.replacement_support or 0)
                        )
                        or (
                            primary_match.context_score == best_context_match.context_score
                            and primary_match.replacement_support == (best_context_match.replacement_support or 0)
                            and primary_match.weight > (best_context_match.weight or -math.huge)
                        )
                    then
                        best_context_match = primary_match
                    end
                end

                if is_active_chunk
                    and leftmost_match
                    and current_start > 1
                    and i > leftmost_match.pos
                then
                    local remaining_ok = can_match_remaining_chunks(
                        chars,
                        i + 1,
                        fuma_chunks,
                        c_idx + 1,
                        env,
                        syllables,
                        syl_offset
                    )

                    if remaining_ok then
                        for item_idx, item in ipairs(replacement_items) do
                            local rescue_alt = nil
                            local rescue_alt_weight = -math.huge

                            if primary_match and primary_match.char ~= item.char then
                                rescue_alt = primary_match.char
                                rescue_alt_weight = primary_match.weight or -math.huge
                            elseif is_orig_valid then
                                rescue_alt = orig_char
                                rescue_alt_weight = orig_weight
                            elseif replacement_items[item_idx + 1] then
                                rescue_alt = replacement_items[item_idx + 1].char
                                rescue_alt_weight = replacement_items[item_idx + 1].weight or -math.huge
                            end

                            local rescue_match = make_match(
                                item.char,
                                item.weight,
                                rescue_alt,
                                rescue_alt_weight
                            )

                            if rescue_match
                                and rescue_match.is_change
                                and override_distance_allowed(
                                    leftmost_match,
                                    rescue_match,
                                    current_start > 1
                                )
                                and rescue_match.replacement_support >= (leftmost_match.replacement_support or 0)
                                and (
                                    (leftmost_match.original_support or 0) > 0
                                    or rescue_match.replacement_support > (leftmost_match.replacement_support or 0)
                                )
                                and (
                                    rescue_match.replacement_support > (leftmost_match.replacement_support or 0)
                                    or rescue_match.weight > (leftmost_match.weight or -math.huge)
                                )
                                and is_better_position_rescue(rescue_match, best_position_rescue)
                            then
                                best_position_rescue = rescue_match
                            end
                        end
                    end
                end
            end
        end

        local selected_match = leftmost_match

        if is_active_chunk
            and leftmost_match and best_context_match and best_context_match.pos ~= leftmost_match.pos
            and should_override_leftmost_match(
                leftmost_match,
                best_context_match,
                current_start > 1
            )
            and can_match_remaining_chunks(
                chars,
                best_context_match.pos + 1,
                fuma_chunks,
                c_idx + 1,
                env,
                syllables,
                syl_offset
            )
        then
            selected_match = best_context_match
        end

        if is_active_chunk
            and best_position_rescue
            and is_better_position_rescue(best_position_rescue, selected_match)
        then
            selected_match = best_position_rescue
        end

        if selected_match then
            m_count = m_count + 1

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

            matched_positions[#matched_positions + 1] = selected_match.pos
            current_start = selected_match.pos + 1
        end
    end

    if m_count < initial_match_count + #fuma_chunks then
        local released_text, released_count, released_next, released_alternate, released_positions =
            try_match_single_chars_with_release(
                original_text,
                original_start,
                env,
                syllables,
                fuma_chunks,
                syl_offset,
                initial_match_count,
                active_chunk_index,
                nil
            )

        if released_text and released_count == initial_match_count + #fuma_chunks then
            return released_text, released_count, released_next, released_alternate, released_positions
        end
    end

    local alternate_text = alternate_chars and chars_to_text(alternate_chars) or nil

    if changed then
        return chars_to_text(chars), m_count, current_start, alternate_text, matched_positions
    end

    return current_text, m_count, current_start, alternate_text, matched_positions
end

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

        if #letters == 1 and digits == "" then
            preview_chunk = last_chunk
            table.remove(completed_chunks)
        end
    end

    return completed_chunks, preview_chunk
end

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

            local is_orig_valid, best_char, second_char,
                best_weight, second_weight, orig_weight =
                collect_best_single_char_match(env, pinyin_code, preview_chunk, orig_char)

            local matched_char = nil
            local matched_weight = -math.huge
            local alternate_char = nil
            local alternate_weight = -math.huge
            local prefer_replacement = first_pos > 1

            if best_char and (not is_orig_valid or prefer_replacement) then
                matched_char = best_char
                matched_weight = best_weight or -math.huge
                if is_orig_valid then
                    alternate_char = orig_char
                    alternate_weight = orig_weight or -math.huge
                else
                    alternate_char = second_char
                    alternate_weight = second_weight or -math.huge
                end
            elseif is_orig_valid then
                matched_char = orig_char
                matched_weight = orig_weight or -math.huge
                alternate_char = best_char
                alternate_weight = best_weight or -math.huge
            end

            if matched_char then
                local context_score, original_support, replacement_support =
                    get_local_context_delta(
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
                    alt_char = alternate_char,
                    weight = matched_weight,
                    alt_weight = alternate_weight,
                    context_score = context_score or 0,
                    original_support = original_support or 0,
                    replacement_support = replacement_support or 0,
                    is_change = matched_char ~= orig_char,
                }

                if not leftmost_match then
                    leftmost_match = current_match
                    best_context_match = current_match
                elseif context_score > best_context_match.context_score
                    or (
                        context_score == best_context_match.context_score
                        and matched_weight > (best_context_match.weight or -math.huge)
                    )
                then
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
            leftmost_match,
            best_context_match,
            first_pos > 1
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

local function copy_chunk_range(chunks, first_idx, last_idx)
    local out = {}
    for i = first_idx, last_idx do
        out[#out + 1] = chunks[i]
    end
    return out
end

local function match_chunk_group(
    current_text,
    search_start_idx,
    cand_len,
    env,
    syllables,
    chunks,
    syl_offset,
    active_chunk_index
)
    if #chunks == 0 then
        return current_text, 0, search_start_idx, nil
    end

    local new_text, count, next_start, second_text, positions =
        try_match_long_phrase(
            current_text,
            cand_len,
            env,
            syllables,
            chunks,
            syl_offset,
            active_chunk_index,
            search_start_idx
        )

    if new_text then
        return new_text, count, next_start, second_text, positions
    end

    if #chunks == 1 and is_active_chunk_spec(active_chunk_index, 1) then
        new_text, count, next_start, second_text, positions =
            try_match_two_char_phrase(
                current_text,
                search_start_idx,
                cand_len,
                env,
                syllables,
                chunks[1],
                syl_offset
            )

        if new_text then
            return new_text, count, next_start, second_text, positions
        end
    end

    return try_match_single_chars(
        current_text,
        search_start_idx,
        env,
        syllables,
        chunks,
        syl_offset,
        0,
        active_chunk_index
    )
end

local function try_match_segmented_chunks(
    current_text,
    search_start_idx,
    cand_len,
    env,
    syllables,
    chunks,
    syl_offset,
    preview_chunk
)
    local chunk_count = #chunks
    if chunk_count < 3 then
        return nil
    end

    for prefix_len = chunk_count - 1, 2, -1 do
        local prefix_chunks = copy_chunk_range(chunks, 1, prefix_len)
        local prefix_text, prefix_count, prefix_next, prefix_second, prefix_positions =
            try_match_long_phrase(
                current_text,
                cand_len,
                env,
                syllables,
                prefix_chunks,
                syl_offset,
                prefix_len,
                search_start_idx
            )

        if prefix_text and prefix_count == prefix_len then
            local suffix_chunks = copy_chunk_range(chunks, prefix_len + 1, chunk_count)
            local suffix_active_index = preview_chunk and 0 or #suffix_chunks
            local final_text, suffix_count, final_next, suffix_second, suffix_positions =
                match_chunk_group(
                    prefix_text,
                    prefix_next,
                    cand_len,
                    env,
                    syllables,
                    suffix_chunks,
                    syl_offset,
                    suffix_active_index
                )

            if suffix_count == #suffix_chunks then
                local alternate_text = suffix_second

                if not alternate_text and prefix_second then
                    local alt_text, alt_count =
                        match_chunk_group(
                            prefix_second,
                            prefix_next,
                            cand_len,
                            env,
                            syllables,
                            suffix_chunks,
                            syl_offset,
                            suffix_active_index
                        )
                    if alt_count == #suffix_chunks then
                        alternate_text = alt_text
                    end
                end

                local positions = {}
                for _, pos in ipairs(prefix_positions or {}) do
                    positions[#positions + 1] = pos
                end
                for _, pos in ipairs(suffix_positions or {}) do
                    positions[#positions + 1] = pos
                end
                return final_text, prefix_count + suffix_count, final_next, alternate_text, positions
            end
        end
    end

    return nil
end

local function rebuild_text_from_locked_prefix(base_text, stable_text, last_locked_pos)
    if not stable_text or stable_text == "" or not last_locked_pos or last_locked_pos <= 0 then
        return base_text
    end

    local base_chars = text_to_chars(base_text)
    local stable_chars = text_to_chars(stable_text)
    local limit = math.min(last_locked_pos, #base_chars, #stable_chars)

    for i = 1, limit do
        base_chars[i] = stable_chars[i]
    end

    return chars_to_text(base_chars)
end

local function attempt_phrase_correction(cand, cand_len, env, syllables, fuma_chunks, syl_offset, seed_progress)
    if #fuma_chunks == 0 then
        return nil
    end

    local completed_chunks, preview_chunk = split_fuma_chunks_for_preview(fuma_chunks)
    local saved_positions = {}
    local saved_count = 0
    local saved_text = nil

    if seed_progress
        and seed_progress.stable_text
        and seed_progress.stable_text ~= ""
        and get_utf8_len(seed_progress.stable_text) == cand_len
    then
        saved_text = seed_progress.stable_text
        for _, pos in ipairs(seed_progress.bound_positions or {}) do
            local n = tonumber(pos)
            if n and n >= 1 and n <= cand_len then
                saved_positions[#saved_positions + 1] = n
            end
        end
        saved_count = math.min(
            tonumber(seed_progress.completed_count) or #saved_positions,
            #saved_positions,
            #completed_chunks
        )
    end

    local function run_with_locked_count(locked_count)
        local bound_positions = {}
        for i = 1, locked_count do
            bound_positions[i] = saved_positions[i]
        end

        local last_locked_pos = locked_count > 0 and bound_positions[locked_count] or 0
        local current_text = rebuild_text_from_locked_prefix(
            cand.text,
            saved_text,
            last_locked_pos
        )
        local remaining_chunks = {}
        for i = locked_count + 1, #completed_chunks do
            remaining_chunks[#remaining_chunks + 1] = completed_chunks[i]
        end

        local released_history = locked_count < saved_count
        local active_remaining_chunk_index

        if released_history then
            active_remaining_chunk_index = {}
            for i = 1, #remaining_chunks do
                active_remaining_chunk_index[i] = true
            end
        else
            active_remaining_chunk_index = preview_chunk and 0 or #remaining_chunks
        end

        local alternate_text = nil
        local match_count = locked_count
        local search_start_idx = last_locked_pos > 0 and last_locked_pos + 1 or 1
        local rematch_base_text = current_text
        local rematch_start_idx = search_start_idx
        local new_positions = {}

        if #remaining_chunks > 0 then
            local new_match_count = 0

            if released_history then
                current_text, new_match_count, search_start_idx, alternate_text, new_positions =
                    match_chunk_group(
                        current_text,
                        search_start_idx,
                        cand_len,
                        env,
                        syllables,
                        remaining_chunks,
                        syl_offset,
                        active_remaining_chunk_index
                    )
            else
                local new_text, count, next_start, second_text, positions =
                    try_match_long_phrase(
                        current_text,
                        cand_len,
                        env,
                        syllables,
                        remaining_chunks,
                        syl_offset,
                        active_remaining_chunk_index,
                        search_start_idx
                    )

                if new_text then
                    current_text = new_text
                    alternate_text = second_text
                    new_match_count = count
                    search_start_idx = next_start
                    new_positions = positions or {}
                else
                    new_text, count, next_start, second_text, positions =
                        try_match_segmented_chunks(
                            current_text,
                            search_start_idx,
                            cand_len,
                            env,
                            syllables,
                            remaining_chunks,
                            syl_offset,
                            preview_chunk
                        )

                    if new_text then
                        current_text = new_text
                        alternate_text = second_text
                        new_match_count = count
                        search_start_idx = next_start
                        new_positions = positions or {}
                    end
                end

                if new_match_count == 0 then
                    current_text, new_match_count, search_start_idx, alternate_text, new_positions =
                        match_chunk_group(
                            current_text,
                            search_start_idx,
                            cand_len,
                            env,
                            syllables,
                            remaining_chunks,
                            syl_offset,
                            active_remaining_chunk_index
                        )
                end
            end

            match_count = locked_count + new_match_count
        end

        if match_count ~= #completed_chunks then
            return nil
        end

        for _, pos in ipairs(new_positions or {}) do
            bound_positions[#bound_positions + 1] = pos
        end

        if #bound_positions ~= #completed_chunks then
            return nil
        end

        local stable_text = current_text
        local preview_matched = false

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

            if not preview_matched and #remaining_chunks > 0 then
                local all_active = {}
                for i = 1, #remaining_chunks do
                    all_active[i] = true
                end

                local constrained_text,
                    constrained_count,
                    constrained_next,
                    constrained_alternate,
                    constrained_positions =
                    try_match_single_chars_with_release(
                        rematch_base_text,
                        rematch_start_idx,
                        env,
                        syllables,
                        remaining_chunks,
                        syl_offset,
                        0,
                        all_active,
                        preview_chunk
                    )

                if constrained_text
                    and constrained_count == #remaining_chunks
                then
                    current_text = constrained_text
                    alternate_text = constrained_alternate
                    search_start_idx = constrained_next
                    new_positions = constrained_positions or {}
                    bound_positions = {}
                    for i = 1, locked_count do
                        bound_positions[i] = saved_positions[i]
                    end
                    for _, pos in ipairs(new_positions) do
                        bound_positions[#bound_positions + 1] = pos
                    end
                    stable_text = current_text
                    preview_start = search_start_idx
                    current_text, preview_matched, search_start_idx, preview_alt =
                        try_preview_half_chunk(
                            current_text,
                            preview_start,
                            env,
                            syllables,
                            preview_chunk,
                            syl_offset
                        )
                end
            end

            if not preview_matched and locked_count > 0 then
                return nil
            end

            if alternate_text then
                local alt_preview_text = select(1, try_preview_half_chunk(
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

        local comment = cand.comment or ""
        if preview_chunk and preview_matched then
            comment = comment .. "〔半码预览〕"
        end

        local function make_candidate(text_value, quality_offset)
            if not text_value or text_value == "" then
                return nil
            end
            if text_value == cand.text and quality_offset and quality_offset < 0 then
                return nil
            end

            local fixed_cand = Candidate(cand.type, cand.start, cand._end, text_value, comment)
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

        return primary, secondary, {
            stable_text = stable_text,
            primary_text = current_text,
            completed_count = #completed_chunks,
            last_match_pos = bound_positions[#bound_positions] or 0,
            bound_positions = bound_positions,
            has_preview = preview_chunk ~= nil,
        }
    end

    local primary, secondary, meta = run_with_locked_count(saved_count)
    if primary then
        return primary, secondary, meta
    end

    for locked_count = saved_count - 1, 0, -1 do
        primary, secondary, meta = run_with_locked_count(locked_count)
        if primary then
            return primary, secondary, meta
        end
    end

    return nil
end

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

local function get_explicit_progress_seed(env, pure_code, explicitly_fuma, cand, cand_len, syl_offset)
    local progress = env._explicit_progress
    if not progress or not progress.stable_text then
        return nil
    end

    if progress.pure_code ~= pure_code
        or progress.base_text ~= cand.text
        or progress.cand_len ~= cand_len
        or progress.cand_start ~= cand.start
        or progress.cand_end ~= cand._end
        or progress.syl_offset ~= syl_offset
    then
        return nil
    end

    local previous_fuma = progress.fuma or ""
    if explicitly_fuma == previous_fuma then
        return progress
    end

    if #explicitly_fuma > #previous_fuma
        and explicitly_fuma:sub(1, #previous_fuma) == previous_fuma
    then
        return progress
    end

    return nil
end

local function save_explicit_progress(env, pure_code, explicitly_fuma, cand, cand_len, syl_offset, meta)
    if not meta or not meta.stable_text then
        env._explicit_progress = nil
        return
    end

    env._explicit_progress = {
        pure_code = pure_code,
        fuma = explicitly_fuma,
        base_text = cand.text,
        cand_len = cand_len,
        cand_start = cand.start,
        cand_end = cand._end,
        syl_offset = syl_offset,
        stable_text = meta.stable_text,
        primary_text = meta.primary_text,
        completed_count = meta.completed_count or 0,
        last_match_pos = meta.last_match_pos or 0,
        bound_positions = copy_number_list(meta.bound_positions or {}),
        has_preview = meta.has_preview == true,
    }
end

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

    local syllables
    if pure_code == env.history_input and env.history_parts and #env.history_parts > 0 then
        syllables = env.history_parts
    else
        syllables = get_script_text_parts(ctx, env.reverse_key)
    end

    for cand in input:iter() do
        local cand_len = get_utf8_len(cand.text)

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
                local seed_progress = get_explicit_progress_seed(
                    env,
                    pure_code,
                    explicitly_fuma,
                    cand,
                    cand_len,
                    syl_offset
                )

                local corr_cand, corr_cand2, progress_meta =
                    attempt_phrase_correction(
                        cand,
                        cand_len,
                        env,
                        syllables,
                        fuma_chunks,
                        syl_offset,
                        seed_progress
                    )

                local has_bound_prefix = seed_progress
                    and (tonumber(seed_progress.completed_count) or 0) > 0
                    and seed_progress.bound_positions
                    and #seed_progress.bound_positions > 0

                if not corr_cand and seed_progress and not has_bound_prefix then
                    corr_cand, corr_cand2, progress_meta =
                        attempt_phrase_correction(
                            cand,
                            cand_len,
                            env,
                            syllables,
                            fuma_chunks,
                            syl_offset,
                            nil
                        )
                end

                if corr_cand then
                    save_explicit_progress(
                        env,
                        pure_code,
                        explicitly_fuma,
                        cand,
                        cand_len,
                        syl_offset,
                        progress_meta
                    )
                    yield(corr_cand)
                    if corr_cand2 and corr_cand2.text ~= corr_cand.text then
                        yield(corr_cand2)
                    end
                    goto skip
                else
                    env._explicit_progress = nil
                end
            end
        end

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

            if follows_base and extra_len == 1 and direct_cache and not direct_cache.active and cand_len == 3 then
                direct_cache.active = true
                mode = "lookup"
                build_matches()

            elseif follows_base and extra_len >= 1 and extra_len <= 2 and direct_cache and direct_cache.active then
                mode = "lookup"
                build_matches()

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

local f = {}

function f.init(env)
    local config = env.engine.schema.config

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
            env._explicit_progress = nil
        else
            ctx.input = no_search_string
            ctx:commit()
            env._explicit_progress = nil
            clear_match_caches(env)
        end
    end)

    env._db_cache = {}
    env._comment_cache = {}
    env.cache_size = 0
    env.direct_cache = nil
    env._explicit_progress = nil
    clear_match_caches(env)
    env.history_parts = {}
    env.history_input = ""
    env.update_conn = env.engine.context.update_notifier:connect(function(ctx)
        if not ctx:is_composing() then
            env.history_parts = {}
            env.history_input = ""
            env.direct_cache = nil
            env._explicit_progress = nil
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
            env._explicit_progress = nil
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        return handle_explicit_mode(input, env, ctx_input, pure_code, explicitly_fuma, s_end)
    else
        env._explicit_progress = nil
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
    env._explicit_progress = nil

    collectgarbage("collect")
end
return f
