local UDP = require "internal.UDP"
local co = require "internal.Co"
local log = require "log"

local co_self = co.self
local co_wait = co.wait
local co_wakeup = co.wakeup

local LIMIT_HEADER_LEN = 12
local MAX_THREAD_ID = 65535

local concat = table.concat
local insert = table.insert

local now = os.time
local fmt = string.format
local match = string.match
local splite = string.gmatch
local pack = string.pack
local unpack = string.unpack

local dns = {}

local dns_cache = {}

local dns_list = {}

local thread_id = 0

local function gen_id()
    thread_id = thread_id % MAX_THREAD_ID + 1
    return thread_id
end

local function check_cache(domain)
    local query = dns_cache[domain]
    if not query then
        return
    end
    if query.ttl and query.ttl < now() then
        dns_cache[domain] = nil
        return
    end
    return query.ip
end

local function gen_cache()
    local file = io.open("/etc/hosts", "r")
    dns_cache['localhost'] = { ip = "127.0.0.1"}
    if file then
        for line in file:lines() do
            local ip, domain = match(line, '(%d+%p%d+%p%d+%p%d+) -(.-)$')
            if ip and domain then
                if not dns_cache[domain] then
                    dns_cache[domain] = {ip = ip}
                else
                    dns_cache[domain]["ip"] = ip
                end
            end
        end
        file:close()
    end
end

local function check_ip(ip, version)
    if version == 4 then
        if #ip > 15 or #ip < 7 then
            return false
        end
        local num_list = {nil, nil, nil, nil}
        for num in splite(ip, '(%d+)') do
            if tonumber(num) < 0 or tonumber(num) > 255 then
                return false
            end
            insert(num_list, tonumber(num))
        end
        if #num_list ~= 4 then
            return false
        end
        return true
    end
end

if #dns_list < 1 then
    local file = io.open("/etc/resolv.conf", "r")
    if file then
        for line in file:lines() do
            local ip = match(line, "nameserver (.-)$")
            local YES = check_ip(ip)
            if YES then
                insert(dns_list, ip)
            end
        end
        file:close()
    end
    if #dns_list < 1 then
        dns_list = {"114.114.114.114", "8.8.8.8"}
    end
    gen_cache()
end

local dns_client_rr = 0

local function get_dns_client()
    dns_client_rr = dns_client_rr % #dns_list + 1
    local udp = UDP:new():timeout(dns._timeout or 10) -- 默认情况下是10秒超时
    local ok = udp:connect(dns_list[dns_client_rr], 53)
    if ok then
        return udp
    end
end

local function pack_header()
    local tid = gen_id()
    local flag = 0x100
    local QCOUNT = 1
    -- QCount 永远是1, flags 永远是256
    return pack(">HHHHHH", tid, flag, QCOUNT, 0, 0, 0)
end

local function pack_question(name)
    local Query_Type  = 0x01 -- IPv4
    local Query_Class = 0x01 -- IN internet
    local question = {}
    for sp in splite(name, "([^%.]*)") do
        insert(question, pack(">s1", sp))
    end
    insert(question, "\0")
    insert(question, pack(">HH", Query_Type, Query_Class))
    return concat(question)
end

local function unpack_header(chunk)
    local tid, flags, qdcount, ancount, nscount, arcount, nbyte = unpack(">HHHHHH", chunk)
    return { tid = tid, flags = flags, qdcount = qdcount, ancount = ancount}, nbyte
end

