local resty_random = require "resty.random"
local str = require "resty.string"
local cjson = require "cjson"

local _M = {}


function _M.new(options)
  assert(options)
  assert(options["adapter"])
  assert(options["json_adapter"])

  return setmetatable(options, { __index = _M })
end

function _M.get_challenge(self, domain, path)
  return self.adapter:get(domain .. ":challenge:" .. path)
end

function _M.set_challenge(self, domain, path, value)
  return self.adapter:set(domain .. ":challenge:" .. path, value)
end

function _M.delete_challenge(self, domain, path)
  return self.adapter:delete(domain .. ":challenge:" .. path)
end

function _M.get_cert(self, domain)
  local json, err = self.adapter:get(domain .. ":latest")
  if err then
    return nil, err
  elseif not json then
    return nil
  end

  local data, json_err = self.json_adapter:decode(json)
  if json_err then
    return nil, json_err
  end

  return data
end

function _M.set_cert(self, domain, fullchain_pem, privkey_pem, cert_pem, expiry)
  -- Store the public certificate and private key as a single JSON string.
  --
  -- We use a single JSON string so that the storage adapter just has to store
  -- a single string (regardless of implementation), and we don't have to worry
  -- about race conditions with the public cert and private key being stored
  -- separately and getting out of sync.
  local string, err = self.json_adapter:encode({
    fullchain_pem = fullchain_pem,
    privkey_pem = privkey_pem,
    cert_pem = cert_pem,
    expiry = tonumber(expiry),
  })
  if err then
    return nil, err
  end

  -- Store the cert under the "latest" alias, which is what this app will use.
  return self.adapter:set(domain .. ":latest", string)
end

function _M.delete_cert(self, domain)
  return self.adapter:delete(domain .. ":latest")
end

function _M.all_cert_domains(self)
  local keys, err = self.adapter:keys_with_suffix(":latest")
  if err then
    return nil, err
  end

  local domains = {}
  for _, key in ipairs(keys) do
    local domain = ngx.re.sub(key, ":latest$", "", "jo")
    table.insert(domains, domain)
  end

  return domains
end

-- A simplistic locking mechanism to try and ensure the app doesn't try to
-- register multiple certificates for the same domain simultaneously.
--
-- This is used in conjunction with resty-lock for local in-memory locking in
-- resty/auto-ssl/ssl_certificate.lua. However, this lock uses the configured
-- storage adapter, so it can work across multiple nginx servers if the storage
-- adapter is something like redis.
--
-- This locking algorithm isn't perfect and probably has some race conditions,
-- but in combination with resty-lock, it should prevent the vast majority of
-- double requests.
function _M.issue_cert_lock(self, domain)
  local key = domain .. ":issue_cert_lock"
  local lock_rand_value = str.to_hex(resty_random.bytes(32))

  -- Wait up to 30 seconds for any existing locks to be unlocked.
  local unlocked = false
  local wait_time = 0
  local sleep_time = 0.5
  local max_time = 30
  repeat
    local existing_value = self.adapter:get(key)
    if not existing_value then
      unlocked = true
    else
      ngx.sleep(sleep_time)
      wait_time = wait_time + sleep_time
    end
  until unlocked or wait_time > max_time

  -- Create a new lock.
  local ok, err = self.adapter:set(key, lock_rand_value, { exptime = 30 })
  if not ok then
    return nil, err
  else
    return lock_rand_value
  end
end

function _M.issue_cert_unlock(self, domain, lock_rand_value)
  local key = domain .. ":issue_cert_lock"

  -- Remove the existing lock if it matches the expected value.
  local current_value, err = self.adapter:get(key)
  if lock_rand_value == current_value then
    return self.adapter:delete(key)
  elseif current_value then
    return false, "lock does not match expected value"
  else
    return false, err
  end
end

function _M.get_adapter_keys(self,suffix)
	return self.adapter:keys_with_suffix(suffix)
end

function _M.get_adapter_key(self,key,decode)
    local value, err = self.adapter:get(key)
	if not err and decode then
	  value = cjson.decode(value)
	end
	return value,err
end

function _M.get_adapter_key_main(self,key,decode)
	local value, err = self.adapter:get(key .. ":main")
	if not err and decode then
	  value = cjson.decode(value)
	end
	return value,err
end

 -- Gets a complete list of keys from the repository.
function _M.get_multiname_array(self)
   local result = {}
   local keys, err = self.get_adapter_keys(self,"main")
   if err then 
     ngx.log(ngx.ERR, "Multiname: storage: get_multiname_array: Error: ", err)
   else
     for t_key, t_value in pairs(keys) do
	   local key, err = self.get_adapter_key(self,t_value, true)
	   if err then
	      ngx.log(ngx.ERR, "Multiname: storage: get_multiname_array: Error: ", err)
       else
	      if key["domain"] ~= nil and key["subdomain"] ~= nil then
		    result[key["domain"]] = key["subdomain"]
		  end
	   end
	 end
   end
   return result
end

 -- Returns the existing certificate name or nil.
function _M.check_multiname(self, domain)
   local domains_array = self.get_multiname_array(self)
   for k, v in pairs(domains_array) do
	for existed_domain in string.gmatch(v, '([^:]+)') do
	  if existed_domain == domain then
		return k
	  end
	end
   end
   
   return nil
end

 -- Сhecks the certificate for the ability to add new domains.
function _M.validate_multiname(self, domain_array, new_domain)
   local domains_string = domain_array:gsub(':', '')
   
   local domains = 0
   for word in string.gmatch(domain_array, '([^:]+)') do
     domains = domains + 1
   end
   
   if not domains or domains > 100 then
     return nil
   end
   
   local check_len = 350 + domains_string:len() + new_domain:len() + (3 * domains)
   if check_len > 1900 then
     return nil
   end
   
   return true
end

function _M.create_multiname(self,domain)
    local data = cjson.encode({domain=domain,subdomain=domain})
    return self.adapter:set(domain .. ":main", data)
end

function _M.multiname_lock_set(self,domain)
    local data = cjson.encode({lock="locked"})
    return self.adapter:set(domain .. ":multiname_lock", data)
end

function _M.multiname_lock_get(self,domain)
    return self.adapter:get(domain .. ":multiname_lock")
end

function _M.multiname_lock_delete(self,domain)
	return self.adapter:delete(domain .. ":multiname_lock")
end

function _M.update_multiname(self,domain_cert_name,domain)
    local existed_data, err = self.get_adapter_key_main(self,domain_cert_name,true)
	if not err then
	  local name = existed_data["domain"]
	  local include = existed_data["subdomain"]
	  include = include .. ":" .. domain
	  local data = cjson.encode({domain=name,subdomain=include})
	  return self.adapter:set(domain_cert_name .. ":main", data)
	end
	
	return nil
end 

function _M.remove_multiname(self,domain_cert_name,domain)
    local existed_data, err = self.get_adapter_key_main(self,domain_cert_name,true)
	if not err then
	  local name = existed_data["domain"]
	  local include = existed_data["subdomain"]
	  
	  include = include:gsub(domain, '')
	  include = include:gsub('::', ':')
	  include = include:gsub('^:', '')
	  include = include:gsub(':$', '')
	  
	  local data = cjson.encode({domain=name,subdomain=include})
	  return self.adapter:set(domain_cert_name .. ":main", data)
	end
	
    return nil
end 

return _M