local function unpack_name(chunk, nbyte)
    local domain = {}
    local jump_pointer
    local tag, offset, label
    while true do
        tag, nbyte = unpack(">B", chunk, nbyte)
        if tag & 0xc0 == 0xc0 then
            offset,nbyte = unpack(">H", chunk, nbyte - 1)
            offset = offset & 0x3fff
            if not jump_pointer then
                jump_pointer = nbyte
            end
            nbyte = offset + 1
        elseif tag == 0 then
            break
        else
            label, nbyte = unpack("s1", chunk, nbyte - 1)
            domain[#domain+1] = label
        end
    end
    return concat(domain, "."), jump_pointer or nbyte
end

local function unpack_question(chunk, nbyte)
    local name, nbyte = unpack_name(chunk, nbyte)
    local atype, aclass, nbyte = unpack(">HH", chunk, nbyte)
    return {atype = atype, aclass = aclass, name = name}, nbyte
end

local function unpack_answer(chunk, nbyte)
    local name, nbyte = unpack_name(chunk, nbyte)
    local atype, class, ttl, rdata, nbyte = unpack(">HHI4s2", chunk, nbyte)
    return { name = name, atype = atype, class = class, ttl = ttl, rdata = rdata }, nbyte
end

local function unpack_rdata(chunk)
    return fmt("%d.%d.%d.%d", unpack(">BBBB", chunk))
end


local cos = {}

local function dns_query(domain)
    -- 当前正在查询的协程不需要加入进去
    local wlist = {}
    cos[domain] = wlist
    -- local start = os.time() + os.clock()
    -- print("开始解析域名:["..domain.."], 开始时间: ", start)
    local header = pack_header()
    local question = pack_question(domain)
    local dns_client = get_dns_client()
    if not dns_client then
        return nil, "No dns client."
    end
    local dns_resp, len
    while 1 do   -- 如果一直没收到回应将会反复请求
        dns_client:send(header..question)
        dns_resp, len = dns_client:recv()
        if dns_resp then
            dns_client:close()
            dns_client = nil
            break
        end
        if type(len) == "string" then
            log.info("正在解析["..domain.."]:"..len)
        end
    end
    if not len or len < LIMIT_HEADER_LEN then
        local err = "Malformed dns response package."
        log.info("正在解析["..domain.."]:"..err)
        return nil, err
    end
    local answer_header, nbyte = unpack_header(dns_resp)
    if answer_header.qdcount ~= 1 then
        local err = "Malformed dns response package."
        return nil, err
    end
    if not answer_header.ancount or answer_header.ancount < 1 then
        local err = "Can't find ip addr in nameserver."
        log.info("正在解析["..domain.."]:"..err)
        return nil, err
    end
    local question, nbyte = unpack_question(dns_resp, nbyte)

    if question.name ~= domain then
        local err = "quetions not equal."
        log.info("正在解析["..domain.."]:"..err)
        return nil, err
    end
    local answer
    for i = 1, answer_header.ancount do
        answer, nbyte = unpack_answer(dns_resp, nbyte)
        answer.ip = unpack_rdata(answer.rdata)
        dns_cache[domain] = {ip = answer.ip, ttl = now() + answer.ttl}
    end
    local ip = answer.ip
    -- local e_n_d = os.time() + os.clock()
    -- print("解析域名["..domain.."]完成, 结束时间:", e_n_d)
    -- print("解析域名用时: ", tostring(e_n_d - start)..'s')
    -- 如果有其它协程也在等待查询, 那么一起唤醒它们
    if wlist and #wlist > 0 then
        for _, co in ipairs(wlist) do
            co_wakeup(co, true, ip)
        end
        wlist = nil
        cos[domain] = nil
    end
    return true, ip
end

function dns.flush()
    dns_cache = {}
    gen_cache()
end

-- 这里设置每个dns查询请求的timeout与retry时间
function dns.timeout(timeout)
    dns._timeout = timeout
end

function dns.resolve(domain)
    -- 如果是正确的ipv4地址直接返回
    local ok = check_ip(domain, 4)
    if ok then
        return ok, domain
    end
    -- 如果有dns缓存直接返回
    local ip = check_cache(domain)
    if ip then
        return true, ip
    end
    -- 如果有其他协程也正巧在查询这个域名, 那么就加入到等待列表内
    local wlist = cos[domain]
    if wlist then
        local co = co_self()
        insert(wlist, co)
        return co_wait()
    end
    return dns_query(domain)
end

return dns
